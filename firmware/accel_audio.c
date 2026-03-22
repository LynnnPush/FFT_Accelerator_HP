/*##########################################################################
###
### FFT Accelerator Firmware (v3 — SW twiddle preload)
###
###     Changes from baseline:
###       - Twiddle section in flash now contains N/2 global twiddle pairs
###         (was: log2(N) per-stage primitives).
###       - Firmware writes these twiddles to CSR registers iomem_accel[3..34]
###         BEFORE asserting enable — completely outside the timed window.
###       - SRAM stores ONLY input/output data (no twiddle offset).
###
###     Flash layout (produced by sound_util.py -> write_accel_io):
###       flash[0]                            = N_total  (= N_chunk * chunks)
###       flash[1]                            = number of chunks
###       flash[2 .. 2 + entries_per_chunk-1] = global twiddle table
###                 (re[0], im[0], re[1], im[1], ..., re[N/2-1], im[N/2-1])
###       flash[2 + entries_per_chunk .. end]  = sample data
###
###     CSR register map:
###       iomem_accel[0]  : Config & Status (reset/enable/done)
###       iomem_accel[1]  : Number of entries (N)
###       iomem_accel[2]  : Number of FFT stages (log2 N)
###       iomem_accel[3]  : {tw_im[0][15:0], tw_re[0][15:0]}   (packed)
###       iomem_accel[4]  : {tw_im[1][15:0], tw_re[1][15:0]}
###         ...
###       iomem_accel[18] : {tw_im[15][15:0], tw_re[15][15:0]}
###       MEM[0] starts at iomem_accel[19] = 0x0300_004C
###
###     TU Delft ET4351 - 2026 Project
###
##########################################################################*/

#include "uart.h"
#include "flash.h"
#include "fft.h"

/*--------------------------------------------------------------------------
    Accelerator CSR / memory address map
  --------------------------------------------------------------------------*/
#define ACCEL_BASE_ADDR             0x03000000

/* Configuration registers (word-addressed) */
#define REG_CONFIG_AND_STATUS       (*(volatile uint32_t*)(ACCEL_BASE_ADDR + 0*4))   /* 0x03000000 */
#define REG_NUMBER_OF_ENTRIES       (*(volatile uint32_t*)(ACCEL_BASE_ADDR + 1*4))   /* 0x03000004 */
#define REG_NUMBER_OF_BITS          (*(volatile uint32_t*)(ACCEL_BASE_ADDR + 2*4))   /* 0x03000008 */

/* Twiddle CSR registers start at word index 3 */
#define ACCEL_TW_CSR_START_ADDR     (ACCEL_BASE_ADDR + 3*4)                          /* 0x0300000C */

/* Number of config + twiddle CSR registers = 3 + N/2 = 3 + 16 = 19
 * (each twiddle CSR packs tw_re[15:0] in lower half, tw_im[15:0] in upper half) */
#define NUM_CSR_REGS                19

/* SRAM data region starts right after all CSR registers */
#define ACCEL_SRAM_START_ADDR       (ACCEL_BASE_ADDR + NUM_CSR_REGS * 4)             /* 0x0300004C */

/* CSR control/status bits */
#define MASK_CSR_RESET              (1 << 0)
#define MASK_CSR_ENABLE             (1 << 1)
#define MASK_CSR_DONE               (1 << 2)

/*--------------------------------------------------------------------------
    Helper: read one signed 32-bit integer from accelerator SRAM by index
  --------------------------------------------------------------------------*/
static int read_dec_entry_from_accelerator_sram(int index) {
    uint32_t sram_address = ACCEL_SRAM_START_ADDR + index * 4;
    return (*(volatile int*)(sram_address));
}

/*--------------------------------------------------------------------------
    Accelerated FFT routine
  --------------------------------------------------------------------------*/
static void accelerated_fft(int n, int chunks, int bits) {
    /* ================================================================
     *  Phase 0:  Initialise accelerator
     * ================================================================ */
    REG_CONFIG_AND_STATUS  = 0;
    REG_NUMBER_OF_ENTRIES  = 0;

    /* Pulse reset */
    REG_CONFIG_AND_STATUS = MASK_CSR_RESET;
    REG_CONFIG_AND_STATUS = 0;

    int entries_per_chunk = n / chunks;
    int half_n = entries_per_chunk / 2;     /* = N/2  (16 for N=32)         */
    int num_tw_values = 2 * half_n;         /* = N    (32 for N=32)         */

    /* Set configuration */
    REG_NUMBER_OF_ENTRIES = entries_per_chunk;
    REG_NUMBER_OF_BITS    = bits;

    /* ================================================================
     *  Phase 1:  Load twiddle factors from flash -> CSR registers
     *            (OUTSIDE the timed accelerator window)
     *
     *  Flash layout: [N_total, chunks, tw_re0, tw_im0, tw_re1, ...]
     *  Each CSR word packs one twiddle pair: {tw_im[15:0], tw_re[15:0]}
     * ================================================================ */
    int flash_offset = 2;   /* skip N_total and chunks at flash[0], flash[1] */

    for (int i = 0; i < half_n; i++) {
        uint32_t tw_re = (uint32_t)read_dec_entry_from_flash(flash_offset + 2*i)     & 0xFFFF;
        uint32_t tw_im = (uint32_t)read_dec_entry_from_flash(flash_offset + 2*i + 1) & 0xFFFF;
        uint32_t packed = (tw_im << 16) | tw_re;
        uint32_t csr_address = ACCEL_TW_CSR_START_ADDR + i * 4;
        (*(volatile uint32_t*)(csr_address)) = packed;
    }
    flash_offset += num_tw_values;

    /* ================================================================
     *  Phase 2:  Process each chunk
     * ================================================================ */
    for (int chunk = 0; chunk < chunks; chunk++) {

        /* --- Reset accelerator for this chunk --- */
        REG_CONFIG_AND_STATUS = MASK_CSR_RESET;
        REG_CONFIG_AND_STATUS = 0;

        /* --- Write input data to SRAM (bit-reversed order) ---
         * SRAM data layout: re[0], im[0], re[1], im[1], ...
         * Data starts at SRAM index 0 (no twiddle offset in SRAM).
         */
        for (int i = 0; i < entries_per_chunk; i++) {
            uint32_t sram_address = ACCEL_SRAM_START_ADDR + (2 * i) * 4;

            int bit_reverse_i = bit_reverse(i, bits);
            (*(volatile int*)(sram_address)) = read_dec_entry_from_flash(flash_offset + bit_reverse_i);

            /* Imaginary part = 0  (real-valued input) */
            sram_address += 4;
            (*(volatile int*)(sram_address)) = 0;
        }

        /* --- Enable accelerator (starts timed window) --- */
        REG_CONFIG_AND_STATUS |= MASK_CSR_ENABLE;

        /* --- Wait for completion --- */
        while (!(REG_CONFIG_AND_STATUS & MASK_CSR_DONE)) { }

        /* --- Disable accelerator --- */
        REG_CONFIG_AND_STATUS &= ~MASK_CSR_ENABLE;

        /* Advance flash pointer to next chunk's samples */
        flash_offset += entries_per_chunk;

        /* --- Read results from SRAM and print --- */
        for (int i = 0; i < entries_per_chunk; i++) {
            int real = read_dec_entry_from_accelerator_sram(2 * i);
            int imag = read_dec_entry_from_accelerator_sram(2 * i + 1);

            print_str("  ");
            print_dec(real);
            print_str(" + ");
            print_dec(imag);
            print_str("j,\n");
        }
    }
}

/*--------------------------------------------------------------------------
    PicoSoC initialisation (SRAM clear + UART baud rate)
  --------------------------------------------------------------------------*/
#define SRAM_ADDR_HEAD 0x00000000
#define SRAM_ADDR_END  0x000003FF

static void init_picosoc(void) {
    /* Zero SRAM — required for post-synthesis/layout simulation */
    volatile uint32_t* sram_addr = 0x00000000;
    for (sram_addr = 0; sram_addr <= (volatile uint32_t*) SRAM_ADDR_END; sram_addr += 4) {
        *sram_addr = 0;
    }

    /* Set UART baud rate */
    init_uart();
}

/*--------------------------------------------------------------------------
    Main entry point
  --------------------------------------------------------------------------*/
void main(void) {
    /* Initialise PicoSoC (SRAM + UART) */
    init_picosoc();

    /* Read N_total and number of chunks from flash */
    int n      = read_dec_entry_from_flash(0);
    int chunks = read_dec_entry_from_flash(1);

    /* Compute bits = log2(N_chunk) */
    int entries_per_chunk = n / chunks;
    int bits = 0;
    {
        int tmp = entries_per_chunk;
        while (tmp > 1) { tmp >>= 1; bits++; }
    }

    print_str("\nFrequency domain output: \n[\n");

    /* Run accelerated FFT */
    accelerated_fft(n, chunks, bits);

    print_str("]\n");

    /* Signal end of program to testbench */
    print_char(-1);
}

/*--------------------------------------------------------------------------
    Entry point — placed in .text.start so the linkerscript puts it at
    the reset vector (0x00100000).
  --------------------------------------------------------------------------*/
__attribute__((section(".text.start")))
void _start(void) {
    main();
}
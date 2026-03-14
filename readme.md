# ET4351 Digital VLSI Design — FFT Accelerator (Baseline Branch)

**TU Delft — ET4351 Digital VLSI Design, 2026 Project**

This repository contains the baseline implementation of an FFT (Fast Fourier Transform) hardware accelerator integrated into a PicoRV32 RISC-V System-on-Chip (PicoSoC). The accelerator implements the iterative, in-place Cooley–Tukey Decimation-in-Time FFT algorithm as a Moore FSM in Verilog, targeting 32-point FFTs on audio signal chunks stored in external flash memory.

The design is synthesized using **Cadence Genus** and physically implemented with **Cadence Innovus**, targeting the **SAED32/GPDK045** 45nm technology library. Behavioral, structural (post-synthesis), and physical (post-layout) simulations are run via **QuestaSim**.

---

## Repository Structure

```
.
├── firmware/               # C firmware & data generation scripts
│   ├── accel_audio.c       # Main firmware: drives the FFT accelerator
│   ├── fft.c / fft.h       # Software FFT (golden reference)
│   ├── fft.py              # Python FFT library (twiddle generation, bit-exact model)
│   ├── prepare_fft.py      # Generates fft_data.hex from audio samples
│   ├── sound_util.py       # Audio processing, hex writing, verification helpers
│   ├── uart.c / uart.h     # UART driver for PicoSoC
│   ├── flash.c / flash.h   # Flash memory read routines
│   ├── linkerscript.ld     # RISC-V linker script
│   ├── Makefile             # Cross-compilation (riscv32-unknown-elf-gcc)
│   ├── count_bytes_in_hex_file.py
│   └── expected_output.txt  # Golden FFT output for verification
│
├── src/
│   ├── design/
│   │   ├── et4351.v         # Top-level chip module
│   │   ├── picosoc.v        # PicoSoC: PicoRV32 + SRAM + UART + SPI flash
│   │   ├── picorv32.v       # PicoRV32 RISC-V CPU core (RV32IMC)
│   │   ├── accelerator.v    # Accelerator wrapper (CSR interface + memory mux)
│   │   ├── accelerator_fft.v# FFT datapath FSM
│   │   ├── accelerator_mem.v# Accelerator internal SRAM (128 words)
│   │   ├── spimemio.v       # SPI flash memory I/O controller
│   │   └── simpleuart.v     # Simple UART peripheral
│   ├── testbench/
│   │   ├── tb_et4351.sv     # Top-level SystemVerilog testbench
│   │   └── spiflash.v       # SPI flash simulation model
│   └── sdc/
│       └── et4351.sdc       # Synopsys Design Constraints (clock, I/O timing)
│
├── sim_behav/              # Behavioral (RTL) simulation
│   ├── run_behav_sim.sh
│   └── scripts/
│
├── sim_struct/             # Post-synthesis (structural) simulation
│   ├── run_struct_sim.sh
│   ├── run_struct_sim_vcd.sh
│   └── scripts/
│
├── sim_phys/               # Post-layout (physical) simulation
│   ├── run_pnr_sim_setup_max.sh
│   ├── run_pnr_sim_hold_min.sh
│   └── scripts/
│
├── synth/                  # Cadence Genus synthesis
│   ├── run_synth.sh
│   └── scripts/
│       ├── synth_set.tcl    # Technology & library settings
│       ├── synth_elb.tcl    # Elaboration (no clock gating)
│       ├── synth_elbcg.tcl  # Elaboration (with clock gating)
│       └── ...              # Mapping, optimization, report scripts
│
├── pnr/                    # Cadence Innovus place-and-route
│   ├── run_pnr.sh
│   └── scripts/
│       ├── 1.settings.tcl   # Technology & library setup
│       ├── 2.init.tcl       # Design import
│       ├── 3.fplan.tcl      # Floorplanning & SRAM placement
│       ├── 4.pplan.tcl      # Power planning (rings, stripes)
│       ├── 5.place.tcl      # Placement
│       ├── 6.cts.tcl        # Clock tree synthesis
│       ├── 7.route.tcl      # Routing
│       └── 8.verify.tcl     # DRC, LVS, antenna checks
│
├── sw/
│   ├── verify.py            # Verification script (compares sim output to golden)
│   └── sound_util.py        # Audio processing & hex generation utilities
│
├── setup.sh                # Environment setup (EDA tool paths)
└── run_all.sh              # End-to-end automation script
```

---

## System Architecture

The top-level module `et4351` instantiates:

1. **PicoSoC** (`picosoc.v`) — a lightweight SoC containing the PicoRV32 RISC-V CPU (RV32IMC ISA), 1 KB on-chip SRAM (4× SRAM1RW256x8), UART, and QSPI flash controller.
2. **FFT Accelerator** (`accelerator.v` + `accelerator_fft.v` + `accelerator_mem.v`) — a memory-mapped peripheral at address `0x0300_0000` with CSR registers and a 128-word internal SRAM.

### Memory Map

| Address | Description |
|---|---|
| `0x0000_0000 – 0x0000_03FF` | On-chip SRAM (1 KB) |
| `0x0010_0000 – 0x004F_FFFF` | External SPI Flash (4 MB) |
| `0x0200_0000` | QSPI config register |
| `0x0200_0004` | UART clock divider |
| `0x0200_0008` | UART data register |
| `0x0300_0000` | Accelerator CSR (Config & Status) |
| `0x0300_0004` | Accelerator: Number of entries (N) |
| `0x0300_0008` | Accelerator: Number of FFT stages |
| `0x0300_000C` | Accelerator: GPIO |
| `0x0300_0010+` | Accelerator internal memory (MEM[0..127]) |

### Accelerator CSR Bit Map (`0x0300_0000`)

| Bits | Field | Description |
|---|---|---|
| `[0]` | Reset | Active-high reset for accelerator |
| `[1]` | Enable | Active-high enable to start FFT |
| `[2]` | Done | Status flag — set when FFT completes |
| `[31:3]` | — | User-defined (available for extensions) |

---

## FFT Algorithm

The accelerator implements a **32-point in-place Cooley–Tukey DIT FFT** using Q12 fixed-point arithmetic. The baseline FSM walks through 13 states per butterfly operation: reading twiddle factors from SRAM, reading two data points, computing the butterfly (complex multiply + add/subtract), and writing back results.

Key parameters:
- **N** = 32 (samples per FFT chunk)
- **Stages** = 5 (log₂ 32)
- **Fixed-point scale** = Q12 (12 fractional bits)
- **Baseline cycle count** = 732 cycles per chunk (all memory accesses serialized)
- **Clock period** = 83.33 ns (≈12 MHz) as defined in `et4351.sdc`

---

## Prerequisites

The project targets a university compute server with the following EDA tools and toolchains pre-installed:

- **Cadence Genus** — Logic synthesis
- **Cadence Innovus** — Place and route
- **QuestaSim** (Siemens EDA) — RTL and gate-level simulation
- **RISC-V GCC toolchain** (`riscv32-unknown-elf-gcc`, RV32IMC) — Firmware cross-compilation
- **Python 3** with `numpy` and `scipy` — Data generation and verification

---

## Design Flow

The project follows a standard ASIC design flow, automated end-to-end by `run_all.sh`. The flow consists of the following stages:

1. **Firmware compilation** — The RISC-V cross-compiler builds `accel_audio.c` into a hex image. A Python script (`prepare_fft.py`) generates the input data hex and golden-reference expected output.
2. **Behavioral simulation** — QuestaSim runs the RTL design with the full firmware, and `verify.py` checks the UART output against the golden reference.
3. **Synthesis** — Cadence Genus maps the RTL to a gate-level netlist using the SAED32/GPDK045 standard cell and SRAM libraries, producing a structural Verilog netlist and SDF timing file.
4. **Structural simulation** — Post-synthesis gate-level simulation with SDF back-annotation to verify functional correctness after technology mapping.
5. **Place and route** — Cadence Innovus performs floorplanning, SRAM macro placement, power planning, cell placement, clock tree synthesis, and routing, producing the physical netlist and SDF.
6. **Physical simulation** — Post-layout simulation at both setup/max and hold/min corners to verify timing closure.

Each stage can also be run independently via shell scripts in the corresponding directory (`sim_behav/`, `synth/`, `sim_struct/`, `pnr/`, `sim_phys/`).

> **Note:** Reproducing this flow requires access to the licensed EDA tools and the SAED32 technology library. The repository is published primarily as a portfolio reference for the design work.

---

## Verification

The verification script `sw/verify.py` compares simulation output against the golden reference. It parses the frequency-domain output printed by the testbench (`outputs.txt`), checks each complex value against `firmware/expected_output.txt`, and on success reconstructs a `.wav` audio file from the FFT results.

---

## Data Flow

1. **`sound_util.py`** generates a melody composed of E-major scale tones with injected noise at 14 Hz and 15 Hz, sampled at a simulated 44.1 kHz rate and chunked into 32-sample blocks.
2. **`prepare_fft.py`** quantizes the audio to Q12 fixed-point, prepends a global twiddle table (N/2 entries), and writes everything to `fft_data.hex` starting at flash address `0x004F0000`. It also runs the Python FFT to produce `expected_output.txt`.
3. **Firmware** (`accel_audio.c`) runs on PicoRV32, loads twiddle factors and data from flash into the accelerator's CSR registers and SRAM, triggers the hardware FFT, reads back results, and prints them over UART.
4. **Testbench** (`tb_et4351.sv`) captures UART output to `outputs.txt` for verification.

---

## Key Design Files

| File | Role |
|---|---|
| `src/design/accelerator_fft.v` | FFT datapath and FSM — core compute engine |
| `src/design/accelerator.v` | CSR interface, memory mux, accelerator wrapper |
| `src/design/accelerator_mem.v` | Internal SRAM instantiation |
| `firmware/accel_audio.c` | Firmware that orchestrates data movement and accelerator control |
| `firmware/fft.py` | Python golden-reference FFT (bit-exact with hardware) |
| `src/sdc/et4351.sdc` | Timing constraints (clock period, I/O delays) |

---

## Design Notes

- The baseline FSM serializes all memory accesses (one read/write per cycle), resulting in **732 cycles per 32-point FFT chunk**. LOAD and STORE phases dominate at ~67% of total cycles, making memory bandwidth the primary bottleneck for optimization.
- Fixed-point arithmetic uses **Q12 format** (12 fractional bits). Twiddle factors are quantized from floating-point, and complex multiplication results are right-shifted by 12 bits.
- The testbench clock period is **83.33 ns** (≈12 MHz) and must match the SDC constraints in `et4351.sdc`.
- The firmware hex includes configurable chunking via the `N_CHUNKS` build variable: the default produces 24 chunks for behavioral simulation, while single-chunk builds are used for faster gate-level simulations.

---

## Authors & Acknowledgments

Course staff and contributors across multiple years:

- **May 2023**: Chang Gao, Charlotte Frenkel — Original baseline (counter accelerator)
- **April 2024**: Nicolas Chauvaux, Douwe den Blanken — Sorting accelerator + memory interface
- **Jan 2025**: Ang Li, Yizhuo Wu — Pathfinding accelerator
- **Jan 2026**: Nicolas Chauvaux, Douwe den Blanken, Guilherme Guedes — FFT accelerator baseline

PicoRV32 and PicoSoC by Claire Xenia Wolf ([YosysHQ/picorv32](https://github.com/YosysHQ/picorv32)).

---

## License

This project is provided for educational use within the TU Delft ET4351 course. The PicoRV32/PicoSoC components are distributed under the ISC license (see source headers).
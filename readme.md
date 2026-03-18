# ET4351 Digital VLSI Design — FFT Accelerator

**TU Delft — ET4351 Digital VLSI Design, 2026 Project**

A high-performance 32-point FFT hardware accelerator integrated into a PicoRV32 RISC-V SoC, targeting the SAED32 45nm technology library. The design combines five architectural optimisations to achieve a **~24× end-to-end latency reduction** over the baseline — from 61 µs down to ~2.5 µs per audio chunk.

For the general project structure, SoC architecture, design flow, and tooling, refer to the [README on the `baseline` branch](../../tree/baseline).

---

## Summary of Optimisations

| # | Optimisation | Effect |
|---|---|---|
| 1 | **Register-file datapath** | All 32 complex samples held in flip-flops. Eliminates per-butterfly SRAM reads/writes during compute — SRAM is accessed only during bulk LOAD and STORE phases. |
| 2 | **SW twiddle preload via CSR** | Firmware pre-computes 16 twiddle pairs (W^k\_32, k=0..15) and writes them to CSR registers before asserting enable. Removes all twiddle accesses from the timed window and reduces accelerator SRAM from 128→64 words. |
| 3 | **2× parallel butterfly units** | Two independent butterfly datapaths process two operations per cycle, halving the issue count per FFT stage from 16 to 8 cycles. |
| 4 | **4-stage micro-pipeline** | The butterfly datapath is split into FETCH → MUL1 → MUL2 → ADD stages. A new butterfly pair enters every clock cycle (1-throughput). Each FFT stage completes in 8 fetch + 3 drain = **11 cycles**. The pipeline also breaks the long combinational multiply-add chain, enabling much higher clock frequencies. |
| 5 | **Wide paired memory port** | A 64-bit paired SRAM interface reads/writes one complete complex sample (re + im) per cycle during LOAD and STORE phases, **halving the memory transfer time** from 128 to 64 cycles. |

Additionally, twiddle factors are stored as **16-bit Q12** values (narrowed from 32-bit data width), reducing multiplier input width and CSR area.

---

## Comparison with Baseline

| Metric | Baseline | This Design | Improvement |
|---|---|---|---|
| FSM states | 13 (per-element SRAM R/W) | 5 (`INIT → LOAD → COMPUTE → STORE → FINISH`) | Simplified control |
| Compute architecture | Single butterfly, fully combinational, all via SRAM | 2× parallel, 4-stage pipelined, register-file | 1-throughput pipeline |
| Twiddle source | Read from SRAM (inside timed window) | CSR registers (firmware preload before enable) | Zero twiddle load cycles |
| Memory interface | 32-bit single-port (1 word/cycle) | 32-bit narrow (CPU) + 64-bit wide paired (FFT) | 2 words/cycle during LOAD/STORE |
| SRAM depth | 128 words (data + twiddles) | 64 words (data only) | 50% SRAM reduction |
| Cycles per chunk (N=32) | 732 | **121** | **6.05× fewer cycles** |
| Synthesis-verified frequency | ~12 MHz | **48 MHz** (with margin for PnR) | **4× higher frequency** |
| Latency per chunk | ~61 µs | **~2.5 µs** | **~24× faster** |

The ~24× speedup comes from two independent and multiplicative axes: 6× fewer cycles **and** 4× higher clock frequency.

---

## Architecture

### Micro-Pipeline

The compute engine is a **4-stage pipeline** with 2× parallel butterfly lanes:

```
 Stage 0 (FETCH)  │ Stage 1 (MUL1)  │ Stage 2 (MUL2)  │ Stage 3 (ADD)
──────────────────┼─────────────────┼─────────────────┼──────────────────
 Comb: generate    │ rr = v_re×tw_re │ t_re = (rr-ii)  │ e = u + t
 bf0/bf1 indices   │ ii = v_im×tw_im │       >>> SCALE  │ o = u - t
 Latch: u, v, tw   │ ri = v_re×tw_im │ t_im = (ri+ir)  │ Write back to
 from regfile/CSR  │ ir = v_im×tw_re │       >>> SCALE  │ register file
```

A 3-bit shift register (`pipe_vld`) tracks valid data in flight. The pipeline pumps a new butterfly pair every cycle while `bf_cnt < N/2`. After the last fetch, 3 drain cycles flush the pipeline. Stage advancement is triggered on the **last drain cycle** — the same posedge where the final ADD/writeback completes — eliminating dead bubbles between FFT stages.

Per-stage cycle count for N=32: **8 fetch + 3 drain = 11 cycles**. Across 5 stages: **55 compute cycles**.

### Wide Paired Memory Port

The accelerator memory exposes two independent interfaces:

- **Narrow port** (32-bit, byte-enable): serves CPU reads/writes via the PicoRV32 `iomem` bus.
- **Wide port** (64-bit, pair-addressed): serves the FFT core during LOAD and STORE phases, reading/writing one complex pair (re + im) per cycle.

The two ports are mutually exclusive by protocol — the CPU writes data before asserting `enable_accel`; the FFT core operates after. No arbitration logic is needed. The design exploits the interleaved `[re[0], im[0], re[1], im[1], ...]` memory layout: a 5-bit `pair_addr` selects one of 32 complex pairs, producing two 32-bit words via **32:1 mux trees** instead of two independent 64:1 trees.

This also **simplifies the wrapper**: the old shared CPU↔FFT address/data mux is eliminated entirely, with each path connecting directly to its respective memory port.

### Cycle Breakdown (N=32)

| Phase | Cycles | % of Total |
|---|---|---|
| INIT | 1 | 0.8% |
| LOAD_DATA | 32 | 26.4% |
| COMPUTE | 55 | 45.5% |
| STORE_DATA | 32 | 26.4% |
| FINISH | 1 | 0.8% |
| **Total** | **121** | **100%** |

For the first time, COMPUTE (45.5%) is the **dominant phase**, overtaking LOAD+STORE (52.9%). In the baseline, memory transfers accounted for ~88% of total cycles. Further cycle reduction now requires either wider memory (W=4) or more butterfly parallelism (P=4).

---

## Synthesis Results (Genus, SAED32 45nm)

**Target:** 48 MHz (20.83 ns) &ensp;|&ensp; **Corner:** PVT\_0P9V\_125C (slow) &ensp;|&ensp; **Clock uncertainty:** 250 ps

### Area

| Module | Cell Count | Cell Area (µm²) | Net Area (µm²) | Total Area (µm²) |
|---|---|---|---|---|
| **et4351 (top)** | 57,809 | 223,229 | 76,390 | **299,619** |
| accelerator | 44,965 | 146,864 | 60,113 | 206,976 |
| &emsp;fft | 29,258 | 92,556 | 39,604 | 132,160 |
| &emsp;mem (64-deep) | 10,780 | 37,280 | 14,384 | 51,664 |
| picosoc | 12,837 | 76,318 | 16,049 | 92,367 |

Total SoC area is **299,619 µm²**, well within the 596 × 596 µm = **355,362 µm² core budget** (84.3% utilisation).

### Timing

All 10 worst paths are in the **SPI flash → PicoRV32 interface**, not in the accelerator or its memory. Worst slack is **+3,418 ps** — timing is met with substantial margin. The wide memory port's 32:1 mux trees do not appear anywhere in the critical path, confirming that the paired-address scheme is not a timing concern at 48 MHz.

---

## Modified Memory Map

| Address | Register | Description |
|---|---|---|
| `0x0300_0000` | `iomem_accel[0]` | Config & Status (reset / enable / done) |
| `0x0300_0004` | `iomem_accel[1]` | Number of entries (N) |
| `0x0300_0008` | `iomem_accel[2]` | Number of FFT stages (log₂ N) |
| `0x0300_000C – 0x0300_0088` | `iomem_accel[3..34]` | 16 twiddle pairs (tw\_re[k], tw\_im[k], k=0..15) |
| `0x0300_008C+` | `MEM[0..63]` | SRAM data region (64 words, re/im interleaved) |

The wrapper packs the 32 twiddle CSR words into flat buses (`tw_re_packed`, `tw_im_packed`) via a generate block, giving the FFT core combinational access to any twiddle by index.

---

## Key Design Files

| File | Role |
|---|---|
| `src/design/accelerator_fft.v` | FFT core: register-file, 2× parallel, 4-stage pipeline, wide memory interface |
| `src/design/accelerator.v` | Wrapper: 35-register CSR array, twiddle bus packing, dual-port memory routing |
| `src/design/accelerator_mem.v` | Dual-interface SRAM: 32-bit narrow (CPU) + 64-bit wide paired (FFT) |
| `firmware/accel_audio.c` | Firmware: CSR twiddle preload, data orchestration |
| `firmware/fft.py` | Python golden-reference FFT with global twiddle table |
| `src/sdc/et4351.sdc` | Timing constraints (48 MHz target, 250 ps clock uncertainty) |

---

## Design Notes

- **Two independent speedup axes.** Cycle count reduction (732→121) and clock frequency increase (~12→48 MHz) are orthogonal improvements that multiply together for the ~24× overall latency reduction. The HP target has no clock frequency constraint — any valid combination works.
- **Memory bandwidth was the binding constraint.** In the baseline, SRAM reads/writes consumed ~88% of cycles. The wide paired memory port halves the transfer time, while the register-file architecture confines SRAM access to bulk LOAD/STORE phases.
- **Zero-bubble stage transitions.** The pipeline advance condition (`pipe_last_drain`) fires on the same posedge as the last ADD/writeback. This eliminates the dead cycle that would otherwise occur between consecutive FFT stages, saving 5 cycles total (1 per stage).
- **16-bit twiddle factors.** Narrowing twiddles from 32-bit to 16-bit reduces multiplier input width (32×16 instead of 32×32), saving area on the 8 multipliers per butterfly pair (16 total). Q12 precision is preserved since twiddle values never exceed ±1.0 in magnitude.
- **Synthesis constraint rationale.** The 48 MHz target (4× baseline) is chosen to leave sufficient timing margin (~3.4 ns worst slack) for place-and-route wire delays. Prior experiments showed that even ~1.3 ns synthesis slack can result in setup violations after PnR without further optimisation passes.
- **Drop-in compatible interface.** The CPU-facing interface (memory map, CSR layout, `iomem` handshake) is a strict superset of the baseline. The firmware (`accel_audio.c`) and verification scripts work without modification.

---

## Authors & Acknowledgments

Course staff and contributors across multiple years:

- **May 2023**: Chang Gao, Charlotte Frenkel — Original baseline (counter accelerator)
- **April 2024**: Nicolas Chauvaux, Douwe den Blanken — Sorting accelerator + memory interface
- **Jan 2025**: Ang Li, Yizhuo Wu — Pathfinding accelerator
- **Jan 2026**: Nicolas Chauvaux, Douwe den Blanken, Guilherme Guedes — FFT accelerator baseline

PicoRV32 and PicoSoC by Claire Xenia Wolf ([YosysHQ/picorv32](https://github.com/YosysHQ/picorv32)).

HP accelerator optimisations (register-file, twiddle preload, parallel butterflies, micro-pipeline, wide memory port) by the HP RTL architecture team.

---

## License

This project is provided for educational use within the TU Delft ET4351 course. The PicoRV32/PicoSoC components are distributed under the ISC license (see source headers).
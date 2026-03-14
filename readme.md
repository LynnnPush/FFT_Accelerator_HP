# ET4351 Digital VLSI Design — FFT Accelerator
**TU Delft — ET4351 Digital VLSI Design, 2026 Project**

This is the **default branch** of the repository. It implements a heavily optimised FFT accelerator that combines four architectural improvements over the baseline: a register-file datapath, SW-driven twiddle preload via CSR registers, 2× parallel butterfly units, and a **4-stage micro-pipelined compute engine** that achieves 1-throughput (one butterfly pair per clock cycle).

The micro-pipeline also shortens the critical path significantly, enabling up to **5× higher clock frequency** compared to the baseline. Combined with the cycle count reduction, this yields an overall **~20× speedup** in single-chunk FFT latency.

For the general project structure, SoC architecture, design flow, and tooling, refer to the [README on the `baseline` branch](../../tree/baseline).

---

## Summary of Optimisations

| # | Optimisation | Effect |
|---|---|---|
| 1 | **Register-file datapath** | All 32 complex values held in flip-flops. Eliminates per-butterfly SRAM reads/writes during compute — SRAM is accessed only during bulk LOAD and STORE phases. |
| 2 | **SW twiddle preload via CSR** | Firmware writes 16 twiddle pairs (W^k_32, k=0..15) to CSR registers before asserting enable. Removes all twiddle SRAM accesses from the timed window and reduces accelerator SRAM from 128→64 words. |
| 3 | **2× parallel butterfly units** | Two independent butterfly datapaths process two operations per cycle, halving the butterfly count per stage from 16 to 8 issue cycles. |
| 4 | **4-stage micro-pipeline** | The butterfly datapath is pipelined into FETCH → MUL1 → MUL2 → ADD stages. A new butterfly pair is issued every clock cycle (1-throughput). Each FFT stage completes in 8 fetch + 3 pipeline drain = **11 cycles**. The pipeline also breaks the long combinational multiply-add chain, enabling much higher clock frequencies. |

Additionally, twiddle factors are stored as **16-bit Q12** values (narrowed from 32-bit data width), reducing the CSR and multiplier area.

---

## Comparison with Baseline

| Metric | Baseline | This Branch | Improvement |
|---|---|---|---|
| FSM states | 13 (per-element SRAM R/W) | 5 (`INIT → LOAD_DATA → COMPUTE → STORE_DATA → FINISH`) | Simplified control |
| Compute architecture | Single butterfly, combinational, all via SRAM | 2× parallel, 4-stage pipelined, register-file | 1-throughput pipeline |
| Twiddle source | Read from SRAM (inside timed window) | CSR registers (written by firmware before enable) | Zero twiddle load cycles |
| Twiddle width | 32-bit | 16-bit (Q12) | ~50% narrower multipliers |
| SRAM depth | 128 words (data + twiddles) | 64 words (data only) | 50% SRAM reduction |
| Cycles per chunk (N=32) | 732 | 185 | **3.96× fewer cycles** |
| Max clock frequency | ~12 MHz (limited by combinational butterfly) | **~60 MHz** (pipelined critical path) | **~5× higher frequency** |
| Latency per chunk | ~61 µs | **~3.1 µs** | **~20× faster** |

The ~20× speedup comes from two independent axes: nearly 4× fewer cycles **and** ~5× higher achievable clock frequency due to the micro-pipelined datapath. These multiply rather than add.

---

## Micro-Pipeline Architecture

The compute engine is a **4-stage pipeline** with 2× parallel butterfly lanes:

```
 Stage 0 (FETCH)  │ Stage 1 (MUL1)  │ Stage 2 (MUL2)  │ Stage 3 (ADD)
──────────────────┼─────────────────┼─────────────────┼──────────────────
 Comb: generate    │ rr = v_re×tw_re │ t_re = (rr-ii)  │ e = u + t
 bf0/bf1 indices   │ ii = v_im×tw_im │       >>> SCALE  │ o = u - t
 Latch: u, v, tw   │ ri = v_re×tw_im │ t_im = (ri+ir)  │ Write back to
 from regfile/CSR  │ ir = v_im×tw_re │       >>> SCALE  │ register file
```

A 3-bit shift register (`pipe_vld`) tracks valid data in flight. The pipeline **pumps** a new butterfly pair every cycle while `bf_cnt < N/2`. After the last fetch, 3 drain cycles flush the pipeline. Stage advancement is triggered on the **last drain cycle** — the same posedge where the final ADD/writeback completes — eliminating dead bubbles between FFT stages.

Per-stage cycle count for N=32: **8 fetch + 3 drain = 11 cycles**. Across 5 stages: **55 compute cycles**.

### Why Pipelining Enables Higher Frequency

The baseline computes the full butterfly in a single combinational path: two 32×32-bit complex multiplications followed by add/subtract. This creates a long critical path that limits clock frequency to ~12 MHz.

By splitting this into 4 registered stages (operand fetch → raw multiply → scale/reduce → final add), each stage contains roughly 1/4 of the combinational logic. Synthesis can meet timing at much tighter clock periods — empirically up to ~5× the baseline frequency.

---

## Cycle Breakdown (N=32)

| Phase | Cycles | % of Total |
|---|---|---|
| INIT | 1 | 0.5% |
| LOAD_DATA | 64 | 34.6% |
| COMPUTE | 55 | 29.7% |
| STORE_DATA | 64 | 34.6% |
| FINISH | 1 | 0.5% |
| **Total** | **185** | **100%** |

LOAD + STORE accounts for ~69% of total cycles. **Memory bandwidth remains the binding constraint** — further compute optimisation yields diminishing returns without wider or dual-ported SRAM.

---

## Modified Memory Map

The CSR interface is extended from 4 registers (baseline) to 35 registers to hold the twiddle table:

| Address | Register | Description |
|---|---|---|
| `0x0300_0000` | `iomem_accel[0]` | Config & Status (reset / enable / done) |
| `0x0300_0004` | `iomem_accel[1]` | Number of entries (N) |
| `0x0300_0008` | `iomem_accel[2]` | Number of FFT stages (log₂ N) |
| `0x0300_000C – 0x0300_0088` | `iomem_accel[3..34]` | 16 twiddle pairs (tw_re[k], tw_im[k], k=0..15) |
| `0x0300_008C+` | `MEM[0..63]` | SRAM data region (64 words, re/im interleaved) |

The wrapper (`accelerator.v`) packs the 32 twiddle CSR words into flat buses (`tw_re_packed`, `tw_im_packed`) via a generate block, giving the FFT core combinational access to any twiddle by index.

---

## Firmware Changes

The firmware (`accel_audio.c`) differs from baseline in two key ways:

1. **Twiddle preload phase** — Before the timed accelerator window, firmware reads 16 twiddle pairs from flash and writes them to CSR registers `iomem_accel[3..34]`. This is a one-time cost per audio stream, amortised across all chunks.

2. **Simplified data layout** — SRAM stores only input/output data (64 words). The flash data section prepends a global twiddle table (16 pairs quantised once from float to Q12) instead of the baseline's per-stage primitives.

---

## Python Golden Reference

`fft.py` uses a **global twiddle table** with direct indexing (`tw_idx = k_loc << (bits - stage)`), matching the hardware's twiddle access pattern exactly. Each twiddle is quantised once from full-precision float to Q12, avoiding accumulated rounding from chained multiplications. This provides both the best fixed-point accuracy and bit-exact verification against the hardware.

---

## Key Design Files

| File | Role |
|---|---|
| `src/design/accelerator_fft.v` | FFT core: register-file, 2× parallel, 4-stage pipelined datapath |
| `src/design/accelerator.v` | Wrapper: 35-register CSR array, twiddle bus packing, memory mux |
| `src/design/accelerator_mem.v` | Internal SRAM (64 words, data only) |
| `firmware/accel_audio.c` | Firmware: CSR twiddle preload, data orchestration |
| `firmware/fft.py` | Python golden-reference FFT with global twiddle table |
| `src/sdc/et4351.sdc` | Timing constraints |

---

## Design Notes

- **Two independent speedup axes.** Cycle count reduction (732→185) and clock frequency increase (~12→60 MHz) are orthogonal improvements that multiply together for the ~20× overall latency reduction. The HP target has no clock frequency constraint — any valid combination works.
- **Memory bandwidth is the binding constraint.** LOAD+STORE is ~69% of total cycles. Compute is already pipelined at 1-throughput with P=2. Going to P=4 butterfly units would only save ~27 compute cycles but adds significant area, while the 128-cycle SRAM transfer remains fixed without wider or multi-ported memory.
- **Zero-bubble stage transitions.** The stage advance condition (`pipe_last_drain`) fires on the same posedge as the last ADD/writeback. This eliminates the dead cycle that would otherwise occur between consecutive FFT stages, saving 5 cycles total (1 per stage).
- **16-bit twiddle factors.** Narrowing twiddles from 32-bit to 16-bit reduces multiplier input width (32×16 instead of 32×32), saving area on the 4 multipliers per butterfly lane (16 total). Q12 precision is preserved since the twiddle values never exceed ±1.0 in magnitude.
- **Drop-in compatible interface.** The CSR + SRAM memory map is a strict superset of the baseline. The same `iomem_valid`/`iomem_ready` handshake and address decoding logic are used.

---

## Authors & Acknowledgments

Course staff and contributors across multiple years:

- **May 2023**: Chang Gao, Charlotte Frenkel — Original baseline (counter accelerator)
- **April 2024**: Nicolas Chauvaux, Douwe den Blanken — Sorting accelerator + memory interface
- **Jan 2025**: Ang Li, Yizhuo Wu — Pathfinding accelerator
- **Jan 2026**: Nicolas Chauvaux, Douwe den Blanken, Guilherme Guedes — FFT accelerator baseline

PicoRV32 and PicoSoC by Claire Xenia Wolf ([YosysHQ/picorv32](https://github.com/YosysHQ/picorv32)).

HP accelerator optimisations (register-file, twiddle preload, parallel butterflies, micro-pipeline) by the HP RTL architecture team.

---

## License

This project is provided for educational use within the TU Delft ET4351 course. The PicoRV32/PicoSoC components are distributed under the ISC license (see source headers).
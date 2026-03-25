"""
algorithm_comparison.py — Compare main (global-twiddle) vs baseline (chained-twiddle)
FFT algorithms in terms of precision loss, computational cost, and end-to-end accuracy.

Both algorithms use Q12 fixed-point scaling, so both are compared against an
unscaled (double-precision float) ground truth to measure the effect of each
scaling/twiddle strategy on precision.

Run:
    cd sw && python algorithm_comparison.py

TU Delft ET4351 — 2026 Project
"""

import sys
import os
import math
import cmath
from typing import List

_sw_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _sw_dir)
sys.path.insert(0, os.path.join(_sw_dir, '..', 'firmware'))

import numpy as np
from scipy.fft import fftfreq

from sound_util import (
    generate_sound,
    downsample_to_32_samples,
    BASE_FREQS,
    SAMPLES_PER_CHUNK,
    SIM_FS,
)

# ── Configuration ────────────────────────────────────────────────────────────
SCALE = 12
N = 32

ORIGINAL_SEQUENCE = [
    (11, 1), (10, 1), (5, 2), (6, 2),
    (9, 1),  (8, 1),  (3, 2), (4, 2),
    (8, 1),  (7, 1),  (2, 2), (4, 2),
    (7, 4),  (-1, 2),
]


# ── Shared helpers ───────────────────────────────────────────────────────────
def flog2(x):
    r = 0
    while x > 1:
        r += 1
        x >>= 1
    return r


def bit_reverse(i, bits):
    r = 0
    for _ in range(bits):
        r = (r << 1) | (i & 1)
        i >>= 1
    return r


def complex_mult_q12(a, b):
    """Q12 fixed-point complex multiply with arithmetic right-shift."""
    ar, ai = int(a.real), int(a.imag)
    br, bi = int(b.real), int(b.imag)
    return complex((ar * br - ai * bi) >> SCALE, (ar * bi + ai * br) >> SCALE)


# ── Twiddle table generators ────────────────────────────────────────────────
def make_global_twiddles(n):
    """Main branch: N/2 twiddles, each quantised once from float."""
    half = n // 2
    tw = []
    for k in range(half):
        angle = -2.0 * math.pi * k / n
        re = round(math.cos(angle) * (1 << SCALE))
        im = round(math.sin(angle) * (1 << SCALE))
        tw.append(complex(re, im))
    return tw


def make_per_stage_twiddles(n):
    """Baseline: one principal twiddle per stage, quantised from float."""
    bits = flog2(n)
    tw = []
    for s in range(1, bits + 1):
        m = 1 << s
        W = cmath.exp(-2j * cmath.pi / m)
        tw.append(complex(round(W.real * (1 << SCALE)),
                          round(W.imag * (1 << SCALE))))
    return tw


# ── FFT implementations ─────────────────────────────────────────────────────
def fft_main(x_quant):
    """
    Main branch algorithm: global twiddle table, direct lookup.

    Twiddle for local index k in stage s:  tw_idx = k << (bits - s)
    No chained multiplication — each twiddle read directly from table.
    """
    n = len(x_quant)
    bits = flog2(n)
    twiddles = make_global_twiddles(n)
    mult_count = 0

    # Bit-reverse permutation
    X = [0j] * n
    for i in range(n):
        X[bit_reverse(i, bits)] = complex(x_quant[i], 0)

    # Butterfly stages
    for stage in range(1, bits + 1):
        m = 1 << stage
        half = m // 2
        stride = bits - stage

        for base in range(0, n, m):
            for k in range(half):
                tw_idx = k << stride
                t = complex_mult_q12(twiddles[tw_idx], X[base + k + half])
                mult_count += 1  # one complex multiply

                u = X[base + k]
                X[base + k]        = u + t
                X[base + k + half] = u - t

    return X, mult_count


def fft_baseline(x_quant):
    """
    Baseline algorithm: per-stage principal twiddle, chained multiplication.

    Each stage has one w_m. Within a group: w starts at 1 and is updated by
    w = w * w_m after each butterfly. This accumulates Q12 rounding error.
    """
    n = len(x_quant)
    bits = flog2(n)
    twiddles = make_per_stage_twiddles(n)
    mult_count = 0

    # Bit-reverse permutation
    X = [0j] * n
    for i in range(n):
        X[bit_reverse(i, bits)] = complex(x_quant[i], 0)

    # Butterfly stages
    for stage in range(1, bits + 1):
        m = 1 << stage
        half = m // 2
        w_m = twiddles[stage - 1]

        for base in range(0, n, m):
            w = complex(1 << SCALE, 0)

            for k in range(half):
                t = complex_mult_q12(w, X[base + k + half])
                mult_count += 1  # butterfly multiply

                u = X[base + k]
                X[base + k]        = u + t
                X[base + k + half] = u - t

                w = complex_mult_q12(w, w_m)
                mult_count += 1  # twiddle chain multiply

    return X, mult_count


# ── Ground truth: unscaled double-precision FFT ──────────────────────────────
def fft_ground_truth(x_float):
    """
    NumPy double-precision FFT on Q12-scaled input.

    This is the 'ideal' result: same quantised input as the fixed-point
    algorithms, but with infinite-precision arithmetic (no rounding in
    twiddles or intermediate products).
    """
    scaled = np.array(x_float) * (1 << SCALE)
    return np.fft.fft(scaled)


# ── Twiddle accuracy analysis ───────────────────────────────────────────────
def twiddle_accuracy_analysis():
    """
    Compare the twiddle factors themselves: how close is each algorithm's
    effective twiddle at every (stage, k) position to the true value?
    """
    bits = flog2(N)
    global_tw = make_global_twiddles(N)
    stage_tw = make_per_stage_twiddles(N)

    rows = []
    for stage in range(1, bits + 1):
        m = 1 << stage
        half = m // 2

        # Baseline: simulate the chained multiplication
        w_m = stage_tw[stage - 1]
        w = complex(1 << SCALE, 0)

        for k in range(half):
            # True twiddle (full precision, scaled to Q12 domain)
            true_angle = -2.0 * math.pi * k / m
            true_re = math.cos(true_angle) * (1 << SCALE)
            true_im = math.sin(true_angle) * (1 << SCALE)
            true_tw = complex(true_re, true_im)

            # Main: direct lookup
            tw_idx = k << (bits - stage)
            main_tw = global_tw[tw_idx]

            # Baseline: chained w
            baseline_tw = w

            # Errors vs true
            main_err = abs(main_tw - true_tw)
            baseline_err = abs(baseline_tw - true_tw)

            rows.append({
                'stage': stage, 'k': k,
                'true': true_tw,
                'main': main_tw, 'baseline': baseline_tw,
                'main_err': main_err, 'baseline_err': baseline_err,
            })

            w = complex_mult_q12(w, w_m)

    return rows


# ── Melody recovery ──────────────────────────────────────────────────────────
def recover_melody(spectrum_chunks):
    """Decode melody indices from FFT output chunks."""
    recovered = []
    for block in spectrum_chunks:
        freq_bins = fftfreq(SAMPLES_PER_CHUNK, 1 / SIM_FS)
        block = np.array(block, dtype=complex)

        # Notch out noise at 14 Hz and 15 Hz
        block[np.abs(np.abs(freq_bins) - 14) < 0.1] = 0
        block[np.abs(np.abs(freq_bins) - 15) < 0.1] = 0

        # IDFT -> time domain
        clean = np.fft.ifft(block).real

        # Decode melody index
        spec = np.fft.fft(clean)
        mag = np.abs(spec)[:SAMPLES_PER_CHUNK // 2]
        peak = np.argmax(mag)
        if mag[peak] < 0.5:
            recovered.append(-1)
        else:
            recovered.append(peak - 1)

    return recovered


# ── Main ─────────────────────────────────────────────────────────────────────
def main():
    # Generate test data
    expanded_seq, _, _ = generate_sound(ORIGINAL_SEQUENCE)
    sim_blocks = downsample_to_32_samples(expanded_seq)
    n_blocks = len(sim_blocks)
    ground_truth_indices = list(expanded_seq)

    print("=" * 78)
    print("  Algorithm Comparison: Main (Global Twiddle) vs Baseline (Chained Twiddle)")
    print("=" * 78)
    print(f"  FFT size       : {N} points")
    print(f"  Fixed-point    : Q{SCALE} ({SCALE}-bit fractional)")
    print(f"  Test data      : Nokia ringtone ({n_blocks} blocks of {SAMPLES_PER_CHUNK} samples)")
    print(f"  Ground truth   : NumPy double-precision FFT (unscaled reference)")
    print("=" * 78)

    # ── 1. Twiddle Factor Accuracy ───────────────────────────────────────────
    print("\n" + "─" * 78)
    print("  1. TWIDDLE FACTOR ACCURACY")
    print("─" * 78)
    print("  Both algorithms quantise twiddles to Q12, but differ in how they are")
    print("  computed per butterfly:")
    print("    Main     : direct table lookup — each W_N^k quantised once from float")
    print("    Baseline : chained multiply — w = w * w_m accumulates rounding error")
    print()

    tw_rows = twiddle_accuracy_analysis()
    bits = flog2(N)

    # Per-stage summary
    print(f"  {'Stage':>5} | {'#Twiddles':>9} | {'Main max err':>13} | {'Base max err':>13} | {'Ratio':>7}")
    print("  " + "-" * 60)
    for s in range(1, bits + 1):
        stage_rows = [r for r in tw_rows if r['stage'] == s]
        main_max = max(r['main_err'] for r in stage_rows)
        base_max = max(r['baseline_err'] for r in stage_rows)
        ratio = base_max / main_max if main_max > 0 else float('inf')
        print(f"  {s:>5} | {len(stage_rows):>9} | {main_max:>13.2f} | {base_max:>13.2f} | {ratio:>6.1f}x")

    main_total = sum(r['main_err'] for r in tw_rows)
    base_total = sum(r['baseline_err'] for r in tw_rows)
    main_max_all = max(r['main_err'] for r in tw_rows)
    base_max_all = max(r['baseline_err'] for r in tw_rows)
    print("  " + "-" * 60)
    print(f"  {'Total':>5} | {len(tw_rows):>9} | {main_max_all:>13.2f} | {base_max_all:>13.2f} | "
          f"{base_max_all / main_max_all if main_max_all > 0 else float('inf'):>6.1f}x")
    print(f"  {'Sum':>5} | {'':>9} | {main_total:>13.2f} | {base_total:>13.2f} | "
          f"{base_total / main_total if main_total > 0 else float('inf'):>6.1f}x")

    # ── 2. FFT Output Precision (vs unscaled ground truth) ───────────────────
    print("\n" + "─" * 78)
    print("  2. FFT OUTPUT PRECISION (vs double-precision ground truth)")
    print("─" * 78)
    print("  Ground truth = NumPy FFT with same Q12 input but float64 arithmetic.")
    print("  This isolates the error introduced by fixed-point twiddles & rounding.")
    print()

    main_spectra = []
    baseline_spectra = []
    ref_spectra = []
    main_mults_total = 0
    baseline_mults_total = 0

    for blk in sim_blocks:
        # Quantise input to Q12 (same for both algorithms)
        x_quant = [round(v * (1 << SCALE)) for v in blk]

        m_out, m_cnt = fft_main(x_quant)
        b_out, b_cnt = fft_baseline(x_quant)
        r_out = fft_ground_truth(blk)

        main_spectra.append(m_out)
        baseline_spectra.append(b_out)
        ref_spectra.append(r_out)
        main_mults_total += m_cnt
        baseline_mults_total += b_cnt

    # Flatten for aggregate metrics
    main_flat = np.array([v for chunk in main_spectra for v in chunk])
    baseline_flat = np.array([v for chunk in baseline_spectra for v in chunk])
    ref_flat = np.concatenate(ref_spectra)

    # Error metrics
    def compute_metrics(fixed_flat, ref_flat, label):
        err = fixed_flat - ref_flat
        mse = np.mean(np.abs(err) ** 2)
        max_err = np.max(np.abs(err))
        mean_err = np.mean(np.abs(err))
        signal_power = np.mean(np.abs(ref_flat) ** 2)
        snr_db = 10 * np.log10(signal_power / mse) if mse > 0 else float('inf')

        # Per-bin RMS error averaged across blocks
        n_bins = SAMPLES_PER_CHUNK
        per_bin_rms = np.zeros(n_bins)
        n_blks = len(fixed_flat) // n_bins
        for i in range(n_blks):
            chunk_err = fixed_flat[i*n_bins:(i+1)*n_bins] - ref_flat[i*n_bins:(i+1)*n_bins]
            per_bin_rms += np.abs(chunk_err) ** 2
        per_bin_rms = np.sqrt(per_bin_rms / n_blks)

        return {
            'label': label, 'mse': mse, 'max_err': max_err,
            'mean_err': mean_err, 'snr_db': snr_db,
            'per_bin_rms': per_bin_rms,
        }

    m_metrics = compute_metrics(main_flat, ref_flat, 'Main (global tw)')
    b_metrics = compute_metrics(baseline_flat, ref_flat, 'Baseline (chained)')

    print(f"  {'Algorithm':>22} | {'MSE':>12} | {'Mean |err|':>12} | {'Max |err|':>10} | {'SNR (dB)':>10}")
    print("  " + "-" * 74)
    for r in [m_metrics, b_metrics]:
        print(f"  {r['label']:>22} | {r['mse']:>12.2f} | {r['mean_err']:>12.2f} | "
              f"{r['max_err']:>10.2f} | {r['snr_db']:>10.2f}")
    print()
    delta_snr = m_metrics['snr_db'] - b_metrics['snr_db']
    print(f"  → Main has {abs(delta_snr):.1f} dB {'better' if delta_snr > 0 else 'worse'} SNR than baseline")
    print(f"  → Main max error {m_metrics['max_err']:.1f} vs baseline {b_metrics['max_err']:.1f} "
          f"({b_metrics['max_err']/m_metrics['max_err']:.1f}x {'larger' if b_metrics['max_err'] > m_metrics['max_err'] else 'smaller'} for baseline)"
          if m_metrics['max_err'] > 0 else "")

    # ── 3. Computational Cost ────────────────────────────────────────────────
    print("\n" + "─" * 78)
    print("  3. COMPUTATIONAL COST")
    print("─" * 78)

    bits = flog2(N)
    # Main: one complex multiply per butterfly (twiddle × data)
    # Baseline: two complex multiplies per butterfly (twiddle × data + w × w_m)
    main_mults_per_block = main_mults_total // n_blocks
    baseline_mults_per_block = baseline_mults_total // n_blocks

    # Count additions (same for both: 2 complex adds per butterfly = N/2*log2(N))
    n_butterflies = (N // 2) * bits
    adds_per_block = n_butterflies * 2  # add + sub, each is 2 real adds

    print(f"  Per {N}-point FFT block:")
    print(f"    {'':>22} | {'Main':>10} | {'Baseline':>10} | {'Savings':>10}")
    print("  " + "-" * 60)
    print(f"    {'Complex multiplies':>22} | {main_mults_per_block:>10} | {baseline_mults_per_block:>10} | "
          f"{baseline_mults_per_block - main_mults_per_block:>10}")
    print(f"    {'Complex add/sub':>22} | {adds_per_block:>10} | {adds_per_block:>10} | {'0':>10}")
    print(f"    {'Twiddle storage':>22} | {N//2:>8} W | {bits:>8} W | {'N/A':>10}")
    print()
    savings_pct = (1 - main_mults_per_block / baseline_mults_per_block) * 100
    print(f"  → Main eliminates {baseline_mults_per_block - main_mults_per_block} complex multiplies/block "
          f"({savings_pct:.0f}% fewer)")
    print(f"  → Baseline needs chained w = w * w_m each butterfly (extra multiply)")
    print(f"  → Main trades compute for storage: {N//2} twiddle entries vs {bits}")

    # ── 4. End-to-End Melody Recovery ────────────────────────────────────────
    print("\n" + "─" * 78)
    print("  4. END-TO-END MELODY RECOVERY ACCURACY")
    print("─" * 78)
    print("  Application: Nokia ringtone noise removal & melody index recovery")
    print()

    main_melody = recover_melody(main_spectra)
    baseline_melody = recover_melody(baseline_spectra)
    ref_melody = recover_melody([r.tolist() for r in ref_spectra])

    main_acc = np.mean(np.array(main_melody) == np.array(ground_truth_indices)) * 100
    baseline_acc = np.mean(np.array(baseline_melody) == np.array(ground_truth_indices)) * 100
    ref_acc = np.mean(np.array(ref_melody) == np.array(ground_truth_indices)) * 100

    print(f"  {'Algorithm':>22} | {'Accuracy':>10} | {'Mismatches':>12}")
    print("  " + "-" * 50)
    main_miss = sum(1 for a, b in zip(main_melody, ground_truth_indices) if a != b)
    base_miss = sum(1 for a, b in zip(baseline_melody, ground_truth_indices) if a != b)
    ref_miss = sum(1 for a, b in zip(ref_melody, ground_truth_indices) if a != b)
    print(f"  {'Float (ground truth)':>22} | {ref_acc:>9.1f}% | {ref_miss:>5}/{n_blocks}")
    print(f"  {'Main (global tw)':>22} | {main_acc:>9.1f}% | {main_miss:>5}/{n_blocks}")
    print(f"  {'Baseline (chained)':>22} | {baseline_acc:>9.1f}% | {base_miss:>5}/{n_blocks}")

    # Show which blocks differ between main and baseline
    differ_blocks = [i for i in range(n_blocks)
                     if main_melody[i] != baseline_melody[i]]
    if differ_blocks:
        print(f"\n  Blocks where main and baseline disagree: {differ_blocks}")
        for i in differ_blocks:
            print(f"    Block {i}: truth={ground_truth_indices[i]}, "
                  f"main={main_melody[i]}, baseline={baseline_melody[i]}")
    else:
        print(f"\n  Main and baseline agree on all {n_blocks} blocks.")

    # ── 5. Per-Bin Error Distribution ────────────────────────────────────────
    print("\n" + "─" * 78)
    print("  5. PER-BIN RMS ERROR (averaged over all blocks)")
    print("─" * 78)
    print(f"  {'Bin':>5} | {'Main RMS':>12} | {'Baseline RMS':>14} | {'Ratio (B/M)':>12}")
    print("  " + "-" * 50)
    for b in range(SAMPLES_PER_CHUNK):
        m_rms = m_metrics['per_bin_rms'][b]
        b_rms = b_metrics['per_bin_rms'][b]
        ratio = b_rms / m_rms if m_rms > 0 else float('inf')
        marker = " ◄" if ratio > 2.0 else ""
        print(f"  {b:>5} | {m_rms:>12.2f} | {b_rms:>14.2f} | {ratio:>11.2f}x{marker}")

    # ── 6. Summary ───────────────────────────────────────────────────────────
    print("\n" + "=" * 78)
    print("  SUMMARY")
    print("=" * 78)
    print(f"""
  Precision:
    - Main (global twiddle) has {abs(delta_snr):.1f} dB {'better' if delta_snr > 0 else 'worse'} SNR vs ground truth
    - Max error: main {m_metrics['max_err']:.1f} vs baseline {b_metrics['max_err']:.1f} (Q12 units)
    - Root cause: baseline accumulates rounding error from chained w = w * w_m;
      main reads each twiddle directly from a pre-quantised table

  Computational cost:
    - Main uses {main_mults_per_block} complex multiplies/block vs baseline {baseline_mults_per_block} ({savings_pct:.0f}% fewer)
    - Main trades {N//2} twiddle entries of storage for {baseline_mults_per_block - main_mults_per_block} fewer multiplies
    - In hardware: eliminates the w_m chaining path, simplifying the butterfly

  Application accuracy:
    - Melody recovery: main {main_acc:.1f}% vs baseline {baseline_acc:.1f}%
    - Both match float reference ({ref_acc:.1f}%) for this signal/noise scenario
""")

    # ── Save CSV ─────────────────────────────────────────────────────────────
    csv_path = os.path.join(_sw_dir, 'algorithm_comparison.csv')
    with open(csv_path, 'w') as f:
        f.write("algorithm,mse,mean_abs_error,max_abs_error,snr_db,"
                "melody_accuracy_pct,complex_mults_per_block\n")
        f.write(f"main_global_twiddle,{m_metrics['mse']:.4f},{m_metrics['mean_err']:.4f},"
                f"{m_metrics['max_err']:.4f},{m_metrics['snr_db']:.4f},"
                f"{main_acc:.2f},{main_mults_per_block}\n")
        f.write(f"baseline_chained_twiddle,{b_metrics['mse']:.4f},{b_metrics['mean_err']:.4f},"
                f"{b_metrics['max_err']:.4f},{b_metrics['snr_db']:.4f},"
                f"{baseline_acc:.2f},{baseline_mults_per_block}\n")
    print(f"  CSV saved to: {csv_path}")

    # ── Plots (optional) ─────────────────────────────────────────────────────
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        print("  (matplotlib not available — skipping plots)\n")
        return

    fig, axes = plt.subplots(2, 3, figsize=(18, 10))
    fig.suptitle('Algorithm Comparison: Main (Global Twiddle) vs Baseline (Chained Twiddle)',
                 fontsize=14, fontweight='bold')

    # Plot 1: Twiddle error by stage
    ax = axes[0, 0]
    stages = list(range(1, bits + 1))
    main_tw_max = []
    base_tw_max = []
    for s in stages:
        sr = [r for r in tw_rows if r['stage'] == s]
        main_tw_max.append(max(r['main_err'] for r in sr))
        base_tw_max.append(max(r['baseline_err'] for r in sr))
    x_pos = np.arange(len(stages))
    ax.bar(x_pos - 0.2, main_tw_max, 0.4, label='Main', color='#2196F3')
    ax.bar(x_pos + 0.2, base_tw_max, 0.4, label='Baseline', color='#FF5722')
    ax.set_xlabel('FFT Stage')
    ax.set_ylabel('Max Twiddle Error (Q12 units)')
    ax.set_title('Twiddle Factor Error by Stage')
    ax.set_xticks(x_pos)
    ax.set_xticklabels(stages)
    ax.legend()
    ax.grid(axis='y', alpha=0.3)

    # Plot 2: SNR comparison
    ax = axes[0, 1]
    labels = ['Main\n(global tw)', 'Baseline\n(chained)']
    snrs = [m_metrics['snr_db'], b_metrics['snr_db']]
    colors = ['#2196F3', '#FF5722']
    bars = ax.bar(labels, snrs, color=colors)
    ax.set_ylabel('SNR (dB)')
    ax.set_title('FFT Output SNR vs Ground Truth')
    ax.grid(axis='y', alpha=0.3)
    for bar, snr in zip(bars, snrs):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.3,
                f'{snr:.1f} dB', ha='center', va='bottom', fontsize=11)

    # Plot 3: Per-bin RMS error
    ax = axes[0, 2]
    bins = np.arange(SAMPLES_PER_CHUNK)
    ax.bar(bins - 0.2, m_metrics['per_bin_rms'], 0.4, label='Main', alpha=0.8, color='#2196F3')
    ax.bar(bins + 0.2, b_metrics['per_bin_rms'], 0.4, label='Baseline', alpha=0.8, color='#FF5722')
    ax.set_xlabel('Frequency Bin')
    ax.set_ylabel('RMS Error (Q12 units)')
    ax.set_title('Per-Bin RMS Error vs Ground Truth')
    ax.legend()
    ax.grid(axis='y', alpha=0.3)

    # Plot 4: Example block spectrum
    ax = axes[1, 0]
    ex = 0  # first block
    ref_mag = np.abs(ref_spectra[ex])[:SAMPLES_PER_CHUNK // 2]
    main_mag = np.abs(np.array(main_spectra[ex]))[:SAMPLES_PER_CHUNK // 2]
    base_mag = np.abs(np.array(baseline_spectra[ex]))[:SAMPLES_PER_CHUNK // 2]
    freq_bins = np.arange(SAMPLES_PER_CHUNK // 2)
    ax.plot(freq_bins, ref_mag, 'k-', linewidth=2, label='Float ref', alpha=0.6)
    ax.plot(freq_bins, main_mag, 'b--', linewidth=1.5, label='Main')
    ax.plot(freq_bins, base_mag, 'r:', linewidth=1.5, label='Baseline')
    ax.set_xlabel('Frequency Bin')
    ax.set_ylabel('Magnitude (Q12 units)')
    ax.set_title(f'Spectrum of Block {ex}')
    ax.legend()
    ax.grid(alpha=0.3)

    # Plot 5: Magnitude error histogram
    ax = axes[1, 1]
    main_mag_err = np.abs(main_flat) - np.abs(ref_flat)
    base_mag_err = np.abs(baseline_flat) - np.abs(ref_flat)
    bins_h = np.linspace(min(main_mag_err.min(), base_mag_err.min()),
                         max(main_mag_err.max(), base_mag_err.max()), 60)
    ax.hist(main_mag_err, bins=bins_h, alpha=0.6, label='Main', color='#2196F3')
    ax.hist(base_mag_err, bins=bins_h, alpha=0.6, label='Baseline', color='#FF5722')
    ax.set_xlabel('Magnitude Error (Q12 units)')
    ax.set_ylabel('Count')
    ax.set_title('Distribution of Magnitude Errors')
    ax.legend()
    ax.grid(axis='y', alpha=0.3)

    # Plot 6: Computational cost
    ax = axes[1, 2]
    labels = ['Main\n(global tw)', 'Baseline\n(chained)']
    mults = [main_mults_per_block, baseline_mults_per_block]
    colors = ['#2196F3', '#FF5722']
    bars = ax.bar(labels, mults, color=colors)
    ax.set_ylabel('Complex Multiplies per Block')
    ax.set_title('Computational Cost (Multiplies)')
    ax.grid(axis='y', alpha=0.3)
    for bar, m in zip(bars, mults):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 1,
                str(m), ha='center', va='bottom', fontsize=12)

    plt.tight_layout()
    out_path = os.path.join(_sw_dir, 'algorithm_comparison.png')
    plt.savefig(out_path, dpi=150)
    print(f"  Plot saved to: {out_path}\n")


if __name__ == '__main__':
    main()

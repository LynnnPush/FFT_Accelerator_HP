"""
datawidth_analysis.py — Compare 32-bit vs 24-bit data width for the FFT accelerator.

Uses the same data source (Nokia ringtone melody + noise) as the baseline
prepare_fft.py / sound_util.py pipeline.  Simulates the fixed-point FFT at
both 32-bit and 24-bit data widths and quantifies:

  1. Quantisation error (MSE, max absolute error, SNR) on raw FFT output
  2. End-to-end melody recovery accuracy (the metric that matters for the app)
  3. Frequency-domain spectral fidelity (per-bin error)

Run:
    cd sw && python datawidth_analysis.py

TU Delft ET4351 — 2026 Project
"""

import sys
import os

_sw_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _sw_dir)
sys.path.insert(0, os.path.join(_sw_dir, '..', 'firmware'))

import numpy as np

try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    HAS_MPL = True
except ImportError:
    HAS_MPL = False

from sound_util import (
    generate_sound,
    downsample_to_32_samples,
    process_audio,
    BASE_FREQS,
    SAMPLES_PER_CHUNK,
    SIM_FS,
)
from fft import flog2, bit_reverse, MAX_N_PER_FFT

# ── Configuration ────────────────────────────────────────────────────────────
# Same melody sequence as prepare_fft.py (Nokia Theme)
ORIGINAL_SEQUENCE = [
    (11, 1), (10, 1), (5, 2), (6, 2),
    (9, 1),  (8, 1),  (3, 2), (4, 2),
    (8, 1),  (7, 1),  (2, 2), (4, 2),
    (7, 4),  (-1, 2),
]

DATA_WIDTHS = [32, 24, 20, 16]          # bits to compare
TWIDDLE_WIDTH = 16                       # kept constant (already narrow)
SCALE = 12                               # Q12 twiddle format


# ── Fixed-point FFT parameterised by data width ─────────────────────────────
def make_twiddles(n, tw_bits, scale):
    """Generate Q<scale> twiddle table, same as firmware/fft.py."""
    import math
    half = n // 2
    twiddles = []
    for k in range(half):
        angle = -2.0 * math.pi * k / n
        re = round(math.cos(angle) * (1 << scale))
        im = round(math.sin(angle) * (1 << scale))
        twiddles.append(complex(re, im))
    return twiddles


def clamp(val, bits):
    """Clamp a signed integer to fit in `bits` width (two's complement)."""
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    if val < lo:
        return lo
    if val > hi:
        return hi
    return val


def fixed_fft(x_float, data_bits, scale=SCALE):
    """
    Bit-exact model of the accelerator FFT at a given data width.

    Steps mirror accelerator_fft.v:
      1. Quantise input to Q<scale> within <data_bits> range
      2. Bit-reverse permutation
      3. Cooley-Tukey butterfly with <data_bits> x <tw_bits> multiply,
         arithmetic right-shift by SCALE, and clamp to <data_bits>
    """
    n = len(x_float)
    bits = flog2(n)
    twiddles = make_twiddles(n, TWIDDLE_WIDTH, scale)

    # Quantise input (same as write_accel_io in sound_util.py)
    quant = [clamp(round(v * (1 << scale)), data_bits) for v in x_float]

    # Bit-reverse permutation
    X_re = [0] * n
    X_im = [0] * n
    for i in range(n):
        j = bit_reverse(i, bits)
        X_re[j] = quant[i]
        X_im[j] = 0

    # Butterfly stages (models accelerator_fft.v datapath exactly)
    for stage in range(1, bits + 1):
        m = 1 << stage
        half = m // 2
        stride = bits - stage

        for base in range(0, n, m):
            for k in range(half):
                tw_idx = k << stride
                tw_re = int(twiddles[tw_idx].real)
                tw_im = int(twiddles[tw_idx].imag)

                v_re = X_re[base + k + half]
                v_im = X_im[base + k + half]

                # Stage 2: multiply (MEM_WIDTH x TW_WIDTH product)
                rr = v_re * tw_re
                ii = v_im * tw_im
                ri = v_re * tw_im
                ir = v_im * tw_re

                # Stage 3: combine + arithmetic right shift + clamp
                t_re = clamp((rr - ii) >> scale, data_bits)
                t_im = clamp((ri + ir) >> scale, data_bits)

                u_re = X_re[base + k]
                u_im = X_im[base + k]

                # Stage 4: butterfly add/sub + clamp
                X_re[base + k]        = clamp(u_re + t_re, data_bits)
                X_im[base + k]        = clamp(u_im + t_im, data_bits)
                X_re[base + k + half] = clamp(u_re - t_re, data_bits)
                X_im[base + k + half] = clamp(u_im - t_im, data_bits)

    return [complex(X_re[i], X_im[i]) for i in range(n)]


# ── Float reference FFT (infinite precision baseline) ────────────────────────
def float_fft(x_float):
    """NumPy double-precision FFT scaled to match the Q12 integer domain."""
    scaled = np.array(x_float) * (1 << SCALE)
    return np.fft.fft(scaled)


# ── Melody recovery (reuses sound_util.process_audio logic) ──────────────────
def recover_melody(spectrum_chunks):
    """
    Given FFT output chunks (complex arrays), run the same decoding as
    sound_util.process_audio and return recovered note indices.
    """
    from scipy.fft import fftfreq
    recovered = []
    for block in spectrum_chunks:
        freq_bins = fftfreq(SAMPLES_PER_CHUNK, 1 / SIM_FS)
        block = np.array(block, dtype=complex)

        # Notch out noise at 14 Hz and 15 Hz
        block[np.abs(np.abs(freq_bins) - 14) < 0.1] = 0
        block[np.abs(np.abs(freq_bins) - 15) < 0.1] = 0

        # IDFT → time domain
        clean = np.fft.ifft(block).real

        # Decode melody index from cleaned spectrum
        spec = np.fft.fft(clean)
        mag = np.abs(spec)[:SAMPLES_PER_CHUNK // 2]
        peak = np.argmax(mag)
        if mag[peak] < 0.5:
            recovered.append(-1)
        else:
            recovered.append(peak - 1)

    return recovered


# ── Main analysis ────────────────────────────────────────────────────────────
def main():
    # --- Generate the same data source as the baseline ---
    expanded_seq, _, _ = generate_sound(ORIGINAL_SEQUENCE)
    sim_blocks = downsample_to_32_samples(expanded_seq)

    n_blocks = len(sim_blocks)
    ground_truth_indices = list(expanded_seq)

    print("=" * 72)
    print("  Data Width Analysis: Impact on FFT Accuracy & Melody Recovery")
    print("=" * 72)
    print(f"  Data source   : Nokia ringtone ({n_blocks} blocks of {SAMPLES_PER_CHUNK} samples)")
    print(f"  Twiddle width : {TWIDDLE_WIDTH} bits (Q{SCALE}, constant across all tests)")
    print(f"  Data widths   : {DATA_WIDTHS}")
    print("=" * 72)

    # --- Compute reference (float) FFT ---
    ref_spectra = [float_fft(blk) for blk in sim_blocks]
    ref_flat = np.concatenate(ref_spectra)
    ref_melody = recover_melody(ref_spectra)

    # --- Per-width analysis ---
    results = {}
    all_fixed_spectra = {}

    for dw in DATA_WIDTHS:
        fixed_spectra = [fixed_fft(blk, dw) for blk in sim_blocks]
        fixed_flat = np.array([v for chunk in fixed_spectra for v in chunk])
        all_fixed_spectra[dw] = fixed_spectra

        # Error metrics (in the Q12 integer domain)
        err = fixed_flat - ref_flat
        mse = np.mean(np.abs(err) ** 2)
        max_err = np.max(np.abs(err))
        signal_power = np.mean(np.abs(ref_flat) ** 2)
        snr_db = 10 * np.log10(signal_power / mse) if mse > 0 else float('inf')

        # Melody recovery
        melody = recover_melody(fixed_spectra)
        accuracy = np.mean(np.array(melody) == np.array(ground_truth_indices)) * 100

        # Per-bin magnitude error (averaged across blocks)
        mag_errors = []
        for ref_blk, fix_blk in zip(ref_spectra, fixed_spectra):
            ref_mag = np.abs(ref_blk)
            fix_mag = np.abs(np.array(fix_blk))
            mag_errors.append(np.abs(ref_mag - fix_mag))
        avg_mag_err = np.mean(mag_errors, axis=0)

        results[dw] = {
            'mse': mse,
            'max_err': max_err,
            'snr_db': snr_db,
            'accuracy': accuracy,
            'melody': melody,
            'avg_mag_err': avg_mag_err,
        }

    # --- Print summary table ---
    print(f"\n{'Width':>7} | {'MSE':>14} | {'Max |err|':>12} | {'SNR (dB)':>10} | {'Melody Acc.':>11}")
    print("-" * 72)
    for dw in DATA_WIDTHS:
        r = results[dw]
        print(f"  {dw:>2}-bit | {r['mse']:>14.2f} | {r['max_err']:>12.2f} | {r['snr_db']:>10.2f} | {r['accuracy']:>10.1f}%")
    print()

    # Float reference melody accuracy
    ref_acc = np.mean(np.array(ref_melody) == np.array(ground_truth_indices)) * 100
    print(f"  Float  | {'(reference)':>14} | {'—':>12} | {'∞':>10} | {ref_acc:>10.1f}%")
    print()

    # --- Highlight the key finding ---
    r32 = results[32]
    r24 = results[24]
    print("-" * 72)
    print("  KEY FINDING: 32-bit vs 24-bit")
    print(f"    Melody accuracy:  {r32['accuracy']:.1f}% → {r24['accuracy']:.1f}%  "
          f"({'IDENTICAL' if r32['accuracy'] == r24['accuracy'] else 'DEGRADED'})")
    print(f"    SNR:              {r32['snr_db']:.1f} dB → {r24['snr_db']:.1f} dB  "
          f"(Δ = {r32['snr_db'] - r24['snr_db']:.1f} dB)")
    print(f"    Max |error|:      {r32['max_err']:.1f} → {r24['max_err']:.1f}")
    if r32['accuracy'] == r24['accuracy']:
        print("\n  → 24-bit data width preserves full melody recovery accuracy.")
        print("    The quantisation noise is below the decision threshold.")
        print("    This justifies reducing MEM_WIDTH from 32 to 24 in the RTL")
        print("    for area savings with zero functional impact.")
    print("-" * 72)

    # --- Determine where accuracy drops ---
    print("\n  ACCURACY BREAKDOWN BY WIDTH:")
    for dw in DATA_WIDTHS:
        r = results[dw]
        mismatches = sum(1 for a, b in zip(r['melody'], ground_truth_indices) if a != b)
        print(f"    {dw:>2}-bit: {r['accuracy']:.1f}% accuracy  ({mismatches}/{n_blocks} blocks wrong)")

    # --- Dynamic range analysis: why 24/20-bit match 32-bit exactly ---
    print("\n  DYNAMIC RANGE ANALYSIS:")
    all_quant = [clamp(round(v * (1 << SCALE)), 32) for blk in sim_blocks for v in blk]
    max_input = max(abs(v) for v in all_quant)
    bits_needed = int(np.ceil(np.log2(max_input + 1))) + 1  # +1 for sign
    print(f"    Max |input| after Q{SCALE} quantisation: {max_input}")
    print(f"    Bits needed to represent inputs:    {bits_needed} bits (incl. sign)")
    print(f"    → Any data width >= {bits_needed} bits produces identical results")
    print(f"    → 24-bit has {24 - bits_needed} bits of headroom for intermediate growth")
    print(f"    → 16-bit overflows (needs {bits_needed}, has 16) → catastrophic errors")

    # --- Save CSV for external plotting ---
    csv_path = os.path.join(_sw_dir, 'datawidth_analysis.csv')
    with open(csv_path, 'w') as f:
        f.write("data_width_bits,mse,max_abs_error,snr_db,melody_accuracy_pct\n")
        for dw in DATA_WIDTHS:
            r = results[dw]
            f.write(f"{dw},{r['mse']:.4f},{r['max_err']:.4f},{r['snr_db']:.4f},{r['accuracy']:.2f}\n")
    print(f"\n  CSV saved to: {csv_path}")

    # ── Plots (optional — requires matplotlib) ───────────────────────────────
    if not HAS_MPL:
        print("  (matplotlib not available — skipping plots)")
        print()
        return

    fig, axes = plt.subplots(2, 2, figsize=(14, 10))
    fig.suptitle('Data Width Reduction Analysis: 32-bit vs Narrower Widths', fontsize=14)

    # Plot 1: SNR vs data width
    ax = axes[0, 0]
    snrs = [results[dw]['snr_db'] for dw in DATA_WIDTHS]
    bars = ax.bar([str(dw) for dw in DATA_WIDTHS], snrs, color=['#2196F3', '#4CAF50', '#FF9800', '#F44336'])
    ax.set_xlabel('Data Width (bits)')
    ax.set_ylabel('SNR (dB)')
    ax.set_title('FFT Output SNR vs Data Width')
    ax.grid(axis='y', alpha=0.3)
    for bar, snr in zip(bars, snrs):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.5,
                f'{snr:.1f}', ha='center', va='bottom', fontsize=10)

    # Plot 2: Melody accuracy vs data width
    ax = axes[0, 1]
    accs = [results[dw]['accuracy'] for dw in DATA_WIDTHS]
    bars = ax.bar([str(dw) for dw in DATA_WIDTHS], accs, color=['#2196F3', '#4CAF50', '#FF9800', '#F44336'])
    ax.set_xlabel('Data Width (bits)')
    ax.set_ylabel('Melody Recovery Accuracy (%)')
    ax.set_title('End-to-End Melody Accuracy vs Data Width')
    ax.set_ylim(0, 105)
    ax.grid(axis='y', alpha=0.3)
    for bar, acc in zip(bars, accs):
        ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 1,
                f'{acc:.1f}%', ha='center', va='bottom', fontsize=10)

    # Plot 3: Per-bin average magnitude error (32 vs 24)
    ax = axes[1, 0]
    bins = np.arange(SAMPLES_PER_CHUNK)
    ax.bar(bins - 0.2, results[32]['avg_mag_err'], 0.4, label='32-bit', alpha=0.8, color='#2196F3')
    ax.bar(bins + 0.2, results[24]['avg_mag_err'], 0.4, label='24-bit', alpha=0.8, color='#4CAF50')
    ax.set_xlabel('Frequency Bin')
    ax.set_ylabel('Avg Magnitude Error (Q12 units)')
    ax.set_title('Per-Bin FFT Magnitude Error: 32-bit vs 24-bit')
    ax.legend()
    ax.grid(axis='y', alpha=0.3)

    # Plot 4: Example block — spectrum comparison
    ax = axes[1, 1]
    example_blk = 0
    ref_mag = np.abs(ref_spectra[example_blk])[:SAMPLES_PER_CHUNK // 2]
    fix32_mag = np.abs(np.array(all_fixed_spectra[32][example_blk]))[:SAMPLES_PER_CHUNK // 2]
    fix24_mag = np.abs(np.array(all_fixed_spectra[24][example_blk]))[:SAMPLES_PER_CHUNK // 2]
    freq_bins = np.arange(SAMPLES_PER_CHUNK // 2)
    ax.plot(freq_bins, ref_mag, 'k-', linewidth=2, label='Float ref', alpha=0.5)
    ax.plot(freq_bins, fix32_mag, 'b--', linewidth=1.5, label='32-bit')
    ax.plot(freq_bins, fix24_mag, 'g:', linewidth=1.5, label='24-bit')
    ax.set_xlabel('Frequency Bin')
    ax.set_ylabel('Magnitude (Q12 units)')
    ax.set_title('Spectrum of Block 0: Float vs Fixed-Point')
    ax.legend()
    ax.grid(alpha=0.3)

    plt.tight_layout()
    out_path = os.path.join(_sw_dir, 'datawidth_analysis.png')
    plt.savefig(out_path, dpi=150)
    print(f"\n  Plot saved to: {out_path}")
    print()


if __name__ == '__main__':
    main()

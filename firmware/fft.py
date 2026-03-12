"""
fft.py — FFT library for the v3 SW-twiddle-preload accelerator.

Changes from baseline:
  - TWIDDLES is now a flat list of N/2 complex values representing the
    global twiddle table W_N^k (k=0..N/2-1), each quantised to Q12
    ONCE from full-precision floating-point (no chained multiply).
  - fft() uses global twiddle indexing:  tw_idx = k_loc << (bits - stage)
  - All other APIs (bit_reverse, complex_mult, flog2, inv_dft) unchanged.

This module is imported by sound_util.py / prepare_fft.py.
It does NOT produce file output on its own.

TU Delft ET4351 — 2026 Project
"""

import cmath
import math
from typing import List


SCALE = 12
MAX_N_PER_FFT = 32

# ---------------------------------------------------------------------------
#  Global twiddle table:  W_N^k = exp(-j * 2*pi*k / N)  for k = 0 .. N/2-1
#
#  Each twiddle is quantised to Q12 ONCE from full-precision float.
#  This gives the best possible fixed-point accuracy — no accumulated
#  rounding from chained multiplications.
# ---------------------------------------------------------------------------
_HALF_N = MAX_N_PER_FFT // 2

TWIDDLES: List[complex] = []
for _k in range(_HALF_N):
    _angle = -2.0 * math.pi * _k / MAX_N_PER_FFT
    _re = round(math.cos(_angle) * (1 << SCALE))
    _im = round(math.sin(_angle) * (1 << SCALE))
    TWIDDLES.append(complex(_re, _im))


def complex_mult(in1: complex, in2: complex) -> complex:
    a = int(in1.real)
    b = int(in1.imag)
    c = int(in2.real)
    d = int(in2.imag)
    return complex((a * c - b * d) >> SCALE, (a * d + b * c) >> SCALE)


def flog2(x: int) -> int:
    r = 0
    while x > 1:
        r += 1
        x = x >> 1
    return r


def bit_reverse(i: int, bits: int) -> int:
    r: int = 0
    for _ in range(bits):
        r = (r << 1) | (i & 1)
        i >>= 1
    return r


def fft(x: List[complex]) -> List[complex]:
    """
    In-place Cooley-Tukey DIT FFT using the global twiddle table.

    Twiddle indexing per stage s (1-indexed), local index k_loc:
        tw_idx = k_loc << (bits - s)

    This is bit-exact with the v3 accelerator_fft.v datapath.
    """
    n = len(x)
    bits = flog2(n)

    # Step 1: bit-reversal permutation
    X = [0j] * n
    for i in range(n):
        X[bit_reverse(i, bits)] = x[i]

    # Step 2: iterative FFT stages
    for stage in range(1, bits + 1):
        m = 1 << stage          # group size = 2, 4, 8, ..., n
        half = m // 2
        stride = bits - stage   # = fft_stages - stage

        for base in range(0, n, m):
            for k in range(half):
                tw_idx = k << stride       # Global twiddle index

                t = complex_mult(TWIDDLES[tw_idx], X[base + k + half])

                u = X[base + k]
                X[base + k]        = u + t
                X[base + k + half] = u - t

    return X


def inv_dft(x: List[complex]) -> List[complex]:
    n = len(x)
    X = [0j] * n

    for k in range(n):
        sum_val = 0j
        for t in range(n):
            angle = 2j * cmath.pi * t * k / n
            sum_val += x[t] * cmath.exp(angle)
        X[k] = sum_val / n

    return X
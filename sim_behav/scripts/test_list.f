# Regression test list. Format (whitespace separated):
#   <UVM_TESTNAME>  <RUNS>  <PLUSARGS>
# RUNS > 1 expands into multiple invocations with seed = 1..RUNS
# (each invocation gets -sv_seed <n>, so randomization differs per run).
# Use "-" for empty plusargs. Lines starting with # are ignored.
#
# Note: fft_random_test internally loops +N_RAND FFTs per invocation
# (default 100). 5 seeds × N_RAND=100 = 500 randomized FFTs total,
# spread across 5 distinct solver trajectories — better coverage than
# 500 internal iters under a single seed.

fft_smoke_test       1   -
fft_impulse_test     1   -
fft_random_test      5   +N_RAND=100
fft_coverage_test    1   -

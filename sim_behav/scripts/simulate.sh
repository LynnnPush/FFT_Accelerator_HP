#!/bin/bash
##########################################################################
### Run a single UVM test against the already-compiled workLib_uvm.
### Args: <UVM_TESTNAME> <SEED> <OUTDIR> [extra plusargs...]
### Produces: $OUTDIR/transcript, $OUTDIR/fft_cov.ucdb
##########################################################################
set -e

TESTNAME=$1
SEED=$2
OUTDIR=$3
shift 3 || true

if [ -z "$TESTNAME" ] || [ -z "$SEED" ] || [ -z "$OUTDIR" ]; then
  echo "usage: simulate.sh <test> <seed> <outdir> [+plusargs...]" >&2
  exit 2
fi

mkdir -p "$OUTDIR"

# Tools must be on PATH; assume caller already sourced setup.sh once.
if ! command -v vsim >/dev/null 2>&1; then
  source ../setup.sh
fi

UVM_DPI_LIB=$(dirname $(which vlog))/../uvm-1.2/linux_x86_64/uvm_dpi

# Run from project sim_behav (where workLib_uvm + fft_ref.so live), but
# redirect transcript and ucdb into per-run OUTDIR via -logfile / coverage save.
vsim tb_top -c -coverage \
     -sv_lib ${UVM_DPI_LIB} \
     -sv_lib ./fft_ref \
     -logfile "${OUTDIR}/transcript" \
     -do "onfinish stop; run -all; coverage save ${OUTDIR}/fft_cov.ucdb; quit -f" \
     +UVM_TESTNAME=${TESTNAME} \
     -sv_seed ${SEED} \
     "$@"

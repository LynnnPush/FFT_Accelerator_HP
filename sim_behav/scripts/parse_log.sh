#!/bin/bash
##########################################################################
### Determine PASS/FAIL from a UVM transcript.
### Usage: parse_log.sh <transcript>
### Stdout: "PASS" or "FAIL: <reason>"
### Exit:    0 on PASS, 1 on FAIL
###
### Why grep the log instead of trusting vsim's exit code?
### Questa returns 0 even when UVM_ERROR/UVM_FATAL fire, and even when
### a $finish never happens. Industrial regressions key on the UVM
### report summary, which always prints if the test reached run_phase end.
##########################################################################
set -u

LOG=$1
if [ ! -f "$LOG" ]; then
  echo "FAIL: transcript missing"
  exit 1
fi

# Real fatals are timestamped: "UVM_FATAL @ <time>". The "UVM_FATAL :"
# line in the report summary also matches a naive grep — must not confuse
# the two. Same trap for UVM_ERROR.
if grep -q "UVM_FATAL @" "$LOG" 2>/dev/null; then
  N=$(grep -c "UVM_FATAL @" "$LOG" || true)
  echo "FAIL: ${N} UVM_FATAL"
  exit 1
fi

# UVM report summary lines: "UVM_ERROR :    N" and "UVM_FATAL :    N"
ERR=$(awk '/UVM_ERROR :/ {print $NF; exit}' "$LOG")
FAT=$(awk '/UVM_FATAL :/ {print $NF; exit}' "$LOG")

if [ -z "$ERR" ] && [ -z "$FAT" ]; then
  echo "FAIL: no UVM report summary (sim crashed or hung)"
  exit 1
fi

if [ "${ERR:-0}" != "0" ]; then
  echo "FAIL: ${ERR} UVM_ERROR"
  exit 1
fi
if [ "${FAT:-0}" != "0" ]; then
  echo "FAIL: ${FAT} UVM_FATAL"
  exit 1
fi

echo "PASS"
exit 0

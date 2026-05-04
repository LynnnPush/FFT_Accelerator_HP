#!/bin/bash
##########################################################################
### Regression orchestrator.
### - reads scripts/test_list.f
### - compiles once via scripts/compile.sh
### - runs each (test,seed) into regress_out/<test>_seed<n>/
### - merges UCDBs, generates HTML coverage, writes summary.txt + summary.xml
###
### Run from sim_behav/. Honors JOBS env var (default: nproc) for
### per-test parallelism via xargs -P. Compile is serial (only once).
##########################################################################
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "${HERE}/.." && pwd)
cd "${ROOT}"

OUT="regress_out"
LIST="scripts/test_list.f"
JOBS=${JOBS:-$(nproc)}

rm -rf "${OUT}"
mkdir -p "${OUT}"

echo ":::: regress :::: compile (once)"
bash scripts/compile.sh 2>&1 | tee "${OUT}/compile.log"
if [ ${PIPESTATUS[0]} -ne 0 ]; then
  echo "FATAL: compile failed; see ${OUT}/compile.log" >&2
  exit 2
fi

# Source setup once so simulate.sh inherits PATH (it skips re-sourcing).
# setup.sh lives at the project root, one level above sim_behav.
source ../setup.sh

# ---- expand test_list.f into a flat job file ----
JOBFILE="${OUT}/jobs.tsv"
: > "${JOBFILE}"
while IFS= read -r line; do
  # strip comments + blanks
  line="${line%%#*}"
  [ -z "${line// }" ] && continue
  read -r TEST RUNS PLUS <<< "$line"
  [ "$PLUS" = "-" ] && PLUS=""
  for s in $(seq 1 "${RUNS}"); do
    printf "%s\t%s\t%s\n" "${TEST}" "${s}" "${PLUS}" >> "${JOBFILE}"
  done
done < "${LIST}"

TOTAL=$(wc -l < "${JOBFILE}")
echo ":::: regress :::: dispatching ${TOTAL} jobs across ${JOBS} workers"

# ---- per-job runner (called by xargs) ----
run_one() {
  local TEST=$1 SEED=$2; shift 2
  local PLUS="$*"
  local TAG="${TEST}_seed${SEED}"
  local DIR="regress_out/${TAG}"
  mkdir -p "${DIR}"

  # shellcheck disable=SC2086
  bash scripts/simulate.sh "${TEST}" "${SEED}" "${DIR}" ${PLUS} \
    > "${DIR}/sim.stdout" 2>&1
  local rc=$?

  local result
  result=$(bash scripts/parse_log.sh "${DIR}/transcript")
  local prc=$?
  echo "${result}" > "${DIR}/result.txt"

  if [ ${prc} -eq 0 ]; then
    printf "  [PASS] %s\n" "${TAG}"
  else
    printf "  [FAIL] %s — %s (vsim rc=%d)\n" "${TAG}" "${result}" "${rc}"
  fi
}
export -f run_one

# xargs -P with a tab delimiter; -I tag swaps the whole line into the cmd.
awk -F'\t' '{printf "%s|%s|%s\n", $1, $2, $3}' "${JOBFILE}" | \
  xargs -P "${JOBS}" -I {} bash -c '
    IFS="|" read -r T S P <<< "{}"
    run_one "$T" "$S" "$P"
  '

# ---- summarize ----
SUMMARY="${OUT}/summary.txt"
XML="${OUT}/summary.xml"
PASS=0; FAIL=0
{
  printf "%-40s %-6s %s\n" "TEST" "SEED" "RESULT"
  printf -- "------------------------------------------------------------\n"
} > "${SUMMARY}"

echo '<?xml version="1.0" encoding="UTF-8"?>' > "${XML}"
echo "<testsuite name=\"fft_regress\" tests=\"${TOTAL}\">" >> "${XML}"

while IFS=$'\t' read -r TEST SEED PLUS; do
  TAG="${TEST}_seed${SEED}"
  RES=$(cat "${OUT}/${TAG}/result.txt" 2>/dev/null || echo "FAIL: missing result")
  printf "%-40s %-6s %s\n" "${TEST}" "${SEED}" "${RES}" >> "${SUMMARY}"
  if [[ "${RES}" == PASS* ]]; then
    PASS=$((PASS+1))
    echo "  <testcase classname=\"${TEST}\" name=\"seed${SEED}\"/>" >> "${XML}"
  else
    FAIL=$((FAIL+1))
    {
      echo "  <testcase classname=\"${TEST}\" name=\"seed${SEED}\">"
      echo "    <failure message=\"${RES//\"/&quot;}\"/>"
      echo "  </testcase>"
    } >> "${XML}"
  fi
done < "${JOBFILE}"

echo "</testsuite>" >> "${XML}"

{
  printf -- "------------------------------------------------------------\n"
  printf "TOTAL=%d  PASS=%d  FAIL=%d\n" "${TOTAL}" "${PASS}" "${FAIL}"
} >> "${SUMMARY}"

echo
cat "${SUMMARY}"

# ---- coverage merge ----
echo
echo ":::: regress :::: merging coverage"
UCDBS=$(find "${OUT}" -name fft_cov.ucdb)
if [ -n "${UCDBS}" ]; then
  # vcover merge: first arg is output, rest are inputs.
  # shellcheck disable=SC2086
  vcover merge "${OUT}/merged.ucdb" ${UCDBS} >/dev/null
  vcover report -summary "${OUT}/merged.ucdb" | tee "${OUT}/cov_summary.txt"
  rm -rf "${OUT}/cov_html"
  vcover report -details -html -output "${OUT}/cov_html" "${OUT}/merged.ucdb" >/dev/null
  echo ":::: regress :::: HTML coverage at ${OUT}/cov_html/index.html"
else
  echo "WARN: no UCDBs found to merge"
fi

# ---- exit ----
if [ "${FAIL}" -ne 0 ]; then
  echo ":::: regress :::: ${FAIL}/${TOTAL} FAILED"
  exit 1
fi
echo ":::: regress :::: all ${TOTAL} tests PASSED"
exit 0

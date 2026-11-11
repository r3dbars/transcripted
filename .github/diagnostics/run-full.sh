#!/bin/bash
set -uo pipefail
# Run every independent stage exactly once; preserve each exit even after failure.
failed=0
run_stage() {
  local name="$1"; shift
  printf 'START %s\n' "$name"
  "$@" > "diagnostic-proof/$name.raw" 2>&1
  local code=$?
  printf '%s\t%s\n' "$name" "$code" >> diagnostic-proof/stages.tsv
  printf 'FINISH %s exit=%s\n' "$name" "$code"
  if [ "$code" -ne 0 ]; then failed=1; fi
}
test "$(git -C ../reviewed-harness rev-parse HEAD)" = 8a38235eef00816a79daa1324387a21ef880204d || exit 1
unset TRANSCRIPTED_SKIP_TIMING_SENSITIVE_TESTS
run_stage full-check bash check.sh full --keep-going
run_stage lab-tests swift test --package-path Tools/TranscriptedLab --jobs 4
run_stage lab-cli swift build --package-path Tools/TranscriptedLab --product transcripted-lab --jobs 4
run_stage lab-app swift build --package-path Tools/TranscriptedLab --product TranscriptedLab --jobs 4
run_stage lab-bundle bash Tools/TranscriptedLab/script/build_and_run.sh --verify
run_stage fixture-guards python3 ../reviewed-harness/Tests/BuildDependencies/HostedQAArtifactsTests.py
run_stage fixture-setup python3 ../diagnostic-harness/.github/diagnostics/prepare-local.py
run_stage full-bench bash scripts/ops/transcripted-qa-bench.sh --mode full --out-root "$RUNNER_TEMP/full-qa-bench" --run-id local-vm
run_stage coverage-receipt python3 ../diagnostic-harness/.github/diagnostics/receipt.py
exit "$failed"

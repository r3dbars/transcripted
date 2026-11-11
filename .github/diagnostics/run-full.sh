#!/bin/bash
set -uo pipefail
failed=0
mkdir -p "$RUNNER_TEMP/private-diagnostic-logs"
run_stage() {
  local name="$1"; shift
  printf 'START %s\n' "$name"
  "$@" > "diagnostic-proof/$name.raw" 2>&1
  local code=$?
  printf '%s\t%s\n' "$name" "$code" >> diagnostic-proof/stages.tsv
  printf 'FINISH %s exit=%s\n' "$name" "$code"
  if [ "$code" -ne 0 ]; then failed=1; fi
}
base=8a38235eef00816a79daa1324387a21ef880204d
verify_refs() {
  test "$(git rev-parse HEAD)" = e66e3e4fb7c4e73e5a6825a8f66458425ca12d16 &&
  test "$(git -C ../reviewed-harness rev-parse HEAD)" = "$base" &&
  test "$(git rev-parse --is-shallow-repository)" = false &&
  git fetch origin main && test "$(git rev-parse origin/main)" = "$base"
}
locale_proof() {
  bash Tests/BuildDependencies/DepsStalenessTests.sh || return
  python3 - <<'PY'
import json, subprocess, os
values={k:subprocess.check_output(['bash','-c','source scripts/entrypoints/lib/deps-staleness.sh; dependency_input_digest'],env=dict(os.environ,LC_ALL=k),text=True).strip() for k in ['C','en_US.UTF-8']}
open('diagnostic-proof/locale.json','w').write(json.dumps(values,indent=2))
assert len(set(values.values()))==1
PY
}
toolchain() {
  { xcodebuild -version; swiftc --version | sed '/^InstalledDir:/d'; } > diagnostic-proof/toolchain.txt
  grep -q 'Xcode 26.5' diagnostic-proof/toolchain.txt || return
  test "$(swiftc --version)" = "$(xcrun swiftc --version)"
}
census() {
  local role="$1" checkout="$2" code savecode=0
  (cd "$checkout" && bash scripts/dev/concurrency-census.sh)
  code=$?
  # Preserve BEFORE any other build; these paths are outside both build trees.
  for file in concurrency-census.log concurrency-census-core.log; do
    if [ -f "$checkout/build/$file" ]; then
      cp "$checkout/build/$file" "$RUNNER_TEMP/private-diagnostic-logs/$role-$file" || savecode=1
    fi
  done
  test -s "$RUNNER_TEMP/private-diagnostic-logs/$role-concurrency-census.log" || savecode=1
  python3 scripts/dev/concurrency-census.py --log "$RUNNER_TEMP/private-diagnostic-logs/$role-concurrency-census.log" --counts-out "diagnostic-proof/$role-counts.json" || savecode=1
  test "$code" -eq 0 && test "$savecode" -eq 0
}
base_deps() { (cd ../reviewed-harness && bash build-deps.sh --force); }
base_toolchain() {
  (cd ../reviewed-harness && { xcodebuild -version; swiftc --version | sed '/^InstalledDir:/d'; }) > diagnostic-proof/base-toolchain.txt
  cmp diagnostic-proof/toolchain.txt diagnostic-proof/base-toolchain.txt
}
unset TRANSCRIPTED_SKIP_TIMING_SENSITIVE_TESTS
run_stage source-verification verify_refs
# Stop if immutable source or toolchain prerequisites are wrong.
[ "$failed" -eq 0 ] || exit 1
run_stage toolchain toolchain
[ "$failed" -eq 0 ] || exit 1
run_stage locale-regressions locale_proof
run_stage head-deps bash build-deps.sh --force
run_stage head-census census head "$PWD"
prerequisites() {
  local name
  for name in "$@"; do
    grep -qx "$name$(printf '\t')0" diagnostic-proof/stages.tsv || return 2
  done
}
strict_census() {
  prerequisites head-deps head-census || return 2
  python3 scripts/dev/concurrency-census.py --log "$RUNNER_TEMP/private-diagnostic-logs/head-concurrency-census.log" --mode check
}
base_comparison() {
  prerequisites head-deps head-census base-deps base-toolchain base-census || return 2
  python3 scripts/dev/concurrency-census.py --log "$RUNNER_TEMP/private-diagnostic-logs/head-concurrency-census.log" --mode check --allow-up-to diagnostic-proof/base-counts.json
}
run_stage strict-census strict_census
run_stage base-deps base_deps
run_stage base-toolchain base_toolchain
run_stage base-census census base "$PWD/../reviewed-harness"
run_stage base-comparison base_comparison
run_stage concurrency-receipt python3 ../diagnostic-harness/.github/diagnostics/concurrency-receipt.py
run_stage fixture-guards python3 ../reviewed-harness/Tests/BuildDependencies/HostedQAArtifactsTests.py
run_stage fixture-setup python3 ../diagnostic-harness/.github/diagnostics/prepare-local.py
run_stage full-bench bash scripts/ops/transcripted-qa-bench.sh --mode full --out-root "$RUNNER_TEMP/full-qa-bench" --run-id local-vm
run_stage coverage-receipt python3 ../diagnostic-harness/.github/diagnostics/receipt.py
exit "$failed"

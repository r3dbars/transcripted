#!/usr/bin/env bash
# linux-checks.sh — every repo check that runs on Linux without a Swift toolchain.
#
# One command for agents (and CI) that cannot build the
# macOS app: contract self-tests, syntax checks, deterministic fixture gates,
# and Linux mirrors of Swift source-text/telemetry contracts. Prints one
# PASS/FAIL/SKIP line per check with its elapsed time and the exact command, so
# a single failing check can be re-run by copy-paste. Exits non-zero if any
# check fails.
#
# Dependencies: bash + python3 (stdlib only). ruby is optional (ruby checks are
# SKIPped with a note when it is missing). No network. Everything a check writes
# lands under build/ (gitignored): logs, reports, TMPDIR and Python bytecode go to
# build/linux-checks/; nightly-security-check.py also writes its fixed
# build/privacy-leak-sweep-nightly.json.
#
# Under --strict-tools (the CI mode), the strict
# nightly-security release-health gate only runs when the branch touches release
# surfaces: it depends on git tags a PR cannot control, so it would otherwise go
# red on every open PR between a release's tag push and its appcast commit.
#
# Usage:
#   bash scripts/dev/linux-checks.sh            # run everything
#   bash scripts/dev/linux-checks.sh --quick    # skip the slower fixture/test lanes (~2x faster)
#   bash scripts/dev/linux-checks.sh --only pins          # only checks whose name contains "pins"
#   bash scripts/dev/linux-checks.sh --list     # print the checks and commands without running
#   bash scripts/dev/linux-checks.sh --verbose  # stream every check's output, not just failures
#   bash scripts/dev/linux-checks.sh --strict-tools  # CI: a missing tool/ref (ruby, origin/main) FAILs instead of SKIPs

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

quick=false
strict_tools=false
list_only=false
verbose=false
only=""

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --quick) quick=true; shift ;;
        --strict-tools) strict_tools=true; shift ;;
        --list) list_only=true; shift ;;
        --verbose|-v) verbose=true; shift ;;
        --only)
            if [ "$#" -lt 2 ]; then echo "--only requires a substring"; exit 2; fi
            only="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)"; exit 2 ;;
    esac
done

OUT_DIR="build/linux-checks"
LOG_DIR="$OUT_DIR/logs"
if [ "$list_only" = false ]; then
    rm -rf "$LOG_DIR" "$OUT_DIR/tmp"
    mkdir -p "$LOG_DIR" "$OUT_DIR/tmp" "$OUT_DIR/pycache"
fi

# Keep every side effect inside build/linux-checks.
export TMPDIR="$REPO_ROOT/$OUT_DIR/tmp"
export PYTHONPYCACHEPREFIX="$REPO_ROOT/$OUT_DIR/pycache"
export PYTHONDONTWRITEBYTECODE=1
export TRANSCRIPTED_DISABLE_FILE_LOGGER=1

# Field separator for the failure summary; commands contain `|`, so use US (0x1f).
SEP=$'\x1f'
pass_count=0
fail_count=0
skip_count=0
check_index=0
failed_checks=()

have_ruby=false
if command -v ruby >/dev/null 2>&1; then have_ruby=true; fi

now_ms() {
    if [ -n "${EPOCHREALTIME:-}" ]; then
        # bash 5+: no subprocess per timestamp
        local t="${EPOCHREALTIME/./}"
        echo $((t / 1000))
    else
        python3 -c 'import time; print(int(time.time() * 1000))'
    fi
}

slugify() {
    printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//' | cut -c1-60
}

selected() {
    [ -z "$only" ] && return 0
    case "$1" in *"$only"*) return 0 ;; esac
    return 1
}

# check NAME COMMAND [slow]
#   COMMAND is a single shell string, run with `bash -c` from the repo root and
#   stdin closed. It is printed verbatim so it can be re-run by hand.
check() {
    local name="$1" command="$2" speed="${3:-}"
    selected "$name" || return 0
    if [ "$quick" = true ] && [ "$speed" = "slow" ]; then
        return 0
    fi
    check_index=$((check_index + 1))
    if [ "$list_only" = true ]; then
        printf '%-44s %s\n' "$name" "$command"
        return 0
    fi
    local log
    log="$LOG_DIR/$(printf '%03d' "$check_index")-$(slugify "$name").log"
    local start end elapsed status
    start="$(now_ms)"
    if [ "$verbose" = true ]; then
        bash -c "$command" </dev/null 2>&1 | tee "$log"
        status="${PIPESTATUS[0]}"
    else
        bash -c "$command" </dev/null >"$log" 2>&1
        status=$?
    fi
    end="$(now_ms)"
    elapsed="$(( (end - start) / 1000 )).$(( ((end - start) % 1000) / 100 ))s"
    if [ "$status" -eq 0 ]; then
        pass_count=$((pass_count + 1))
        printf 'PASS  %6s  %-44s $ %s\n' "$elapsed" "$name" "$command"
    else
        fail_count=$((fail_count + 1))
        failed_checks+=("$name$SEP$command$SEP$log")
        printf 'FAIL  %6s  %-44s $ %s\n' "$elapsed" "$name" "$command"
        if [ "$verbose" = false ]; then
            echo "      --- last 40 lines of $log (exit $status) ---"
            tail -n 40 "$log" | sed 's/^/      | /'
        fi
    fi
}

skip() {
    local name="$1" reason="$2"
    selected "$name" || return 0
    if [ "$list_only" = true ]; then
        printf '%-44s SKIP: %s\n' "$name" "$reason"
        return 0
    fi
    if [ "$strict_tools" = true ]; then
        fail_count=$((fail_count + 1))
        failed_checks+=("$name$SEP(not run: $reason)$SEP-")
        printf 'FAIL  %6s  %-44s (not run under --strict-tools: %s)\n' "-" "$name" "$reason"
        return 0
    fi
    skip_count=$((skip_count + 1))
    printf 'SKIP  %6s  %-44s (%s)\n' "-" "$name" "$reason"
}

echo "Transcripted Linux checks (no Swift) — repo: $REPO_ROOT"
[ "$quick" = true ] && echo "Mode: --quick (slow lanes skipped)"
[ -n "$only" ] && echo "Filter: --only $only"
echo ""

# ---------------------------------------------------------------- agent contract
# These mirror repo-hygiene's inline steps; test-matrix-checks and agent-context pin
# exact matrix command strings.
if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    check "agent preflight" "bash scripts/dev/agent-preflight.sh origin/main"
else
    skip "agent preflight" "origin/main not available; fetch it to enable"
fi
check "test matrix selector self-test" "python3 scripts/dev/test-matrix-checks.py --self-test"
check "agent contract self-test" "python3 scripts/dev/agent-context.py --self-test"
check "agent proof runner self-test" "python3 scripts/dev/agent-check.py --self-test"
if [ -f scripts/dev/check-superseded.py ]; then
    check "check-superseded self-test" "python3 scripts/dev/check-superseded.py --self-test"
fi

# ---------------------------------------------------------------- build/source contracts
check "build source lists" "python3 scripts/dev/check-build-source-lists.py"
check "duplicate declarations self-test" "python3 scripts/dev/check-duplicate-declarations.py --self-test"
check "duplicate declarations" "python3 scripts/dev/check-duplicate-declarations.py"
check "fast-test naming convention (run-tests --list)" "bash run-tests.sh --list"
check "source pins self-test" "python3 scripts/dev/check-source-pins.py --self-test"
if [ "$quick" = true ] && git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    check "source pins (changed vs origin/main)" "python3 scripts/dev/check-source-pins.py --changed-only origin/main"
else
    check "source pins (Swift text contracts)" "python3 scripts/dev/check-source-pins.py"
fi

# ---------------------------------------------------------------- telemetry/privacy
check "analytics emitters" "python3 scripts/dev/check-analytics-emitters.py"
if python3 scripts/ops/normalize-analytics-taxonomy.py --help 2>/dev/null | grep -q -- '--check'; then
    check "analytics taxonomy normalized" "python3 scripts/ops/normalize-analytics-taxonomy.py --check"
else
    skip "analytics taxonomy normalized" "normalize-analytics-taxonomy.py has no --check flag"
fi
check "telemetry keys self-test" "python3 scripts/dev/check-telemetry-keys.py --self-test"
check "telemetry keys survive sanitizers" "python3 scripts/dev/check-telemetry-keys.py"
check "privacy leak sweep" "python3 scripts/ops/privacy-leak-sweep.py --write-report $OUT_DIR/privacy-leak-sweep-report.json"

# The strict release-health gate needs the GitHub release fixture that matches
# the current bundle version; compute it from Info.plist so this never goes stale.
app_version="$(python3 -c 'import plistlib; print(plistlib.load(open("Info.plist", "rb"))["CFBundleShortVersionString"])' 2>/dev/null || true)"
release_fixture="Tests/Fixtures/release-health-github-release-${app_version}.json"

# Paths whose change makes the tag-dependent release-health gate the PR's business.
RELEASE_SURFACE_RE='^(Info\.plist|docs/appcast\.xml|Casks/|Tests/Fixtures/release-health-|scripts/ops/nightly-security-check\.py)'

# Prints "yes"/"no" for whether the branch (committed + uncommitted + untracked,
# vs its merge-base with origin/main) touches a release surface, or "unknown".
release_surface_changed() {
    local base
    if ! base="$(git merge-base HEAD origin/main 2>/dev/null)"; then
        echo unknown
        return
    fi
    if { git diff --name-only "$base" 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } \
        | grep -Eq "$RELEASE_SURFACE_RE"; then
        echo yes
    else
        echo no
    fi
}

run_nightly_strict=true
nightly_skip_reason=""
if [ "$strict_tools" = true ]; then
    case "$(release_surface_changed)" in
        yes) ;;
        no)
            run_nightly_strict=false
            nightly_skip_reason="no release surface changed vs origin/main; tag-dependent gate stays out of PR checks"
            ;;
        *)
            run_nightly_strict=false
            nightly_skip_reason="cannot diff vs origin/main; tag-dependent gate stays out of PR checks"
            ;;
    esac
fi

if [ "$run_nightly_strict" = false ]; then
    # Always an informational SKIP, even under --strict-tools.
    if selected "nightly security strict" && [ "$list_only" = false ]; then
        skip_count=$((skip_count + 1))
        printf 'SKIP  %6s  %-44s (%s)\n' "-" "nightly security strict" "$nightly_skip_reason"
    elif selected "nightly security strict"; then
        printf '%-44s SKIP: %s\n' "nightly security strict" "$nightly_skip_reason"
    fi
elif [ -n "$app_version" ] && [ -f "$release_fixture" ]; then
    check "nightly security strict ($app_version fixture)" "python3 scripts/ops/nightly-security-check.py --strict --automation-toml Tests/Fixtures/nightly-security-automation.toml --github-release-json $release_fixture --write-report $OUT_DIR/nightly-security-report.json"
else
    # No fixture for this version yet (e.g. mid version bump): still run the
    # rest of the strict gate, just without the GitHub asset-digest comparison.
    check "nightly security strict (no ${app_version:-?} GitHub fixture)" "python3 scripts/ops/nightly-security-check.py --strict --automation-toml Tests/Fixtures/nightly-security-automation.toml --write-report $OUT_DIR/nightly-security-report.json"
fi

# ---------------------------------------------------------------- syntax
check "shell syntax (root, scripts, Tests/BuildDependencies)" \
    "set -e; for f in *.sh; do bash -n \"\$f\"; done; find scripts Tests/BuildDependencies -name '*.sh' -print0 | xargs -0 -n1 bash -n"
check "python syntax (scripts)" "find scripts -name '*.py' -print0 | xargs -0 python3 -m py_compile"
if [ "$have_ruby" = true ]; then
    check "ruby syntax (scripts)" "find scripts -name '*.rb' -print0 | xargs -0 -n1 ruby -c >/dev/null"
else
    skip "ruby syntax (scripts)" "ruby not installed"
fi

# ---------------------------------------------------------------- VM script guards
check "vnc driver self-test" "python3 scripts/vm/vnc.py --self-test"
check "clean VM script guards" "bash scripts/vm/test-transcripted-vm.sh"

# ---------------------------------------------------------------- ops/release self-tests
# Explicit opt-in lists: anything here becomes a REQUIRED check on every PR
# once the repo-hygiene job runs this script. To add yours, append its path to the
# matching array below. It must pass offline, in any timezone, with only the
# python3 stdlib (or ruby), and write nothing outside build/ or $TMPDIR.
SELF_TEST_SCRIPTS=(
    scripts/ops/check-crash-free-rate.py
    scripts/ops/generate-nightly-digest.py
    scripts/ops/packaged-app-smoke.py
    scripts/ops/posthog-activation-funnel.py
    scripts/ops/posthog-dashboard-queries.py
    scripts/ops/posthog-product-context-pack.py
    scripts/ops/posthog-product-dashboard-summary.py
    scripts/ops/release-gate-report.py
    scripts/ops/release-health-card.py
    scripts/ops/release-watch.py
    scripts/ops/retention-cohort-report.py
    scripts/release/bump-release-version.py
    scripts/release/post-dmg-release-audit.py
    scripts/release/sentry-release-dry-run.py
)
PY_TEST_SUITES=(
    scripts/ops/test-native-smoke-isolation.py
    scripts/ops/test-nightly-security-check.py
    scripts/ops/test-score-boards.py
    scripts/test_speaker_autoresearch.py
)
# Empty for now. Expansions below use ${arr[@]+...} so an empty list is safe
# under set -u on macOS's bash 3.2.
RB_TEST_SUITES=()

for script in "${SELF_TEST_SCRIPTS[@]}"; do
    check "self-test $(basename "$script")" "python3 $script --self-test"
done

# ---------------------------------------------------------------- script test suites
for script in "${PY_TEST_SUITES[@]}"; do
    check "py tests $(basename "$script")" "python3 $script" slow
done

if [ "$have_ruby" = true ]; then
    for script in ${RB_TEST_SUITES[@]+"${RB_TEST_SUITES[@]}"}; do
        check "rb tests $(basename "$script")" "ruby $script" slow
    done
    check "dictation recovery autoeval (fixture)" "ruby scripts/ops/dictation-recovery-autoeval.rb --details" slow
else
    skip "ruby test suites" "ruby not installed"
fi

# Informational only: candidates that look like self-tests/test suites but are
# not in the lists above. Never fails; it just tells authors how to opt in.
unlisted_candidates() {
    local listed=" ${SELF_TEST_SCRIPTS[*]} ${PY_TEST_SUITES[*]} ${RB_TEST_SUITES[*]+${RB_TEST_SUITES[*]}} "
    {
        grep -l -- '"--self-test"' scripts/ops/*.py scripts/release/*.py 2>/dev/null
        find scripts \( -name 'test-*.py' -o -name 'test_*.py' -o -name '*-test.rb' -o -name '*_test.rb' -o -name 'test_*.rb' \) \
            ! -name 'test-matrix-checks.py' -print 2>/dev/null
    } | sort -u | while IFS= read -r candidate; do
        case "$listed" in *" $candidate "*) ;; *) echo "$candidate" ;; esac
    done
}

check "build-deps archive inputs" "bash Tests/BuildDependencies/ArchiveInputsTests.sh" slow
check "CLI packaging contracts" "bash Tests/BuildDependencies/CLIPackagingTests.sh" slow

# ---------------------------------------------------------------- deterministic fixture lanes (from .agents/test-matrix.yml)
check "posthog dashboard summary (fixture)" "python3 scripts/ops/posthog-product-dashboard-summary.py --fixture Tests/Fixtures/posthog-product-dashboard-summary.json --json-only >/dev/null" slow
check "posthog product context pack (fixture)" "python3 scripts/ops/posthog-product-context-pack.py --fixture Tests/Fixtures/posthog-product-context-pack-fixture.json --write-dir $OUT_DIR/posthog-product-context-sample" slow
check "posthog taxonomy check (fixture)" "python3 scripts/ops/posthog-dashboard-queries.py --taxonomy-check --observed-fixture Tests/Fixtures/posthog-observed-event-taxonomy.json --json-only >/dev/null" slow
# --version is required; use the next patch after Info.plist's version, i.e. the
# bump a release-prep branch would actually make. --dry-run writes nothing.
next_patch_version="$(python3 -c 'import plistlib; a, b, c = plistlib.load(open("Info.plist", "rb"))["CFBundleShortVersionString"].split("."); print(f"{a}.{b}.{int(c) + 1}")' 2>/dev/null || true)"
if [ -n "$next_patch_version" ]; then
    check "bump-release-version dry run" "python3 scripts/release/bump-release-version.py --version $next_patch_version --dry-run" slow
else
    skip "bump-release-version dry run" "could not read an x.y.z CFBundleShortVersionString from Info.plist"
fi
check "speaker naming simulator" "python3 scripts/ops/speaker-naming-simulator.py" slow

# ---------------------------------------------------------------- summary
if [ "$list_only" = true ]; then
    exit 0
fi

unlisted="$(unlisted_candidates)"
if [ -n "$unlisted" ] && [ -z "$only" ]; then
    echo ""
    echo "Note: these look like self-tests/test suites but are not run here (not a failure)."
    echo "To make one a required check, add it to SELF_TEST_SCRIPTS / PY_TEST_SUITES / RB_TEST_SUITES in scripts/dev/linux-checks.sh:"
    printf '%s\n' "$unlisted" | sed 's/^/  - /'
fi

echo ""
echo "Summary: $pass_count passed, $fail_count failed, $skip_count skipped (logs: $LOG_DIR/)"
if [ "$fail_count" -gt 0 ]; then
    echo "Failed checks (re-run individually from the repo root):"
    for entry in "${failed_checks[@]}"; do
        IFS="$SEP" read -r name command log <<<"$entry"
        echo "  - $name"
        echo "      \$ $command"
        echo "      log: $log"
    done
    exit 1
fi
exit 0

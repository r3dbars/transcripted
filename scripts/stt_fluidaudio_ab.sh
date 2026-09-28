#!/usr/bin/env bash
# FluidAudio A/B for Parakeet V3 speech-to-text. One command on an Apple Silicon Mac:
#
#   bash scripts/stt_fluidaudio_ab.sh           # origin/main @ FluidAudio 0.15.4 vs HEAD @ 0.17.0
#   bash scripts/stt_fluidaudio_ab.sh --quick   # 3-minute plumbing check once the builds exist
#
# What it does:
#   1. Checks out each side as a git worktree under <base>/src/<side> and builds it:
#      FLUID_AUDIO_VERSION=<version> bash build-deps.sh --force, then the CLI with
#      TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION=1 swift build -c release. The CLI links
#      FluidAudio from its own checkout's deps-libs/, so two worktrees are the only
#      way to have both versions side by side. Builds are reused while the side's
#      inputs (CLI, CaptureKit, TranscriptedCore, Package.swift, build-deps.sh) and
#      version are unchanged, so only the first run pays for build-deps (long).
#   2. Runs scripts/stt_fluidaudio_ab.py (under uv with the shootout's pinned jiwer +
#      Whisper normalizer + yt-dlp): WER on a captioned lecture, and dictation-stop
#      timing on silence / noise / short speech. See that file's docstring.
#
# Why the baseline is a different ref: 0.15.4 can't compile the 0.17-only
# `ASRConfig(melChunkContext:seamGapRepair:)` call (CLI + app) or the 0.17 diarizer
# config in TranscriptedCore, so the baseline side builds the pre-bump source from
# --baseline-ref (default origin/main). The wrapper refuses a baseline ref whose CLI
# already uses the 0.17 API; pass the commit before the bump then.
#
# Flags (everything not listed here passes through to stt_fluidaudio_ab.py, e.g.
# --minutes, --segments, --repeats, --rounds, --max-wer-delta-pp, --max-time-ratio,
# --max-time-delta-ms, --audio/--reference, --models-source, --quick):
#   --base-dir DIR            work folder (default ~/stt-fluidaudio-ab, env STT_AB_BASE)
#   --baseline-ref REF        default origin/main
#   --candidate-ref REF       default HEAD
#   --baseline-version V      default 0.15.4
#   --candidate-version V     default 0.17.0
#   --skip-build              use the existing builds; fail if one is missing
#   --rebuild                 rebuild both sides even if their inputs are unchanged
#   --no-fetch                don't `git fetch origin` first
#
# Output: <base>/runs/<UTC stamp>/{result.json,report.md,transcripts/,logs/}. Progress
# goes to stderr; the last stdout line is the result.json path. Exit 0 = gate passed,
# 3 = gate failed, 1 = something couldn't run.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="${STT_AB_BASE:-$HOME/stt-fluidaudio-ab}"
BASELINE_REF="origin/main"
CANDIDATE_REF="HEAD"
BASELINE_VERSION="0.15.4"
CANDIDATE_VERSION="0.17.0"
SKIP_BUILD=0
REBUILD=0
FETCH=1
PY_ARGS=()

die() { echo "[stt-ab] ERROR: $*" >&2; exit 1; }
say() { echo "[stt-ab] $*" >&2; }

need_value() { [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --base-dir) need_value "$@"; BASE="$2"; shift 2 ;;
        --baseline-ref) need_value "$@"; BASELINE_REF="$2"; shift 2 ;;
        --candidate-ref) need_value "$@"; CANDIDATE_REF="$2"; shift 2 ;;
        --baseline-version) need_value "$@"; BASELINE_VERSION="$2"; shift 2 ;;
        --candidate-version) need_value "$@"; CANDIDATE_VERSION="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --rebuild) REBUILD=1; shift ;;
        --no-fetch) FETCH=0; shift ;;
        -h|--help) sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) PY_ARGS+=("$1"); shift ;;
    esac
done

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "The A/B measures Parakeet on Core ML, so it only runs on an Apple Silicon Mac." >&2
    echo "(Linux checks: python3 $REPO/scripts/test_stt_fluidaudio_ab.py)" >&2
    exit 1
fi

mkdir -p "$BASE"
BASE="$(cd "$BASE" && pwd -P)"

if [ "$FETCH" = 1 ]; then
    say "Fetching origin..."
    git -C "$REPO" fetch --quiet origin >&2 || say "git fetch failed; using the refs already here"
fi

# Hash of everything that goes into the CLI binary for one commit + version.
build_key() {
    local sha="$1" version="$2" path
    {
        echo "fluidaudio=$version"
        for path in Tools/TranscriptedCLI Tools/TranscriptedCaptureKit Sources/TranscriptedCore \
            Package.swift scripts/entrypoints/build-deps.sh build-deps.sh; do
            echo "$path=$(git -C "$REPO" rev-parse --verify --quiet "$sha:$path" || echo missing)"
        done
    } | shasum -a 256 | awk '{print $1}'
}

json_field() {
    python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception: print("")' "$1" "$2"
}

build_side() {
    local side="$1" ref="$2" version="$3"
    local sha src record logs key cli bin_dir resolved build_info ref_label
    sha="$(git -C "$REPO" rev-parse --verify --quiet "$ref^{commit}")" || die "can't resolve $side ref '$ref'"
    src="$BASE/src/$side"
    record="$BASE/builds/$side.json"
    logs="$BASE/builds/$side-logs"
    cli=""
    [ -f "$record" ] && cli="$(json_field "$record" cli)"
    key="$(build_key "$sha" "$version")"

    if [ "$SKIP_BUILD" = 1 ]; then
        [ -n "$cli" ] && [ -x "$cli" ] || die "--skip-build, but there is no $side build yet (run without --skip-build)"
        [ "$(json_field "$record" fluidaudio_version)" = "$version" ] \
            || die "--skip-build, but the $side build is FluidAudio $(json_field "$record" fluidaudio_version), not $version"
        say "$side: reusing $(json_field "$record" ref) @ $(json_field "$record" commit | cut -c1-10) (--skip-build)"
        return 0
    fi

    if [ "${version#0.15.}" != "$version" ] \
        && git -C "$REPO" show "$sha:Tools/TranscriptedCLI/Sources/TranscriptedCLI/TranscribeCommand.swift" 2>/dev/null \
            | grep -q 'seamGapRepair'; then
        die "$side ref $ref already calls the FluidAudio 0.17 ASRConfig API, so it can't build on $version. Pass --baseline-ref <commit before the bump>."
    fi

    if [ -d "$src" ]; then
        # Only ever force a checkout inside our own worktree, never a parent repo.
        [ "$(git -C "$src" rev-parse --show-toplevel 2>/dev/null)" = "$src" ] \
            || die "$src exists but isn't a git worktree; delete it and rerun"
        git -C "$src" checkout --quiet --force --detach "$sha" >&2
    else
        mkdir -p "$BASE/src"
        git -C "$REPO" worktree prune
        git -C "$REPO" worktree add --quiet --detach "$src" "$sha" >&2
    fi

    if [ "$REBUILD" = 0 ] && [ -n "$cli" ] && [ -x "$cli" ] && [ "$(json_field "$record" build_key)" = "$key" ]; then
        say "$side: build is current for $ref @ ${sha:0:10} (FluidAudio $version)"
    else
        mkdir -p "$logs"
        say "$side: build-deps with FluidAudio $version at $ref @ ${sha:0:10} (long; log: $logs/build-deps.log)..."
        (cd "$src" && FLUID_AUDIO_VERSION="$version" bash build-deps.sh --force) >"$logs/build-deps.log" 2>&1 \
            || die "$side build-deps failed; see $logs/build-deps.log"
        say "$side: building transcripted-cli (log: $logs/cli-build.log)..."
        TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION=1 swift build -c release \
            --package-path "$src/Tools/TranscriptedCLI" --product transcripted-cli >"$logs/cli-build.log" 2>&1 \
            || die "$side CLI build failed; see $logs/cli-build.log"
        bin_dir="$(TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION=1 swift build -c release \
            --package-path "$src/Tools/TranscriptedCLI" --product transcripted-cli --show-bin-path)"
        cli="$bin_dir/transcripted-cli"
        [ -x "$cli" ] || die "$side CLI build produced no binary at $cli"
    fi

    # SwiftPM prints "Computed .../FluidAudio.git at X"; catch an override that didn't take.
    resolved="$(grep -Eo 'FluidAudio(\.git)? at [0-9][0-9A-Za-z.+-]*' "$logs/build-deps.log" 2>/dev/null | tail -1 | awk '{print $NF}' || true)"
    if [ -n "$resolved" ] && [ "$resolved" != "$version" ]; then
        die "$side resolved FluidAudio $resolved, expected $version (see $logs/build-deps.log)"
    fi
    build_info="$(TRANSCRIPTED_DISABLE_FILE_LOGGER=1 "$cli" build-info 2>/dev/null || echo '{}')"
    ref_label="$ref"
    if [ "$ref" = "HEAD" ]; then
        ref_label="HEAD ($(git -C "$REPO" rev-parse --abbrev-ref HEAD))"
    fi
    python3 - "$record" "$side" "$ref_label" "$sha" "$version" "${resolved:-unknown}" "$cli" "$key" "$build_info" <<'PY' || die "couldn't write $record"
import json, sys
from datetime import datetime, timezone
path, side, ref, sha, version, resolved, cli, key, info = sys.argv[1:]
try:
    info = json.loads(info)
except json.JSONDecodeError:
    info = {}
if not info.get("transcription"):
    sys.exit(f"{cli} build-info says transcription is off: {info}")
old = {}
try:
    old = json.load(open(path))
except Exception:
    pass
record = {
    "side": side, "ref": ref, "commit": sha, "fluidaudio_version": version,
    "fluidaudio_resolved": resolved if resolved != "unknown" else old.get("fluidaudio_resolved", "unknown"),
    "cli": cli, "build_key": key, "build_info": info,
    "built_at": old.get("built_at") if old.get("build_key") == key else datetime.now(timezone.utc).isoformat(timespec="seconds"),
}
json.dump(record, open(path, "w"), indent=2)
PY
}

mkdir -p "$BASE/builds"
build_side baseline "$BASELINE_REF" "$BASELINE_VERSION"
build_side candidate "$CANDIDATE_REF" "$CANDIDATE_VERSION"

export PATH="$HOME/.local/bin:$PATH"
if ! command -v uv >/dev/null 2>&1; then
    say "Installing uv (Python manager) into ~/.local/bin..."
    curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh >&2
fi
export HF_HUB_DISABLE_TELEMETRY=1
export TRANSCRIPTED_DISABLE_FILE_LOGGER=1
export PYTHONWARNINGS="ignore::SyntaxWarning"
export UV_CACHE_DIR="${UV_CACHE_DIR:-$BASE/uv-cache}"
export UV_PYTHON_INSTALL_DIR="${UV_PYTHON_INSTALL_DIR:-$BASE/uv-python}"

# Same pins as scripts/stt-shootout/run.sh, so WER matches the shootout's scoring.
exec uv run --quiet --no-project --python 3.12 \
    --with "yt-dlp[default,deno]" --with "jiwer==4.0.0" --with "whisper-normalizer==0.1.12" \
    python "$REPO/scripts/stt_fluidaudio_ab.py" \
    --base "$BASE" \
    --baseline-cli "$(json_field "$BASE/builds/baseline.json" cli)" \
    --baseline-build-json "$BASE/builds/baseline.json" \
    --candidate-cli "$(json_field "$BASE/builds/candidate.json" cli)" \
    --candidate-build-json "$BASE/builds/candidate.json" \
    ${PY_ARGS[@]+"${PY_ARGS[@]}"}

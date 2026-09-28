#!/usr/bin/env bash
# Run one simulated set through the real meeting pipeline and score it.
#
#   bash scripts/speaker_lab/run_set.sh <set> [knobs.json] [extra harness args...]
#   RUN_TAG=hint-oracle bash scripts/speaker_lab/run_set.sh <set> --speaker-hint oracle
#   (HARNESS=<path> picks another harness build)
#
# <set> lives at data/eval/yodas3/sim/<set> (make it with meeting_sim.py).
# An optional knobs file is passed through TRANSCRIPTED_LAB_KNOBS_FILE (see
# Sources/TranscriptedCore/Utilities/LabKnobOverrides.swift); results then go
# to a copy of the set named <set>@<knobs basename>, so the baseline stays put.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
root="${YODAS_ROOT:-$repo_root/data/eval/yodas3}"
py="$root/venv/bin/python"
harness="${HARNESS:-$repo_root/Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness}"
set_name="${1:?usage: $0 <set> [knobs.json] [harness args...]}"
shift
knobs=""
if [[ $# -gt 0 && "$1" == *.json ]]; then
  knobs="$1"
  shift
fi

src="$root/sim/$set_name"
[[ -f "$src/series.json" ]] || { echo "no set at $src" >&2; exit 2; }
[[ -x "$harness" ]] || swift build --package-path "$repo_root/Tools/SpeakerEvalHarness" -c release

run_name="$set_name"
tag="${RUN_TAG:-}"
[[ -n "$knobs" && -z "$tag" ]] && tag="$(basename "$knobs" .json)"
if [[ -n "$tag" ]]; then
  run_name="$set_name@$tag"
  dst="$root/sim/$run_name"
  mkdir -p "$dst"
  cp "$src/series.json" "$dst/series.json"
  # Share the audio and answer keys; each run keeps its own lab_result.json.
  for m in "$src"/*/; do
    m="$(basename "$m")"
    mkdir -p "$dst/$m"
    for f in mic.wav system.wav truth.json calendar.json truth.rttm; do
      [[ -e "$dst/$m/$f" ]] || ln -s "$src/$m/$f" "$dst/$m/$f"
    done
  done
  sed -i '' "s/\"set\": \"$set_name\"/\"set\": \"$run_name\"/" "$dst/series.json"
fi
if [[ -n "$knobs" ]]; then
  export TRANSCRIPTED_LAB_KNOBS_FILE="$(cd "$(dirname "$knobs")" && pwd)/$(basename "$knobs")"
fi

export TRANSCRIPTED_DISABLE_FILE_LOGGER=1
"$harness" meeting-series --series "$root/sim/$run_name" "$@"
"$py" "$repo_root/scripts/speaker_lab/score.py" --set "$run_name"

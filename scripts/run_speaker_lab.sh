#!/bin/bash
# Speaker lab: side-by-side bake-off of diarizers and voice-fingerprint models on the
# SAME meetings, scored on what users feel — did the app find the right speakers, and
# did it recognize a returning person on their next call without asking again?
#
#   1. build the harness (unless --skip-build)
#   2. dump every meeting once per VARIANT = diarizer backend × embedder (× Nemotron preset),
#      cached under data/eval/<corpus>/dumps/<variant>/ (variants never share a cache)
#   2b. (--embedding-parity) diarize each meeting with today's pyannote pipeline and re-embed
#      the same segments with the online WeSpeaker model the Nemotron backend falls back to,
#      cached under data/eval/<corpus>/parity/ — can Nemotron voiceprints share speakers.sqlite?
#   3. replay each variant's dumps in meeting order through the real clusterer + speaker DB
#      for every knob setting in the grid
#   4. score everything (scripts/score_speaker_lab.py) into ONE run directory:
#        reports/speaker-lab/<timestamp>/{REPORT.md,scores.json,recognition-events.json}
#      (+ timeline.html in --own-calls mode)
#
# The last line on stdout is always the absolute path of scores.json, so an outer
# optimizer can call this once per trial. Progress goes to stderr. Exit status is
# non-zero on any failure. Nothing here is interactive.
#
# Usage:
#   bash scripts/run_speaker_lab.sh                                  # AMI, default variants + sweep
#   bash scripts/run_speaker_lab.sh --variants "pyannote:native nemotron:native nemotron:native:fast32"
#   bash scripts/run_speaker_lab.sh --single --backend nemotron --match 0.6 --write-path-fixes on
#   bash scripts/run_speaker_lab.sh --own-calls "$HOME/Library/Application Support/Transcripted/captures/meetings"
#
# Every flag has an env twin (flag wins). Grid knobs take a space-separated list; the
# replay sweep is their cartesian product. See Tools/SpeakerEvalHarness/README.md
# "Speaker lab" for what each knob does and for the scores.json schema.
#
#   --variants / VARIANTS        "backend:embedder[:preset] ..."  backend pyannote|nemotron,
#                                embedder native|eres2net, preset = TRANSCRIPTED_NEMOTRON_PRESET
#   --backend/--embedder/--preset  shorthand for one variant (BACKEND, EMBEDDER, NEMOTRON_PRESET)
#   --eres2net-model / ERES2NET_MODEL   path to the ERes2Net Model.mlmodelc
#   --corpus / CORPUS            ami | icsi | voxconverse | voxceleb (default ami)
#   --series / SERIES            meeting ids or AMI series prefixes (ES2002 = ES2002a–d); default: all downloaded
#   --own-calls <folder>         run on your own saved meetings (no ground truth)
#   --own-calls-limit / OWN_CALLS_LIMIT   only the N most recent calls
#   --match / MATCH              grid: floats and/or "adaptive" (default per embedder, see below)
#   --same-voice / SAME_VOICE    grid: profile | none | float        (default profile)
#   --consolidation / CONSOLIDATION  grid: none | float (pairwise merge) (default: harness default none)
#   --write-path-fixes / WRITE_PATH_FIXES  grid: on | off           (default on = what ships)
#   --thresholds / THRESHOLDS    grid: auto | weSpeaker | eRes2Net   (default auto)
#   --dedup / DEDUP              grid: match | float                 (default 0.6 = what ships)
#   --blend-confident / BLEND_CONFIDENT, --blend-cautious / BLEND_CAUTIOUS,
#   --writeback-confident-sim / WRITEBACK_CONFIDENT_SIM, --writeback-cautious-sim /
#   WRITEBACK_CAUTIOUS_SIM, --writeback-margin / WRITEBACK_MARGIN   grids, fingerprint update
#                                policy (default: SpeakerWritePathPolicy production values)
#   --single / SINGLE=1          one variant, one setting, no sweep (grids must be one value;
#                                unset knobs take the production defaults)
#   --collar / COLLAR            DER collar, pyannote convention (default 0.25)
#   --min-appearance-sec / MIN_APPEARANCE_SEC   ignore appearances shorter than this (default 5)
#   --wrong-penalty / WRONG_PENALTY  objective weight on wrong-person + false-match (default 2)
#   --out-dir / OUT_DIR          run directory (default reports/speaker-lab/<utc timestamp>-<pid>)
#   --skip-build / SKIP_BUILD=1  reuse the existing release harness binary
#   --redump / REDUMP=1          ignore cached dumps (and cached parity reports)
#   --embedding-parity / EMBEDDING_PARITY=1   also run the WeSpeaker embedding-parity check per
#                                meeting and add `embeddingParity` to scores.json + REPORT.md
#   ALLOW_PARTIAL_CORPUS=1       keep going when some meetings are missing or fail to dump
#   HARNESS_BIN                  use this harness binary (implies --skip-build; used by tests)
#   LAB_DATA_DIR                 corpus + dump cache root (default <repo>/data)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
COMMAND_LINE="$0 $*"

say() { echo "$@" >&2; }
die() { echo "error: $*" >&2; exit 1; }

# ---- flags (env twins as defaults) ------------------------------------------------------
VARIANTS="${VARIANTS:-}"
BACKEND="${BACKEND:-}"; EMBEDDER="${EMBEDDER:-}"; PRESET="${NEMOTRON_PRESET:-}"
ERES2NET_MODEL="${ERES2NET_MODEL:-}"
CORPUS="${CORPUS:-ami}"
SERIES="${SERIES:-}"
OWN_CALLS="${OWN_CALLS:-}"
OWN_CALLS_LIMIT="${OWN_CALLS_LIMIT:-0}"
MATCH="${MATCH:-}"
SAME_VOICE="${SAME_VOICE:-profile}"
CONSOLIDATION="${CONSOLIDATION:-}"
WRITE_PATH_FIXES="${WRITE_PATH_FIXES:-on}"
THRESHOLDS="${THRESHOLDS:-}"
DEDUP="${DEDUP:-0.6}"
BLEND_CONFIDENT="${BLEND_CONFIDENT:-}"
BLEND_CAUTIOUS="${BLEND_CAUTIOUS:-}"
WRITEBACK_CONFIDENT_SIM="${WRITEBACK_CONFIDENT_SIM:-}"
WRITEBACK_CAUTIOUS_SIM="${WRITEBACK_CAUTIOUS_SIM:-}"
WRITEBACK_MARGIN="${WRITEBACK_MARGIN:-}"
SINGLE="${SINGLE:-0}"
COLLAR="${COLLAR:-0.25}"
MIN_APPEARANCE_SEC="${MIN_APPEARANCE_SEC:-5}"
WRONG_PENALTY="${WRONG_PENALTY:-2}"
OUT_DIR="${OUT_DIR:-}"
SKIP_BUILD="${SKIP_BUILD:-0}"
REDUMP="${REDUMP:-0}"
EMBEDDING_PARITY="${EMBEDDING_PARITY:-0}"
ALLOW_PARTIAL_CORPUS="${ALLOW_PARTIAL_CORPUS:-0}"
HARNESS_BIN="${HARNESS_BIN:-}"
LAB_DATA_DIR="${LAB_DATA_DIR:-$ROOT/data}"

while [ $# -gt 0 ]; do
  flag="$1"
  case "$flag" in
    --single) SINGLE=1; shift; continue ;;
    --skip-build) SKIP_BUILD=1; shift; continue ;;
    --redump) REDUMP=1; shift; continue ;;
    --embedding-parity) EMBEDDING_PARITY=1; shift; continue ;;
    -h|--help) awk 'NR > 1 && /^set -euo/ { exit } NR > 1' "$0" >&2; exit 0 ;;
  esac
  [ $# -ge 2 ] || die "$flag needs a value"
  val="$2"
  case "$flag" in
    --variants) VARIANTS="$val" ;;
    --backend) BACKEND="$val" ;;
    --embedder) EMBEDDER="$val" ;;
    --preset) PRESET="$val" ;;
    --eres2net-model) ERES2NET_MODEL="$val" ;;
    --corpus) CORPUS="$val" ;;
    --series) SERIES="$val" ;;
    --own-calls) OWN_CALLS="$val" ;;
    --own-calls-limit) OWN_CALLS_LIMIT="$val" ;;
    --match) MATCH="$val" ;;
    --same-voice) SAME_VOICE="$val" ;;
    --consolidation) CONSOLIDATION="$val" ;;
    --write-path-fixes) WRITE_PATH_FIXES="$val" ;;
    --thresholds) THRESHOLDS="$val" ;;
    --dedup) DEDUP="$val" ;;
    --blend-confident) BLEND_CONFIDENT="$val" ;;
    --blend-cautious) BLEND_CAUTIOUS="$val" ;;
    --writeback-confident-sim) WRITEBACK_CONFIDENT_SIM="$val" ;;
    --writeback-cautious-sim) WRITEBACK_CAUTIOUS_SIM="$val" ;;
    --writeback-margin) WRITEBACK_MARGIN="$val" ;;
    --collar) COLLAR="$val" ;;
    --min-appearance-sec) MIN_APPEARANCE_SEC="$val" ;;
    --wrong-penalty) WRONG_PENALTY="$val" ;;
    --out-dir) OUT_DIR="$val" ;;
    *) die "unknown flag $flag (see --help)" ;;
  esac
  shift 2
done

SCORER="$ROOT/scripts/score_speaker_lab.py"
MODE="corpus"; [ -n "$OWN_CALLS" ] && MODE="own-calls"

# ---- variants -----------------------------------------------------------------------------
DEFAULT_ERES2NET="$HOME/Library/Application Support/FluidAudio/Models/eres2net-embedding/Model.mlmodelc"
if [ -n "$BACKEND$EMBEDDER$PRESET" ]; then
  [ -z "$VARIANTS" ] || die "use --variants OR --backend/--embedder/--preset, not both"
  VARIANTS="${BACKEND:-pyannote}:${EMBEDDER:-native}${PRESET:+:$PRESET}"
fi
if [ -z "$VARIANTS" ]; then
  if [ "$SINGLE" = "1" ]; then
    VARIANTS="pyannote:native"
  else
    VARIANTS="pyannote:native nemotron:native"
    if [ -e "${ERES2NET_MODEL:-$DEFAULT_ERES2NET}" ]; then
      VARIANTS="$VARIANTS pyannote:eres2net nemotron:eres2net"
    else
      say "    (ERes2Net model not found; skipping eres2net variants — pass --eres2net-model to add them)"
    fi
  fi
fi

V_NAME=(); V_BACKEND=(); V_EMBEDDER=(); V_PRESET=()
for spec in $VARIANTS; do
  IFS=':' read -r b e p extra <<< "$spec"
  [ -z "${extra:-}" ] || die "bad variant '$spec' (backend:embedder[:preset])"
  e="${e:-native}"; [ "$e" = "wespeaker" ] && e="native"
  case "$b" in pyannote|nemotron) ;; *) die "bad backend in '$spec' (pyannote|nemotron)" ;; esac
  case "$e" in native|eres2net) ;; *) die "bad embedder in '$spec' (native|eres2net)" ;; esac
  [ -z "${p:-}" ] || [ "$b" = "nemotron" ] || die "a preset only applies to nemotron ('$spec')"
  ename="wespeaker"; [ "$e" = "eres2net" ] && ename="eres2net"
  V_NAME+=("$b-$ename${p:+-$p}"); V_BACKEND+=("$b"); V_EMBEDDER+=("$e"); V_PRESET+=("${p:-}")
done
[ "${#V_NAME[@]}" -gt 0 ] || die "no variants"

# ---- grids --------------------------------------------------------------------------------
grid_count() { echo "$1" | wc -w | tr -d ' '; }
if [ "$SINGLE" = "1" ] || [ "$MODE" = "own-calls" ]; then
  [ "$SINGLE" != "1" ] || [ "${#V_NAME[@]}" -eq 1 ] || die "--single takes exactly one variant"
  [ -n "$MATCH" ] || MATCH="adaptive"
  for knob in MATCH SAME_VOICE CONSOLIDATION WRITE_PATH_FIXES THRESHOLDS DEDUP BLEND_CONFIDENT \
              BLEND_CAUTIOUS WRITEBACK_CONFIDENT_SIM WRITEBACK_CAUTIOUS_SIM WRITEBACK_MARGIN; do
    [ "$(grid_count "${!knob}")" -le 1 ] || die "$knob must be a single value with --single / --own-calls (got '${!knob}')"
  done
fi
match_grid_for() {   # per-embedder default: ERes2Net cosines run lower than WeSpeaker's
  if [ -n "$MATCH" ]; then echo "$MATCH"
  elif [ "$1" = "eres2net" ]; then echo "adaptive 0.45 0.50 0.55 0.60"
  else echo "adaptive 0.55 0.60 0.65 0.70"; fi
}

# ---- meetings -----------------------------------------------------------------------------
case "$CORPUS" in
  ami)         AUDIO_DIR="$LAB_DATA_DIR/ami/audio";               RTTM_DIR="$LAB_DATA_DIR/ami/rttm";               SUFFIX=".Mix-Headset.wav" ;;
  icsi)        AUDIO_DIR="$LAB_DATA_DIR/icsi/audio";              RTTM_DIR="$LAB_DATA_DIR/icsi/rttm";              SUFFIX=".wav" ;;
  voxconverse) AUDIO_DIR="$LAB_DATA_DIR/voxconverse/audio";       RTTM_DIR="$LAB_DATA_DIR/voxconverse/rttm";       SUFFIX=".wav" ;;
  voxceleb)    AUDIO_DIR="$LAB_DATA_DIR/voxceleb/sessions/audio"; RTTM_DIR="$LAB_DATA_DIR/voxceleb/sessions/rttm"; SUFFIX=".wav" ;;
  *) die "unknown CORPUS='$CORPUS' (ami|icsi|voxconverse|voxceleb)" ;;
esac

STAMP="$(date -u +%Y%m%d-%H%M%S)-$$"
if [ -z "$OUT_DIR" ]; then
  if [ "$MODE" = "own-calls" ]; then OUT_DIR="$ROOT/reports/speaker-lab/own-calls-$STAMP"
  else OUT_DIR="$ROOT/reports/speaker-lab/$STAMP"; fi
fi
mkdir -p "$OUT_DIR/replays" "$OUT_DIR/logs"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
: > "$OUT_DIR/meetings.tsv"; : > "$OUT_DIR/variants.tsv"; : > "$OUT_DIR/replays.tsv"; : > "$OUT_DIR/parity.tsv"

M_ID=(); M_AUDIO=()
if [ "$MODE" = "own-calls" ]; then
  DUMP_ROOT="$LAB_DATA_DIR/eval/own-calls/dumps"
  python3 "$SCORER" own-calls-list --folder "$OWN_CALLS" --limit "$OWN_CALLS_LIMIT" > "$OUT_DIR/meetings.tsv" \
    || die "could not list calls in $OWN_CALLS"
  while IFS=$'\t' read -r id audio _; do
    [ -n "$id" ] || continue
    M_ID+=("$id"); M_AUDIO+=("$audio")
  done < "$OUT_DIR/meetings.tsv"
  [ "${#M_ID[@]}" -gt 0 ] || die "no call audio found under $OWN_CALLS (expected <stem>_audio/system_audio.* or recording.*)"
  say "==> own calls: ${#M_ID[@]} meeting(s) from $OWN_CALLS (audio is read in place, never copied)"
else
  DUMP_ROOT="$LAB_DATA_DIR/eval/$CORPUS/dumps"
  if [ -n "$SERIES" ]; then
    MEETINGS=""
    for tok in $SERIES; do
      if [[ "$tok" =~ ^[A-Z]{2}[0-9]{4}$ ]]; then
        # a series prefix: every downloaded session of it (some AMI series lack a session),
        # or a–d when none are downloaded yet so the missing ones get reported
        found="$(ls "$RTTM_DIR" 2>/dev/null | sed -n "s/^\(${tok}[a-z]\)\.rttm$/\1/p" | sort | tr '\n' ' ')"
        MEETINGS="$MEETINGS ${found:-${tok}a ${tok}b ${tok}c ${tok}d}"
      else MEETINGS="$MEETINGS $tok"; fi
    done
  else
    MEETINGS="$(ls "$RTTM_DIR" 2>/dev/null | sed -n 's/\.rttm$//p' | sort | tr '\n' ' ')"
  fi
  [ -n "${MEETINGS// /}" ] || die "no meetings for CORPUS=$CORPUS (run the downloader first; looked in $RTTM_DIR)"
  missing=()
  for m in $MEETINGS; do
    if [ ! -s "$RTTM_DIR/$m.rttm" ]; then missing+=("missing RTTM $m"); continue; fi
    if [ ! -s "$AUDIO_DIR/$m$SUFFIX" ]; then missing+=("missing audio $m"); continue; fi
    M_ID+=("$m"); M_AUDIO+=("$AUDIO_DIR/$m$SUFFIX")
    printf '%s\t%s\t%s\n' "$m" "$AUDIO_DIR/$m$SUFFIX" "$m" >> "$OUT_DIR/meetings.tsv"
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    printf '    !! %s\n' "${missing[@]}" >&2
    [ "$ALLOW_PARTIAL_CORPUS" = "1" ] || die "partial corpus refused (fetch the inputs or set ALLOW_PARTIAL_CORPUS=1)"
  fi
  [ "${#M_ID[@]}" -gt 0 ] || die "no complete audio+RTTM meetings for CORPUS=$CORPUS"
  say "==> CORPUS=$CORPUS meetings=${#M_ID[@]} variants=${V_NAME[*]}"
fi

# ---- build --------------------------------------------------------------------------------
if [ -n "$HARNESS_BIN" ]; then
  BIN="$HARNESS_BIN"
else
  BIN="$ROOT/Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness"
  if [ "$SKIP_BUILD" != "1" ]; then
    say "==> build harness (log: $OUT_DIR/logs/build.log)"
    swift build -c release --package-path "$ROOT/Tools/SpeakerEvalHarness" > "$OUT_DIR/logs/build.log" 2>&1 \
      || { tail -30 "$OUT_DIR/logs/build.log" >&2; die "harness build failed"; }
  fi
fi
[ -x "$BIN" ] || die "harness binary not found at $BIN (drop --skip-build)"

# ---- dump (cached per variant) --------------------------------------------------------------
export TRANSCRIPTED_DISABLE_FILE_LOGGER=1
for vi in "${!V_NAME[@]}"; do
  name="${V_NAME[$vi]}"; backend="${V_BACKEND[$vi]}"; embedder="${V_EMBEDDER[$vi]}"; preset="${V_PRESET[$vi]}"
  vdir="$DUMP_ROOT/$name"
  mkdir -p "$vdir"
  printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$backend" "$embedder" "$preset" "$vdir" >> "$OUT_DIR/variants.tsv"
  say "==> dump $name"
  failures=()
  for mi in "${!M_ID[@]}"; do
    m="${M_ID[$mi]}"; audio="${M_AUDIO[$mi]}"; dump="$vdir/$m.json"
    if [ "$REDUMP" != "1" ] && [ -s "$dump" ] \
       && python3 "$SCORER" dump-ok --dump "$dump" --backend "$backend" --embedder "$embedder" --preset "$preset"; then
      say "    cached $m"
      continue
    fi
    rm -f "$dump"
    args=(dump --audio "$audio" --meeting "$m" --out "$dump" --backend "$backend" --embedder "$embedder")
    [ "$embedder" = "eres2net" ] && [ -n "$ERES2NET_MODEL" ] && args+=(--eres2net-model "$ERES2NET_MODEL")
    log="$OUT_DIR/logs/dump-$name-$m.log"
    if [ -n "$preset" ]; then
      TRANSCRIPTED_NEMOTRON_PRESET="$preset" "$BIN" "${args[@]}" > "$log" 2>&1 || true
    else
      env -u TRANSCRIPTED_NEMOTRON_PRESET "$BIN" "${args[@]}" > "$log" 2>&1 || true
    fi
    if [ -s "$dump" ]; then
      grep -E "^\[dump\] .*->" "$log" | sed 's/^/    /' >&2 || true
    else
      failures+=("$name/$m (see $log)")
      tail -3 "$log" | sed 's/^/      /' >&2 || true
    fi
  done
  if [ "${#failures[@]}" -gt 0 ]; then
    printf '    !! dump failed: %s\n' "${failures[@]}" >&2
    if [ "$MODE" = "corpus" ] && [ "$ALLOW_PARTIAL_CORPUS" != "1" ]; then
      die "dump failures (fix them or set ALLOW_PARTIAL_CORPUS=1)"
    fi
  fi
done

# ---- embedding parity (optional, cached per meeting) -----------------------------------------
if [ "$EMBEDDING_PARITY" = "1" ]; then
  PARITY_ROOT="$(dirname "$DUMP_ROOT")/parity"
  mkdir -p "$PARITY_ROOT"
  label_source="diarizer"; [ "$MODE" = "corpus" ] && label_source="rttm"
  say "==> embedding parity: pyannote WeSpeaker vs online WeSpeaker (labels: $label_source)"
  failures=()
  for mi in "${!M_ID[@]}"; do
    m="${M_ID[$mi]}"; audio="${M_AUDIO[$mi]}"; pout="$PARITY_ROOT/$m.json"
    if [ "$REDUMP" != "1" ] && [ -s "$pout" ] \
       && python3 "$SCORER" parity-ok --parity "$pout" --label-source "$label_source"; then
      say "    cached $m"
    else
      rm -f "$pout"
      args=(embedding-parity --audio "$audio" --meeting "$m" --out "$pout")
      [ "$MODE" = "corpus" ] && args+=(--rttm "$RTTM_DIR/$m.rttm")
      log="$OUT_DIR/logs/parity-$m.log"
      "$BIN" "${args[@]}" > "$log" 2>&1 || true
      if [ -s "$pout" ]; then
        grep -E "^\[parity\] .*->" "$log" | sed 's/^/    /' >&2 || true
      else
        failures+=("$m (see $log)")
        tail -3 "$log" | sed 's/^/      /' >&2 || true
        continue
      fi
    fi
    printf '%s\t%s\n' "$m" "$pout" >> "$OUT_DIR/parity.tsv"
  done
  if [ "${#failures[@]}" -gt 0 ]; then
    printf '    !! embedding parity failed: %s\n' "${failures[@]}" >&2
    if [ "$MODE" = "corpus" ] && [ "$ALLOW_PARTIAL_CORPUS" != "1" ]; then
      die "embedding parity failures (fix them or set ALLOW_PARTIAL_CORPUS=1)"
    fi
  fi
fi

# ---- replay sweep ---------------------------------------------------------------------------
for vi in "${!V_NAME[@]}"; do
  name="${V_NAME[$vi]}"; embedder="${V_EMBEDDER[$vi]}"
  vdir="$DUMP_ROOT/$name"
  inputs=""
  for m in "${M_ID[@]}"; do
    [ -s "$vdir/$m.json" ] && inputs="${inputs:+$inputs,}$vdir/$m.json"
  done
  if [ -z "$inputs" ]; then
    [ "$MODE" = "own-calls" ] && { say "    !! $name has no dumps; skipping"; continue; }
    die "$name has no dumps to replay"
  fi
  grid_file="$OUT_DIR/logs/grid-$name.tsv"
  python3 "$SCORER" grid \
    --match "$(match_grid_for "$embedder")" --same-voice "$SAME_VOICE" --consolidation "$CONSOLIDATION" \
    --write-path-fixes "$WRITE_PATH_FIXES" --thresholds "$THRESHOLDS" --dedup "$DEDUP" \
    --blend-confident "$BLEND_CONFIDENT" --blend-cautious "$BLEND_CAUTIOUS" \
    --writeback-confident-sim "$WRITEBACK_CONFIDENT_SIM" --writeback-cautious-sim "$WRITEBACK_CAUTIOUS_SIM" \
    --writeback-margin "$WRITEBACK_MARGIN" > "$grid_file"
  n="$(wc -l < "$grid_file" | tr -d ' ')"
  say "==> replay $name ($n setting(s))"
  mkdir -p "$OUT_DIR/replays/$name"
  while IFS=$'\t' read -r tag replay_args; do
    [ -n "$tag" ] || continue
    out="$OUT_DIR/replays/$name/$tag.json"
    log="$OUT_DIR/logs/replay-$name-$tag.log"
    # shellcheck disable=SC2086  # replay_args is a generated, space-free flag list
    if ! "$BIN" replay --inputs "$inputs" $replay_args --out "$out" > "$log" 2>&1 || [ ! -s "$out" ]; then
      tail -5 "$log" >&2 || true
      die "replay failed for $name $tag (see $log)"
    fi
    printf '%s\t%s\t%s\n' "$name" "$tag" "$out" >> "$OUT_DIR/replays.tsv"
  done < "$grid_file"
done

# ---- score ----------------------------------------------------------------------------------
GIT_REVISION="$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY=0; [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null | head -1)" ] && GIT_DIRTY=1
{
  echo "MODE=$MODE"
  echo "CORPUS=$([ "$MODE" = "own-calls" ] && echo own-calls || echo "$CORPUS")"
  echo "RTTM_DIR=$RTTM_DIR"
  echo "COLLAR=$COLLAR"
  echo "MIN_APPEARANCE_SEC=$MIN_APPEARANCE_SEC"
  echo "WRONG_PENALTY=$WRONG_PENALTY"
  echo "GIT_REVISION=$GIT_REVISION"
  echo "GIT_DIRTY=$GIT_DIRTY"
  echo "SINGLE=$SINGLE"
  echo "EMBEDDING_PARITY=$EMBEDDING_PARITY"
  echo "COMMAND=$COMMAND_LINE"
  echo "KNOB_VARIANTS=$VARIANTS"
  echo "KNOB_SERIES=$SERIES"
  echo "KNOB_MATCH=${MATCH:-per-embedder default}"
  for knob in SAME_VOICE CONSOLIDATION WRITE_PATH_FIXES THRESHOLDS DEDUP BLEND_CONFIDENT BLEND_CAUTIOUS \
              WRITEBACK_CONFIDENT_SIM WRITEBACK_CAUTIOUS_SIM WRITEBACK_MARGIN; do
    echo "KNOB_$knob=${!knob}"
  done
} > "$OUT_DIR/run.env"

say "==> score"
python3 "$SCORER" score --run-dir "$OUT_DIR" --quiet || die "scoring failed"
say "==> wrote $OUT_DIR/REPORT.md"
[ "$MODE" = "own-calls" ] && say "==> open $OUT_DIR/timeline.html"
echo "$OUT_DIR/scores.json"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

LABEL="run"
VARIANT="native"
ITERATIONS="3"
BUILD_APP=1
INCLUDE_SILENCE=0
AUTO_ENTER=1
CHUNK_SECONDS="30"
WORK_DIR="${TRANSCRIPTED_DICTATION_STOP_BENCH_WORK_DIR:-$REPO_ROOT/.autoeval/dictation-stop}"
FIXTURE_DIR="$WORK_DIR/fixtures"
RESULT_DIR="$WORK_DIR/results"

usage() {
    cat <<USAGE
Usage: scripts/ops/dictation-stop-autoeval.sh [options]

Options:
  --label NAME          Result label (default: run)
  --variant NAME        native, pre_resampled, or chunked (default: native)
  --iterations N        Iterations per case (default: 3)
  --skip-build          Reuse build/Transcripted.app
  --include-silence     Include the no-speech guardrail fixture
  --no-auto-enter       Do not simulate the Auto Enter delay
  --chunk-seconds N     Chunk size for --variant chunked (default: 30)
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --label)
            LABEL="$2"
            shift 2
            ;;
        --variant)
            VARIANT="$2"
            shift 2
            ;;
        --iterations)
            ITERATIONS="$2"
            shift 2
            ;;
        --skip-build)
            BUILD_APP=0
            shift
            ;;
        --include-silence)
            INCLUDE_SILENCE=1
            shift
            ;;
        --no-auto-enter)
            AUTO_ENTER=0
            shift
            ;;
        --chunk-seconds)
            CHUNK_SECONDS="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

case "$VARIANT" in
    native|pre_resampled|chunked) ;;
    *)
        echo "Unknown variant: $VARIANT" >&2
        exit 1
        ;;
esac

mkdir -p "$FIXTURE_DIR" "$RESULT_DIR"

duration_for() {
    /usr/bin/afinfo "$1" | awk '/estimated duration/ { print $3; exit }'
}

validate_duration() {
    local id="$1"
    local wav="$2"
    local min="$3"
    local max="$4"
    local duration
    duration="$(duration_for "$wav")"
    ruby -e 'd=ARGV[0].to_f; min=ARGV[1].to_f; max=ARGV[2].to_f; exit(d >= min && d <= max ? 0 : 1)' "$duration" "$min" "$max" || {
        echo "Fixture $id duration ${duration}s is outside ${min}-${max}s" >&2
        exit 1
    }
}

make_speech_fixture() {
    local id="$1"
    local min="$2"
    local max="$3"
    local text="$4"
    local text_file="$FIXTURE_DIR/$id.txt"
    local aiff="$FIXTURE_DIR/$id.aiff"
    local wav="$FIXTURE_DIR/$id.wav"

    if [ -f "$text_file" ] && [ "$(cat "$text_file")" != "$text" ]; then
        rm -f "$aiff" "$wav"
    fi
    printf '%s\n' "$text" > "$text_file"
    if [ ! -f "$wav" ]; then
        if ! /usr/bin/say -v "${TRANSCRIPTED_DICTATION_STOP_BENCH_VOICE:-Samantha}" -r 170 -f "$text_file" -o "$aiff"; then
            /usr/bin/say -r 170 -f "$text_file" -o "$aiff"
        fi
        /usr/bin/afconvert -f WAVE -d LEI16@48000 "$aiff" "$wav"
    fi
    validate_duration "$id" "$wav" "$min" "$max"
}

make_silence_fixture() {
    local wav="$FIXTURE_DIR/silence_guardrail.wav"
    if [ ! -f "$wav" ]; then
        /usr/bin/python3 - "$wav" <<'PY'
import struct
import sys
import wave

path = sys.argv[1]
rate = 48000
seconds = 5
with wave.open(path, "wb") as handle:
    handle.setnchannels(1)
    handle.setsampwidth(2)
    handle.setframerate(rate)
    frame = struct.pack("<h", 0)
    handle.writeframes(frame * rate * seconds)
PY
    fi
}

make_speech_fixture "very_short" 3 5 \
    "Transcripted should paste this short note quickly after recording stops."

make_speech_fixture "short" 10 15 \
    "This is a short dictation benchmark for Transcripted. It checks whether the final text appears quickly after I stop recording, and whether the saved Markdown file is ready without an avoidable delay."

make_speech_fixture "medium" 30 45 \
    "This medium dictation benchmark is meant to feel like a normal spoken note. I am describing a product decision, a follow up item, and a few details that should survive the transcription path. The important thing is not perfect prose. The important thing is that Transcripted turns the audio into final text quickly after I stop, saves the local Markdown artifact, and does not lose the paste back into the editor. We need enough words here to exercise the model for a real note instead of a tiny sample. I am adding a little more ordinary speech so this lands inside the requested duration range and gives the stop path a fair medium length workload."

make_speech_fixture "long" 90 120 \
    "This long dictation benchmark is a longer spoken memo for Transcripted. I am talking through a realistic work note with several sections, some repeated phrasing, and enough audio to make the transcription path do meaningful work. First, the app should stop recording cleanly and preserve the audio buffer. Second, it should start final transcription without waiting on unrelated user interface work. Third, it should produce the final text, paste it back, and save the local Markdown artifact without extra delay. Fourth, it should keep correctness stable, because a faster result that drops words or changes the saved file is not a real improvement. I am also adding a few practical sentences about follow up, product testing, release notes, and local privacy so the transcript has ordinary vocabulary. The benchmark should be boring on purpose. It should be easy to run again, easy to compare, and hard to fool with a lucky result. If chunking helps longer notes, the long case should show it. If resampling is too small to matter, this long case should also make that obvious. The final answer should come from raw numbers, not from a feeling that the code looks faster. That is the point of this experiment. Now I am continuing the same memo with more ordinary spoken detail. A user might be dictating a project update, explaining what happened in a customer call, naming the next three follow ups, and describing which decision needs to be captured before they forget. They might pause briefly, correct themselves, and then keep going. The stop path should not become fragile just because the note is longer. It should handle a full minute and a half or more of useful speech, preserve the same final wording style, and avoid any extra waiting that happens after the model already has enough audio to work. This additional section makes the long case long enough to match the requested duration while still staying simple, local, and repeatable."

if [ "$INCLUDE_SILENCE" = "1" ]; then
    make_silence_fixture
fi

BENCH_FIXTURES="$FIXTURE_DIR"
if [ "$INCLUDE_SILENCE" != "1" ]; then
    BENCH_FIXTURES="$WORK_DIR/fixtures-no-silence"
    rm -rf "$BENCH_FIXTURES"
    mkdir -p "$BENCH_FIXTURES"
    cp "$FIXTURE_DIR"/very_short.wav "$BENCH_FIXTURES/"
    cp "$FIXTURE_DIR"/short.wav "$BENCH_FIXTURES/"
    cp "$FIXTURE_DIR"/medium.wav "$BENCH_FIXTURES/"
    cp "$FIXTURE_DIR"/long.wav "$BENCH_FIXTURES/"
fi

if [ "$BUILD_APP" = "1" ]; then
    bash build.sh --no-open --full
fi

APP_BINARY="$REPO_ROOT/build/Transcripted.app/Contents/MacOS/Transcripted"
if [ ! -x "$APP_BINARY" ]; then
    echo "Missing app binary: $APP_BINARY" >&2
    exit 1
fi

RESULT_JSONL="$RESULT_DIR/$LABEL-$VARIANT.jsonl"
RESULT_SUMMARY="$RESULT_DIR/$LABEL-$VARIANT.summary.md"
RUN_HOME="$WORK_DIR/home-$LABEL-$VARIANT"
SAVE_DIR="$WORK_DIR/saved-$LABEL-$VARIANT"
rm -rf "$RUN_HOME" "$SAVE_DIR"
mkdir -p "$RUN_HOME" "$SAVE_DIR"

CFFIXED_USER_HOME="$RUN_HOME" \
HOME="$RUN_HOME" \
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 \
TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS=1 \
TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD=1 \
TRANSCRIPTED_DICTATION_STOP_BENCH_AUDIO_DIR="$BENCH_FIXTURES" \
TRANSCRIPTED_DICTATION_STOP_BENCH_OUTPUT="$RESULT_JSONL" \
TRANSCRIPTED_DICTATION_STOP_BENCH_SAVE_DIR="$SAVE_DIR" \
TRANSCRIPTED_DICTATION_STOP_BENCH_ITERATIONS="$ITERATIONS" \
TRANSCRIPTED_DICTATION_STOP_BENCH_VARIANT="$VARIANT" \
TRANSCRIPTED_DICTATION_STOP_BENCH_AUTO_ENTER="$AUTO_ENTER" \
TRANSCRIPTED_DICTATION_STOP_BENCH_CHUNK_SECONDS="$CHUNK_SECONDS" \
"$APP_BINARY"

ruby -rjson - "$RESULT_JSONL" "$RESULT_SUMMARY" <<'RUBY'
jsonl = ARGV.fetch(0)
summary = ARGV.fetch(1)
records = File.readlines(jsonl, chomp: true).map { |line| JSON.parse(line) }
run = records.find { |record| record["record_type"] == "run_start" } || {}
cases = records.select { |record| record["record_type"] == "case_result" }

def avg(values)
  values = values.compact
  return nil if values.empty?
  values.sum / values.length
end

def fmt(value)
  value.nil? ? "n/a" : format("%.3f", value)
end

lines = []
lines << "# Dictation Stop Autoeval Summary"
lines << ""
lines << "- Variant: `#{run["variant"]}`"
lines << "- Finalization order: `#{run["finalization_order"]}`"
lines << "- Iterations: `#{run["iterations"]}`"
lines << "- Model init: #{fmt(run["model_init_s"])}s"
lines << "- Auto Enter simulated: `#{run["simulate_auto_enter"]}`"
lines << ""
lines << "| case | n | audio_s | avg text_s | avg saved_s | avg delivery_s | hashes | words |"
lines << "|---|---:|---:|---:|---:|---:|---|---:|"

cases.group_by { |record| record["case_id"] }.sort.each do |case_id, rows|
  hashes = rows.map { |row| row["text_hash"] }.uniq.reject(&:empty?)
  words = rows.map { |row| row["words"] }.compact
  lines << [
    case_id,
    rows.length,
    fmt(avg(rows.map { |row| row["audio_duration_s"] })),
    fmt(avg(rows.map { |row| row["stop_to_text_s"] })),
    fmt(avg(rows.map { |row| row["stop_to_saved_s"] })),
    fmt(avg(rows.map { |row| row["stop_to_delivery_s"] })),
    hashes.empty? ? "n/a" : hashes.join(","),
    words.empty? ? 0 : words.first
  ].join(" | ").then { |row| "| #{row} |" }
end

File.write(summary, lines.join("\n") + "\n")
puts File.read(summary)
puts "Raw JSONL: #{jsonl}"
RUBY

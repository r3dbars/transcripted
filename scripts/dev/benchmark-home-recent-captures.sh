#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/benchmarks"
BINARY="$BUILD_DIR/home-recent-captures-benchmark"

mkdir -p "$BUILD_DIR"

swiftc \
  "$ROOT_DIR/Tests/Benchmarks/HomeRecentCaptureBenchmark.swift" \
  "$ROOT_DIR/Sources/Support/TranscriptedStoragePaths.swift" \
  "$ROOT_DIR/Sources/Dictation/DictationStoragePaths.swift" \
  "$ROOT_DIR/Sources/Dictation/DictationTranscriptWriter.swift" \
  "$ROOT_DIR/Sources/Dictation/DictationTranscriptStore.swift" \
  "$ROOT_DIR/Sources/Meeting/MeetingArtifactRenamer.swift" \
  "$ROOT_DIR/Sources/Meeting/MeetingStoragePaths.swift" \
  "$ROOT_DIR/Sources/Meeting/MeetingTranscriptStyler.swift" \
  "$ROOT_DIR/Sources/Meeting/LocalMeetingSummarizer.swift" \
  "$ROOT_DIR/Sources/Support/LocalMeetingSummaryPreferences.swift" \
  "$ROOT_DIR/Sources/TranscriptedCore/Speaker/SpeakerProfile.swift" \
  "$ROOT_DIR/Sources/TranscriptedCore/Models/TranscriptionTypes.swift" \
  "$ROOT_DIR/Sources/TranscriptedCore/Storage/TranscriptFrontmatter.swift" \
  "$ROOT_DIR/Sources/UI/Shared/MeetingAudioArchiveResolver.swift" \
  "$ROOT_DIR/Sources/UI/Shared/RecentCaptureScanners.swift" \
  "$ROOT_DIR/Sources/UI/Shared/RecentMeetingMetadataCache.swift" \
  -framework AppKit \
  -parse-as-library \
  -O \
  -o "$BINARY"

echo "| captures | meetings | dictations | reps | raw load ms | avg load ms | best load ms | cancel ms |"
echo "|---:|---:|---:|---:|---|---:|---:|---:|"
"$BINARY" --captures 1000 --repetitions "${REPETITIONS:-3}" "$@"
"$BINARY" --captures 10000 --repetitions "${REPETITIONS:-3}" "$@"

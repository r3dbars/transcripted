#!/usr/bin/env bash
set -euo pipefail

# Deterministic local-summary fixture smoke.
# This proves the Transcripted app-side summarizer starts, finishes, and writes
# the expected Markdown shape without private meeting content or model downloads.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_ROOT="${TRANSCRIPTED_LOCAL_SUMMARY_FIXTURE_OUT:-${REPO_ROOT}/build/local-summary-fixture}"
RUN_ID="${TRANSCRIPTED_LOCAL_SUMMARY_FIXTURE_RUN_ID:-fixture-$(date +%Y%m%d-%H%M%S)}"
REAL_GEMMA="${TRANSCRIPTED_LOCAL_SUMMARY_FIXTURE_REAL_GEMMA:-0}"

usage() {
  cat <<'USAGE'
Usage: bash scripts/ops/run-local-summary-fixture.sh [--real-gemma]

Runs the deterministic local-summary fixture by default.

Options:
  --real-gemma  Run the real Gemma MLX runtime on the synthetic fixture.
                Requires uv plus the pinned mlx-vlm runtime/model prerequisites.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --real-gemma)
      REAL_GEMMA=1
      shift
      ;;
    --mock|--deterministic)
      REAL_GEMMA=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${REAL_GEMMA}" == "1" ]]; then
  TIMEOUT_SECONDS="${TRANSCRIPTED_LOCAL_SUMMARY_FIXTURE_TIMEOUT:-1200}"
else
  TIMEOUT_SECONDS="${TRANSCRIPTED_LOCAL_SUMMARY_FIXTURE_TIMEOUT:-10}"
fi
RUN_ROOT="${OUT_ROOT}/${RUN_ID}"
BUILD_DIR="${RUN_ROOT}/build"
FAKE_HOME="${RUN_ROOT}/home"
HARNESS="${BUILD_DIR}/LocalSummaryFixture.swift"
BIN="${BUILD_DIR}/local-summary-fixture"

mkdir -p "${BUILD_DIR}" "${FAKE_HOME}"

cat > "${HARNESS}" <<'SWIFT'
import Foundation

private enum FixtureError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@main
struct LocalSummaryFixture {
    static func main() async {
        do {
            let runRoot = URL(
                fileURLWithPath: ProcessInfo.processInfo.environment["TRANSCRIPTED_LOCAL_SUMMARY_FIXTURE_RUN_ROOT"]!,
                isDirectory: true
            )
            let repoRoot = URL(
                fileURLWithPath: ProcessInfo.processInfo.environment["TRANSCRIPTED_REPO_ROOT"]!,
                isDirectory: true
            )
            let realGemma = ProcessInfo.processInfo.environment["TRANSCRIPTED_LOCAL_SUMMARY_FIXTURE_REAL_GEMMA"] == "1"
            try await run(in: runRoot, repoRoot: repoRoot, realGemma: realGemma)
        } catch {
            fputs("[local-summary-fixture] FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run(in runRoot: URL, repoRoot: URL, realGemma: Bool) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: runRoot, withIntermediateDirectories: true)

        let transcriptURL = runRoot.appendingPathComponent("Synthetic Summary Fixture.md")
        let promptCaptureURL = runRoot.appendingPathComponent("captured-prompt.txt")
        try fixtureTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let configuration = realGemma ? LocalGemmaSummaryConfiguration.m1Optimized() : fixtureConfiguration()
        let runtime: LocalGemmaSummaryRuntime
        if realGemma {
            try configuration.validateHardware()
            let runnerURL = repoRoot.appendingPathComponent("Resources/LocalSummarizer/gemma4_mlx_prompt_runner.py")
            try expect(fileManager.fileExists(atPath: runnerURL.path), "bundled Gemma MLX runner should exist")
            var realRuntime = LocalGemmaSummaryRuntime(configuration: configuration)
            realRuntime.runnerURLOverride = runnerURL
            runtime = realRuntime
        } else {
            runtime = LocalGemmaSummaryRuntime(
                configuration: configuration,
                generateBatchOverride: { prompts, _ in
                    guard prompts.count == 1 else {
                        throw FixtureError.failed("expected direct one-prompt fixture, got \(prompts.count)")
                    }
                    let promptText = prompts.map(\.prompt).joined(separator: "\n---\n")
                    try promptText.write(to: promptCaptureURL, atomically: true, encoding: .utf8)
                    return [fixtureModelOutput]
                }
            )
        }

        let result = try await LocalMeetingSummarizer(
            configuration: configuration,
            runtime: runtime
        ).summarize(
            transcriptURL: transcriptURL,
            title: "Synthetic Summary Fixture",
            date: Date(timeIntervalSince1970: 1_780_000_000)
        )

        let updatedMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)

        try expect(result.chunkCount == 1, "fixture should use the direct summary path")
        try expect(result.profileName == configuration.profileName, "fixture profile should be reported")
        try expect(updatedMarkdown.contains("local_summary_version: \"1\""), "frontmatter should include local summary version")
        try expect(updatedMarkdown.contains("local_summary_source_transcript: \"Synthetic Summary Fixture.md\""), "frontmatter should backlink the source transcript")
        try expect(updatedMarkdown.contains("local_summary_chunk_count: \"1\""), "frontmatter should include chunk count")
        try expect(updatedMarkdown.contains("local_summary_participants: \"- Alex | - Riley\""), "frontmatter should include transcript participants")
        try expect(updatedMarkdown.contains("local_summary_model: \"\(configuration.modelID)\""), "frontmatter should include the model id")
        try expect(updatedMarkdown.contains("local_summary_runtime: \"\(configuration.runtimePackage)\""), "frontmatter should include the runtime package")
        try expect(updatedMarkdown.contains("local_summary_profile: \"\(configuration.profileName)\""), "frontmatter should include the runtime profile")
        try expect(updatedMarkdown.contains("local_summary_next_steps:"), "frontmatter should include agent next steps")
        try expect(updatedMarkdown.contains("local_summary_commitments:"), "frontmatter should include commitment aliases")
        try expect(updatedMarkdown.contains(LocalMeetingSummaryMarkdownUpdater.startMarker), "managed summary start marker should be present")
        try expect(updatedMarkdown.contains("## Local Gemma Summary"), "managed summary heading should be present")
        try expect(updatedMarkdown.contains("Source transcript: `Synthetic Summary Fixture.md`"), "managed summary should backlink the source transcript")
        try expect(updatedMarkdown.contains("### Summary\n"), "summary body should be written")
        try expect(updatedMarkdown.contains("### Next Steps\n"), "next steps body should be written")
        try expect(updatedMarkdown.contains("### Participants\n- Alex\n- Riley"), "participants body should be written")
        try expect(updatedMarkdown.contains("### Action Items\n"), "action item body should be written")
        try expect(updatedMarkdown.contains(LocalMeetingSummaryMarkdownUpdater.endMarker), "managed summary end marker should be present")
        try expect(!fileManager.fileExists(atPath: LocalMeetingSummaryStore.summaryURL(for: transcriptURL).path), "fixture should not create a sibling summary sidecar")

        if realGemma {
            print("[local-summary-fixture] PASS: generated real Gemma local summary fixture")
            print("[local-summary-fixture] Transcript: \(transcriptURL.path)")
            return
        }

        let capturedPrompt = try String(contentsOf: promptCaptureURL, encoding: .utf8)
        try expect(capturedPrompt.contains("summary fixture stays local"), "prompt should include synthetic transcript text")
        try expect(!capturedPrompt.contains("fixture-secret"), "prompt should exclude non-transcript notes")
        try expect(updatedMarkdown.contains("local_summary_title: \"Fixture Summary Review\""), "frontmatter should include generated title")
        try expect(updatedMarkdown.contains("### Summary\nThe fixture proves local summary generation can finish and rewrite the saved meeting."), "summary body should be written")
        try expect(updatedMarkdown.contains("### Next Steps\nQA should keep this fixture in the bench.\nThe release gate should not treat fixture output as quality proof."), "next steps body should be written")
        try expect(updatedMarkdown.contains("### Action Items\nQA should keep this fixture in the bench."), "action item body should be written")

        print("[local-summary-fixture] PASS: generated deterministic local summary fixture")
        print("[local-summary-fixture] Transcript: \(transcriptURL.path)")

        try await runChunkedScenario(in: runRoot)
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw FixtureError.failed(message)
        }
    }

    private static func runChunkedScenario(in runRoot: URL) async throws {
        let fileManager = FileManager.default
        let transcriptURL = runRoot.appendingPathComponent("Synthetic Long Summary Fixture.md")
        let recorder = LocalSummaryFixtureBatchRecorder()
        try fixtureLongTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let configuration = LocalGemmaSummaryConfiguration(
            modelID: LocalMeetingSummarySetupStatus.defaultModelID,
            runtimePackage: LocalMeetingSummarySetupStatus.defaultRuntimePackage,
            profileName: "fixture-chunked",
            minimumPhysicalMemoryBytes: 0,
            chunkCharacterLimit: 360,
            chunkMaxTokens: 64,
            directMaxTokens: 64,
            mergeMaxTokens: 128,
            maxKVSize: 1_024,
            processTimeoutSeconds: 5,
            processNiceValue: 0,
            cpuThreadLimit: 1,
            interJobCooldownSeconds: 0
        )
        let runtime = LocalGemmaSummaryRuntime(
            configuration: configuration,
            generateBatchOverride: { prompts, _ in
                recorder.record(prompts)
                if prompts.allSatisfy({ $0.label.hasPrefix("chunk-") }) {
                    return prompts.map { prompt in
                        """
                        # Summary
                        \(prompt.label) preserved local-summary fixture details.

                        # Decisions
                        Keep long local Gemma summaries serialized.

                        # Action Items
                        Dogfood the next beta on a real meeting.

                        # Open Questions
                        Whether real model quality is good enough.

                        # Risks or Follow-ups
                        Long meetings can still be slow on low-memory Macs.
                        """
                    }
                }
                if prompts.map(\.label) == ["merge"] {
                    return [fixtureModelOutput]
                }
                throw FixtureError.failed("unexpected chunk prompt batch: \(prompts.map(\.label).joined(separator: ", "))")
            }
        )

        let result = try await LocalMeetingSummarizer(
            configuration: configuration,
            runtime: runtime
        ).summarize(
            transcriptURL: transcriptURL,
            title: "Synthetic Long Summary Fixture",
            date: Date(timeIntervalSince1970: 1_780_000_000)
        )

        let updatedMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        let batches = recorder.batches()

        try expect(result.chunkCount > 1, "long fixture should use the chunked summary path")
        try expect(batches.count == 2, "long fixture should run one chunk batch and one merge job")
        try expect(batches[0].labels.allSatisfy { $0.hasPrefix("chunk-") }, "first batch should contain chunk jobs")
        try expect(batches[1].labels == ["merge"], "second batch should merge chunk notes")
        try expect(batches[1].prompts.joined(separator: "\n").contains("# Chunk 1"), "merge prompt should receive chunk notes")
        try expect(updatedMarkdown.contains("local_summary_profile: \"fixture-chunked\""), "frontmatter should record the chunked profile")
        try expect(updatedMarkdown.contains("local_summary_chunk_count: \"\(result.chunkCount)\""), "frontmatter should record chunk count")
        try expect(!fileManager.fileExists(atPath: LocalMeetingSummaryStore.summaryURL(for: transcriptURL).path), "chunked fixture should not create a sibling summary sidecar")

        print("[local-summary-fixture] PASS: generated deterministic chunked local summary fixture")
        print("[local-summary-fixture] Chunked transcript: \(transcriptURL.path)")
    }
}

private final class LocalSummaryFixtureBatchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedBatches: [(labels: [String], prompts: [String])] = []

    func record(_ prompts: [LocalGemmaSummaryPrompt]) {
        lock.lock()
        recordedBatches.append((prompts.map(\.label), prompts.map(\.prompt)))
        lock.unlock()
    }

    func batches() -> [(labels: [String], prompts: [String])] {
        lock.lock()
        let batches = recordedBatches
        lock.unlock()
        return batches
    }
}

private func fixtureConfiguration() -> LocalGemmaSummaryConfiguration {
    LocalGemmaSummaryConfiguration(
        modelID: LocalMeetingSummarySetupStatus.defaultModelID,
        runtimePackage: LocalMeetingSummarySetupStatus.defaultRuntimePackage,
        profileName: "fixture",
        minimumPhysicalMemoryBytes: 0,
        chunkCharacterLimit: 100_000,
        chunkMaxTokens: 64,
        directMaxTokens: 64,
        mergeMaxTokens: 64,
        maxKVSize: 1_024,
        processTimeoutSeconds: 5,
        processNiceValue: 0,
        cpuThreadLimit: 1,
        interJobCooldownSeconds: 0
    )
}

private let fixtureTranscript = """
---
capture_type: meeting
title: "Synthetic Summary Fixture"
private_note: "fixture-secret"
---

# Synthetic Summary Fixture

## Notes

This fixture-secret note should never be sent to the summarizer prompt.

## Transcript

**00:01** [Mic/Alex]
The summary fixture stays local and should prove that generation starts, finishes, and updates the saved meeting Markdown.

**00:20** [System/Riley]
QA should keep this fixture in the bench so missing output shape is caught before release.

**00:42** [Mic/Alex]
The open question is whether real Gemma quality still needs manual review, but the fixture can prove the app path does not hang.
"""

private let fixtureLongTranscript = """
---
capture_type: meeting
title: "Synthetic Long Summary Fixture"
---

# Synthetic Long Summary Fixture

## Transcript

**00:01** [Mic/Alex]
Chunk one says the local summary path should stay serialized, avoid surprise setup work from Home, keep transcripts canonical, preserve user edits, and leave enough detail for a final merge.

**00:20** [System/Riley]
Chunk two says the long meeting smoke should finish without model downloads and should catch regressions where chunk summaries never merge.

**00:41** [Mic/Alex]
Chunk three says the beta dogfood build should make progress visible and avoid pretending a slow model is stuck forever.

**01:02** [System/Riley]
Chunk four says the saved Markdown should be enhanced in place instead of creating a second summary artifact.

**01:23** [Mic/Alex]
Chunk five says stale transcript writes should fail closed if the meeting changes while local generation is running.

**01:44** [System/Riley]
Chunk six says the final notice should be short-lived after success, because the actual saved summary is already in the meeting Markdown.
"""

private let fixtureModelOutput = """
# Title
Fixture Summary Review

# Summary
The fixture proves local summary generation can finish and rewrite the saved meeting.

# Decisions
Keep the fixture local and deterministic.

# Action Items
QA should keep this fixture in the bench.

# Open Questions
Real Gemma summary quality still needs manual review.

# Risks or Follow-ups
The release gate should not treat fixture output as quality proof.

# Accuracy Notes
Synthetic fixture only.
"""
SWIFT

swiftc \
  "${HARNESS}" \
  "${REPO_ROOT}/Sources/Support/LocalMeetingSummaryPreferences.swift" \
  "${REPO_ROOT}/Sources/Support/TranscriptedStoragePaths.swift" \
  "${REPO_ROOT}/Sources/Meeting/LocalMeetingSummarizer.swift" \
  "${REPO_ROOT}/Sources/TranscriptedCore/Storage/TranscriptFrontmatter.swift" \
  -framework FoundationModels \
  -parse-as-library \
  -o "${BIN}"

run_with_timeout() {
  local deadline pid status
  deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
  "$@" &
  pid=$!

  while kill -0 "${pid}" 2>/dev/null; do
    if [[ "$(date +%s)" -ge "${deadline}" ]]; then
      kill "${pid}" 2>/dev/null || true
      wait "${pid}" 2>/dev/null || true
      echo "[local-summary-fixture] FAIL: fixture exceeded ${TIMEOUT_SECONDS}s watchdog" >&2
      return 124
    fi
    sleep 0.2
  done

  wait "${pid}"
  status=$?
  return "${status}"
}

echo "[local-summary-fixture] Run root: ${RUN_ROOT}"
if [[ "${REAL_GEMMA}" == "1" ]]; then
  echo "[local-summary-fixture] Real Gemma mode: requires uv plus mlx-vlm/model availability through uv."
  if [[ -z "${TRANSCRIPTED_UV_PATH:-}" ]]; then
    RESOLVED_UV="$(command -v uv || true)"
    if [[ -n "${RESOLVED_UV}" ]]; then
      export TRANSCRIPTED_UV_PATH="${RESOLVED_UV}"
    fi
  fi
  if [[ -z "${UV_PYTHON:-}" ]]; then
    for PYTHON_CANDIDATE in python3.14 python3.13 python3.12 python3.11 python3.10; do
      RESOLVED_PYTHON="$(command -v "${PYTHON_CANDIDATE}" || true)"
      if [[ -n "${RESOLVED_PYTHON}" ]]; then
        export UV_PYTHON="${RESOLVED_PYTHON}"
        break
      fi
    done
  fi
else
  echo "[local-summary-fixture] Deterministic mode: mocked model output, no mlx runtime required."
fi
export CFFIXED_USER_HOME="${FAKE_HOME}"
export HOME="${FAKE_HOME}"
export TRANSCRIPTED_DISABLE_FILE_LOGGER=1
export TRANSCRIPTED_REPO_ROOT="${REPO_ROOT}"
export TRANSCRIPTED_LOCAL_SUMMARY_FIXTURE_RUN_ROOT="${RUN_ROOT}"
export TRANSCRIPTED_LOCAL_SUMMARY_FIXTURE_REAL_GEMMA="${REAL_GEMMA}"
run_with_timeout "${BIN}"

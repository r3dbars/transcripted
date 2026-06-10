#!/usr/bin/env bash
set -euo pipefail

# Deterministic local-summary fixture smoke.
# This proves the Transcripted app-side summarizer starts, finishes, and writes
# the expected Markdown shape without private meeting content or model downloads.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_ROOT="${TRANSCRIPTED_LOCAL_SUMMARY_FIXTURE_OUT:-${REPO_ROOT}/build/local-summary-fixture}"
RUN_ID="${TRANSCRIPTED_LOCAL_SUMMARY_FIXTURE_RUN_ID:-fixture-$(date +%Y%m%d-%H%M%S)}"
TIMEOUT_SECONDS="${TRANSCRIPTED_LOCAL_SUMMARY_FIXTURE_TIMEOUT:-10}"
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
            try await run(in: runRoot)
        } catch {
            fputs("[local-summary-fixture] FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run(in runRoot: URL) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: runRoot, withIntermediateDirectories: true)

        let transcriptURL = runRoot.appendingPathComponent("Synthetic Summary Fixture.md")
        let promptCaptureURL = runRoot.appendingPathComponent("captured-prompt.txt")
        try fixtureTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let configuration = fixtureConfiguration()
        let runtime = LocalGemmaSummaryRuntime(
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

        let result = try await LocalMeetingSummarizer(
            configuration: configuration,
            runtime: runtime
        ).summarize(
            transcriptURL: transcriptURL,
            title: "Synthetic Summary Fixture",
            date: Date(timeIntervalSince1970: 1_780_000_000)
        )

        let updatedMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        let capturedPrompt = try String(contentsOf: promptCaptureURL, encoding: .utf8)

        try expect(result.chunkCount == 1, "fixture should use the direct summary path")
        try expect(result.profileName == "fixture", "fixture profile should be reported")
        try expect(capturedPrompt.contains("summary fixture stays local"), "prompt should include synthetic transcript text")
        try expect(!capturedPrompt.contains("fixture-secret"), "prompt should exclude non-transcript notes")
        try expect(updatedMarkdown.contains("local_summary_version: \"1\""), "frontmatter should include local summary version")
        try expect(updatedMarkdown.contains("local_summary_source_transcript: \"Synthetic Summary Fixture.md\""), "frontmatter should backlink the source transcript")
        try expect(updatedMarkdown.contains("local_summary_title: \"Fixture Summary Review\""), "frontmatter should include generated title")
        try expect(updatedMarkdown.contains("local_summary_chunk_count: \"1\""), "frontmatter should include chunk count")
        try expect(updatedMarkdown.contains("local_summary_participants: \"- Alex | - Riley\""), "frontmatter should include transcript participants")
        try expect(updatedMarkdown.contains("local_summary_next_steps:"), "frontmatter should include agent next steps")
        try expect(updatedMarkdown.contains("local_summary_commitments:"), "frontmatter should include commitment aliases")
        try expect(updatedMarkdown.contains(LocalMeetingSummaryMarkdownUpdater.startMarker), "managed summary start marker should be present")
        try expect(updatedMarkdown.contains("## Local Gemma Summary"), "managed summary heading should be present")
        try expect(updatedMarkdown.contains("Source transcript: `Synthetic Summary Fixture.md`"), "managed summary should backlink the source transcript")
        try expect(updatedMarkdown.contains("### Summary\nThe fixture proves local summary generation can finish and rewrite the saved meeting."), "summary body should be written")
        try expect(updatedMarkdown.contains("### Next Steps\nQA should keep this fixture in the bench.\nThe release gate should not treat fixture output as quality proof."), "next steps body should be written")
        try expect(updatedMarkdown.contains("### Participants\n- Alex\n- Riley"), "participants body should be written")
        try expect(updatedMarkdown.contains("### Action Items\nQA should keep this fixture in the bench."), "action item body should be written")
        try expect(updatedMarkdown.contains(LocalMeetingSummaryMarkdownUpdater.endMarker), "managed summary end marker should be present")
        try expect(!fileManager.fileExists(atPath: LocalMeetingSummaryStore.summaryURL(for: transcriptURL).path), "fixture should not create a sibling summary sidecar")

        print("[local-summary-fixture] PASS: generated deterministic local summary fixture")
        print("[local-summary-fixture] Transcript: \(transcriptURL.path)")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw FixtureError.failed(message)
        }
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
  "${REPO_ROOT}/Sources/Support/TranscriptedStoragePaths.swift" \
  "${REPO_ROOT}/Sources/Meeting/LocalMeetingSummarizer.swift" \
  "${REPO_ROOT}/Sources/TranscriptedCore/Storage/TranscriptFrontmatter.swift" \
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
export CFFIXED_USER_HOME="${FAKE_HOME}"
export HOME="${FAKE_HOME}"
export TRANSCRIPTED_DISABLE_FILE_LOGGER=1
export TRANSCRIPTED_LOCAL_SUMMARY_FIXTURE_RUN_ROOT="${RUN_ROOT}"
run_with_timeout "${BIN}"

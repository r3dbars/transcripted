import Foundation

func testMeetingTranscriptStyler() {
    runSuite("MeetingTranscriptStylerTests") {
        testMeetingTranscriptStylerRenamesArtifacts()
        testMeetingTranscriptStylerRenamesSiblingArtifacts()
        testMeetingTranscriptStylerIsIdempotent()
    }
}

private func testMeetingTranscriptStylerRenamesArtifacts() {
    let directory = makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let originalStem = "Call_2026-04-07_09-14-00"
    let transcriptURL = directory.appendingPathComponent("\(originalStem).md")
    try? sampleMeetingTranscript().write(to: transcriptURL, atomically: true, encoding: .utf8)

    let styled = MeetingTranscriptStyler.restyleTranscript(at: transcriptURL)
    let updatedMarkdown = try? String(contentsOf: styled.url, encoding: .utf8)

    assertEqual(styled.title, "Meeting with Alex", "Styler should promote named remote speakers into the title")
    assertEqual(styled.url.lastPathComponent, "Meeting with Alex.md", "Styler should rename the markdown artifact to the final title")
    assertTrue(FileManager.default.fileExists(atPath: styled.url.path), "Renamed markdown should exist")
    assertFalse(FileManager.default.fileExists(atPath: transcriptURL.path), "Original markdown should be replaced")
    assertTrue(updatedMarkdown?.contains("# Meeting with Alex") == true, "Markdown body should be rewritten with the canonical title")
}

private func testMeetingTranscriptStylerRenamesSiblingArtifacts() {
    let directory = makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let originalStem = "Call_2026-04-07_09-14-00"
    let transcriptURL = directory.appendingPathComponent("\(originalStem).md")
    let sidecarURL = directory.appendingPathComponent("\(originalStem).json")
    let indexURL = directory.appendingPathComponent("transcripted.json")

    try? sampleMeetingTranscript().write(to: transcriptURL, atomically: true, encoding: .utf8)
    try? """
    {"version":"1.0","transcript_id":"abc","recording":{"date":"2026-04-07T09:14:00-0500","duration_seconds":750,"dropped_segments":0,"engines":{"stt":"parakeet-tdt-v3","diarization":"pyannote-offline"}},"speakers":[],"utterances":[]}
    """.write(to: sidecarURL, atomically: true, encoding: .utf8)
    try? """
    {"version":"1.0","updated_at":"2026-04-07T09:14:00-0500","transcript_count":1,"transcripts":[{"filename":"\(originalStem)","date":"2026-04-07","duration_seconds":750,"speaker_count":1,"word_count":42,"speakers":["Alex"]}],"known_speakers":[]}
    """.write(to: indexURL, atomically: true, encoding: .utf8)

    let styled = MeetingTranscriptStyler.restyleTranscript(at: transcriptURL)
    let renamedSidecar = directory.appendingPathComponent("Meeting with Alex.json")
    let indexText = try? String(contentsOf: indexURL, encoding: .utf8)

    assertTrue(FileManager.default.fileExists(atPath: renamedSidecar.path), "Styler should move the sibling JSON sidecar with the markdown file")
    assertFalse(FileManager.default.fileExists(atPath: sidecarURL.path), "Original JSON sidecar should be replaced")
    assertTrue(indexText?.contains("\"filename\" : \"Meeting with Alex\"") == true, "Styler should update transcripted.json to the renamed stem")
    assertTrue(styled.url.lastPathComponent == "Meeting with Alex.md", "Markdown rename should still use the canonical title")
}

private func testMeetingTranscriptStylerIsIdempotent() {
    let directory = makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let transcriptURL = directory.appendingPathComponent("Meeting with Alex.md")
    try? sampleMeetingTranscript().write(to: transcriptURL, atomically: true, encoding: .utf8)

    let firstPass = MeetingTranscriptStyler.restyleTranscript(at: transcriptURL)
    let secondPass = MeetingTranscriptStyler.restyleTranscript(at: firstPass.url)

    assertEqual(firstPass.url, secondPass.url, "Styler should not create duplicate files once the title is canonical")
    assertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Meeting with Alex 2.md").path), "Styler should not append duplicate suffixes on repeated passes")
}

private func sampleMeetingTranscript() -> String {
    """
    ---
    date: "2026-04-07"
    time: "09:14:00"
    duration: "12:30"
    total_word_count: "42"
    mic_utterances: "1"
    system_utterances: "1"
    ---

    ## Full Transcript

    **[00:00] [Mic/You]**
    Thanks for making time today.

    **[00:04] [System/Alex]**
    Happy to help. Let's get started.
    """
}

private func makeTemporaryTestDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingTranscriptStylerTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

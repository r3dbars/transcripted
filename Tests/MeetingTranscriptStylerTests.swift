import Foundation

func testMeetingTranscriptStyler() {
    runSuite("MeetingTranscriptStylerTests") {
        testMeetingTranscriptStylerRenamesArtifacts()
        testMeetingTranscriptStylerIsIdempotent()
    }
}

private func testMeetingTranscriptStylerRenamesArtifacts() {
    let directory = makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let originalStem = "Call_2026-04-07_09-14-00"
    let transcriptURL = directory.appendingPathComponent("\(originalStem).md")
    let jsonURL = directory.appendingPathComponent("\(originalStem).json")
    let indexURL = directory.appendingPathComponent("transcripted.json")

    try? sampleMeetingTranscript().write(to: transcriptURL, atomically: true, encoding: .utf8)
    try? "{}".write(to: jsonURL, atomically: true, encoding: .utf8)
    try? sampleAgentIndex(stem: originalStem).write(to: indexURL, atomically: true, encoding: .utf8)

    let styled = MeetingTranscriptStyler.restyleTranscript(at: transcriptURL)
    let updatedMarkdown = try? String(contentsOf: styled.url, encoding: .utf8)
    let updatedIndexData = try? Data(contentsOf: indexURL)
    let updatedIndex = updatedIndexData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let transcripts = updatedIndex?["transcripts"] as? [[String: Any]]

    assertEqual(styled.title, "Meeting with Alex", "Styler should promote named remote speakers into the title")
    assertEqual(styled.url.lastPathComponent, "Meeting with Alex.md", "Styler should rename the markdown artifact to the final title")
    assertTrue(FileManager.default.fileExists(atPath: styled.url.path), "Renamed markdown should exist")
    assertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Meeting with Alex.json").path), "Matching JSON sidecar should move with the markdown")
    assertFalse(FileManager.default.fileExists(atPath: transcriptURL.path), "Original markdown should be replaced")
    assertTrue(updatedMarkdown?.contains("# Meeting with Alex") == true, "Markdown body should be rewritten with the canonical title")
    assertEqual(transcripts?.first?["filename"] as? String, "Meeting with Alex" as String?, "Agent index should follow the renamed artifact")
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

private func sampleAgentIndex(stem: String) -> String {
    """
    {
      "known_speakers" : [],
      "transcript_count" : 1,
      "transcripts" : [
        {
          "date" : "2026-04-07",
          "duration_seconds" : 750,
          "filename" : "\(stem)",
          "speaker_count" : 2,
          "speakers" : [
            "You",
            "Alex"
          ],
          "word_count" : 42
        }
      ],
      "updated_at" : "2026-04-07T09:14:00-0500",
      "version" : "1.0"
    }
    """
}

private func makeTemporaryTestDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingTranscriptStylerTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

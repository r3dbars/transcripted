import Foundation

func testMeetingTranscriptStyler() {
    runSuite("MeetingTranscriptStylerTests") {
        testMeetingTranscriptStylerRenamesArtifacts()
        testMeetingTranscriptStylerDoesNotCreateSiblingArtifacts()
        testMeetingTranscriptStylerIsIdempotent()
        testMeetingTranscriptStylerPreservesExplicitTitle()
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

private func testMeetingTranscriptStylerDoesNotCreateSiblingArtifacts() {
    let directory = makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let originalStem = "Call_2026-04-07_09-14-00"
    let transcriptURL = directory.appendingPathComponent("\(originalStem).md")

    try? sampleMeetingTranscript().write(to: transcriptURL, atomically: true, encoding: .utf8)

    let styled = MeetingTranscriptStyler.restyleTranscript(at: transcriptURL)
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    let jsonArtifacts = files.filter { $0.pathExtension == "json" }

    assertTrue(jsonArtifacts.isEmpty, "Styler should not create or depend on sibling JSON artifacts")
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

private func testMeetingTranscriptStylerPreservesExplicitTitle() {
    let directory = makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let transcriptURL = directory.appendingPathComponent("Call_2026-04-07_09-14-00.md")
    try? sampleImportedTranscript().write(to: transcriptURL, atomically: true, encoding: .utf8)

    let styled = MeetingTranscriptStyler.restyleTranscript(at: transcriptURL)
    let updatedMarkdown = try? String(contentsOf: styled.url, encoding: .utf8)

    assertEqual(styled.title, "Customer Interview April", "Styler should respect an explicit imported transcript title")
    assertEqual(styled.url.lastPathComponent, "Customer Interview April.md", "Explicit titles should drive the final transcript filename")
    assertTrue(updatedMarkdown?.contains("# Customer Interview April") == true, "Explicit titles should be written back into the rendered markdown")
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

private func sampleImportedTranscript() -> String {
    """
    ---
    title: "Customer Interview April"
    date: "2026-04-07"
    time: "09:14:00"
    duration: "12:30"
    total_word_count: "42"
    mic_utterances: "0"
    system_utterances: "2"
    ---

    ## Full Transcript

    **[00:00] [System/Speaker 0]**
    Thanks for sitting down with us today.

    **[00:04] [System/Speaker 1]**
    Happy to help.
    """
}

private func makeTemporaryTestDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingTranscriptStylerTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

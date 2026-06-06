import Foundation

func testMeetingTranscriptStyler() {
    runSuite("MeetingTranscriptStylerTests") {
        testMeetingTranscriptStylerRenamesArtifacts()
        testMeetingTranscriptStylerDoesNotCreateSiblingArtifacts()
        testMeetingTranscriptStylerIsIdempotent()
        testMeetingTranscriptStylerPreservesExplicitTitle()
        testMeetingTranscriptStylerDisplaysExplicitTitleWithoutFullBodyRead()
        testMeetingTranscriptStylerPreviewReadsBoundedMeetingMetadata()
        testMeetingTranscriptStylerPreviewReadsLegacyHeadingAtBodyStart()
        testMeetingTranscriptStylerPreviewReadsOversizedMeetingFrontmatter()
        testMeetingTranscriptStylerPreviewRejectsPlainMarkdown()
        testMeetingTranscriptStylerSkipsNonMeetingFrontmatter()
        testMeetingTranscriptStylerRenamesRetainedAudioDirectory()
        testMeetingTranscriptStylerAvoidsAudioDirectoryCollisions()
        testMeetingTranscriptStylerPreservesObsidianSpeakerLinks()
        testMeetingTranscriptStylerPreservesLocalGemmaSummaryBlock()
        testMeetingTranscriptStylerRestrictsRewrittenTranscript()
        testMeetingTranscriptStylerPreservesImportedRecordingDate()
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

private func testMeetingTranscriptStylerPreservesImportedRecordingDate() {
    let directory = makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    // The styler renames an imported note off its Call_<date> stem to a title
    // stem. It must not drop or rewrite the recording date carried in the front
    // matter — preserving that source date end-to-end is the point of issue #850.
    let transcriptURL = directory.appendingPathComponent("Call_2026-04-07_09-14-00.md")
    try? sampleImportedTranscript().write(to: transcriptURL, atomically: true, encoding: .utf8)

    let styled = MeetingTranscriptStyler.restyleTranscript(at: transcriptURL)
    let updatedMarkdown = (try? String(contentsOf: styled.url, encoding: .utf8)) ?? ""

    assertEqual(
        styled.url.lastPathComponent,
        "Customer Interview April.md",
        "Imported notes should still be renamed to their explicit title"
    )
    assertTrue(
        updatedMarkdown.contains("date: \"2026-04-07\""),
        "Restyling must preserve the imported recording date in the front matter"
    )
    assertTrue(
        updatedMarkdown.contains("time: \"09:14:00\""),
        "Restyling must preserve the imported recording time in the front matter"
    )
}

private func testMeetingTranscriptStylerDisplaysExplicitTitleWithoutFullBodyRead() {
    let directory = makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let transcriptURL = directory.appendingPathComponent("Customer Interview April.md")
    let frontmatter = """
    ---
    title: "Customer Interview April"
    date: "2026-04-07"
    time: "09:14:00"
    duration: "12:30"
    ---

    """
    var data = Data(frontmatter.utf8)
    data.append(Data(repeating: UInt8(ascii: "x"), count: 70_000))
    data.append(0xff)
    try? data.write(to: transcriptURL)

    let styled = MeetingTranscriptStyler.displayTranscript(at: transcriptURL)

    assertEqual(
        styled.title,
        "Customer Interview April",
        "Display-only titles should come from frontmatter without requiring a full transcript body read"
    )
}

private func testMeetingTranscriptStylerPreviewReadsBoundedMeetingMetadata() {
    let directory = makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let transcriptURL = directory.appendingPathComponent("Call_2026-04-07_09-14-00.md")
    let oversizedBody = String(repeating: "extra transcript text\n", count: 8_000)
    try? (sampleImportedTranscript() + "\n" + oversizedBody).write(to: transcriptURL, atomically: true, encoding: .utf8)

    let preview = MeetingTranscriptStyler.displayTranscriptPreview(at: transcriptURL)

    assertEqual(preview?.title, "Customer Interview April", "Preview should derive the same title without requiring a full restyle pass")
    assertEqual(preview?.url, transcriptURL, "Preview should not rename or rewrite the transcript")
}

private func testMeetingTranscriptStylerPreviewReadsLegacyHeadingAtBodyStart() {
    let directory = makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let transcriptURL = directory.appendingPathComponent("Legacy_Call.md")
    let raw = """
    ---
    title: "Legacy Meeting"
    date: "2026-04-07"
    time: "09:14:00"
    duration: "12:30"
    total_word_count: "42"
    mic_utterances: "0"
    system_utterances: "1"
    ---
    ## Transcript

    [00:00] [System/Speaker 1] Hello.
    """
    try? raw.write(to: transcriptURL, atomically: true, encoding: .utf8)

    let preview = MeetingTranscriptStyler.displayTranscriptPreview(at: transcriptURL)

    assertEqual(preview?.title, "Legacy Meeting", "Preview should include legacy meeting transcripts when the body starts with the transcript heading")
    assertEqual(preview?.url, transcriptURL, "Preview should not rename or rewrite legacy meeting transcripts")
}

private func testMeetingTranscriptStylerPreviewReadsOversizedMeetingFrontmatter() {
    let directory = makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let transcriptURL = directory.appendingPathComponent("Long_Call_2026-04-07_09-14-00.md")
    let gapEvents = (0..<3_000)
        .map { "  - \"gap \($0) \(String(repeating: "x", count: 24))\"" }
        .joined(separator: "\n")
    let raw = """
    ---
    capture_type: meeting
    title: "Long Customer Call"
    date: 2026-04-07
    time: 09:14:00
    duration: "120:00"
    mic_utterances: 1
    system_utterances: 24
    total_word_count: 5000
    gap_events:
    \(gapEvents)
    ---

    ## Full Transcript

    [00:00] [System/Speaker 1] Hello.
    """
    try? raw.write(to: transcriptURL, atomically: true, encoding: .utf8)

    let preview = MeetingTranscriptStyler.displayTranscriptPreview(at: transcriptURL)

    assertEqual(preview?.title, "Long Customer Call", "Preview should include long meetings even when frontmatter exceeds the first preview chunk")
    assertEqual(preview?.url, transcriptURL, "Preview should not rename or rewrite oversized meeting transcripts")
}

private func testMeetingTranscriptStylerPreviewRejectsPlainMarkdown() {
    let directory = makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let noteURL = directory.appendingPathComponent("notes.md")
    try? "# Notes\n\nNot a Transcripted meeting.".write(to: noteURL, atomically: true, encoding: .utf8)

    assertNil(MeetingTranscriptStyler.displayTranscriptPreview(at: noteURL), "Preview should skip non-meeting markdown files")
}

private func testMeetingTranscriptStylerSkipsNonMeetingFrontmatter() {
    let directory = makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let noteURL = directory.appendingPathComponent("notes.md")
    let raw = """
    ---
    title: "Project Note"
    date: "2026-04-07"
    ---

    # Project Note

    This is not a Transcripted meeting.
    """
    try? raw.write(to: noteURL, atomically: true, encoding: .utf8)

    let styled = MeetingTranscriptStyler.restyleTranscript(at: noteURL)
    let updated = try? String(contentsOf: noteURL, encoding: .utf8)

    assertEqual(styled.url, noteURL, "Styler should leave non-meeting notes at their original path")
    assertEqual(styled.title, "Project Note", "Styler may display the explicit title without taking ownership")
    assertEqual(updated, raw, "Styler should not rewrite Markdown that is not a Transcripted meeting")
    assertFalse(
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("Project Note.md").path),
        "Styler should not rename non-meeting notes"
    )
}

private func testMeetingTranscriptStylerRenamesRetainedAudioDirectory() {
    let directory = makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let originalStem = "Call_2026-04-07_09-14-00"
    let transcriptURL = directory.appendingPathComponent("\(originalStem).md")
    let audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
    let audioDirectory = audioRoot.appendingPathComponent("\(originalStem)_audio", isDirectory: true)
    let micURL = audioDirectory.appendingPathComponent("microphone.wav")
    try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))
    try? sampleMeetingTranscript().write(to: transcriptURL, atomically: true, encoding: .utf8)

    let styled = MeetingTranscriptStyler.restyleTranscript(at: transcriptURL)
    let styledAudioDirectory = audioRoot.appendingPathComponent("Meeting with Alex_audio", isDirectory: true)

    assertEqual(styled.url.lastPathComponent, "Meeting with Alex.md", "Styler should still rename the transcript")
    assertTrue(FileManager.default.fileExists(atPath: styledAudioDirectory.path), "Retained audio directory should follow the transcript rename")
    assertTrue(FileManager.default.fileExists(atPath: styledAudioDirectory.appendingPathComponent("microphone.wav").path), "Retained audio files should move with the directory")
    assertFalse(FileManager.default.fileExists(atPath: audioDirectory.path), "Original retained audio directory should be replaced")
}

private func testMeetingTranscriptStylerAvoidsAudioDirectoryCollisions() {
    let directory = makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let originalStem = "Call_2026-04-07_09-14-00"
    let transcriptURL = directory.appendingPathComponent("\(originalStem).md")
    let audioRoot = directory.appendingPathComponent("audio", isDirectory: true)
    let originalAudioDirectory = audioRoot.appendingPathComponent("\(originalStem)_audio", isDirectory: true)
    let existingAudioDirectory = audioRoot.appendingPathComponent("Meeting with Alex_audio", isDirectory: true)
    let movedAudioDirectory = audioRoot.appendingPathComponent("Meeting with Alex 2_audio", isDirectory: true)
    try? FileManager.default.createDirectory(at: originalAudioDirectory, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: existingAudioDirectory, withIntermediateDirectories: true)
    FileManager.default.createFile(
        atPath: originalAudioDirectory.appendingPathComponent("microphone.wav").path,
        contents: Data("mic".utf8)
    )
    try? sampleMeetingTranscript().write(to: transcriptURL, atomically: true, encoding: .utf8)

    let styled = MeetingTranscriptStyler.restyleTranscript(at: transcriptURL)

    assertEqual(styled.url.lastPathComponent, "Meeting with Alex 2.md", "Styler should avoid transcript/audio collisions together")
    assertTrue(FileManager.default.fileExists(atPath: movedAudioDirectory.path), "Audio directory should keep the matching transcript stem")
    assertTrue(
        FileManager.default.fileExists(atPath: movedAudioDirectory.appendingPathComponent("microphone.wav").path),
        "Retained audio should move to the collision-free matching directory"
    )
    assertTrue(FileManager.default.fileExists(atPath: existingAudioDirectory.path), "Existing audio directory should not be overwritten")
}

private func testMeetingTranscriptStylerPreservesObsidianSpeakerLinks() {
    let directory = makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let transcriptURL = directory.appendingPathComponent("Call_2026-04-07_09-14-00.md")
    try? sampleObsidianTranscript().write(to: transcriptURL, atomically: true, encoding: .utf8)

    let styled = MeetingTranscriptStyler.restyleTranscript(at: transcriptURL)
    let updatedMarkdown = try? String(contentsOf: styled.url, encoding: .utf8)

    assertTrue(updatedMarkdown?.contains("[System/[[Alex]]]") == true, "Styler should preserve Obsidian speaker links")
    assertTrue(updatedMarkdown?.contains("Linked speaker text should stay intact.") == true, "Styler should keep the transcript text attached to the right speaker")
}

private func testMeetingTranscriptStylerPreservesLocalGemmaSummaryBlock() {
    let directory = makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let transcriptURL = directory.appendingPathComponent("Call_2026-04-07_09-14-00.md")
    let markdown = LocalMeetingSummaryMarkdownUpdater.markdown(
        byApplying: sampleMeetingTranscriptLocalSummarySections(),
        to: sampleMeetingTranscript(),
        configuration: .m1Optimized(physicalMemoryBytes: 16 * 1024 * 1024 * 1024),
        generatedAt: Date(timeIntervalSince1970: 1_780_000_000),
        chunkCount: 1
    )
    try? markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)

    let styled = MeetingTranscriptStyler.restyleTranscript(at: transcriptURL)
    let updatedMarkdown = (try? String(contentsOf: styled.url, encoding: .utf8)) ?? ""

    assertTrue(
        updatedMarkdown.contains(LocalMeetingSummaryMarkdownUpdater.startMarker),
        "Restyling should preserve the managed local summary block"
    )
    assertTrue(
        updatedMarkdown.contains("Team agreed to keep launch pricing simple."),
        "Restyling should preserve the local summary text"
    )
    assertTrue(
        updatedMarkdown.contains("local_summary_title: \"Launch Pricing Review\""),
        "Restyling should preserve local summary frontmatter"
    )
}

private func testMeetingTranscriptStylerRestrictsRewrittenTranscript() {
    let directory = makeTemporaryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let transcriptURL = directory.appendingPathComponent("Call_2026-04-07_09-14-00.md")
    try? sampleMeetingTranscript().write(to: transcriptURL, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: transcriptURL.path)

    let styled = MeetingTranscriptStyler.restyleTranscript(at: transcriptURL)

    assertEqual(
        meetingTranscriptStylerFilePermissions(of: styled.url),
        NSNumber(value: 0o600),
        "rewriting a transcript should restore owner-only permissions"
    )
}

private func sampleMeetingTranscriptLocalSummarySections() -> LocalMeetingSummarySections {
    LocalMeetingSummarySections(
        title: "Launch Pricing Review",
        summary: "Team agreed to keep launch pricing simple.",
        decisions: "Keep the first version small.",
        actionItems: "Alex will check pricing language before Friday.",
        openQuestions: "Whether enterprise pricing needs a separate page.",
        risksOrFollowUps: "Pricing copy could overpromise the first version.",
        accuracyNotes: "Based only on the transcript."
    )
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

private func sampleObsidianTranscript() -> String {
    """
    ---
    date: "2026-04-07"
    time: "09:14:00"
    duration: "12:30"
    total_word_count: "42"
    mic_utterances: "0"
    system_utterances: "1"
    ---

    ## Full Transcript

    **[00:04] [System/[[Alex]]]**
    Linked speaker text should stay intact.
    """
}

private func makeTemporaryTestDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingTranscriptStylerTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func meetingTranscriptStylerFilePermissions(of url: URL) -> NSNumber? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return attributes?[.posixPermissions] as? NSNumber
}

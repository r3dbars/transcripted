import Foundation

func testMeetingAudioArchiveResolver() {
    runSuite("MeetingAudioArchiveResolverTests") {
        testResolverFindsLiveMeetingAudioPair()
        testResolverPrefersImportedRecording()
        testResolverPrefersPlaybackMix()
        testResolverReturnsNilWhenAudioIsMissing()
    }
}

private func testResolverFindsLiveMeetingAudioPair() {
    let directory = makeMeetingAudioResolverTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let transcriptURL = directory.appendingPathComponent("Meeting with Alex.md")
    let audioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: transcriptURL)
    try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    FileManager.default.createFile(
        atPath: audioDirectory.appendingPathComponent("microphone.wav").path,
        contents: Data("mic".utf8)
    )
    FileManager.default.createFile(
        atPath: audioDirectory.appendingPathComponent("system_audio.wav").path,
        contents: Data("system".utf8)
    )

    let attachment = MeetingAudioArchiveResolver.attachment(forTranscript: transcriptURL)

    assertNotNil(attachment, "Live meeting audio should resolve")
    assertEqual(
        attachment?.urls.map(\.lastPathComponent),
        ["system_audio.wav", "microphone.wav"],
        "Live playback should include system audio and microphone together"
    )
    assertTrue(attachment?.isCompositePlayback == true, "Two retained streams should be treated as composite playback")
}

private func testResolverPrefersImportedRecording() {
    let directory = makeMeetingAudioResolverTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let transcriptURL = directory.appendingPathComponent("Customer Interview.md")
    let audioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: transcriptURL)
    try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    FileManager.default.createFile(
        atPath: audioDirectory.appendingPathComponent("recording.m4a").path,
        contents: Data("imported".utf8)
    )
    FileManager.default.createFile(
        atPath: audioDirectory.appendingPathComponent("system_audio.wav").path,
        contents: Data("system".utf8)
    )

    let attachment = MeetingAudioArchiveResolver.attachment(forTranscript: transcriptURL)

    assertEqual(
        attachment?.urls.map(\.lastPathComponent),
        ["recording.m4a"],
        "Imported recordings should play the original retained recording"
    )
    assertTrue(attachment?.isCompositePlayback == false, "A single imported recording is not composite playback")
}

private func testResolverPrefersPlaybackMix() {
    let directory = makeMeetingAudioResolverTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let transcriptURL = directory.appendingPathComponent("Weekly Review.md")
    let audioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: transcriptURL)
    try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    FileManager.default.createFile(
        atPath: audioDirectory.appendingPathComponent("playback.m4a").path,
        contents: Data("mix".utf8)
    )
    FileManager.default.createFile(
        atPath: audioDirectory.appendingPathComponent("recording.m4a").path,
        contents: Data("imported".utf8)
    )
    FileManager.default.createFile(
        atPath: audioDirectory.appendingPathComponent("system_audio.m4a").path,
        contents: Data("system".utf8)
    )
    FileManager.default.createFile(
        atPath: audioDirectory.appendingPathComponent("microphone.m4a").path,
        contents: Data("mic".utf8)
    )

    let attachment = MeetingAudioArchiveResolver.attachment(forTranscript: transcriptURL)

    assertEqual(
        attachment?.urls.map(\.lastPathComponent),
        ["playback.m4a"],
        "Playback mixes should win over imported and split-stream audio"
    )
    assertTrue(attachment?.isCompositePlayback == false, "A single playback mix is not composite playback")
}

private func testResolverReturnsNilWhenAudioIsMissing() {
    let directory = makeMeetingAudioResolverTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let transcriptURL = directory.appendingPathComponent("No Audio.md")

    assertNil(
        MeetingAudioArchiveResolver.attachment(forTranscript: transcriptURL),
        "Missing retained audio should not show playback controls"
    )
}

private func makeMeetingAudioResolverTestDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingAudioArchiveResolverTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

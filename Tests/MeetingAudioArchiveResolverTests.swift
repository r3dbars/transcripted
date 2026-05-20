import Foundation

func testMeetingAudioArchiveResolver() {
    runSuite("MeetingAudioArchiveResolverTests") {
        testResolverKeepsLiveMeetingAudioPairButPrefersSystemPlayback()
        testResolverFallsBackToMicrophonePlayback()
        testAttachmentPlaybackPrefersSystemForFailedMeetingAudio()
        testRetainedAudioFactoryPreservesFailedMeetingSources()
        testPlaybackLoadingPolicyUsesDefaultSourceOnly()
        testPlaybackLoadingPolicyUsesSelectedSourceOnly()
        testResolverPrefersImportedRecording()
        testResolverPrefersPlaybackMix()
        testResolverReturnsNilWhenAudioIsMissing()
    }
}

private func testResolverKeepsLiveMeetingAudioPairButPrefersSystemPlayback() {
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
        "Live meetings should keep both retained source files available"
    )
    assertEqual(
        attachment?.playbackURLs.map(\.lastPathComponent),
        ["system_audio.wav"],
        "Live meeting playback should prefer the clean system track over mic+system echo"
    )
    assertEqual(
        attachment?.playbackURLCandidates.map { $0.map(\.lastPathComponent).joined(separator: "+") },
        ["system_audio.wav", "microphone.wav"],
        "Live meeting playback should offer each retained source without layering them"
    )
    assertEqual(
        attachment?.playbackChoices.map(\.title),
        ["System", "Mic"],
        "Live meeting playback should make the mic track selectable when system is the default"
    )
    assertTrue(attachment?.isCompositePlayback == false, "Live playback should not layer mic and system audio by default")
}

private func testResolverFallsBackToMicrophonePlayback() {
    let directory = makeMeetingAudioResolverTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let transcriptURL = directory.appendingPathComponent("In Room Meeting.md")
    let audioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: transcriptURL)
    try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    FileManager.default.createFile(
        atPath: audioDirectory.appendingPathComponent("microphone.wav").path,
        contents: Data("mic".utf8)
    )

    let attachment = MeetingAudioArchiveResolver.attachment(forTranscript: transcriptURL)

    assertEqual(
        attachment?.urls.map(\.lastPathComponent),
        ["microphone.wav"],
        "Mic-only retained audio should still resolve"
    )
    assertEqual(
        attachment?.playbackURLs.map(\.lastPathComponent),
        ["microphone.wav"],
        "Mic-only retained audio should remain playable when system audio is missing"
    )
    assertTrue(attachment?.isCompositePlayback == false, "A mic fallback should stay single-file playback")
}

private func testAttachmentPlaybackPrefersSystemForFailedMeetingAudio() {
    let directory = makeMeetingAudioResolverTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let systemURL = directory.appendingPathComponent("system_audio.wav")
    let micURL = directory.appendingPathComponent("microphone.wav")
    let attachment = MeetingAudioAttachment(
        directoryURL: directory,
        urls: [micURL, systemURL]
    )

    assertEqual(
        attachment.urls.map(\.lastPathComponent),
        ["microphone.wav", "system_audio.wav"],
        "Failed-meeting attachments should preserve all retained source URLs"
    )
    assertEqual(
        attachment.playbackURLs.map(\.lastPathComponent),
        ["system_audio.wav"],
        "Failed-meeting playback should also avoid layering mic and system audio"
    )
    assertEqual(
        attachment.playbackURLCandidates.map { $0.map(\.lastPathComponent).joined(separator: "+") },
        ["system_audio.wav", "microphone.wav"],
        "Failed-meeting playback should offer each retained source without layering them"
    )
    assertEqual(
        attachment.playbackChoices.map(\.title),
        ["System", "Mic"],
        "Failed-meeting playback should make the mic track selectable when system is the default"
    )
    assertTrue(attachment.isCompositePlayback == false, "Failed-meeting playback should default to one source")
}

private func testRetainedAudioFactoryPreservesFailedMeetingSources() {
    let directory = makeMeetingAudioResolverTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let micURL = directory.appendingPathComponent("microphone.wav")
    let systemURL = directory.appendingPathComponent("system_audio.wav")

    let attachment = MeetingAudioAttachment.retainedAudio(urls: [micURL, systemURL])

    assertNotNil(attachment, "Failed-meeting retained audio should build a playback attachment")
    assertEqual(
        attachment?.directoryURL,
        directory,
        "Failed-meeting retained audio should use the retained audio directory"
    )
    assertEqual(
        attachment?.urls.map(\.lastPathComponent),
        ["microphone.wav", "system_audio.wav"],
        "Failed-meeting retained audio should keep every source for retry/debug access"
    )
    assertEqual(
        attachment?.playbackURLs.map(\.lastPathComponent),
        ["system_audio.wav"],
        "Failed-meeting retained audio should still default to one clean source"
    )
}

private func testPlaybackLoadingPolicyUsesDefaultSourceOnly() {
    let directory = makeMeetingAudioResolverTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let attachment = MeetingAudioAttachment(
        directoryURL: directory,
        urls: [
            directory.appendingPathComponent("microphone.wav"),
            directory.appendingPathComponent("system_audio.wav")
        ]
    )

    let choices = MeetingAudioPlaybackLoadingPolicy.choices(
        for: attachment,
        preferredChoice: nil
    )

    assertEqual(
        choices.map(\.title),
        ["System"],
        "The player should load only the default source instead of compositing mic plus system"
    )
    assertEqual(
        choices.flatMap(\.urls).map(\.lastPathComponent),
        ["system_audio.wav"],
        "Default playback should not hand both retained files to NSSound"
    )
}

private func testPlaybackLoadingPolicyUsesSelectedSourceOnly() {
    let directory = makeMeetingAudioResolverTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let attachment = MeetingAudioAttachment(
        directoryURL: directory,
        urls: [
            directory.appendingPathComponent("microphone.wav"),
            directory.appendingPathComponent("system_audio.wav")
        ]
    )
    let micChoice = attachment.playbackChoices.first { $0.title == "Mic" }

    let choices = MeetingAudioPlaybackLoadingPolicy.choices(
        for: attachment,
        preferredChoice: micChoice
    )

    assertEqual(
        choices.map(\.title),
        ["Mic"],
        "When the user chooses Mic, the player should load Mic without also adding System"
    )
    assertEqual(
        choices.flatMap(\.urls).map(\.lastPathComponent),
        ["microphone.wav"],
        "Selected mic playback should stay single-source"
    )
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
    assertEqual(
        attachment?.playbackURLs.map(\.lastPathComponent),
        ["recording.m4a"],
        "Imported recordings should keep the same single playback source"
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
    assertEqual(
        attachment?.playbackURLs.map(\.lastPathComponent),
        ["playback.m4a"],
        "Playback mixes should remain the default listening source"
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

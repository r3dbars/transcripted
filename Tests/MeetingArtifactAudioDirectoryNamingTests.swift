import Foundation

/// Contract test for `Sources/Meeting/MeetingArtifactRenamer.swift`
/// (`audioDirectoryURL(for:)`): retained meeting audio lives under
/// `audio/<stem>_audio/` beside the transcript Markdown file.
func testMeetingArtifactAudioDirectoryNaming() {
    runSuite("MeetingArtifactRenamer.audioDirectoryURL — audio/<stem>_audio/ naming") {
        for fixture in meetingArtifactAudioDirectoryNamingFixtures {
            let transcriptURL = URL(fileURLWithPath: fixture.transcriptPath, isDirectory: false)
            let produced = MeetingArtifactRenamer.audioDirectoryURL(for: transcriptURL)

            assertEqual(
                produced.path,
                fixture.expectedAudioDirectoryPath,
                "audioDirectoryURL(for:) should follow the audio/<stem>_audio/ convention for \(fixture.transcriptPath)"
            )
        }
    }
}

private let meetingArtifactAudioDirectoryNamingFixtures: [(transcriptPath: String, expectedAudioDirectoryPath: String)] = [
    (
        "/tmp/x/Call_2026-01-01_10-00-00.md",
        "/tmp/x/audio/Call_2026-01-01_10-00-00_audio"
    ),
    (
        "/Users/justin/Meetings/Weekly Sync.md",
        "/Users/justin/Meetings/audio/Weekly Sync_audio"
    ),
    (
        "/tmp/nested/dir/2026-07-12 Standup.md",
        "/tmp/nested/dir/audio/2026-07-12 Standup_audio"
    )
]

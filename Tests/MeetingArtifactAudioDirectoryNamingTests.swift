import Foundation

/// Drift guard: `audio/<stem>_audio/` is hardcoded in both
/// `Sources/Meeting/MeetingArtifactRenamer.swift` (`audioDirectoryURL(for:)`) and
/// `Tools/TranscriptedMCP/Sources/TranscriptedMCP/RecentMeetingsWidgetBuilder.swift`
/// (`audioDirectory(for:)`). The two packages can't share a module, so this test
/// and its MCP counterpart —
/// `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/AudioDirectoryNamingTests.swift`
/// — run over the same fixture table (codebase audit 2026-07-08). A future rename
/// of the convention in either place, without updating the other, is caught by
/// review diffing both tests' literal fixture tables and by whichever side's
/// implementation drifted from its own pinned expectation.
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

/// Same fixture inputs as `Tools/TranscriptedMCP/Tests/TranscriptedMCPTests/AudioDirectoryNamingTests.swift`.
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

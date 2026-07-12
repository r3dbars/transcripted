import XCTest
@testable import transcripted_mcp

/// Drift guard: `audio/<stem>_audio/` is hardcoded in both
/// `Tools/TranscriptedMCP/Sources/TranscriptedMCP/RecentMeetingsWidgetBuilder.swift`
/// (`audioDirectory(for:)`) and `Sources/Meeting/MeetingArtifactRenamer.swift`
/// (`audioDirectoryURL(for:)`) in the app. The two packages can't share a module,
/// so this test and its app-side counterpart —
/// `Tests/MeetingArtifactAudioDirectoryNamingTests.swift` — run over the same
/// fixture table (codebase audit 2026-07-08). A future rename of the convention
/// in either place, without updating the other, is caught by review diffing both
/// tests' literal fixture tables and by whichever side's implementation drifted
/// from its own pinned expectation.
final class AudioDirectoryNamingTests: XCTestCase {
    /// Same fixture inputs as `Tests/MeetingArtifactAudioDirectoryNamingTests.swift`.
    private let fixtures: [(transcriptPath: String, expectedAudioDirectoryPath: String)] = [
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

    func testAudioDirectoryFollowsSharedNamingConvention() {
        for fixture in fixtures {
            let transcriptURL = URL(fileURLWithPath: fixture.transcriptPath, isDirectory: false)
            let produced = RecentMeetingsWidgetBuilder.audioDirectory(for: transcriptURL)

            XCTAssertEqual(
                produced.path,
                fixture.expectedAudioDirectoryPath,
                "audioDirectory(for:) should follow the audio/<stem>_audio/ convention for \(fixture.transcriptPath)"
            )
        }
    }
}

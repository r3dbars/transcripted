import Foundation
import XCTest

/// Always compiled, including retrieval mode. A cached manifest or incomplete
/// dependency export must not turn an audio CI lane into retrieval-only proof.
final class BuildModeTests: XCTestCase {
    func testCompiledCapabilitiesMatchRequestedMode() {
        let environment = ProcessInfo.processInfo.environment
        let requestedMode: String
        if environment["TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT"] == "1" {
            requestedMode = "meeting"
        } else if environment["TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION"] == "1"
                    || environment["TRANSCRIPTEDCLI_ENABLE_DIARIZATION"] == "1" {
            requestedMode = "audio"
        } else {
            requestedMode = "retrieval"
        }
        let expectedMode = environment["TRANSCRIPTEDCLI_EXPECT_BUILD_MODE"] ?? requestedMode
        guard ["retrieval", "audio", "meeting"].contains(expectedMode) else {
            return XCTFail("Unknown expected CLI build mode: \(expectedMode)")
        }

        #if TRANSCRIPTEDCLI_WITH_TRANSCRIPTION && TRANSCRIPTEDCLI_WITH_DIARIZATION
        let compiledAudio = true
        #else
        let compiledAudio = false
        #endif
        #if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT
        let compiledMeeting = true
        #else
        let compiledMeeting = false
        #endif

        XCTAssertEqual(compiledAudio, expectedMode != "retrieval", "Wrong compiled audio capability for \(expectedMode)")
        XCTAssertEqual(compiledMeeting, expectedMode == "meeting", "Wrong compiled meeting capability for \(expectedMode)")
    }
}

import XCTest
@testable import TranscriptedCore

final class MicrophoneSharingTests: XCTestCase {
    func testZoomGuardOverridesAppleProcessingWithoutChangingPreferenceOrOpeningIdleMic() {
        let audio = Audio()
        audio.enableVoiceProcessing = true
        XCTAssertTrue(audio.shouldArmVoiceProcessing)
        audio.voiceProcessingSuppressedForMicrophoneSharing = true
        XCTAssertFalse(audio.shouldArmVoiceProcessing)
        XCTAssertTrue(audio.enableVoiceProcessing, "Preserve the requested processing mode")
        XCTAssertNil(audio.engine)
        XCTAssertNil(audio.inputNode)

        audio.prepareForNewRecordingStart()
        audio.resetMeetingRouteState()
        XCTAssertFalse(audio.shouldArmVoiceProcessing, "Start and device recovery must retain sharing protection")
        audio.voiceProcessingSuppressedForMicrophoneSharing = false
        XCTAssertTrue(audio.shouldArmVoiceProcessing, "Host can restore preference at a later recording")
    }

    func testSharedMeetingMicKeepsSoftwareGainAndHonorsRawMode() {
        let audio = Audio()
        audio.enableVoiceProcessing = true
        audio.enableSoftwareAGC = true
        audio.voiceProcessingSuppressedForMicrophoneSharing = true
        audio.refreshRealtimeAGCForCurrentProcessingMode()
        XCTAssertNotNil(audio.realtimeAGC, "Shared capture still boosts its saved microphone copy")

        audio.enableVoiceProcessing = false
        audio.enableSoftwareAGC = false
        audio.refreshRealtimeAGCForCurrentProcessingMode()
        XCTAssertFalse(audio.shouldArmVoiceProcessing)
        XCTAssertNil(audio.realtimeAGC, "Raw/off must not acquire processing or gain")
    }
}

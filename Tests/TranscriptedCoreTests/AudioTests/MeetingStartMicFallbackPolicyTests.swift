import XCTest
@testable import TranscriptedCore

final class MeetingStartMicFallbackPolicyTests: XCTestCase {
    func testRetriesDeviceLookupOnlyWhenTheFirstPassFoundNothing() {
        XCTAssertTrue(
            MeetingStartMicFallbackPolicy.shouldRetryDeviceLookup(foundFallback: false),
            "a Bluetooth route switch can hide the built-in mic for one lookup"
        )
        XCTAssertFalse(
            MeetingStartMicFallbackPolicy.shouldRetryDeviceLookup(foundFallback: true),
            "a found fallback must not look again"
        )
    }

    func testSettlesBeforeBindingWhenTheRouteIsBluetooth() {
        XCTAssertTrue(
            MeetingStartMicFallbackPolicy.shouldSettleBeforeFirstBind(
                defaultInputIsBluetooth: true,
                selectedInputIsBluetooth: false
            ),
            "automatic mode still has a Bluetooth default input to wait out"
        )
        XCTAssertTrue(
            MeetingStartMicFallbackPolicy.shouldSettleBeforeFirstBind(
                defaultInputIsBluetooth: false,
                selectedInputIsBluetooth: true
            ),
            "preserve-default keeps a Bluetooth headset as the meeting mic"
        )
        XCTAssertFalse(
            MeetingStartMicFallbackPolicy.shouldSettleBeforeFirstBind(
                defaultInputIsBluetooth: false,
                selectedInputIsBluetooth: false
            ),
            "a wired or built-in route does not wait"
        )
    }

    func testAdmitsSystemAudioWhenOnlyTheBluetoothMicIsMissing() {
        XCTAssertTrue(
            MeetingStartMicFallbackPolicy.shouldAdmitSystemAudioFirst(
                isRecording: true,
                micStreaming: false,
                systemStreaming: true,
                selectedInputIsBluetooth: true,
                requiresSystemAudio: true
            ),
            "call audio that is already flowing must not be torn down for a Bluetooth mic still settling"
        )
        XCTAssertFalse(
            MeetingStartMicFallbackPolicy.shouldAdmitSystemAudioFirst(
                isRecording: false,
                micStreaming: false,
                systemStreaming: true,
                selectedInputIsBluetooth: true,
                requiresSystemAudio: true
            ),
            "a graph that never started is a real start failure"
        )
        XCTAssertFalse(
            MeetingStartMicFallbackPolicy.shouldAdmitSystemAudioFirst(
                isRecording: true,
                micStreaming: false,
                systemStreaming: true,
                selectedInputIsBluetooth: false,
                requiresSystemAudio: true
            ),
            "a built-in or USB mic that never streams is not a Bluetooth settle"
        )
        XCTAssertFalse(
            MeetingStartMicFallbackPolicy.shouldAdmitSystemAudioFirst(
                isRecording: true,
                micStreaming: false,
                systemStreaming: false,
                selectedInputIsBluetooth: true,
                requiresSystemAudio: true
            ),
            "no system audio means there is nothing to keep"
        )
        XCTAssertFalse(
            MeetingStartMicFallbackPolicy.shouldAdmitSystemAudioFirst(
                isRecording: true,
                micStreaming: true,
                systemStreaming: true,
                selectedInputIsBluetooth: true,
                requiresSystemAudio: true
            ),
            "a ready mic does not need this admission"
        )
        XCTAssertFalse(
            MeetingStartMicFallbackPolicy.shouldAdmitSystemAudioFirst(
                isRecording: true,
                micStreaming: false,
                systemStreaming: true,
                selectedInputIsBluetooth: true,
                requiresSystemAudio: false
            ),
            "a mic-only recording has no system stream to admit"
        )
    }

    func testBluetoothTransportAndDeviceClassStayAligned() {
        XCTAssertTrue(MeetingStartMicFallbackPolicy.isBluetoothInput(transportRawValue: "bluetooth"))
        XCTAssertTrue(MeetingStartMicFallbackPolicy.isBluetoothInput(transportRawValue: "bluetoothLE"))
        XCTAssertFalse(MeetingStartMicFallbackPolicy.isBluetoothInput(transportRawValue: "usb"))
        XCTAssertTrue(MeetingStartMicFallbackPolicy.isBluetoothDeviceClass("bluetooth"))
        XCTAssertFalse(MeetingStartMicFallbackPolicy.isBluetoothDeviceClass("built_in"))
    }
}

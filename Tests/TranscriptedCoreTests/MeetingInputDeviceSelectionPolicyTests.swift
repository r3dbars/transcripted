import CoreAudio
import XCTest
@testable import TranscriptedCore

final class MeetingInputDeviceSelectionPolicyTests: XCTestCase {
    func testPrefersBuiltInInputWhenDefaultInputAndOutputAreBluetooth() {
        let airPods = device(
            id: 10,
            name: "Justin's AirPods Pro",
            transport: .bluetooth,
            channels: 1
        )
        let macBookMic = device(
            id: 20,
            name: "MacBook Pro Microphone",
            transport: .builtIn,
            channels: 1
        )

        let selection = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: airPods,
            defaultOutput: airPods,
            availableInputs: [airPods, macBookMic]
        )

        XCTAssertEqual(selection.selectedInput, macBookMic)
        XCTAssertEqual(selection.reason, .preferredBuiltInForBluetoothHeadset)
        XCTAssertTrue(selection.didOverrideDefault)
    }

    func testKeepsDefaultInputWhenOutputIsNotBluetooth() {
        let usbMic = device(id: 10, name: "Scarlett Microphone", transport: .usb, channels: 2)
        let headphones = device(id: 20, name: "External Headphones", transport: .usb, channels: 0)
        let macBookMic = device(id: 30, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)

        let selection = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: usbMic,
            defaultOutput: headphones,
            availableInputs: [usbMic, macBookMic]
        )

        XCTAssertEqual(selection.selectedInput, usbMic)
        XCTAssertEqual(selection.reason, .defaultIsSafe)
        XCTAssertFalse(selection.didOverrideDefault)
    }

    func testKeepsBluetoothInputWhenNoBuiltInFallbackExists() {
        let airPods = device(id: 10, name: "AirPods Pro", transport: .bluetooth, channels: 1)

        let selection = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: airPods,
            defaultOutput: airPods,
            availableInputs: [airPods]
        )

        XCTAssertEqual(selection.selectedInput, airPods)
        XCTAssertEqual(selection.reason, .noBuiltInFallbackAvailable)
        XCTAssertFalse(selection.didOverrideDefault)
    }

    func testRanksMacBookMicrophoneAheadOfOtherBuiltInCandidates() {
        let airPods = device(id: 10, name: "AirPods Pro", transport: .bluetooth, channels: 1)
        let studioDisplayMic = device(
            id: 20,
            name: "Studio Display Microphone",
            transport: .builtIn,
            channels: 1
        )
        let macBookMic = device(
            id: 30,
            name: "MacBook Pro Microphone",
            transport: .builtIn,
            channels: 1
        )

        let selection = MeetingInputDeviceSelectionPolicy.selection(
            defaultInput: airPods,
            defaultOutput: airPods,
            availableInputs: [studioDisplayMic, macBookMic, airPods]
        )

        XCTAssertEqual(selection.selectedInput, macBookMic)
    }

    private func device(
        id: AudioDeviceID,
        name: String,
        transport: MeetingAudioTransport,
        channels: UInt32
    ) -> MeetingAudioDevice {
        MeetingAudioDevice(
            id: id,
            name: name,
            transport: transport,
            inputChannelCount: channels
        )
    }
}

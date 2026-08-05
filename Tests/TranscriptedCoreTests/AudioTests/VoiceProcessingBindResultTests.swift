import CoreAudio
import XCTest
@testable import TranscriptedCore

/// `Audio.armVoiceProcessing(on:)` now returns a `VoiceProcessingBindResult`
/// pairing the physical input device it observed before any wrap with
/// whether VPIO ended up active, instead of callers separately capturing
/// the pre-wrap device ID and re-reading the ambient `voiceProcessingEnabled`
/// cache afterward. `armVoiceProcessing` itself needs a live `AVAudioInputNode`
/// to exercise (out of scope for a headless unit test, matching this
/// directory's existing convention of not constructing real audio engines),
/// so these tests lock in the value type's shape and the invariant that
/// `MeetingInputDeviceSelectionPolicy.routeReadiness` — the exact call site
/// the 1.1.52 field fix touched — behaves identically whether its
/// `boundInputDeviceIDBeforeVoiceProcessing`/`voiceProcessingEnabled`
/// arguments come from a `VoiceProcessingBindResult` or from the two
/// previously-separate reads it replaces.
final class VoiceProcessingBindResultTests: XCTestCase {
    private func device(id: AudioDeviceID, name: String, transport: MeetingAudioTransport, channels: UInt32) -> MeetingAudioDevice {
        MeetingAudioDevice(id: id, name: name, transport: transport, inputChannelCount: channels)
    }

    func testBindResultEqualityReflectsBothFields() {
        let a = Audio.VoiceProcessingBindResult(boundInputDeviceIDBeforeWrap: 10, enabled: true)
        let b = Audio.VoiceProcessingBindResult(boundInputDeviceIDBeforeWrap: 10, enabled: true)
        let differentDevice = Audio.VoiceProcessingBindResult(boundInputDeviceIDBeforeWrap: 20, enabled: true)
        let differentEnabled = Audio.VoiceProcessingBindResult(boundInputDeviceIDBeforeWrap: 10, enabled: false)

        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, differentDevice)
        XCTAssertNotEqual(a, differentEnabled)
    }

    /// Reproduces the exact scenario the 1.1.52 fix targeted (a bound
    /// physical device ID that stays intact through VPIO's wrap) but drives
    /// `routeReadiness` from a `VoiceProcessingBindResult`-shaped pair of
    /// values, the way `makeReadyMeetingInputGraph` now does, instead of two
    /// independently-captured values. The outcome must be `.ready`, matching
    /// the pre-refactor behavior asserted in
    /// `MeetingInputDeviceSelectionPolicyTests`.
    func testRouteReadinessAcceptsBindResultShapedValuesForBoundVoiceProcessedDevice() {
        let builtInMic = device(id: 20, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)
        let selection = MeetingInputDeviceSelection(
            defaultInput: builtInMic,
            selectedInput: builtInMic,
            defaultOutput: nil,
            reason: .defaultIsSafe
        )

        // Stand-in for what `armVoiceProcessing(on:)` would have returned:
        // the physical device it bound before VPIO wrapped the node, and
        // that VPIO ended up enabled.
        let bindResult = Audio.VoiceProcessingBindResult(
            boundInputDeviceIDBeforeWrap: builtInMic.id,
            enabled: true
        )

        // Once VPIO wraps the node, `actualInputDeviceID` may no longer be
        // the physical device (private aggregate wrapper) — routeReadiness
        // must not re-derive identity from it when voiceProcessingEnabled.
        let postWrapDeviceID: AudioDeviceID = 999

        XCTAssertEqual(
            MeetingInputDeviceSelectionPolicy.routeReadiness(
                selection: selection,
                boundInputDeviceIDBeforeVoiceProcessing: bindResult.boundInputDeviceIDBeforeWrap,
                actualInputDeviceID: postWrapDeviceID,
                capturedSampleRate: 48_000,
                selectedNominalSampleRate: 48_000,
                voiceProcessingEnabled: bindResult.enabled
            ),
            .ready
        )
    }

    /// The mirror-image failure case: if the physical device bound before
    /// the wrap does NOT match the selected microphone, routeReadiness must
    /// still reject it — a bind result carrying the wrong pre-wrap ID must
    /// not be masked by `enabled` being true.
    func testRouteReadinessRejectsBindResultWithMismatchedPreWrapDevice() {
        let builtInMic = device(id: 20, name: "MacBook Pro Microphone", transport: .builtIn, channels: 1)
        let wrongMic = device(id: 30, name: "USB Microphone", transport: .usb, channels: 1)
        let selection = MeetingInputDeviceSelection(
            defaultInput: builtInMic,
            selectedInput: builtInMic,
            defaultOutput: nil,
            reason: .defaultIsSafe
        )

        let bindResult = Audio.VoiceProcessingBindResult(
            boundInputDeviceIDBeforeWrap: wrongMic.id,
            enabled: true
        )

        XCTAssertEqual(
            MeetingInputDeviceSelectionPolicy.routeReadiness(
                selection: selection,
                boundInputDeviceIDBeforeVoiceProcessing: bindResult.boundInputDeviceIDBeforeWrap,
                actualInputDeviceID: 999,
                capturedSampleRate: 48_000,
                selectedNominalSampleRate: 48_000,
                voiceProcessingEnabled: bindResult.enabled
            ),
            .deviceMismatch
        )
    }
}

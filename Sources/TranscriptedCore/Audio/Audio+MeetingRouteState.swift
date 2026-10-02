import Foundation
import QuartzCore
@preconcurrency import AVFoundation
import CoreAudio
import Combine
import Synchronization

// Meeting input route state: selection mode, picked mic, the last
// selection, and the one bounded route-stabilization attempt.
extension Audio {
    /// The host's microphone preference for the next recording. Set before
    /// `start()`. The active recording retains its start-time mode through
    /// recovery; changing this property only affects the next recording.
    /// Preserving the macOS input still permits the existing bounded built-in
    /// fallback after an actual Bluetooth route failure.
    public var meetingInputDeviceSelectionMode: MeetingInputDeviceSelectionMode {
        get {
            meetingRouteStateLock.lock()
            defer { meetingRouteStateLock.unlock() }
            return _meetingInputDeviceSelectionMode
        }
        set {
            meetingRouteStateLock.lock()
            _meetingInputDeviceSelectionMode = newValue
            meetingRouteStateLock.unlock()
        }
    }

    var meetingInputDeviceSelectionModeForCurrentRecording: MeetingInputDeviceSelectionMode {
        meetingRouteStateLock.lock()
        defer { meetingRouteStateLock.unlock() }
        return _activeMeetingInputDeviceSelectionMode
    }

    /// A specific mic (Core Audio UID) the host wants the next recording to
    /// use instead of the macOS input, or nil for the automatic pick. Set
    /// before `start()`; like the mode, the active recording keeps its
    /// start-time value through recovery. Only `.automatic` mode honors it,
    /// and never for a Bluetooth headset or a closed MacBook's own mic. While
    /// that mic is missing, automatic selection runs as usual.
    public var meetingPreferredInputDeviceUID: String? {
        get {
            meetingRouteStateLock.lock()
            defer { meetingRouteStateLock.unlock() }
            return _meetingPreferredInputDeviceUID
        }
        set {
            meetingRouteStateLock.lock()
            _meetingPreferredInputDeviceUID = newValue
            meetingRouteStateLock.unlock()
        }
    }

    var meetingPreferredInputDeviceUIDForCurrentRecording: String? {
        meetingRouteStateLock.lock()
        defer { meetingRouteStateLock.unlock() }
        return _activeMeetingPreferredInputDeviceUID
    }

    /// Stops honoring the picked mic for the rest of this recording. The
    /// start retry calls it after a first attempt on the picked mic failed,
    /// so a connected mic that won't start falls back to the automatic
    /// choice instead of failing the meeting. Returns whether a pick was
    /// dropped.
    func dropMeetingPreferredInputDeviceForCurrentRecording() -> Bool {
        meetingRouteStateLock.lock()
        defer { meetingRouteStateLock.unlock() }
        guard _activeMeetingPreferredInputDeviceUID != nil else { return false }
        _activeMeetingPreferredInputDeviceUID = nil
        return true
    }

    /// The selection the last graph attempt tried to bind, kept even when
    /// binding failed and the selection itself was never stored.
    func recordAttemptedMeetingSelectionReason(_ reason: MeetingInputDeviceSelectionReason) {
        meetingRouteStateLock.lock()
        _lastAttemptedMeetingSelectionReason = reason
        meetingRouteStateLock.unlock()
    }

    var lastAttemptedMeetingSelectionReason: MeetingInputDeviceSelectionReason? {
        meetingRouteStateLock.lock()
        defer { meetingRouteStateLock.unlock() }
        return _lastAttemptedMeetingSelectionReason
    }

    var meetingInputSelectionReasonValue: String {
        meetingRouteStateLock.lock()
        defer { meetingRouteStateLock.unlock() }
        return _meetingInputSelection?.reason.rawValue ?? "unavailable"
    }

    var meetingRouteStabilizationAttemptBucket: String {
        meetingRouteStateLock.lock()
        defer { meetingRouteStateLock.unlock() }
        switch _meetingRouteStabilizationAttemptCount {
        case 0: return "0"
        case 1: return "1"
        case 2...3: return "2_3"
        case 4...9: return "4_9"
        default: return "10_plus"
        }
    }

    var meetingRouteStabilizationOutcomeValue: String {
        meetingRouteStateLock.lock()
        defer { meetingRouteStateLock.unlock() }
        return _meetingRouteStabilizationOutcome.rawValue
    }

    var meetingRouteStabilityWarningEmitted: Bool {
        meetingRouteStateLock.lock()
        defer { meetingRouteStateLock.unlock() }
        return _meetingRouteStabilityWarningEmitted
    }

    func meetingInputIsBluetooth() -> Bool {
        meetingRouteStateLock.lock()
        defer { meetingRouteStateLock.unlock() }
        guard let selection = _meetingInputSelection else { return false }
        return selection.selectedInput.transport == .bluetooth
            || selection.selectedInput.transport == .bluetoothLE
    }

    func meetingInputSelectionSnapshot() -> MeetingInputDeviceSelection? {
        meetingRouteStateLock.lock()
        defer { meetingRouteStateLock.unlock() }
        return _meetingInputSelection
    }

    func setMeetingInputSelection(_ selection: MeetingInputDeviceSelection) {
        meetingRouteStateLock.lock()
        _meetingInputSelection = selection
        meetingRouteStateLock.unlock()
    }

    func recordMeetingRouteStabilizationAttempt(
        outcome: CaptureRouteStabilizationOutcome
    ) {
        meetingRouteStateLock.lock()
        _meetingRouteStabilizationAttemptCount += 1
        _meetingRouteStabilizationOutcome = outcome
        meetingRouteStateLock.unlock()
    }

    func setMeetingRouteStabilizationOutcome(
        _ outcome: CaptureRouteStabilizationOutcome
    ) {
        meetingRouteStateLock.lock()
        _meetingRouteStabilizationOutcome = outcome
        meetingRouteStateLock.unlock()
    }

    func resetMeetingRouteState(forNewRecording: Bool = false) {
        meetingRouteStateLock.lock()
        if forNewRecording {
            _activeMeetingInputDeviceSelectionMode = _meetingInputDeviceSelectionMode
            _activeMeetingPreferredInputDeviceUID = _meetingPreferredInputDeviceUID
        }
        _meetingInputSelection = nil
        _lastAttemptedMeetingSelectionReason = nil
        _meetingRouteStabilizationAttemptCount = 0
        _meetingRouteStabilizationOutcome = .notNeeded
        _meetingRouteStabilityWarningEmitted = false
        meetingRouteStateLock.unlock()
    }

    func emitMeetingRouteStabilityWarningIfNeeded(
        outcome: CaptureRouteStabilizationOutcome
    ) {
        guard outcome != .notNeeded else { return }

        meetingRouteStateLock.lock()
        guard !_meetingRouteStabilityWarningEmitted else {
            meetingRouteStateLock.unlock()
            return
        }
        _meetingRouteStabilityWarningEmitted = true
        meetingRouteStateLock.unlock()

        onCaptureLifecycleCue?(.meetingRouteStabilityWarning(outcome))
    }
}

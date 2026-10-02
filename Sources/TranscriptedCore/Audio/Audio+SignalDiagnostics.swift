import Foundation
import QuartzCore
@preconcurrency import AVFoundation
import CoreAudio
import Combine
import Synchronization

// Per-recording amplitude diagnostics (issue #500) and recording-start
// route volume diagnostics. Amplitude only; never text or raw audio.
extension Audio {
    public var systemAudioFinalizationFailed: Bool {
        signalDiagnosticsLock.lock()
        let finishing = finishingSystemSignalAttempt
        signalDiagnosticsLock.unlock()
        guard let finishing else { return false }
        return finishing.hasFinalizationFailure
    }
    /// Evidence scoped to this recording, not a TCC permission determination.
    public var hasObservedSystemAudioSignal: Bool {
        signalDiagnosticsLock.lock()
        let peak = _systemAudioPeak
        let finishing = finishingSystemSignalAttempt
        signalDiagnosticsLock.unlock()
        return (peak.isFinite && peak > 0) || finishing?.hasObservedSignal == true
    }

    struct MicSignalIntervalDiagnostics {
        let rawPeak: Float
        let processedPeak: Float
        let minAppliedGain: Float?
        let agcMaxGain: Float?
        let sawBuffer: Bool
    }

    var signalDiagnosticsSnapshot: AudioSignalDiagnosticsSnapshot {
        signalDiagnosticsLock.lock()
        defer { signalDiagnosticsLock.unlock() }
        return AudioSignalDiagnosticsSnapshot(
            micRawPeak: _micRawPeak,
            micProcessedPeak: _micProcessedPeak,
            systemAudioPeak: _systemAudioPeak
        )
    }

    func resetSignalDiagnostics() {
        signalDiagnosticsLock.lock()
        defer { signalDiagnosticsLock.unlock() }
        _micRawPeak = 0
        _micProcessedPeak = 0
        _systemAudioPeak = 0
        finishingSystemSignalAttempt = nil
        _intervalMicRawPeak = 0
        _intervalMicProcessedPeak = 0
        _intervalMinAppliedGain = nil
        _intervalAGCMaxGain = nil
        _intervalSawMicBuffer = false
    }

    func recordMicSignalPeaks(raw: Float, processed: Float, appliedGain: Float?, agcMaxGain: Float?) {
        signalDiagnosticsLock.lock()
        defer { signalDiagnosticsLock.unlock() }
        _micRawPeak = max(_micRawPeak, raw)
        _micProcessedPeak = max(_micProcessedPeak, processed)
        _intervalMicRawPeak = max(_intervalMicRawPeak, raw)
        _intervalMicProcessedPeak = max(_intervalMicProcessedPeak, processed)
        if let appliedGain {
            _intervalMinAppliedGain = min(_intervalMinAppliedGain ?? .infinity, appliedGain)
            _intervalAGCMaxGain = agcMaxGain
        }
        _intervalSawMicBuffer = true
    }

    /// Read-and-zero the interval-scoped mic facts. Called only from the
    /// 0.2s recording timer so each tick sees exactly one interval.
    func drainMicSignalIntervalDiagnostics() -> MicSignalIntervalDiagnostics {
        signalDiagnosticsLock.lock()
        defer { signalDiagnosticsLock.unlock() }
        let interval = MicSignalIntervalDiagnostics(
            rawPeak: _intervalMicRawPeak,
            processedPeak: _intervalMicProcessedPeak,
            minAppliedGain: _intervalMinAppliedGain,
            agcMaxGain: _intervalAGCMaxGain,
            sawBuffer: _intervalSawMicBuffer
        )
        _intervalMicRawPeak = 0
        _intervalMicProcessedPeak = 0
        _intervalMinAppliedGain = nil
        _intervalAGCMaxGain = nil
        _intervalSawMicBuffer = false
        return interval
    }

    func recordSystemSignalPeak(_ peak: Float) {
        guard peak.isFinite else { return }
        signalDiagnosticsLock.lock()
        defer { signalDiagnosticsLock.unlock() }
        _systemAudioPeak = max(_systemAudioPeak, peak)
    }

    var recordingStartRouteVolumeSnapshot: AudioRouteVolumeSnapshot? {
        get {
            routeVolumeDiagnosticsLock.lock()
            defer { routeVolumeDiagnosticsLock.unlock() }
            return _recordingStartRouteVolumeSnapshot
        }
        set {
            routeVolumeDiagnosticsLock.lock()
            defer { routeVolumeDiagnosticsLock.unlock() }
            _recordingStartRouteVolumeSnapshot = newValue
        }
    }

    var recordingStartCapturedInputDeviceID: AudioDeviceID? {
        routeVolumeDiagnosticsLock.lock()
        defer { routeVolumeDiagnosticsLock.unlock() }
        return _recordingStartCapturedInputDeviceID
    }

    func recordRecordingStartCapturedInput(deviceID: AudioDeviceID?) {
        let volume = AudioRouteVolumeSnapshot.inputVolumeString(for: deviceID)
        let validDeviceID = deviceID?.isValid == true ? deviceID : nil

        routeVolumeDiagnosticsLock.lock()
        defer { routeVolumeDiagnosticsLock.unlock() }
        _recordingStartCapturedInputDeviceID = validDeviceID
        _recordingStartCapturedInputVolume = volume
    }

    func resetRecordingStartCapturedInput() {
        routeVolumeDiagnosticsLock.lock()
        defer { routeVolumeDiagnosticsLock.unlock() }
        _recordingStartCapturedInputDeviceID = nil
        _recordingStartCapturedInputVolume = "unavailable"
    }

    func recordingStartCapturedInputVolume(matching deviceID: AudioDeviceID?) -> String {
        guard let deviceID, deviceID.isValid else { return "unavailable" }

        routeVolumeDiagnosticsLock.lock()
        defer { routeVolumeDiagnosticsLock.unlock() }
        guard _recordingStartCapturedInputDeviceID == deviceID else { return "unavailable" }
        return _recordingStartCapturedInputVolume
    }
}

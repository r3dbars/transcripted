import Foundation
@preconcurrency import AVFoundation
import CoreAudio

/// Wiring for the off-by-default capture telemetry. Every call runs on
/// `queue`; nothing here touches the IOProc.
extension CoreAudioSystemAudioCapture {
    func startTelemetry(aggregate: AudioObjectID) {
        guard telemetryEnabled else { return }
        signalTelemetry = CaptureSignalTelemetry()
        AppLogger.audioSystem.info("Capture telemetry on")
        guard hardwareHooks == nil, deviceTelemetry == nil else { return }
        let observer = CaptureDeviceTelemetryObserver()
        observer.start(aggregate: aggregate)
        deviceTelemetry = observer
    }

    func recordTelemetry(_ buffer: AVAudioPCMBuffer, at now: TimeInterval, hostSeconds: TimeInterval?) {
        guard let fields = signalTelemetry?.record(buffer, arrival: now, hostSeconds: hostSeconds) else { return }
        logTelemetryWindow(fields)
    }

    /// Closes a window with no buffers too, so a stalled tap logs `buffers: 0`.
    func tickTelemetry(at now: TimeInterval) {
        guard let fields = signalTelemetry?.flushIfDue(at: now) else { return }
        logTelemetryWindow(fields)
    }

    func stopTelemetry() {
        signalTelemetry = nil
        deviceTelemetry?.stop()
        deviceTelemetry = nil
    }

    var captureTelemetryWindowCount: Int { signalTelemetry?.emittedWindows ?? 0 }

    private func logTelemetryWindow(_ fields: [String: String]) {
        var fields = fields
        fields["watch"] = silenceWatch == nil ? "off" : "on"
        fields["unheard"] = "\(isNotHearingPlayback)"
        AppLogger.audioSystem.info("System capture window", fields)
    }
}

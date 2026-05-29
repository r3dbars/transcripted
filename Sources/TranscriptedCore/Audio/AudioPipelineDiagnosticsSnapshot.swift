import CoreAudio
import Foundation
@preconcurrency import AVFoundation

/// Privacy-safe audio pipeline facts used for PostHog and Sentry diagnostics.
/// Never includes device names, UIDs, file paths, app names, transcript text, or raw audio.
struct AudioSignalDiagnosticsSnapshot: Equatable, Sendable {
    let micRawPeak: Float
    let micProcessedPeak: Float
    let systemAudioPeak: Float

    var micRawPeakString: String { Self.peakString(micRawPeak) }
    var micProcessedPeakString: String { Self.peakString(micProcessedPeak) }
    var systemAudioPeakString: String { Self.peakString(systemAudioPeak) }

    private static func peakString(_ value: Float) -> String {
        guard value.isFinite else { return "0.00000" }
        return String(format: "%.5f", max(0, min(1, value)))
    }
}

struct AudioRouteVolumeSnapshot: Equatable, Sendable {
    let defaultInputVolume: String
    let defaultOutputVolume: String
    let defaultSystemOutputVolume: String

    static let unavailable = AudioRouteVolumeSnapshot(
        defaultInputVolume: "unavailable",
        defaultOutputVolume: "unavailable",
        defaultSystemOutputVolume: "unavailable"
    )

    static func captureDefaultRoute() -> AudioRouteVolumeSnapshot {
        let inputDevice = try? AudioObjectID.readDefaultInputDevice()
        let outputDevice = try? AudioObjectID.readDefaultOutputDevice()
        let systemOutputDevice = try? AudioObjectID.readDefaultSystemOutputDevice()

        return AudioRouteVolumeSnapshot(
            defaultInputVolume: volumeString(for: inputDevice, scope: kAudioDevicePropertyScopeInput),
            defaultOutputVolume: volumeString(for: outputDevice, scope: kAudioDevicePropertyScopeOutput),
            defaultSystemOutputVolume: volumeString(for: systemOutputDevice, scope: kAudioDevicePropertyScopeOutput)
        )
    }

    func context(suffix: String) -> [String: String] {
        [
            "default_input_volume_\(suffix)": defaultInputVolume,
            "default_output_volume_\(suffix)": defaultOutputVolume,
            "default_system_output_volume_\(suffix)": defaultSystemOutputVolume,
        ]
    }

    /// Read-only input volume scalar for a specific captured device. Meetings
    /// can capture from a device other than the default input (the input
    /// policy overrides a Bluetooth headset to the built-in mic), so issue #500
    /// scalar-drop detection has to look at the device we actually record from,
    /// not just the system default. Never writes or adjusts volume.
    static func inputVolumeString(for deviceID: AudioDeviceID?) -> String {
        volumeString(for: deviceID, scope: kAudioDevicePropertyScopeInput)
    }

    private static func volumeString(
        for deviceID: AudioDeviceID?,
        scope: AudioObjectPropertyScope
    ) -> String {
        guard let deviceID, deviceID.isValid,
              let value = try? deviceID.readVolumeScalar(scope: scope),
              value.isFinite else {
            return "unavailable"
        }
        return String(format: "%.3f", max(0, min(1, value)))
    }
}

public struct AudioPipelineDiagnosticsSnapshot: Equatable, Sendable {
    public let inputDeviceClass: String
    public let outputDeviceClass: String
    public let systemOutputDeviceClass: String
    public let inputRateHz: String
    public let outputRateHz: String
    public let systemOutputRateHz: String
    public let systemRateHz: String
    public let inputChannels: String
    public let systemChannels: String
    public let systemBackend: String
    public let systemStatus: String
    public let bufferSuccessBucket: String
    public let gapCount: Int
    public let routeChangeCount: Int
    public let recoveryAttemptCount: Int
    public let micRecovering: Bool
    public let systemFailed: Bool
    public let voiceProcessingRequested: Bool
    public let voiceProcessingActive: Bool
    public let realtimeAGCActive: Bool
    public let micRawPeak: String
    public let micProcessedPeak: String
    public let systemAudioPeak: String
    public let defaultInputVolumeBefore: String
    public let defaultOutputVolumeBefore: String
    public let defaultSystemOutputVolumeBefore: String
    public let defaultInputVolumeDuring: String
    public let defaultOutputVolumeDuring: String
    public let defaultSystemOutputVolumeDuring: String
    // Input volume scalar read from the device meetings actually capture from
    // (which can differ from the default input device). Lets issue #500
    // scalar-drop detection stay correct when the meeting input policy
    // overrides a Bluetooth headset to the built-in mic.
    public let capturedInputVolumeDuring: String

    public var privacySafeContext: [String: String] {
        [
            "buffer_success_bucket": bufferSuccessBucket,
            "captured_input_volume_during": capturedInputVolumeDuring,
            "default_input_volume_before": defaultInputVolumeBefore,
            "default_input_volume_during": defaultInputVolumeDuring,
            "default_output_volume_before": defaultOutputVolumeBefore,
            "default_output_volume_during": defaultOutputVolumeDuring,
            "default_system_output_volume_before": defaultSystemOutputVolumeBefore,
            "default_system_output_volume_during": defaultSystemOutputVolumeDuring,
            "gap_count": "\(gapCount)",
            "input_channels": inputChannels,
            "input_device_class": inputDeviceClass,
            "input_rate_hz": inputRateHz,
            "mic_processing": voiceProcessingRequested ? "apple_voice_processing" : "software_agc",
            "mic_processed_peak": micProcessedPeak,
            "mic_raw_peak": micRawPeak,
            "mic_recovering": boolString(micRecovering),
            "output_device_class": outputDeviceClass,
            "output_rate_hz": outputRateHz,
            "realtime_agc": boolString(realtimeAGCActive),
            "recovery_attempt_count": "\(recoveryAttemptCount)",
            "route_change_count": "\(routeChangeCount)",
            "system_backend": systemBackend,
            "system_channels": systemChannels,
            "system_peak": systemAudioPeak,
            "system_failed": boolString(systemFailed),
            "system_output_device_class": systemOutputDeviceClass,
            "system_output_rate_hz": systemOutputRateHz,
            "system_rate_hz": systemRateHz,
            "system_status": systemStatus,
            "voice_processing": boolString(voiceProcessingRequested),
            "voice_processing_active": boolString(voiceProcessingActive),
        ]
    }

    private func boolString(_ value: Bool) -> String {
        value ? "true" : "false"
    }
}

extension Audio {
    public func createPipelineDiagnosticsSnapshot(
        overrideSystemAudioStatus: SystemAudioStatus? = nil
    ) -> AudioPipelineDiagnosticsSnapshot {
        let inputDevice = try? AudioObjectID.readDefaultInputDevice()
        let outputDevice = try? AudioObjectID.readDefaultOutputDevice()
        let systemOutputDevice = try? AudioObjectID.readDefaultSystemOutputDevice()
        let actualInputDevice = currentInputDeviceID() ?? inputDevice
        let inputFormat = currentInputFormatSnapshot()
        let systemFormat = systemAudioCapture?.audioFormat
        let signalSnapshot = signalDiagnosticsSnapshot
        let routeVolumeBefore = recordingStartRouteVolumeSnapshot ?? .unavailable
        let routeVolumeDuring = AudioRouteVolumeSnapshot.captureDefaultRoute()

        return AudioPipelineDiagnosticsSnapshot(
            inputDeviceClass: Self.deviceClass(for: actualInputDevice),
            outputDeviceClass: Self.deviceClass(for: outputDevice),
            systemOutputDeviceClass: Self.deviceClass(for: systemOutputDevice),
            inputRateHz: Self.rateString(inputFormat?.sampleRate ?? Self.nominalRate(for: actualInputDevice)),
            outputRateHz: Self.rateString(Self.nominalRate(for: outputDevice)),
            systemOutputRateHz: Self.rateString(Self.nominalRate(for: systemOutputDevice)),
            systemRateHz: Self.rateString(systemFormat?.sampleRate),
            inputChannels: Self.channelString(inputFormat?.channelCount),
            systemChannels: Self.channelString(systemFormat?.channelCount),
            systemBackend: systemAudioCapture?.diagnosticBackendName ?? "none",
            systemStatus: Self.statusName(overrideSystemAudioStatus ?? systemAudioStatus),
            bufferSuccessBucket: Self.successRateBucket(systemAudioCapture?.bufferSuccessRate),
            gapCount: recordingGaps.count,
            routeChangeCount: deviceSwitchCount,
            recoveryAttemptCount: recoveryAttemptCount,
            micRecovering: isMicRecovering,
            systemFailed: systemAudioFailed,
            voiceProcessingRequested: enableVoiceProcessing,
            voiceProcessingActive: voiceProcessingEnabled,
            realtimeAGCActive: realtimeAGC != nil,
            micRawPeak: signalSnapshot.micRawPeakString,
            micProcessedPeak: signalSnapshot.micProcessedPeakString,
            systemAudioPeak: signalSnapshot.systemAudioPeakString,
            defaultInputVolumeBefore: routeVolumeBefore.defaultInputVolume,
            defaultOutputVolumeBefore: routeVolumeBefore.defaultOutputVolume,
            defaultSystemOutputVolumeBefore: routeVolumeBefore.defaultSystemOutputVolume,
            defaultInputVolumeDuring: routeVolumeDuring.defaultInputVolume,
            defaultOutputVolumeDuring: routeVolumeDuring.defaultOutputVolume,
            defaultSystemOutputVolumeDuring: routeVolumeDuring.defaultSystemOutputVolume,
            capturedInputVolumeDuring: AudioRouteVolumeSnapshot.inputVolumeString(for: actualInputDevice)
        )
    }

    public func createRouteVolumeDiagnosticsContext(currentPhase: String) -> [String: String] {
        let before = recordingStartRouteVolumeSnapshot ?? .unavailable
        let current = AudioRouteVolumeSnapshot.captureDefaultRoute()
        return before.context(suffix: "before").merging(
            current.context(suffix: currentPhase),
            uniquingKeysWith: { _, new in new }
        )
    }

    private func currentInputFormatSnapshot() -> AudioRecordingFormatSnapshot? {
        withAudioGraphLock {
            guard let inputNode else { return nil }
            return AudioRecordingFormatPolicy.snapshot(recordingFormat(for: inputNode))
        }
    }

    private func currentInputDeviceID() -> AudioDeviceID? {
        withAudioGraphLock {
            guard let inputNode else { return nil }
            let deviceID = inputNode.auAudioUnit.deviceID
            return deviceID.isValid ? deviceID : nil
        }
    }

    private static func nominalRate(for deviceID: AudioDeviceID?) -> Double? {
        guard let deviceID, deviceID.isValid else { return nil }
        return try? deviceID.readNominalSampleRate()
    }

    private static func deviceClass(for deviceID: AudioDeviceID?) -> String {
        guard let deviceID, deviceID.isValid else { return "unknown" }
        let transport = (try? deviceID.readTransportType()) ?? UInt32(kAudioDeviceTransportTypeUnknown)

        switch transport {
        case UInt32(kAudioDeviceTransportTypeBuiltIn):
            return "built_in"
        case UInt32(kAudioDeviceTransportTypeBluetooth),
             UInt32(kAudioDeviceTransportTypeBluetoothLE):
            return "bluetooth"
        case UInt32(kAudioDeviceTransportTypeUSB):
            return "usb"
        case UInt32(kAudioDeviceTransportTypeHDMI):
            return "hdmi"
        case UInt32(kAudioDeviceTransportTypeDisplayPort):
            return "display_port"
        case UInt32(kAudioDeviceTransportTypeAirPlay):
            return "airplay"
        case UInt32(kAudioDeviceTransportTypeAggregate),
             UInt32(kAudioDeviceTransportTypeAutoAggregate):
            return "aggregate"
        case UInt32(kAudioDeviceTransportTypeVirtual):
            return "virtual"
        case UInt32(kAudioDeviceTransportTypePCI):
            return "pci"
        case UInt32(kAudioDeviceTransportTypeFireWire):
            return "firewire"
        case UInt32(kAudioDeviceTransportTypeThunderbolt):
            return "thunderbolt"
        case UInt32(kAudioDeviceTransportTypeAVB):
            return "avb"
        default:
            return "other"
        }
    }

    private static func rateString(_ rate: Double?) -> String {
        guard let rate, rate.isFinite, rate > 0 else { return "unknown" }
        return "\(Int(rate.rounded()))"
    }

    private static func channelString(_ count: AVAudioChannelCount?) -> String {
        guard let count, count > 0 else { return "unknown" }
        return "\(count)"
    }

    private static func successRateBucket(_ rate: Double?) -> String {
        guard let rate, rate.isFinite else { return "unknown" }
        switch rate {
        case 0.98...:
            return "98_100"
        case 0.90..<0.98:
            return "90_97"
        case 0.80..<0.90:
            return "80_89"
        case 0.50..<0.80:
            return "50_79"
        default:
            return "lt_50"
        }
    }

    private static func statusName(_ status: SystemAudioStatus) -> String {
        switch status {
        case .unknown:
            return "unknown"
        case .healthy:
            return "healthy"
        case .reconnecting:
            return "reconnecting"
        case .silent:
            return "silent"
        case .failed:
            return "failed"
        }
    }
}

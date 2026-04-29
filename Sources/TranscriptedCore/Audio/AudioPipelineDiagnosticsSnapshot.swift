import CoreAudio
import Foundation
@preconcurrency import AVFoundation

/// Privacy-safe audio pipeline facts used for PostHog and Sentry diagnostics.
/// Never includes device names, UIDs, file paths, app names, transcript text, or raw audio.
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

    public var privacySafeContext: [String: String] {
        [
            "buffer_success_bucket": bufferSuccessBucket,
            "gap_count": "\(gapCount)",
            "input_channels": inputChannels,
            "input_device_class": inputDeviceClass,
            "input_rate_hz": inputRateHz,
            "mic_processing": voiceProcessingRequested ? "apple_voice_processing" : "software_agc",
            "mic_recovering": boolString(micRecovering),
            "output_device_class": outputDeviceClass,
            "output_rate_hz": outputRateHz,
            "realtime_agc": boolString(realtimeAGCActive),
            "recovery_attempt_count": "\(recoveryAttemptCount)",
            "route_change_count": "\(routeChangeCount)",
            "system_backend": systemBackend,
            "system_channels": systemChannels,
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
        let inputFormat = currentInputFormatSnapshot()
        let systemFormat = systemAudioCapture?.audioFormat

        return AudioPipelineDiagnosticsSnapshot(
            inputDeviceClass: Self.deviceClass(for: inputDevice),
            outputDeviceClass: Self.deviceClass(for: outputDevice),
            systemOutputDeviceClass: Self.deviceClass(for: systemOutputDevice),
            inputRateHz: Self.rateString(inputFormat?.sampleRate ?? Self.nominalRate(for: inputDevice)),
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
            realtimeAGCActive: realtimeAGC != nil
        )
    }

    private func currentInputFormatSnapshot() -> AudioRecordingFormatSnapshot? {
        withAudioGraphLock {
            guard let inputNode else { return nil }
            return AudioRecordingFormatPolicy.snapshot(recordingFormat(for: inputNode))
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

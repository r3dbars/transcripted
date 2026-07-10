import AVFoundation
import Foundation

enum ParakeetPrewarmLevel: Equatable {
    case info
    case warning
}

enum ParakeetPrewarmDecision: Equatable {
    case proceed
    case skip(level: ParakeetPrewarmLevel, event: String, message: String, context: [String: String])
}

enum ParakeetPrewarmPolicy {
    static func shouldDeferHardwarePrewarm(for selection: DictationInputDeviceSelection?) -> Bool {
        selection?.didOverrideDefault == true
            && selection?.reason == .preferredBuiltInForBluetoothHeadset
    }

    static func shouldDeferHardwareRecovery(
        for selection: DictationInputDeviceSelection?,
        wasRecording: Bool
    ) -> Bool {
        !wasRecording && shouldDeferHardwarePrewarm(for: selection)
    }

    static func decision(for microphoneStatus: AVAuthorizationStatus) -> ParakeetPrewarmDecision {
        switch microphoneStatus {
        case .authorized:
            return .proceed
        case .notDetermined:
            return .skip(
                level: .info,
                event: "prewarm_permission_pending",
                message: "Skipping speech engine prewarm until microphone permission is decided",
                context: ["mic_status": microphoneStatus.diagnosticName]
            )
        case .denied, .restricted:
            return .skip(
                level: .warning,
                event: "prewarm_permission_unavailable",
                message: "Skipping speech engine prewarm because microphone permission is unavailable",
                context: ["mic_status": microphoneStatus.diagnosticName]
            )
        @unknown default:
            return .skip(
                level: .warning,
                event: "prewarm_permission_unavailable",
                message: "Skipping speech engine prewarm because microphone permission is unavailable",
                context: ["mic_status": "unknown"]
            )
        }
    }
}

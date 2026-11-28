import Foundation
import TranscriptedCore

/// Start-deadline decisions for `MeetingCaptureBridge`. Kept out of the
/// bridge so the Bluetooth-unready keep-alive does not grow that file.
enum MeetingCaptureStartTimeout {
    static func shouldKeepRecording(
        isRecording: Bool,
        micStreaming: Bool,
        systemStreaming: Bool,
        inputDeviceClass: String,
        requiresSystemAudio: Bool
    ) -> Bool {
        MeetingStartMicFallbackPolicy.shouldAdmitSystemAudioFirst(
            isRecording: isRecording,
            micStreaming: micStreaming,
            systemStreaming: systemStreaming,
            selectedInputIsBluetooth: MeetingStartMicFallbackPolicy.isBluetoothDeviceClass(
                inputDeviceClass
            ),
            requiresSystemAudio: requiresSystemAudio
        )
    }

    static func failureMessage(
        bridgeError: String?,
        audioError: String?,
        microphoneGranted: Bool?,
        explicitMicrophoneDenial: Bool,
        explicitSystemAudioDenial: Bool,
        micAudioStreaming: Bool,
        systemAudioStreaming: Bool,
        requiresSystemAudio: Bool
    ) -> String {
        let existing = [bridgeError, audioError]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        if let existing, MeetingStartFailureClassifier.kind(
            from: existing,
            microphoneGranted: microphoneGranted,
            explicitMicrophoneDenial: explicitMicrophoneDenial
        ) == "permission_missing" {
            return existing
        }
        if explicitMicrophoneDenial {
            return existing ?? "Turn on Microphone access in System Settings before recording a meeting."
        }
        if explicitSystemAudioDenial {
            return existing ?? "Turn on System Audio Recording before recording a meeting."
        }
        return AudioCaptureStartState.timeoutFailureMessage(
            existingErrorMessage: existing,
            micAudioStreaming: micAudioStreaming,
            systemAudioStreaming: systemAudioStreaming,
            requiresSystemAudio: requiresSystemAudio
        )
    }
}

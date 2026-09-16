import Foundation

/// A settled stop is not proof that its recovery WAV was written successfully.
/// While finalization is still active, only an existing WAV permits the
/// preserving-cancel fallback. Once inactive, retained native audio without a
/// WAV still blocks Quit; a completed save or explicit discard has neither.
enum DictationTerminationAdmissionPolicy {
    static func mustStopBeforeInference(snapshotAvailable: Bool, hasRecoverableRecording: Bool) -> Bool {
        !snapshotAvailable && hasRecoverableRecording
    }

    static func blocksNewCapture(hasRecoverableRecording: Bool, recoveryWAVExists: Bool) -> Bool {
        hasRecoverableRecording && !recoveryWAVExists
    }

    static func canTerminate(
        isDictating: Bool,
        checkpointSettled: Bool,
        hasRecoverableRecording: Bool,
        recoveryWAVExists: Bool
    ) -> Bool {
        if isDictating {
            return checkpointSettled && recoveryWAVExists
        }
        return recoveryWAVExists || !hasRecoverableRecording
    }

    static func canRetrySaving(
        isDictating: Bool,
        checkpointSettled: Bool,
        hasRecoverableRecording: Bool,
        recoveryWAVExists: Bool,
        isCurrentSession: Bool,
        hasPendingStart: Bool
    ) -> Bool {
        !isDictating && checkpointSettled && hasRecoverableRecording
            && !recoveryWAVExists && isCurrentSession && !hasPendingStart
    }
}

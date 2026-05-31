// DictationReadinessWaitPolicy.swift
// Small policy for deciding how dictation should react while waiting for
// Parakeet input readiness.

import Foundation

enum DictationReadinessWaitAction: Equatable {
    case waitForRecovery
    case refreshInputReadiness
    case forceInputRecovery
    case startRecording
    case startRecoveryRecording
}

struct DictationReadinessWaitPolicy {
    private static let refreshesBeforeRecoveryStart = 4
    private static let maxRecoveryStartAttempts = 2
    private static let maxRecordingStartAttempts = 3

    static func recordingStartAttemptsExhausted(
        inputFormatReady: Bool,
        recordingStartAttempts: Int,
        maxAttempts: Int = maxRecordingStartAttempts
    ) -> Bool {
        guard inputFormatReady, maxAttempts > 0 else { return false }
        return recordingStartAttempts >= maxAttempts
    }

    static func action(
        isRecovering: Bool,
        inputFormatReady: Bool,
        recordingStartAttempts: Int = 0,
        readinessRefreshes: Int = 0,
        forcedRecoveryAttempts: Int = 0,
        forcedRecoveryRefreshThreshold: Int = TranscriptedConstants.dictationReadinessForcedRecoveryRefreshes,
        maxForcedRecoveryAttempts: Int = TranscriptedConstants.dictationReadinessForcedRecoveryAttempts,
        recoveryStartAttempts: Int = 0,
        readinessRefreshTimedOut: Bool = false
    ) -> DictationReadinessWaitAction {
        if isRecovering {
            return .waitForRecovery
        }

        let shouldForceInputRecovery = readinessRefreshes >= forcedRecoveryRefreshThreshold
            || recordingStartAttemptsExhausted(
                inputFormatReady: inputFormatReady,
                recordingStartAttempts: recordingStartAttempts
            )
        if shouldForceInputRecovery,
           forcedRecoveryAttempts < maxForcedRecoveryAttempts {
            return .forceInputRecovery
        }

        if inputFormatReady {
            if recordingStartAttemptsExhausted(
                inputFormatReady: inputFormatReady,
                recordingStartAttempts: recordingStartAttempts
            ) {
                return .refreshInputReadiness
            }
            return .startRecording
        }

        let shouldTryRecoveryStart = readinessRefreshTimedOut
            || readinessRefreshes >= refreshesBeforeRecoveryStart
        if shouldTryRecoveryStart,
           recoveryStartAttempts == 0 {
            return .startRecoveryRecording
        }

        if shouldTryRecoveryStart,
           forcedRecoveryAttempts > 0,
           forcedRecoveryAttempts < maxForcedRecoveryAttempts,
           recoveryStartAttempts < maxRecoveryStartAttempts {
            return .startRecoveryRecording
        }

        return .refreshInputReadiness
    }
}

struct DictationReadinessRefreshTimeoutPolicy {
    static func timedOut(
        startedAt: TimeInterval?,
        now: TimeInterval,
        timeout: TimeInterval = TranscriptedConstants.dictationReadinessRefreshTimeout
    ) -> Bool {
        guard timeout > 0, let startedAt else { return false }
        return now - startedAt >= timeout
    }
}

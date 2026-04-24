import Foundation

struct ParakeetRecoveryState: Equatable {
    private(set) var isRecovering: Bool = false
    private(set) var inputFormatReady: Bool = true
    private(set) var generation: UInt64 = 0

    var canStartRecording: Bool {
        !isRecovering && inputFormatReady
    }

    mutating func beginConfigChange() -> UInt64 {
        generation &+= 1
        isRecovering = true
        inputFormatReady = false
        return generation
    }

    mutating func markFormatUnready() {
        inputFormatReady = false
    }

    mutating func markStartFailed() {
        inputFormatReady = false
    }

    /// Marks the engine as ready without generation gating. Use only from non-Task
    /// contexts where no stale-generation race is possible (e.g. after a successful
    /// synchronous prewarm or after recording starts on the current generation).
    mutating func markFormatReady() {
        isRecovering = false
        inputFormatReady = true
    }

    mutating func finishRecovery(success: Bool, generation: UInt64) -> Bool {
        guard generation == self.generation else { return false }
        isRecovering = false
        inputFormatReady = success
        return true
    }

    mutating func timeoutRecovery(generation: UInt64) -> Bool {
        guard generation == self.generation, isRecovering else { return false }
        self.generation &+= 1
        isRecovering = false
        inputFormatReady = false
        return true
    }

    func isStale(generation: UInt64) -> Bool {
        generation != self.generation
    }
}

struct ParakeetAudioStartRecoveryPolicy: Equatable {
    static func shouldRetryStartFailure(
        isRecoveryAttempt: Bool,
        failedAttempts: Int,
        retryBudget: Int = TranscriptedConstants.audioStartRecoveryAttempts
    ) -> Bool {
        guard !isRecoveryAttempt else { return false }
        guard retryBudget > 0 else { return false }
        return failedAttempts <= retryBudget
    }

    static func shouldReportFailure(
        now: TimeInterval,
        lastReportAt: TimeInterval?,
        throttle: TimeInterval = TranscriptedConstants.audioStartFailureReportThrottle
    ) -> Bool {
        guard let lastReportAt else { return true }
        return now - lastReportAt >= throttle
    }
}

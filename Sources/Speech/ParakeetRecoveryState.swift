import Foundation

struct ParakeetRecoveryState: Equatable {
    private(set) var isRecovering: Bool = false
    private(set) var inputFormatReady: Bool = true
    private(set) var generation: UInt64 = 0

    mutating func beginConfigChange() -> UInt64 {
        generation &+= 1
        isRecovering = true
        inputFormatReady = false
        return generation
    }

    mutating func markFormatUnready() {
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

    func isStale(generation: UInt64) -> Bool {
        generation != self.generation
    }
}

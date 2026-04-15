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

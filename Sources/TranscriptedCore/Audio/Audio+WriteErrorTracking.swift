import Foundation
import QuartzCore
@preconcurrency import AVFoundation
import CoreAudio
import Combine
import Synchronization

// Generation-scoped consecutive write-error counters for the mic and
// system writers.
extension Audio {
    var consecutiveMicWriteErrors: Int {
        get {
            let generation = recordingSessionGeneration
            return writeErrorLock.withLock {
                micWriteErrorsByGeneration[generation] ?? 0
            }
        }
        set {
            let generation = recordingSessionGeneration
            writeErrorLock.withLock {
                micWriteErrorsByGeneration[generation] = newValue
            }
        }
    }
    var consecutiveSystemWriteErrors: Int {
        get {
            let generation = recordingSessionGeneration
            return writeErrorLock.withLock {
                systemWriteErrorsByGeneration[generation] ?? 0
            }
        }
        set {
            let generation = recordingSessionGeneration
            writeErrorLock.withLock {
                systemWriteErrorsByGeneration[generation] = newValue
            }
        }
    }

    func beginWriteErrorTracking(generation: UInt64) {
        writeErrorLock.withLock {
            micWriteErrorsByGeneration[generation] = 0
            systemWriteErrorsByGeneration[generation] = 0
        }
    }

    func endMicWriteErrorTracking(generation: UInt64) {
        writeErrorLock.withLock {
            micWriteErrorsByGeneration.removeValue(forKey: generation)
        }
    }

    func endSystemWriteErrorTracking(generation: UInt64) {
        writeErrorLock.withLock {
            systemWriteErrorsByGeneration.removeValue(forKey: generation)
        }
    }

    func micWriteErrorCount(generation: UInt64) -> Int? {
        writeErrorLock.withLock {
            micWriteErrorsByGeneration[generation]
        }
    }

    func systemWriteErrorCount(generation: UInt64) -> Int? {
        writeErrorLock.withLock {
            systemWriteErrorsByGeneration[generation]
        }
    }

    func recordMicWriteSuccess(generation: UInt64) {
        writeErrorLock.withLock {
            guard micWriteErrorsByGeneration[generation] != nil else { return }
            micWriteErrorsByGeneration[generation] = 0
        }
    }

    func recordSystemWriteSuccess(generation: UInt64) {
        writeErrorLock.withLock {
            guard systemWriteErrorsByGeneration[generation] != nil else { return }
            systemWriteErrorsByGeneration[generation] = 0
        }
    }

    func incrementMicWriteError(generation: UInt64) -> Int? {
        writeErrorLock.withLock {
            guard let count = micWriteErrorsByGeneration[generation] else { return nil }
            let next = count + 1
            micWriteErrorsByGeneration[generation] = next
            return next
        }
    }

    func incrementSystemWriteError(generation: UInt64) -> Int? {
        writeErrorLock.withLock {
            guard let count = systemWriteErrorsByGeneration[generation] else { return nil }
            let next = count + 1
            systemWriteErrorsByGeneration[generation] = next
            return next
        }
    }
}

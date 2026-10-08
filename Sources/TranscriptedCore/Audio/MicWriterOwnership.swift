import Foundation

/// Lock-backed ownership for the shared microphone writer. Stop detaches and
/// closes the exact-generation writer from a barrier on its serial file queue,
/// after every already-admitted buffer has had a chance to write.
final class MicWriterOwnership<Writer: AnyObject>: @unchecked Sendable {
    struct SessionInstallResult {
        let didInstall: Bool
        let displacedWriter: Writer?
    }

    private let lock = NSLock()
    private var storedWriter: Writer?
    private var storedGeneration: UInt64?
    private var invalidatedThroughGeneration: UInt64?

    var writer: Writer? {
        lock.lock()
        defer { lock.unlock() }
        return storedWriter
    }

    var generation: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return storedGeneration
    }

    @discardableResult
    func installSessionWriter(
        _ writer: Writer,
        generation: UInt64
    ) -> SessionInstallResult {
        lock.lock()
        defer { lock.unlock() }
        if let invalidatedThroughGeneration,
           generation <= invalidatedThroughGeneration {
            return SessionInstallResult(didInstall: false, displacedWriter: nil)
        }
        if let storedGeneration, storedGeneration > generation {
            return SessionInstallResult(didInstall: false, displacedWriter: nil)
        }
        let displacedWriter = storedWriter
        storedWriter = writer
        storedGeneration = generation
        return SessionInstallResult(
            didInstall: true,
            displacedWriter: displacedWriter
        )
    }

    func takeWriterOwned(by generation: UInt64) -> Writer? {
        lock.lock()
        defer { lock.unlock() }
        guard storedGeneration == generation, let writer = storedWriter else { return nil }
        storedWriter = nil
        return writer
    }

    enum RecoveryRetirement {
        case retired(Writer)
        /// Still this recording's, but an earlier failed recovery already
        /// closed its segment and had nothing to replace it with.
        case alreadyRetired
        case notOwned
    }

    /// Take the writer a device recovery is about to replace. Unlike
    /// `takeWriterOwned(by:)`, tells "a failed attempt left no writer" apart
    /// from "ownership moved to another recording", so the next attempt can
    /// still install its recovery segment.
    func retireWriterForRecovery(by generation: UInt64) -> RecoveryRetirement {
        lock.lock()
        defer { lock.unlock() }
        guard storedGeneration == generation else { return .notOwned }
        guard let writer = storedWriter else { return .alreadyRetired }
        storedWriter = nil
        return .retired(writer)
    }

    /// True while `generation` still owns the mic file, whether or not a
    /// failed recovery left it without an open writer.
    func recordingOwnsMicFile(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let invalidatedThroughGeneration, generation <= invalidatedThroughGeneration { return false }
        return storedGeneration == generation
    }

    func writerOwned(by generation: UInt64) -> Writer? {
        lock.lock()
        defer { lock.unlock() }
        guard storedGeneration == generation else { return nil }
        return storedWriter
    }

    func installRecoveryWriter(_ writer: Writer, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let invalidatedThroughGeneration,
           generation <= invalidatedThroughGeneration {
            return false
        }
        guard storedGeneration == generation, storedWriter == nil else { return false }
        storedWriter = writer
        return true
    }

    func takeWriterOwned(
        by captureGeneration: UInt64,
        invalidatingFor stopGeneration: UInt64
    ) -> Writer? {
        lock.lock()
        defer { lock.unlock() }
        if let invalidatedThroughGeneration {
            self.invalidatedThroughGeneration = max(
                invalidatedThroughGeneration,
                stopGeneration
            )
        } else {
            self.invalidatedThroughGeneration = stopGeneration
        }
        guard storedGeneration == captureGeneration else { return nil }
        let writer = storedWriter
        storedWriter = nil
        storedGeneration = stopGeneration
        return writer
    }

    @discardableResult
    func removeIfOwned(_ writer: Writer, generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storedGeneration == generation, storedWriter === writer else { return false }
        storedWriter = nil
        return true
    }
}

import Foundation

/// Lock-backed ownership for one system-audio capture attempt. Stop cancels the
/// capture off-main, then detaches and closes the exact-generation writer from
/// a barrier on its serial file queue after every admitted buffer drains.
final class SystemAudioCaptureAttemptOwnership<Capture, Writer: AnyObject>: @unchecked Sendable {
    struct Attempt {
        let generation: UInt64
        let capture: Capture
        let captureID: ObjectIdentifier
        var writer: Writer?
        var fileURL: URL?
    }

    private let lock = NSLock()
    private var storedCurrent: Attempt?
    private var invalidatedThroughGeneration: UInt64?

    var current: Attempt? {
        lock.lock()
        defer { lock.unlock() }
        return storedCurrent
    }

    @discardableResult
    func begin(generation: UInt64, capture: Capture) -> Attempt? {
        lock.lock()
        defer { lock.unlock() }
        if let invalidatedThroughGeneration,
           generation <= invalidatedThroughGeneration {
            return nil
        }
        if let storedCurrent, storedCurrent.generation > generation {
            return nil
        }
        let displacedAttempt = storedCurrent
        storedCurrent = Attempt(
            generation: generation,
            capture: capture,
            captureID: ObjectIdentifier(capture as AnyObject),
            writer: nil,
            fileURL: nil
        )
        return displacedAttempt
    }

    func install(
        _ writer: Writer,
        generation: UInt64,
        capture: Capture,
        fileURL: URL? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var current = storedCurrent,
              current.generation == generation,
              current.captureID == ObjectIdentifier(capture as AnyObject),
              current.writer == nil else {
            return false
        }
        current.writer = writer
        current.fileURL = fileURL
        storedCurrent = current
        return true
    }

    func fileURLOwned(by generation: UInt64) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard storedCurrent?.generation == generation else { return nil }
        return storedCurrent?.fileURL
    }

    func owns(generation: UInt64, capture: Capture) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedCurrent?.generation == generation
            && storedCurrent?.captureID == ObjectIdentifier(capture as AnyObject)
    }

    func captureOwned(by generation: UInt64) -> Capture? {
        lock.lock()
        defer { lock.unlock() }
        guard storedCurrent?.generation == generation else { return nil }
        return storedCurrent?.capture
    }

    func writerOwned(by generation: UInt64, capture: Capture) -> Writer? {
        lock.lock()
        defer { lock.unlock() }
        guard storedCurrent?.generation == generation,
              storedCurrent?.captureID == ObjectIdentifier(capture as AnyObject) else { return nil }
        return storedCurrent?.writer
    }

    func takeWriterOwned(by generation: UInt64, capture: Capture) -> Writer? {
        lock.lock()
        defer { lock.unlock() }
        guard storedCurrent?.generation == generation,
              storedCurrent?.captureID == ObjectIdentifier(capture as AnyObject) else { return nil }
        let ownedWriter = storedCurrent?.writer
        storedCurrent?.writer = nil
        return ownedWriter
    }

    func takeAttemptOwned(by generation: UInt64) -> Attempt? {
        lock.lock()
        defer { lock.unlock() }
        guard storedCurrent?.generation == generation else { return nil }
        let ownedAttempt = storedCurrent
        storedCurrent = nil
        return ownedAttempt
    }

    func takeAttemptOwned(
        by captureGeneration: UInt64,
        invalidatingFor stopGeneration: UInt64
    ) -> Attempt? {
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
        guard storedCurrent?.generation == captureGeneration else { return nil }
        let ownedAttempt = storedCurrent
        storedCurrent = nil
        return ownedAttempt
    }
}

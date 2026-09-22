import Darwin
import Foundation

/// Process-wide stdout routing is intentionally confined to the single import
/// command. Third-party inference libraries can print outside our logging API.
final class ImportAudioStandardOutput {
    private var descriptor: Int32

    init() throws {
        fflush(stdout)
        descriptor = dup(STDOUT_FILENO)
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        guard dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            close(descriptor)
            throw POSIXError(.EBADF)
        }
    }

    func write(_ data: Data) throws {
        // FileHandle handles partial writes and exposes a broken output pipe.
        try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
    }

    func restore() {
        guard descriptor >= 0 else { return }
        fflush(stdout)
        _ = dup2(descriptor, STDOUT_FILENO)
        close(descriptor)
        descriptor = -1
    }

    deinit { restore() }
}

/// Cooperative shutdown lets owned scratch unwind normally. CoreML may finish
/// its current inference before cancellation is observed; no output is committed
/// until the workflow's final cancellation check.
final class ImportAudioSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    private var sources: [DispatchSourceSignal] = []
    // SIG_DFL is a null C function pointer. Preserve it as optional rather than
    // implicitly unwrapping signal()'s imported return value.
    private var previous: [(Int32, sig_t?)] = []

    var receivedSignal: Int32? { lock.lock(); defer { lock.unlock() }; return value }

    init(cancel: @escaping @Sendable () -> Void) {
        for number in [SIGINT, SIGTERM] {
            previous.append((number, signal(number, SIG_IGN)))
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if self.value == nil { self.value = number }
                self.lock.unlock()
                cancel()
            }
            source.resume()
            sources.append(source)
        }
    }

    func restore() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        for (number, handler) in previous { signal(number, handler) }
        previous.removeAll()
    }

    deinit { restore() }
}

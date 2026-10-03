import Foundation
import Logging
import MCP
import System

/// Newline-delimited stdio transport that sleeps in the kernel while idle.
///
/// SDK 0.12's `StdioTransport` sets O_NONBLOCK and polls stdin every 10 ms for
/// the life of the process (~0.5% of a core and ~200 context switches/s per
/// idle server). This keeps the same wire format: split on 0x0A, skip empty
/// lines, keep CR, finish the stream (without an error) at EOF or on a read
/// error so the server still exits with its client.
///
/// It never changes the descriptors' file status flags. The open file
/// description can be shared with the parent, so flipping O_NONBLOCK could
/// change the client's own I/O. If a descriptor arrives non-blocking, reads
/// and writes wait in poll(2) instead of sleeping in a loop.
actor BlockingStdioTransport: Transport {
    typealias ReadFunction = @Sendable (Int32, UnsafeMutableRawPointer, Int) -> Int

    nonisolated let logger = Logger(label: "transcripted.mcp.stdio", factory: { _ in SwiftLogNoOpLogHandler() })

    private let input: Int32
    private let output: Int32
    private let readFunction: ReadFunction
    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private let writeQueue = DispatchQueue(label: "transcripted.mcp.stdio.write", qos: .userInitiated)
    private var connected = false
    private var started = false

    init(
        input: Int32 = STDIN_FILENO,
        output: Int32 = STDOUT_FILENO,
        readFunction: @escaping ReadFunction = { Darwin.read($0, $1, $2) }
    ) {
        self.input = input
        self.output = output
        self.readFunction = readFunction
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async throws {
        guard !started else { return }
        for fd in [input, output] where fcntl(fd, F_GETFL) < 0 {
            throw MCPError.transportError(Errno(rawValue: errno))
        }
        started = true
        connected = true

        let fd = input
        let readFunction = readFunction
        let continuation = continuation
        let reader = Thread {
            Self.readLoop(fd: fd, read: readFunction, continuation: continuation)
        }
        reader.name = "transcripted.mcp.stdio.read"
        reader.qualityOfService = .userInitiated
        reader.start()
    }

    func disconnect() async {
        guard connected else { return }
        connected = false
        // The reader exits the next time read(2) returns. Never close the fd
        // from here; the process exits at EOF anyway.
        continuation.finish()
    }

    func send(_ message: Data) async throws {
        guard connected else {
            throw MCPError.transportError(Errno(rawValue: ENOTCONN))
        }
        var frame = message
        frame.append(0x0A)
        let fd = output
        // Each frame is written whole on one serial queue with no suspension
        // between partial writes, so concurrent replies cannot interleave. A
        // stalled client pins a GCD worker, not a cooperative-pool thread.
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Swift.Error>) in
            writeQueue.async {
                if let code = Self.writeAll(frame, to: fd) {
                    done.resume(throwing: MCPError.transportError(Errno(rawValue: code)))
                } else {
                    done.resume()
                }
            }
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> { stream }

    // MARK: - Reader thread

    private static let readBufferSize = 64 * 1024

    private static func readLoop(
        fd: Int32,
        read: ReadFunction,
        continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    ) {
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: readBufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var splitter = StdioLineSplitter()
        var running = true
        while running {
            // The thread lives as long as the client session (often days);
            // drain autoreleased objects every iteration.
            running = autoreleasepool {
                let count = read(fd, buffer, readBufferSize)
                if count > 0 {
                    splitter.feed(UnsafeRawBufferPointer(start: buffer, count: count)) { continuation.yield($0) }
                    return true
                }
                if count == 0 { return false }
                let code = errno
                if code == EINTR { return true }
                if code == EAGAIN || code == EWOULDBLOCK {
                    // Inherited O_NONBLOCK (or SO_RCVTIMEO): read first, then
                    // wait for data instead of spinning.
                    waitUntilReady(fd, events: Int16(POLLIN))
                    return true
                }
                return false
            }
        }
        // A partial trailing line is dropped, as SDK 0.12 does at EOF.
        continuation.finish()
    }

    // MARK: - Writer

    /// Writes all of `frame`; returns the errno on failure, nil on success.
    private static func writeAll(_ frame: Data, to fd: Int32) -> Int32? {
        frame.withUnsafeBytes { raw -> Int32? in
            guard let base = raw.baseAddress else { return nil }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 {
                    waitUntilReady(fd, events: Int16(POLLOUT))
                    continue
                }
                let code = errno
                if code == EINTR { continue }
                if code == EAGAIN || code == EWOULDBLOCK {
                    waitUntilReady(fd, events: Int16(POLLOUT))
                    continue
                }
                return code
            }
            return nil
        }
    }

    /// Blocks until `fd` is ready for `events`. If poll reports an invalid
    /// descriptor or fails, it backs off 10 ms so the caller can never spin;
    /// the next read or write then reports the real error.
    private static func waitUntilReady(_ fd: Int32, events: Int16) {
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        while true {
            descriptor.revents = 0
            let result = poll(&descriptor, 1, -1)
            if result < 0 && errno == EINTR { continue }
            if result < 0 || descriptor.revents & Int16(POLLNVAL) != 0 {
                usleep(10_000)
            }
            return
        }
    }
}

/// O(n) newline framing with SDK 0.12 semantics: split on 0x0A, skip empty
/// lines, keep any CR, and emit fresh zero-based `Data` values.
struct StdioLineSplitter {
    private var pending = Data()

    mutating func feed(_ chunk: UnsafeRawBufferPointer, emit: (Data) -> Void) {
        guard let base = chunk.baseAddress, chunk.count > 0 else { return }
        var start = 0
        while start < chunk.count,
              let hit = memchr(base + start, 0x0A, chunk.count - start) {
            let newline = base.distance(to: UnsafeRawPointer(hit))
            if pending.isEmpty {
                if newline > start {
                    emit(Data(bytes: base + start, count: newline - start))
                }
            } else {
                pending.append(base.assumingMemoryBound(to: UInt8.self) + start, count: newline - start)
                emit(pending)
                pending = Data()
            }
            start = newline + 1
        }
        if start < chunk.count {
            pending.append(base.assumingMemoryBound(to: UInt8.self) + start, count: chunk.count - start)
        }
    }
}

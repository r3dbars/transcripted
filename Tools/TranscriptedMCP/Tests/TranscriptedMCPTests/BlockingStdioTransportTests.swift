import Foundation
import XCTest
@testable import transcripted_mcp

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func increment() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

/// Drains `fd` in 8 KB reads on its own thread until EOF.
private func drainUntilEOF(_ fd: Int32) async -> Data {
    await withCheckedContinuation { (done: CheckedContinuation<Data, Never>) in
        let thread = Thread {
            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 8 * 1024)
            while true {
                let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { break }
                output.append(contentsOf: chunk[..<count])
            }
            done.resume(returning: output)
        }
        thread.start()
    }
}

final class BlockingStdioTransportTests: XCTestCase {
    private var openDescriptors: [Int32] = []

    override func tearDown() {
        for fd in openDescriptors { close(fd) }
        openDescriptors = []
        super.tearDown()
    }

    // MARK: Framing

    private let framingStream = Data("{\"a\":1}\n{\"b\":2}\n\n{\"c\":3}\r\n\r\n{\"d\":4}\n{\"partial\"".utf8)
    private let framingExpected: [Data] = [
        Data(#"{"a":1}"#.utf8),
        Data(#"{"b":2}"#.utf8),
        Data("{\"c\":3}\r".utf8),
        Data("\r".utf8),
        Data(#"{"d":4}"#.utf8),
    ]

    func testSplitterFramesMatchForEveryChunking() {
        let bytes = [UInt8](framingStream)
        var chunkings: [[Int]] = [[bytes.count], Array(repeating: 1, count: bytes.count)]
        for cut in 1..<bytes.count { chunkings.append([cut, bytes.count - cut]) }
        for sizes in chunkings {
            var splitter = StdioLineSplitter()
            var frames: [Data] = []
            var offset = 0
            for size in sizes {
                bytes[offset..<(offset + size)].withUnsafeBytes { chunk in
                    splitter.feed(chunk) { frames.append($0) }
                }
                offset += size
            }
            XCTAssertEqual(frames, framingExpected, "chunk sizes \(sizes)")
            XCTAssertTrue(frames.allSatisfy { $0.startIndex == 0 })
        }
    }

    func testPipeDeliversFramesAndFinishesAtEOF() async throws {
        let (readEnd, writeEnd) = try makePipe()
        let (_, sink) = try makePipe()
        let transport = BlockingStdioTransport(input: readEnd, output: sink)
        try await transport.connect()
        let stream = await transport.receive()

        let bytes = [UInt8](framingStream)
        let cut = bytes.count / 2
        writeAll(Array(bytes[..<cut]), to: writeEnd)
        writeAll(Array(bytes[cut...]), to: writeEnd)
        closeOwned(writeEnd)

        var frames: [Data] = []
        for try await frame in stream { frames.append(frame) }
        XCTAssertEqual(frames, framingExpected)
    }

    // MARK: Inherited non-blocking descriptors

    func testInheritedNonBlockingPipeDeliversEveryFrameWithoutChangingFlagsOrSpinning() async throws {
        let (readEnd, writeEnd) = try makePipe()
        let (_, sink) = try makePipe()
        try await assertNonBlockingInput(readEnd: readEnd, writeEnd: writeEnd, output: sink)
    }

    func testInheritedNonBlockingSocketpairDeliversEveryFrameWithoutChangingFlagsOrSpinning() async throws {
        let (serverIn, clientOut) = try makeSocketpair()
        let (serverOut, _) = try makeSocketpair()
        setNonBlocking(serverOut)
        try await assertNonBlockingInput(readEnd: serverIn, writeEnd: clientOut, output: serverOut)
    }

    private func assertNonBlockingInput(readEnd: Int32, writeEnd: Int32, output: Int32) async throws {
        setNonBlocking(readEnd)
        let inputFlags = fcntl(readEnd, F_GETFL)
        let outputFlags = fcntl(output, F_GETFL)
        XCTAssertNotEqual(inputFlags & O_NONBLOCK, 0)

        let counter = ReadCounter()
        let transport = BlockingStdioTransport(input: readEnd, output: output) { fd, buffer, size in
            counter.increment()
            return Darwin.read(fd, buffer, size)
        }
        try await transport.connect()
        XCTAssertEqual(fcntl(readEnd, F_GETFL), inputFlags)
        XCTAssertEqual(fcntl(output, F_GETFL), outputFlags)

        var frames = await transport.receive().makeAsyncIterator()
        let messages = (1...3).map { Data(#"{"jsonrpc":"2.0","method":"ping","id":\#($0)}"#.utf8) }
        for message in messages {
            writeAll([UInt8](message + Data("\n".utf8)), to: writeEnd)
            let received = try await frames.next()
            XCTAssertEqual(received, message)
        }
        closeOwned(writeEnd)
        let end = try await frames.next()
        XCTAssertNil(end)

        XCTAssertEqual(fcntl(readEnd, F_GETFL), inputFlags)
        XCTAssertEqual(fcntl(output, F_GETFL), outputFlags)
        // Each frame costs one read that returns data and at most one or two
        // that return EAGAIN before poll(2) blocks; EOF costs one more. A
        // retry loop without poll makes millions of calls in the same span.
        XCTAssertLessThanOrEqual(counter.count, messages.count * 3 + 2)
    }

    // MARK: Writes

    func testConcurrentSendsNeverInterleaveAndLargeFramesArriveWhole() async throws {
        let (readEnd, writeEnd) = try makePipe()
        let (source, sourceWriter) = try makePipe()
        let drained = Task { await drainUntilEOF(readEnd) }

        let transport = BlockingStdioTransport(input: source, output: writeEnd)
        try await transport.connect()

        var expected: [UInt8: Int] = [:]
        for index in 0..<22 {
            expected[UInt8(0x41 + index)] = index < 2 ? 300 * 1024 : 200
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (byte, length) in expected {
                group.addTask { try await transport.send(Data(repeating: byte, count: length)) }
            }
            try await group.waitForAll()
        }
        closeOwned(writeEnd)
        let output = await drained.value
        // Let the reader thread reach EOF before tearDown recycles its fd.
        closeOwned(sourceWriter)
        for try await _ in await transport.receive() {}

        XCTAssertEqual(output.last, 0x0A)
        let lines = output.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast()
        XCTAssertEqual(lines.count, expected.count)
        var seen: [UInt8: Int] = [:]
        for line in lines {
            guard let first = line.first else {
                XCTFail("empty line")
                continue
            }
            XCTAssertTrue(line.allSatisfy { $0 == first }, "interleaved line starting with \(first)")
            seen[first] = line.count
        }
        XCTAssertEqual(seen, expected)
    }

    func testSendBeforeConnectThrows() async {
        let transport = BlockingStdioTransport(input: -1, output: -1)
        do {
            try await transport.send(Data("{}".utf8))
            XCTFail("send before connect should throw")
        } catch {}
    }

    func testConnectOnInvalidDescriptorThrows() async {
        let transport = BlockingStdioTransport(input: -1, output: -1)
        do {
            try await transport.connect()
            XCTFail("connect on an invalid descriptor should throw")
        } catch {}
    }

    // MARK: Helpers

    private func makePipe() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        openDescriptors += fds
        return (fds[0], fds[1])
    }

    private func makeSocketpair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        openDescriptors += fds
        return (fds[0], fds[1])
    }

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertEqual(fcntl(fd, F_SETFL, flags | O_NONBLOCK), 0)
    }

    private func closeOwned(_ fd: Int32) {
        openDescriptors.removeAll { $0 == fd }
        close(fd)
    }

    private func writeAll(_ bytes: [UInt8], to fd: Int32) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else {
                XCTFail("write failed: \(errno)")
                return
            }
            offset += written
        }
    }
}

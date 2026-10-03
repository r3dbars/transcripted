import Foundation
import XCTest
@testable import transcripted_mcp

private final class ProcessReplyCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var replies: [Int: [String: Any]] = [:]
    private var waiting: [Int: XCTestExpectation] = [:]

    func expect(id: Int, _ expectation: XCTestExpectation) {
        lock.lock()
        defer { lock.unlock() }
        if replies[id] != nil { expectation.fulfill() } else { waiting[id] = expectation }
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = (object["id"] as? NSNumber)?.intValue else { continue }
            replies[id] = object
            waiting.removeValue(forKey: id)?.fulfill()
        }
    }

    func reply(_ id: Int) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return replies[id]
    }
}

/// The helper speaks newline-delimited JSON over its real stdio and exits
/// cleanly when the client closes stdin.
final class ProcessStdioTransportTests: XCTestCase {
    func testExecutableAnswersSequentialRequestsAndExitsAtEOF() throws {
        let executable = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/transcripted-mcp")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))

        let dataRoot = makeTempDir()
        defer { removeTempDir(dataRoot) }

        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.executableURL = executable
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["TRANSCRIPTED_DATA_DIR"] = dataRoot.path
        environment["TRANSCRIPTED_INDEX_DIR"] = dataRoot.appendingPathComponent("index").path
        environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
        process.environment = environment

        let collector = ProcessReplyCollector()
        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            collector.consume(handle.availableData)
        }
        let exited = expectation(description: "helper exits after stdin closes")
        process.terminationHandler = { _ in exited.fulfill() }

        try process.run()
        defer {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let requests: [(Int, String)] = [
            (1, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"synthetic-test-client","version":"1.0"}}}"#),
            (2, #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#),
            (3, #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#),
        ]
        for (id, request) in requests {
            let replied = expectation(description: "reply \(id)")
            collector.expect(id: id, replied)
            try standardInput.fileHandleForWriting.write(contentsOf: Data((request + "\n").utf8))
            if id == 1 {
                let initialized = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"# + "\n"
                try standardInput.fileHandleForWriting.write(contentsOf: Data(initialized.utf8))
            }
            XCTAssertEqual(XCTWaiter.wait(for: [replied], timeout: 10), .completed, "reply \(id)")
        }

        let tools = try XCTUnwrap((collector.reply(2)?["result"] as? [String: Any])?["tools"] as? [Any])
        XCTAssertFalse(tools.isEmpty)
        XCTAssertNotNil(collector.reply(3)?["result"])

        try standardInput.fileHandleForWriting.close()
        XCTAssertEqual(XCTWaiter.wait(for: [exited], timeout: 10), .completed)
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

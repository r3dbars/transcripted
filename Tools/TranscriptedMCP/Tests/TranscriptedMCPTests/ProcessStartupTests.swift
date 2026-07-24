import Foundation
import XCTest
@testable import transcripted_mcp

private final class ProcessResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var response: [String: Any]?

    func set(_ response: [String: Any]) {
        lock.lock()
        self.response = response
        lock.unlock()
    }

    func get() -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return response
    }
}

private final class ProcessInitializeReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var completed = false
    private let responseBox: ProcessResponseBox
    private let responseReceived: XCTestExpectation

    init(responseBox: ProcessResponseBox, responseReceived: XCTestExpectation) {
        self.responseBox = responseBox
        self.responseReceived = responseReceived
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }

        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let response = object as? [String: Any],
                  (response["id"] as? NSNumber)?.intValue == 1 else {
                continue
            }

            completed = true
            responseBox.set(response)
            responseReceived.fulfill()
            return
        }
    }
}

final class ProcessStartupTests: XCTestCase {
    func testExecutableAnswersInitializeOverStdio() throws {
        let executable = builtExecutable()
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

        let responseReceived = expectation(description: "initialize response")
        let responseBox = ProcessResponseBox()
        let outputLock = NSLock()
        var outputBuffer = Data()
        standardOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            outputLock.lock()
            outputBuffer.append(data)
            while let newline = outputBuffer.firstIndex(of: 0x0A) {
                let line = outputBuffer[..<newline]
                outputBuffer.removeSubrange(...newline)
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                      let response = object as? [String: Any],
                      (response["id"] as? NSNumber)?.intValue == 1 else {
                    continue
                }
                responseBox.set(response)
                responseReceived.fulfill()
                break
            }
            outputLock.unlock()
        }

        try process.run()
        defer {
            standardOutput.fileHandleForReading.readabilityHandler = nil
            try? standardInput.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"synthetic-test-client","version":"1.0"}}}"# + "\n"
        try standardInput.fileHandleForWriting.write(contentsOf: Data(request.utf8))

        XCTAssertEqual(XCTWaiter.wait(for: [responseReceived], timeout: 5), .completed)
        let response = try XCTUnwrap(responseBox.get())
        XCTAssertEqual(response["jsonrpc"] as? String, "2.0")

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "transcripted")
        XCTAssertEqual(serverInfo["version"] as? String, TranscriptedMCP.serverVersion)
    }

    func testConcurrentExecutablesAnswerInitializeAgainstSharedColdIndex() throws {
        let executable = builtExecutable()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))

        let dataRoot = makeTempDir()
        defer { removeTempDir(dataRoot) }
        let sharedIndexRoot = dataRoot.appendingPathComponent("shared-index", isDirectory: true)

        var processes: [Process] = []
        var standardInputs: [Pipe] = []
        var standardOutputs: [Pipe] = []
        var responseBoxes: [ProcessResponseBox] = []
        let responseExpectations = (1...2).map {
            expectation(description: "concurrent initialize response \($0)")
        }

        defer {
            for output in standardOutputs {
                output.fileHandleForReading.readabilityHandler = nil
            }
            for input in standardInputs {
                try? input.fileHandleForWriting.close()
            }
            for process in processes where process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        for responseExpectation in responseExpectations {
            let process = Process()
            let standardInput = Pipe()
            let standardOutput = Pipe()
            let responseBox = ProcessResponseBox()
            let responseReader = ProcessInitializeReader(
                responseBox: responseBox,
                responseReceived: responseExpectation
            )

            process.executableURL = executable
            process.standardInput = standardInput
            process.standardOutput = standardOutput
            process.standardError = Pipe()

            var environment = ProcessInfo.processInfo.environment
            environment["TRANSCRIPTED_DATA_DIR"] = dataRoot.path
            environment["TRANSCRIPTED_INDEX_DIR"] = sharedIndexRoot.path
            environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
            process.environment = environment
            standardOutput.fileHandleForReading.readabilityHandler = { handle in
                responseReader.consume(handle.availableData)
            }

            try process.run()
            processes.append(process)
            standardInputs.append(standardInput)
            standardOutputs.append(standardOutput)
            responseBoxes.append(responseBox)
        }

        let request = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"synthetic-concurrent-client","version":"1.0"}}}"# + "\n"
        for input in standardInputs {
            try input.fileHandleForWriting.write(contentsOf: Data(request.utf8))
        }

        XCTAssertEqual(XCTWaiter.wait(for: responseExpectations, timeout: 10), .completed)
        for responseBox in responseBoxes {
            let response = try XCTUnwrap(responseBox.get())
            XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
            let result = try XCTUnwrap(response["result"] as? [String: Any])
            let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
            XCTAssertEqual(serverInfo["name"] as? String, "transcripted")
        }
    }

    private func builtExecutable() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/transcripted-mcp")
    }
}

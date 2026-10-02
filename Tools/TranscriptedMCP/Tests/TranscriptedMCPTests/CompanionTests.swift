import XCTest
import Foundation
import Darwin
import MCP
@testable import transcripted_mcp

/// Same-user Unix socket fixture; contains invented state only, never opens the app.
private final class CompanionSocketFixture {
    let root: URL
    let token = String(repeating: "a", count: 64)
    private let listener: Int32
    init(replies: Int = 1, reply: @escaping @Sendable ([String: Value]) -> [String: Value]) throws {
        root = URL(fileURLWithPath: "/private/tmp/transcripted-companion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw CompanionClient.Failure(code: "fixture_socket") }
        let path = root.appendingPathComponent("s").path
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.initializeMemory(as: UInt8.self, repeating: 0); $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, listen(listener, 4) == 0 else { throw CompanionClient.Failure(code: "fixture_socket") }
        _ = chmod(path, 0o600)
        let config = CompanionClient.Connection(protocol_version: 1, socket_path: path, token: token)
        let file = root.appendingPathComponent("connection.json")
        try JSONEncoder().encode(config).write(to: file); _ = chmod(file.path, 0o600)
        let fd = listener
        DispatchQueue.global().async {
            for _ in 0..<replies {
                let peer = accept(fd, nil, nil)
                guard peer >= 0 else { return }
                var noSignal: Int32 = 1
                _ = setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                var data = Data(); var byte: UInt8 = 0
                while recv(peer, &byte, 1, 0) == 1, byte != 0x0A { data.append(byte) }
                if let request = try? JSONDecoder().decode([String: Value].self, from: data),
                   var response = try? JSONEncoder().encode(reply(request)) {
                    response.append(0x0A)
                    response.withUnsafeBytes { buffer in _ = Darwin.send(peer, buffer.baseAddress, buffer.count, 0) }
                }
                close(peer)
            }
        }
    }
    deinit { shutdown(listener, SHUT_RDWR); close(listener); try? FileManager.default.removeItem(at: root) }
}

private final class CompanionProcessReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    let complete: XCTestExpectation
    init(complete: XCTestExpectation) { self.complete = complete }
    func consume(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = object["id"] as? Int, (1...5).contains(id), responses[id] == nil else { continue }
            responses[id] = object; complete.fulfill()
        }
    }
    func get(_ id: Int) -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return responses[id] }
}

final class CompanionTests: XCTestCase {
    func testPackagedCompanionRefusesUnlistedLegacyAudioToolAndResource() throws {
        let root = makeTempDir(); defer { removeTempDir(root) }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/transcripted-mcp")
        process.standardInput = input; process.standardOutput = output; process.standardError = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["TRANSCRIPTED_DATA_DIR"] = root.path
        environment["TRANSCRIPTED_INDEX_DIR"] = root.appendingPathComponent("index").path
        environment["TRANSCRIPTED_MCP_COMPANION_MODE"] = "1"
        environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
        environment["TRANSCRIPTED_CONTAINER_DIR"] = root.path
        process.environment = environment
        let complete = expectation(description: "companion protocol responses"); complete.expectedFulfillmentCount = 5
        let responses = CompanionProcessReplies(complete: complete)
        output.fileHandleForReading.readabilityHandler = { responses.consume($0.availableData) }
        try process.run()
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        let requests: [[String: Any]] = [
            ["id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "Synthetic companion safety test", "version": "1"]]],
            ["id": 2, "method": "tools/list", "params": [:]],
            ["id": 3, "method": "resources/list", "params": [:]],
            ["id": 4, "method": "tools/call", "params": ["name": "show_recent_meetings", "arguments": ["count": 1]]],
            ["id": 5, "method": "resources/read", "params": ["uri": RecentMeetingsWidget.resourceURI]]
        ]
        for var request in requests {
            request["jsonrpc"] = "2.0"
            var data = try JSONSerialization.data(withJSONObject: request); data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 10), .completed)
        let toolList = try XCTUnwrap((responses.get(2)?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertFalse(toolList.contains { $0["name"] as? String == "show_recent_meetings" })
        XCTAssertTrue(toolList.contains { $0["name"] as? String == "show_companion" })
        let resources = try XCTUnwrap((responses.get(3)?["result"] as? [String: Any])?["resources"] as? [[String: Any]])
        XCTAssertEqual(resources.compactMap { $0["uri"] as? String }, [CompanionTools.resourceURI])
        XCTAssertEqual((responses.get(4)?["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertNotNil(responses.get(5)?["error"])
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: try XCTUnwrap(responses.get(4))), as: UTF8.self).contains("base64"))
    }

    func testClientAuthenticatesAndReadsNativeStatusWithoutCredentialLeakage() throws {
        let fixture = try CompanionSocketFixture { request in
            let authenticated = request["token"] == .string(String(repeating: "a", count: 64)) && request["method"] == .string("status") && request["version"] == .int(1)
            return ["version": .int(1), "id": request["id"] ?? .null, "ok": .bool(true), "result": .object(["authenticated": .bool(authenticated), "state": .string("ready")])]
        }
        let result = try CompanionClient(root: fixture.root).call("status")
        XCTAssertEqual(result["authenticated"], .bool(true))
        XCTAssertEqual(result["state"], .string("ready"))
        XCTAssertNil(result["token"])
        XCTAssertNil(result["socket_path"])
    }

    func testClientRejectsPublicCredentialFile() throws {
        let fixture = try CompanionSocketFixture { _ in [:] }
        _ = chmod(fixture.root.appendingPathComponent("connection.json").path, 0o644)
        XCTAssertThrowsError(try CompanionClient(root: fixture.root).connection()) { XCTAssertEqual(($0 as? CompanionClient.Failure)?.code, "invalid_connection") }
    }

    func testClientRejectsSymlinkedCredentialFile() throws {
        let fixture = try CompanionSocketFixture { _ in [:] }
        let file = fixture.root.appendingPathComponent("connection.json")
        let linked = fixture.root.appendingPathComponent("linked.json")
        try FileManager.default.moveItem(at: file, to: linked)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: linked)
        XCTAssertThrowsError(try CompanionClient(root: fixture.root).connection())
    }

    func testClientRejectsSocketOutsideCredentialRoot() throws {
        let fixture = try CompanionSocketFixture { _ in [:] }
        let file = fixture.root.appendingPathComponent("connection.json")
        let config = CompanionClient.Connection(protocol_version: 1, socket_path: "/private/tmp/unrelated.sock", token: fixture.token)
        try JSONEncoder().encode(config).write(to: file); _ = chmod(file.path, 0o600)
        XCTAssertThrowsError(try CompanionClient(root: fixture.root).connection()) { XCTAssertEqual(($0 as? CompanionClient.Failure)?.code, "invalid_connection") }
    }

    func testClientRejectsStaleResponseInsteadOfApplyingIt() throws {
        let fixture = try CompanionSocketFixture { _ in ["version": .int(1), "id": .string(UUID().uuidString), "ok": .bool(true), "result": .object(["started": .bool(true)])] }
        XCTAssertThrowsError(try CompanionClient(root: fixture.root).call("status")) { XCTAssertEqual(($0 as? CompanionClient.Failure)?.code, "invalid_response") }
    }

    func testDeadlineFailsWithoutInventingARecordingOutcome() throws {
        let fixture = try CompanionSocketFixture { request in ["version": .int(1), "id": request["id"] ?? .null, "ok": .bool(true), "result": .object([:])] }
        XCTAssertThrowsError(try CompanionClient(root: fixture.root, timeout: 0).call("start_meeting")) { XCTAssertEqual(($0 as? CompanionClient.Failure)?.code, "timeout") }
    }

    func testNativeErrorsExposeOnlySafeActionableMessages() throws {
        let response: [String: Value] = ["version": .int(1), "id": .string("request"), "ok": .bool(false), "error": .object(["code": .string("auth_failed"), "message": .string("PRIVATE credential /secret/path")])]
        XCTAssertThrowsError(try CompanionClient.decodeResponse(JSONEncoder().encode(response), expectedID: "request")) {
            XCTAssertEqual(($0 as? CompanionClient.Failure)?.code, "auth_failed")
            XCTAssertFalse($0.localizedDescription.contains("PRIVATE"))
            XCTAssertFalse($0.localizedDescription.contains("/secret"))
        }
    }

    func testSavedPassageViewDoesNotPutTranscriptInModelContent() throws {
        let result = try CompanionTools.viewResult("Passage loaded.", payload: ["passage": .object(["text": .string("Invented private passage")])], summary: ["loaded": .bool(true)])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as! [String: Any]
        let content = try JSONSerialization.data(withJSONObject: json["content"]!)
        let structured = try JSONSerialization.data(withJSONObject: json["structuredContent"]!)
        XCTAssertFalse(String(decoding: content, as: UTF8.self).contains("Invented private"))
        XCTAssertFalse(String(decoding: structured, as: UTF8.self).contains("Invented private"))
        let meta = try XCTUnwrap(json["_meta"] as? [String: Any])
        let data = try XCTUnwrap(meta[CompanionTools.payloadKey] as? [String: Any])
        XCTAssertEqual((data["passage"] as? [String: String])?["text"], "Invented private passage")
    }

    func testSelectedSavedUtteranceHasAccurateSourceAndNoAdjacentText() throws {
        let root = makeTempDir(); defer { removeTempDir(root) }
        let directories = TranscriptedDataDirectories(meetingsDir: root, dictationsDir: root, indexDir: root)
        try writeFixture(makeFixtureJSON(utterances: [("mic_0", 0, 5, "Adjacent text must remain unselected"), ("system_0", 9, 14, "Only this selected evidence")]), filename: "Call_2026-09-30_10-00-00", to: root)
        let passage = try CompanionTools.savedPassage(args: ["kind": .string("meeting"), "filename": .string("Call_2026-09-30_10-00-00"), "passage_index": .int(1)], directories: directories)
        XCTAssertEqual(passage["text"], .string("Only this selected evidence"))
        XCTAssertEqual(passage["start_seconds"], .double(9))
        XCTAssertEqual(passage["total_passages"], .int(2))
        guard case .string(let source)? = passage["source_url"] else { return XCTFail("Missing source URL") }
        let url = try XCTUnwrap(URLComponents(string: source))
        XCTAssertEqual(url.path, "/transcripted@transcripted-local/app/show_companion")
        XCTAssertTrue(url.queryItems?.first?.value?.contains("passage=1") == true)
    }

    func testSavedPassageRejectsTraversalAndFractionalIndexes() throws {
        let root = makeTempDir(); defer { removeTempDir(root) }
        let directories = TranscriptedDataDirectories(meetingsDir: root, dictationsDir: root, indexDir: root)
        XCTAssertThrowsError(try CompanionTools.savedPassage(args: ["kind": .string("meeting"), "filename": .string("../private")], directories: directories))
        XCTAssertThrowsError(try CompanionTools.savedPassage(args: ["kind": .string("meeting"), "filename": .string("anything"), "passage_index": .double(0.5)], directories: directories))
    }

    func testLiveTextResultIsBoundedAndContinuationDoesNotSkipOmittedSegments() throws {
        let segments = (1...12).map { Value.object(["sequence": .int($0), "text": .string(String(repeating: "x", count: 2_000))]) }
        let result = CompanionTools.boundedLiveResult(["segments": .array(segments), "next_sequence": .int(12)])
        let bounded = try XCTUnwrap(result["segments"]?.arrayValue)
        XCTAssertEqual(bounded.count, 4)
        XCTAssertEqual(result["next_sequence"], .int(4))
        XCTAssertEqual(result["truncated"], .bool(true))
    }

    func testModelLiveContextKeepsTheNewestSpeechWithinItsTextBudget() throws {
        let segments = (1...12).map { Value.object(["sequence": .int($0), "text": .string(String(repeating: "x", count: 2_000))]) }
        let result = CompanionTools.boundedLiveResult(["segments": .array(segments), "next_sequence": .int(12)], newest: true)
        guard case .array(let bounded)? = result["segments"] else { return XCTFail("Missing segments") }
        XCTAssertEqual(bounded.count, 4)
        guard case .object(let first)? = bounded.first, case .object(let last)? = bounded.last else { return XCTFail("Missing window") }
        XCTAssertEqual(first["sequence"], .int(9))
        XCTAssertEqual(last["sequence"], .int(12))
        XCTAssertEqual(result["next_sequence"], .int(12))
        XCTAssertEqual(result["truncated"], .bool(true))
    }

    func testModelLiveReadFailsBeforeFetchingTextWithoutSessionConsent() async throws {
        let session = UUID().uuidString
        let fixture = try CompanionSocketFixture { request in
            ["version": .int(1), "id": request["id"] ?? .null, "ok": .bool(true), "result": .object(["session_id": .string(session), "sharing_enabled": .bool(false), "latest_sequence": .int(8)])]
        }
        let root = makeTempDir(); defer { removeTempDir(root) }
        let directories = TranscriptedDataDirectories(meetingsDir: root, dictationsDir: root, indexDir: root)
        let index = try TranscriptIndex(indexDir: root)
        let result = await CompanionTools.call(params: .init(name: "get_live_meeting_context", arguments: ["session_id": .string(session)]), index: index, directories: directories, client: CompanionClient(root: fixture.root))
        XCTAssertEqual(result.isError, true)
        XCTAssertNil(result.structuredContent)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("segments"))
    }

    func testControlToolsDeclareWritesAndViewPollingIsAppOnly() throws {
        let start = try XCTUnwrap(CompanionTools.tools.first { $0.name == "start_meeting" })
        let stop = try XCTUnwrap(CompanionTools.tools.first { $0.name == "stop_meeting" })
        XCTAssertEqual(start.annotations.readOnlyHint, false)
        XCTAssertEqual(stop.annotations.destructiveHint, false)
        let view = try XCTUnwrap(CompanionTools.tools.first { $0.name == "read_live_transcript" })
        let metadata = try JSONSerialization.jsonObject(with: JSONEncoder().encode(view)) as! [String: Any]
        XCTAssertEqual(((metadata["_meta"] as? [String: Any])?["ui"] as? [String: Any])?["visibility"] as? [String], ["app"])
    }
}

import Foundation
import Logging
import MCP
import XCTest
@testable import transcripted_mcp

private actor FixtureCompanionTransport: Transport {
    nonisolated let logger = Logger(label: "fixture", factory: { _ in SwiftLogNoOpLogHandler() })
    let stream: AsyncThrowingStream<Data, Swift.Error>
    let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    var connected = false
    var sent: [Data] = []

    init() {
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }
    func connect() async throws { connected = true }
    func disconnect() async { connected = false; continuation.finish() }
    func send(_ data: Data) async throws { sent.append(data) }
    func receive() -> AsyncThrowingStream<Data, Swift.Error> { stream }
    func emit(_ data: Data) { continuation.yield(data) }
    func finish() { continuation.finish() }
}

final class CompanionTransportTests: XCTestCase {
    private let initialize = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"synthetic-app-host","version":"1.0"},"capabilities":{"experimental":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html;profile=mcp-app"]},"unknown/namespace":{"enabled":true},"legacy/string":"supported"},"roots":{"listChanged":true},"sampling":{"tools":{},"context":{}},"elicitation":{"form":{},"url":{}},"extensions":{"unknown/object":{"enabled":true}}}}}"#.utf8)

    func testAppObjectCapabilitiesInitializeDecodesWithSDK() throws {
        let adapted = CompanionTransport.compatibleInitialize(initialize)
        let request = try JSONDecoder().decode(Request<Initialize>.self, from: adapted)
        XCTAssertEqual(request.params.clientInfo.name, "synthetic-app-host")
        XCTAssertEqual(request.params.protocolVersion, "2025-11-25")
        XCTAssertEqual(request.params.capabilities.experimental, ["legacy/string": "supported"])
        XCTAssertEqual(request.params.capabilities.roots?.listChanged, true)
        XCTAssertNotNil(request.params.capabilities.sampling?.tools)
        XCTAssertNotNil(request.params.capabilities.sampling?.context)
        XCTAssertNotNil(request.params.capabilities.elicitation?.form)
        XCTAssertNotNil(request.params.capabilities.elicitation?.url)
        let before = try capabilities(initialize)
        let after = try capabilities(adapted)
        for key in ["roots", "sampling", "elicitation", "extensions"] {
            XCTAssertEqual(before[key] as? NSDictionary, after[key] as? NSDictionary)
        }
    }

    func testLegacyStringsArePassedThroughByteForByte() {
        let data = Data(#"{ "jsonrpc": "2.0", "id": 2, "method": "initialize", "params": {"capabilities":{"experimental":{"legacy/string":"supported"}}} }"#.utf8)
        XCTAssertEqual(CompanionTransport.compatibleInitialize(data), data)
    }

    func testNonInitializeAndMalformedFramesRemainUnchanged() {
        let fixtures = [
            #"{ "jsonrpc":"2.0", "id":3, "method":"tools/call", "params":{"name":"synthetic","arguments":{"method":"initialize","capabilities":{"experimental":{"object":{}}}}} }"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized","params":{"capabilities":{"experimental":{"object":{}}}}}"#,
            #"{"method":"initialize","params":{"capabilities":{"experimental":{"object":{}}}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"initialize","params":"malformed"}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"initialize","params":{"capabilities":{"experimental":[]}}}"#,
            #"[{"jsonrpc":"2.0","id":6,"method":"initialize","params":{"capabilities":{"experimental":{"object":{}}}}}]"#,
            "invalid JSON",
        ]
        for fixture in fixtures {
            let data = Data(fixture.utf8)
            XCTAssertEqual(CompanionTransport.compatibleInitialize(data), data)
        }
    }

    func testTransportDelegatesLifecycleAndPreservesOtherFrames() async throws {
        let underlying = FixtureCompanionTransport()
        let transport = CompanionTransport(underlying: underlying)
        try await transport.connect()
        let connected = await underlying.connected
        XCTAssertTrue(connected)
        let stream = await transport.receive()
        let ordinary = Data(#"{ "jsonrpc":"2.0", "id":7, "method":"tools/list", "params":{} }"#.utf8)
        await underlying.emit(ordinary)
        await underlying.emit(initialize)
        await underlying.finish()
        var received: [Data] = []
        for try await frame in stream { received.append(frame) }
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.first, ordinary)
        _ = try JSONDecoder().decode(Request<Initialize>.self, from: XCTUnwrap(received.last))
        let reply = Data(#"{ "jsonrpc":"2.0", "id":7, "result":{} }"#.utf8)
        try await transport.send(reply)
        let sent = await underlying.sent
        XCTAssertEqual(sent, [reply])
        await transport.disconnect()
        let disconnected = await underlying.connected
        XCTAssertFalse(disconnected)
    }

    private func capabilities(_ data: Data) throws -> [String: Any] {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        return try XCTUnwrap(params["capabilities"] as? [String: Any])
    }
}

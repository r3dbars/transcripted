import Foundation
import Logging
import MCP

/// SDK 0.12 models experimental client capabilities as strings, while MCP Apps
/// hosts advertise objects. The server does not consume these declarations.
/// Adapt only that initialize field; never rewrite tool requests or replies.
actor CompanionTransport: Transport {
    nonisolated let logger = Logger(label: "transcripted.mcp.compatibility", factory: { _ in SwiftLogNoOpLogHandler() })
    private let underlying: any Transport
    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var forwarding: Task<Void, Never>?
    private var started = false

    init(underlying: any Transport = BlockingStdioTransport()) {
        self.underlying = underlying
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async throws { try await underlying.connect() }

    func disconnect() async {
        forwarding?.cancel()
        continuation.finish()
        await underlying.disconnect()
    }

    func send(_ data: Data) async throws { try await underlying.send(data) }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        if !started {
            started = true
            let underlying = underlying
            let continuation = continuation
            forwarding = Task {
                do {
                    for try await data in await underlying.receive() {
                        guard !Task.isCancelled else { break }
                        continuation.yield(Self.compatibleInitialize(data))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        return stream
    }

    static func compatibleInitialize(_ data: Data) -> Data {
        guard var request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              request["jsonrpc"] as? String == "2.0",
              request["method"] as? String == "initialize",
              (try? JSONDecoder().decode(InitializeEnvelope.self, from: data)) != nil,
              var params = request["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any] else {
            return data
        }
        let supported = experimental.filter { $0.value is String }
        guard supported.count != experimental.count else { return data }
        capabilities["experimental"] = supported
        params["capabilities"] = capabilities
        request["params"] = params
        return (try? JSONSerialization.data(withJSONObject: request)) ?? data
    }

    private struct InitializeEnvelope: Decodable {
        let id: ID
    }
}

import Foundation
import Testing
@testable import TranscriptedWritingRuntime

@Suite("Llama transport owns configuration copies and per-operation lifetimes")
struct LlamaTransportConfigurationTests {
    @Test("Caller configuration is untouched and later caller mutations cannot change a request")
    func callerAliasIsIsolated() async throws {
        try requireConfigurationFixtureEnvironment()
        let caller = URLSessionConfiguration.ephemeral
        caller.requestCachePolicy = .returnCacheDataDontLoad
        caller.httpShouldSetCookies = true
        caller.connectionProxyDictionary = ["SyntheticProxyEnabled": 1]
        caller.timeoutIntervalForRequest = 17
        caller.timeoutIntervalForResource = 29
        caller.httpAdditionalHeaders = ["X-Synthetic-Configuration": "initial"]
        caller.protocolClasses = [ConfigurationProtocolMarker.self]
        let originalCache = caller.urlCache
        let originalCookies = caller.httpCookieStorage
        let originalCredentials = caller.urlCredentialStorage
        let factory = ConfigurationNetworkFactory()
        defer { factory.cancelAll() }
        let transport = URLSessionLlamaCompletionTransport(configuration: caller, makeNetwork: { request, configuration, operation in
            factory.make(request, configuration, operation)
        })

        #expect(caller.requestCachePolicy == .returnCacheDataDontLoad)
        #expect(caller.httpShouldSetCookies)
        #expect((caller.connectionProxyDictionary?["SyntheticProxyEnabled"] as? Int) == 1)
        #expect(caller.urlCache === originalCache)
        #expect(caller.httpCookieStorage === originalCookies)
        #expect(caller.urlCredentialStorage === originalCredentials)
        #expect(caller.timeoutIntervalForRequest == 17)
        #expect(caller.timeoutIntervalForResource == 29)
        #expect(configurationHeader(caller) == "initial")
        #expect(hasConfigurationMarker(caller))

        // Mutations are sequential, after init copied the caller. This is not
        // a claim that Foundation permits concurrent caller mutation/copying.
        caller.timeoutIntervalForRequest = 91
        caller.timeoutIntervalForResource = 92
        caller.httpAdditionalHeaders = ["X-Synthetic-Configuration": "caller changed"]
        caller.protocolClasses = []
        let stream = try await transport.open(request: configurationRequest("caller"))
        defer { stream.cancel() }
        let captured = try #require(factory.entry("caller"))
        #expect(captured.configuration !== caller)
        expectSanitizedConfiguration(captured.configuration)
        #expect(captured.configuration.timeoutIntervalForRequest == 17)
        #expect(captured.configuration.timeoutIntervalForResource == 29)
        #expect(configurationHeader(captured.configuration) == "initial")
        #expect(hasConfigurationMarker(captured.configuration))
        #expect(caller.timeoutIntervalForRequest == 91)
        #expect(configurationHeader(caller) == "caller changed")
    }

    @Test("A retained factory configuration cannot poison a later operation")
    func retainedFactoryAliasIsIsolated() async throws {
        try requireConfigurationFixtureEnvironment()
        let caller = URLSessionConfiguration.ephemeral
        caller.timeoutIntervalForRequest = 13
        caller.httpAdditionalHeaders = ["X-Synthetic-Configuration": "template"]
        let factory = ConfigurationNetworkFactory()
        defer { factory.cancelAll() }
        let transport = URLSessionLlamaCompletionTransport(configuration: caller, makeNetwork: { request, configuration, operation in
            factory.make(request, configuration, operation)
        })
        let first = try await transport.open(request: configurationRequest("first"))
        defer { first.cancel() }
        let firstCapture = try #require(factory.entry("first"))
        firstCapture.configuration.timeoutIntervalForRequest = 88
        firstCapture.configuration.httpAdditionalHeaders = ["X-Synthetic-Configuration": "factory changed"]
        firstCapture.configuration.httpShouldSetCookies = true
        firstCapture.configuration.connectionProxyDictionary = ["SyntheticProxyEnabled": 1]

        let second = try await transport.open(request: configurationRequest("second"))
        defer { second.cancel() }
        let secondCapture = try #require(factory.entry("second"))
        #expect(firstCapture.configuration !== caller)
        #expect(secondCapture.configuration !== caller)
        #expect(firstCapture.configuration !== secondCapture.configuration)
        #expect(firstCapture.configuration.timeoutIntervalForRequest == 88)
        #expect(configurationHeader(firstCapture.configuration) == "factory changed")
        #expect(secondCapture.configuration.timeoutIntervalForRequest == 13)
        #expect(configurationHeader(secondCapture.configuration) == "template")
        expectSanitizedConfiguration(secondCapture.configuration)
        #expect(caller.timeoutIntervalForRequest == 13)
        #expect(configurationHeader(caller) == "template")
    }

    @Test("Concurrent operations have separate configurations and cancellation cannot invalidate a sibling")
    func concurrentCancellationIsIndependent() async throws {
        try requireConfigurationFixtureEnvironment()
        let factory = ConfigurationNetworkFactory(event: .held)
        defer { factory.cancelAll() }
        let transport = URLSessionLlamaCompletionTransport(configuration: .ephemeral, makeNetwork: { request, configuration, operation in
            factory.make(request, configuration, operation)
        })
        let aTask = Task { try await transport.open(request: configurationRequest("A")) }
        let bTask = Task { try await transport.open(request: configurationRequest("B")) }
        // Signaled by each fake resume, after the actual operation owns its
        // fake network. No response is delivered until both have started.
        await factory.started.wait(atLeast: 2)
        let a = try #require(factory.entry("A"))
        let b = try #require(factory.entry("B"))
        #expect(a.configuration !== b.configuration)
        #expect(a.network.resumeCount == 1)
        #expect(b.network.resumeCount == 1)
        #expect(a.operation.receive(statusCode: 200))
        #expect(b.operation.receive(statusCode: 201))
        let aStream = try await aTask.value
        let bStream = try await bTask.value
        #expect(aStream.statusCode == 200)
        #expect(bStream.statusCode == 201)
        aStream.cancel()
        aStream.cancel()
        #expect(a.network.cancelCount == 1)
        #expect(a.network.invalidateCount == 1)
        #expect(b.network.cancelCount == 0)
        #expect(b.network.invalidateCount == 0)
        b.operation.receive(data: Data("synthetic line\nsynthetic tail".utf8))
        b.operation.complete(error: nil)
        var lines: [String] = []
        for try await line in bStream.lines { lines.append(line) }
        #expect(lines == ["synthetic line", "synthetic tail"])
        #expect(b.network.cancelCount == 0)
        #expect(b.network.invalidateCount == 1)
        #expect(a.network.cancelCount == 1)
        #expect(a.network.invalidateCount == 1)
        bStream.cancel()
        #expect(b.network.cancelCount == 0)
        #expect(b.network.invalidateCount == 1)
    }

    @Test("Successful response and buffered lines use the actual operation without a session")
    func successPreservesBufferedTail() async throws {
        try requireConfigurationFixtureEnvironment()
        let factory = ConfigurationNetworkFactory(event: .response(202))
        defer { factory.cancelAll() }
        let transport = URLSessionLlamaCompletionTransport(configuration: .ephemeral, makeNetwork: { request, configuration, operation in
            factory.make(request, configuration, operation)
        })
        let stream = try await transport.open(request: configurationRequest("success"))
        let captured = try #require(factory.entry("success"))
        #expect(stream.statusCode == 202)
        captured.operation.receive(data: Data("one\ntwo".utf8))
        captured.operation.complete(error: nil)
        var lines: [String] = []
        for try await line in stream.lines { lines.append(line) }
        #expect(lines == ["one", "two"])
        #expect(captured.network.resumeCount == 1)
        #expect(captured.network.cancelCount == 0)
        #expect(captured.network.invalidateCount == 1)
        stream.cancel()
        #expect(captured.network.invalidateCount == 1)
    }

    @Test("Failure or clean EOF before headers wakes open with the corresponding error")
    func completionBeforeHeadersIsReported() async throws {
        try requireConfigurationFixtureEnvironment()
        for (event, expected) in [(ConfigurationInitialEvent.failure(.networkConnectionLost), URLError.Code.networkConnectionLost),
                                  (.finishedWithoutResponse, .badServerResponse)] {
            let factory = ConfigurationNetworkFactory(event: event)
            defer { factory.cancelAll() }
            let transport = URLSessionLlamaCompletionTransport(configuration: .ephemeral, makeNetwork: { request, configuration, operation in
            factory.make(request, configuration, operation)
        })
            do {
                _ = try await transport.open(request: configurationRequest("failure"))
                Issue.record("A completed operation without response headers must throw")
            } catch {
                #expect((error as? URLError)?.code == expected)
            }
            let captured = try #require(factory.entry("failure"))
            #expect(captured.network.resumeCount == 1)
            #expect(captured.network.cancelCount == 0)
            #expect(captured.network.invalidateCount == 1)
        }
    }
}

private func requireConfigurationFixtureEnvironment() throws {
    try #require(ProcessInfo.processInfo.environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1")
}

private func configurationRequest(_ name: String) -> URLRequest {
    // Value only: every transport initializer receives a fake factory. This
    // address is never handed to a session, protocol registration or socket.
    URLRequest(url: URL(string: "https://configuration-fixture.invalid/\(name)")!)
}

private func configurationHeader(_ configuration: URLSessionConfiguration) -> String? {
    configuration.httpAdditionalHeaders?["X-Synthetic-Configuration"] as? String
}

private func hasConfigurationMarker(_ configuration: URLSessionConfiguration) -> Bool {
    configuration.protocolClasses?.contains { ObjectIdentifier($0) == ObjectIdentifier(ConfigurationProtocolMarker.self) } == true
}

private func expectSanitizedConfiguration(_ configuration: URLSessionConfiguration) {
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(configuration.urlCache == nil)
    #expect(configuration.httpCookieStorage == nil)
    #expect(configuration.httpShouldSetCookies == false)
    #expect(configuration.urlCredentialStorage == nil)
    #expect(configuration.connectionProxyDictionary?.isEmpty == true)
}

// A class marker only. It is never globally registered or invoked.
private final class ConfigurationProtocolMarker: URLProtocol, @unchecked Sendable {}

private enum ConfigurationInitialEvent: Sendable {
    case held
    case response(Int)
    case failure(URLError.Code)
    case finishedWithoutResponse
}

private final class ConfigurationNetworkFactory: @unchecked Sendable {
    struct Entry: @unchecked Sendable {
        let name: String
        let configuration: URLSessionConfiguration
        let operation: URLSessionStreamOperation
        let network: ConfigurationFakeNetwork
    }
    private let lock = NSLock()
    private var entries: [Entry] = []
    private let event: ConfigurationInitialEvent
    let started = ConfigurationStartSignal()

    init(event: ConfigurationInitialEvent = .response(200)) { self.event = event }

    func make(_ request: URLRequest, _ configuration: URLSessionConfiguration,
              _ operation: URLSessionStreamOperation) -> LlamaStreamNetwork {
        let network = ConfigurationFakeNetwork(operation: operation, event: event, started: started)
        let entry = Entry(name: request.url?.lastPathComponent ?? "missing", configuration: configuration,
                          operation: operation, network: network)
        lock.withLock { entries.append(entry) }
        return network.handle
    }

    func entry(_ name: String) -> Entry? { lock.withLock { entries.first { $0.name == name } } }
    func cancelAll() {
        let operations = lock.withLock { entries.map(\.operation) }
        for operation in operations { operation.cancel() }
    }
}

private final class ConfigurationFakeNetwork: @unchecked Sendable {
    private let lock = NSLock()
    private var resumes = 0
    private var cancels = 0
    private var invalidates = 0
    private let operation: URLSessionStreamOperation
    private let event: ConfigurationInitialEvent
    private let started: ConfigurationStartSignal
    init(operation: URLSessionStreamOperation, event: ConfigurationInitialEvent, started: ConfigurationStartSignal) {
        self.operation = operation; self.event = event; self.started = started
    }
    var resumeCount: Int { lock.withLock { resumes } }
    var cancelCount: Int { lock.withLock { cancels } }
    var invalidateCount: Int { lock.withLock { invalidates } }
    var handle: LlamaStreamNetwork {
        LlamaStreamNetwork(resume: { [self] in
            lock.withLock { resumes += 1 }
            started.note()
            switch event {
            case .held: break
            case .response(let status): _ = operation.receive(statusCode: status)
            case .failure(let code): operation.complete(error: URLError(code))
            case .finishedWithoutResponse: operation.complete(error: nil)
            }
        }, cancelTask: { [self] in lock.withLock { cancels += 1 } },
        invalidate: { [self] in lock.withLock { invalidates += 1 } })
    }
}

private final class ConfigurationStartSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func note() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            count += 1
            let ready = waiters.filter { count >= $0.0 }.map(\.1)
            waiters.removeAll { count >= $0.0 }
            return ready
        }
        for continuation in ready { continuation.resume() }
    }
    func wait(atLeast minimum: Int) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                if count >= minimum { return true }
                waiters.append((minimum, continuation)); return false
            }
            if ready { continuation.resume() }
        }
    }
}

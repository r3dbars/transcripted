import TranscriptedWritingCore
import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// The llama-server helper only answers the app: every launch gets a fresh
/// random key, the key reaches the helper outside argv, and every request the
/// app makes carries it.
@Suite("Llama server access key")
struct LlamaServerAccessKeyTests {
    @Test("Each rotation issues a new 32-byte random key")
    func rotationIssuesFreshKeys() throws {
        let key = LlamaServerAccessKey()
        #expect(key.current == nil)

        let first = try #require(key.rotate())
        let second = try #require(key.rotate())

        #expect(first != second)
        #expect(key.current == second)
        for issued in [first, second] {
            #expect(issued.count == LlamaServerAccessKey.byteCount * 2)
            #expect(issued.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }

    @Test("Authorizing a request adds the current key as a bearer token")
    func authorizeAddsBearerHeader() throws {
        let key = LlamaServerAccessKey()
        var bare = URLRequest(url: URL(string: "http://127.0.0.1:17891/health")!)
        key.authorize(&bare)
        #expect(bare.value(forHTTPHeaderField: "Authorization") == nil)

        let issued = try #require(key.rotate())
        var request = URLRequest(url: URL(string: "http://127.0.0.1:17891/completion")!)
        key.authorize(&request)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(issued)")
    }

    @Test("The helper gets the key in its environment, never in argv, with the web UI off")
    func launchConfigurationCarriesKeyOutsideArgv() {
        let launch = LlamaServerProcessHost.launchConfiguration(
            model: "/dev/fd/0",
            port: 17891,
            apiKey: "k3y",
            inheritedEnvironment: ["PATH": "/usr/bin", "LLAMA_API_KEY": "stale"]
        )

        #expect(launch.environment["LLAMA_API_KEY"] == "k3y")
        #expect(launch.environment["PATH"] == "/usr/bin")
        #expect(!launch.arguments.contains { $0.contains("k3y") })
        #expect(!launch.arguments.contains("--api-key"))
        #expect(launch.arguments.contains("--no-webui"))
        let host = launch.arguments.firstIndex(of: "--host").map { launch.arguments[$0 + 1] }
        #expect(host == "127.0.0.1")
    }

    @Test("A completion request carries the helper's current key")
    func completionRequestIsAuthorized() async throws {
        let key = LlamaServerAccessKey()
        let issued = try #require(key.rotate())
        let recorder = RequestRecorder()
        let engine = LlamaCompletionEngine(
            baseURL: URL(string: "http://127.0.0.1:17891")!,
            accessKey: key,
            diagnostics: .disabled,
            transport: RecordingTransport(recorder: recorder)
        )

        _ = try? await engine.suggestion(
            textBeforeCursor: "hello ",
            appBundleIdentifier: "com.apple.TextEdit",
            scene: nil
        )

        let request = try #require(recorder.requests.first)
        #expect(request.url?.path == "/completion")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(issued)")
    }

    @Test("A scaffold warm-up carries the helper's current key")
    func prewarmRequestIsAuthorized() async throws {
        let key = LlamaServerAccessKey()
        let issued = try #require(key.rotate())
        let recorder = RequestRecorder()
        let prewarmer = ScaffoldPrewarmer(
            baseURL: URL(string: "http://127.0.0.1:17891")!,
            accessKey: key,
            quietPeriod: 0,
            now: { 100 },
            perform: { request in
                recorder.record(request)
                return true
            }
        )

        prewarmer.noteFrontmostApp(bundleIdentifier: "com.apple.mail")
        prewarmer.noteHelperReady()
        await prewarmer.settle()

        let request = try #require(recorder.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(issued)")
    }

    /// Runs the real host against a stand-in helper that records the key it
    /// was given and exits at once, so the host relaunches it. Nothing here
    /// touches the real model, port 17891, or app support.
    @Test("Every helper launch gets a different key, and the key never reaches argv")
    func relaunchRotatesKey() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("llama-access-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("launches.txt")
        let helper = directory.appendingPathComponent("fake-llama-server")
        try """
        #!/bin/sh
        printf '%s|%s\\n' "$LLAMA_API_KEY" "$*" >> '\(log.path)'
        exit 1
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)

        let host = LlamaServerProcessHost(
            port: Int.random(in: 40_000...60_000),
            assetResolver: { .init(binary: helper.path, model: "/nonexistent-model") }
        )
        host.start()
        defer { host.stop() }

        var launches: [(key: String, argv: String)] = []
        for _ in 0..<300 where launches.count < 2 {
            try await Task.sleep(nanoseconds: 100_000_000)
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            launches = text.split(separator: "\n").map { line in
                let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
            }
        }
        host.stop()

        try #require(launches.count >= 2)
        #expect(launches[0].key.count == LlamaServerAccessKey.byteCount * 2)
        #expect(launches[1].key.count == LlamaServerAccessKey.byteCount * 2)
        #expect(launches[0].key != launches[1].key)
        for launch in launches {
            #expect(!launch.argv.contains(launch.key))
            #expect(launch.argv.contains("--no-webui"))
        }
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    func record(_ request: URLRequest) { lock.withLock { recorded.append(request) } }
}

private struct RecordingTransport: LlamaCompletionStreamingTransport {
    let recorder: RequestRecorder

    func open(request: URLRequest) async throws -> LlamaCompletionHTTPStream {
        recorder.record(request)
        return LlamaCompletionHTTPStream(
            statusCode: 200,
            lines: AsyncThrowingStream { continuation in
                continuation.yield(#"data: {"content":" world","stop":true}"#)
                continuation.finish()
            },
            cancel: {}
        )
    }
}

import Foundation
import Testing
@testable import TranscriptedWritingRuntime

@Suite("Runtime boundaries")
struct RuntimeBoundaryTests {
    @Test("Runtime snapshots have explicit status-menu copy")
    func statusMenuCopy() {
        #expect(LlamaRuntimeSnapshot.starting.menuLine == "Engine: Gemma (starting…)")
        #expect(LlamaRuntimeSnapshot.ready.menuLine == "Engine: Gemma (ready)")
        #expect(LlamaRuntimeSnapshot.retrying(.portInUse).menuLine == "⚠️ Engine port busy — retrying")
        #expect(LlamaRuntimeSnapshot.retrying(.launchFailed).menuLine == "⚠️ Engine couldn't start — retrying")
        #expect(LlamaRuntimeSnapshot.retrying(.healthTimeout).menuLine == "⚠️ Engine didn't become ready — retrying")
        #expect(LlamaRuntimeSnapshot.retrying(.processExited).menuLine == "⚠️ Engine stopped — retrying")
        #expect(LlamaRuntimeSnapshot.retrying(.completionFailed).menuLine == "⚠️ Engine stopped responding — retrying")
        #expect(LlamaRuntimeSnapshot.failed(.assetsMissing).menuLine == "⚠️ Engine files missing — reinstall Transcripted")
        #expect(LlamaRuntimeSnapshot.retrying(.healthTimeout).restartReasonAfterExit == .healthTimeout)
        #expect(LlamaRuntimeSnapshot.ready.restartReasonAfterExit == .processExited)
    }

    @Test("Completion failure keeps proven health for restart backoff")
    func completionFailureKeepsHealthForBackoff() {
        var policy = LlamaRestartPolicy()
        _ = policy.delay(wasHealthy: false, uptime: 1)
        _ = policy.delay(wasHealthy: false, uptime: 1)

        #expect(policy.delay(
            wasHealthy: LlamaRuntimeSnapshot.retrying(.completionFailed).wasHealthyBeforeExit,
            uptime: 120
        ) == 2)
    }

    @Test("Missing assets are a terminal failure, not endless starting")
    func missingAssetsFailTerminally() async throws {
        let runtime = LlamaServerProcessHost(port: 19_002, assetResolver: { nil })
        defer { runtime.stop() }

        runtime.start()
        for _ in 0..<100 where runtime.snapshot != .failed(.assetsMissing) {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(runtime.snapshot == .failed(.assetsMissing))
    }

    @Test("Runtime base URL uses the injected port")
    func injectedPort() {
        let runtime = LlamaServerProcessHost(port: 19_001)

        #expect(runtime.baseURL == URL(string: "http://127.0.0.1:19001"))
    }

    @Test("A child can consume the exact inherited model descriptor")
    func inheritedModelDescriptor() throws {
        let model = FileManager.default.temporaryDirectory
            .appendingPathComponent("tilde-model-fd-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: model) }
        let bytes = Data("verified model inode".utf8)
        try bytes.write(to: model)
        let input = try FileHandle(forReadingFrom: model)
        defer { try? input.close() }
        let output = Pipe()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "cat /dev/fd/0"]
        child.standardInput = input
        child.standardOutput = output
        try child.run()
        child.waitUntilExit()

        #expect(child.terminationStatus == 0)
        #expect(output.fileHandleForReading.readDataToEndOfFile() == bytes)
    }

    @Test("Localhost requests never follow redirects")
    func redirectsAreRejected() async throws {
        let local = try #require(URL(string: "http://127.0.0.1:17891/completion"))
        let remote = try #require(URL(string: "https://example.com/collect"))
        let response = try #require(HTTPURLResponse(
            url: local,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": remote.absoluteString]
        ))
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: local)
        defer { session.invalidateAndCancel() }

        let redirected = await withCheckedContinuation { continuation in
            LocalhostURLSessionDelegate().urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: remote)
            ) { continuation.resume(returning: $0) }
        }

        #expect(redirected == nil)
        #expect(LocalhostURLSession.shared.delegate is LocalhostURLSessionDelegate)
    }

    @Test("Exact child shutdown is bounded and synchronous")
    func childShutdownIsBounded() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()

        let started = ContinuousClock.now
        LlamaServerProcessHost.shutDownNow(child)

        #expect(!child.isRunning)
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}

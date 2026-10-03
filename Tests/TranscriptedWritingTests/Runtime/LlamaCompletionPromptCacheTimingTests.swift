import TranscriptedWritingCore
import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// The completion request asks llama-server for per-token timings so the
/// timing log can say how much of the prompt the slot reused. That read is
/// diagnostics only: whatever the `timings` object looks like, the decision
/// the writer sees must be the same, and a bad one must never fail the stream.
@Suite("Llama completion prompt-cache timing")
struct LlamaCompletionPromptCacheTimingTests {
    private static let baseURL = URL(string: "http://127.0.0.1:17891")!

    private static func frames(firstContent: String) -> [String] {
        [
            "data: \(firstContent)",
            #"data: {"content":" good "}"#,
            #"data: {"stop":true,"tokens_predicted":2,"stopped_word":true}"#,
        ]
    }

    private static let variants: [(name: String, firstContent: String)] = [
        ("no timings", #"{"content":" pretty"}"#),
        ("valid timings", #"{"content":" pretty","timings":{"cache_n":276,"prompt_n":5,"prompt_ms":3.1}}"#),
        ("string cache_n", #"{"content":" pretty","timings":{"cache_n":"lots","prompt_n":5}}"#),
        ("missing keys", #"{"content":" pretty","timings":{}}"#),
        ("timings not an object", #"{"content":" pretty","timings":"soon"}"#),
    ]

    private func decide(lines: [String], diagnostics: DiagnosticsLog = .disabled) async throws -> LlamaCompletionEngine.Decision {
        let engine = LlamaCompletionEngine(
            baseURL: Self.baseURL,
            diagnostics: diagnostics,
            transport: RecordingFrameTransport(lines: lines, recorder: RequestRecorder())
        )
        return try await engine.decide(
            textBeforeCursor: "That was ",
            appBundleIdentifier: "com.apple.TextEdit",
            scene: nil,
            onPartialSuggestion: { _, _ in }
        )
    }

    @Test("Frames with no, valid or malformed timings give the same decision")
    func timingsNeverChangeTheDecision() async throws {
        let baseline = try await decide(lines: Self.frames(firstContent: Self.variants[0].firstContent))
        #expect(baseline.reason == .shown)
        for variant in Self.variants.dropFirst() {
            let decision = try await decide(lines: Self.frames(firstContent: variant.firstContent))
            #expect(decision.suggestion == baseline.suggestion, "\(variant.name)")
            #expect(decision.reason == baseline.reason, "\(variant.name)")
            #expect(decision.generated == baseline.generated, "\(variant.name)")
        }
    }

    @Test("The request asks for per-token timings and keeps prompt caching on")
    func requestAsksForTimings() async throws {
        let recorder = RequestRecorder()
        let engine = LlamaCompletionEngine(
            baseURL: Self.baseURL,
            diagnostics: .disabled,
            transport: RecordingFrameTransport(
                lines: Self.frames(firstContent: Self.variants[0].firstContent),
                recorder: recorder
            )
        )
        _ = try await engine.decide(
            textBeforeCursor: "That was ",
            appBundleIdentifier: "com.apple.TextEdit",
            scene: nil,
            onPartialSuggestion: { _, _ in }
        )
        let data = try #require(recorder.lastBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["timings_per_token"] as? Bool == true)
        #expect(body["cache_prompt"] as? Bool == true)
        #expect(body["stream"] as? Bool == true)
    }

    @Test("Valid timings log as counts; malformed ones log nothing")
    func timingLogCarriesCountsOnly() async throws {
        let valid = try await timingLine(firstContent: Self.variants[1].firstContent)
        #expect(valid.contains("cache_n=276"))
        #expect(valid.contains("prompt_n=5"))

        let malformed = try await timingLine(firstContent: Self.variants[2].firstContent)
        #expect(malformed.contains("llama-completion-timing"))
        #expect(!malformed.contains("cache_n"))
        #expect(!malformed.contains("prompt_n"))
    }

    private func timingLine(firstContent: String) async throws -> String {
        let directory = Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("writing-diagnostics.log")
        let log = DiagnosticsLog(logURL: logURL)
        _ = try await decide(lines: Self.frames(firstContent: firstContent), diagnostics: log)
        log.flush()
        let contents = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return contents
            .split(separator: "\n")
            .first { $0.contains("llama-completion-timing") }
            .map(String.init) ?? ""
    }

    /// The log refuses symlinked path components and the temp directory
    /// lives under `/var`, which is one; hand it the real path.
    private static func makeDirectory() -> URL {
        let temporary = FileManager.default.temporaryDirectory.path
        let real = realpath(temporary, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? temporary
        return URL(fileURLWithPath: real, isDirectory: true)
            .appendingPathComponent("writing-prompt-cache-timing-\(UUID().uuidString)", isDirectory: true)
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var body: Data?
    var lastBody: Data? { lock.withLock { body } }
    func record(_ request: URLRequest) { lock.withLock { body = request.httpBody } }
}

private struct RecordingFrameTransport: LlamaCompletionStreamingTransport {
    let lines: [String]
    let recorder: RequestRecorder

    func open(request: URLRequest) async throws -> LlamaCompletionHTTPStream {
        recorder.record(request)
        return LlamaCompletionHTTPStream(
            statusCode: 200,
            lines: AsyncThrowingStream { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish()
            },
            cancel: {}
        )
    }
}

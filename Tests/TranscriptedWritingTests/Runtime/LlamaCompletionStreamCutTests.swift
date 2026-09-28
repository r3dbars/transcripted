import TranscriptedWritingCore
import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// The engine stops reading the helper's stream once the display cap has
/// settled the visible text. Nothing the writer sees may change: the final
/// suggestion must equal what the full stream would have produced.
@Suite("Llama completion stream cut at the visible cap")
struct LlamaCompletionStreamCutTests {
    @Test("The stream is cancelled one word past the three-word cap")
    func streamIsCutPastTheCap() async throws {
        let transport = CountingTransport(lines: [
            #"data: {"content":" sounds"}"#,
            #"data: {"content":" really"}"#,
            #"data: {"content":" good"}"#,
            #"data: {"content":" today"}"#,
            #"data: {"content":" and"}"#,
            #"data: {"content":" tomorrow"}"#,
            #"data: {"content":" too"}"#,
            #"data: {"stop":true,"tokens_predicted":7,"stopped_limit":true}"#,
        ])
        let engine = LlamaCompletionEngine(
            baseURL: URL(string: "http://127.0.0.1:17875")!,
            diagnostics: .disabled,
            transport: transport,
            productProfile: .preview9B
        )

        let suggestion = try await engine.suggestion(
            textBeforeCursor: "That ",
            appBundleIdentifier: "com.apple.TextEdit",
            scene: nil
        )
        #expect(suggestion?.visibleText == "sounds really good")
        #expect(transport.wasCancelled)
        // Four content frames settle a three-word cap; the tail is never read.
        #expect(transport.linesRead == 4)
    }

    @Test("Cutting the stream leaves the visible text identical to the full stream")
    func cutMatchesFullStream() async throws {
        let cases: [(context: String, words: [String])] = [
            ("Thanks, I will ", ["see", "you", "tomorrow", "at", "the", "office"]),
            ("Thanks, I will ", ["see", "you", "at", "the", "park", "later"]),
            ("Let's meet ", ["at", "10:30", "tomorrow", "morning", "if", "that", "works"]),
            ("That ", ["sounds", "really", "good", "today", "and", "tomorrow"]),
            ("Sure, ", ["happy", "to", "help", "with", "that", "later"]),
        ]
        for testCase in cases {
            let frames = testCase.words.map { #"data: {"content":" \#($0)"}"# }
                + [#"data: {"stop":true,"tokens_predicted":\#(testCase.words.count),"stopped_limit":true}"#]
            let streamed = CountingTransport(lines: frames)
            let engine = LlamaCompletionEngine(
                baseURL: URL(string: "http://127.0.0.1:17875")!,
                diagnostics: .disabled,
                transport: streamed,
                productProfile: .preview9B
            )
            let final = try await engine.suggestion(
                textBeforeCursor: testCase.context,
                appBundleIdentifier: "com.apple.TextEdit",
                scene: nil
            )

            // The reference: the same raw text through the same final pass a
            // stream that ran to the helper's stop frame would take —
            // normalize, clean, cap, then the profile's grounding gate.
            let recipe = RawContinuationPrompt(textBeforeCursor: testCase.context, register: .prose)
            let profile = TildeProductProfile.preview9B
            let cleaner = CompletionOutputCleaner(maxVisibleWords: profile.maximumVisibleWords)
            let raw = testCase.words.map { " " + $0 }.joined()
            var reference = cleaner.cleanWithReason(recipe.normalizedContinuation(raw), after: testCase.context).suggestion
            if let candidate = reference, FactualGroundingPolicy.containsUnsupportedFact(
                candidate.visibleText,
                typedContext: testCase.context,
                scene: nil,
                mode: profile.factualGrounding
            ) {
                reference = nil
            }

            #expect(final?.visibleText == reference?.visibleText, "\(testCase.words)")
            #expect(streamed.wasCancelled, "\(testCase.words)")
        }
    }

    @Test("A short completion runs to the helper's stop frame")
    func shortCompletionIsNotCut() async throws {
        let transport = CountingTransport(lines: [
            #"data: {"content":" sounds"}"#,
            #"data: {"content":" good"}"#,
            #"data: {"stop":true,"tokens_predicted":2,"stopped_eos":true}"#,
        ])
        let engine = LlamaCompletionEngine(
            baseURL: URL(string: "http://127.0.0.1:17875")!,
            diagnostics: .disabled,
            transport: transport,
            productProfile: .preview9B
        )
        let suggestion = try await engine.suggestion(
            textBeforeCursor: "That ",
            appBundleIdentifier: "com.apple.TextEdit",
            scene: nil
        )
        #expect(suggestion?.visibleText == "sounds good")
        #expect(!transport.wasCancelled)
        #expect(transport.linesRead == 3)
    }

    @Test("Partials before the cut are unchanged and the final adds the last capped word")
    func partialsThenFinal() async throws {
        // "pretty", not "really": the dangling-tail repair strips "really"
        // from a partial that ends on it, which is pre-existing behavior this
        // test is not about.
        let transport = CountingTransport(lines: [
            #"data: {"content":" sounds"}"#,
            #"data: {"content":" pretty"}"#,
            #"data: {"content":" good"}"#,
            #"data: {"content":" today"}"#,
            #"data: {"content":" and"}"#,
            #"data: {"stop":true,"tokens_predicted":5,"stopped_limit":true}"#,
        ])
        let engine = LlamaCompletionEngine(
            baseURL: URL(string: "http://127.0.0.1:17875")!,
            diagnostics: .disabled,
            transport: transport,
            productProfile: .preview9B
        )
        let partials = Collected()
        let final = try await engine.suggestion(
            textBeforeCursor: "That ",
            appBundleIdentifier: "com.apple.TextEdit",
            scene: nil,
            onPartialSuggestion: { partial, _ in partials.append(partial.visibleText) }
        )
        #expect(partials.values == ["sounds", "sounds pretty"])
        #expect(final?.visibleText == "sounds pretty good")
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ value: String) { lock.withLock { stored.append(value) } }
}

/// Hands out one frame per pull, so `linesRead` counts what the engine
/// actually consumed rather than what a buffered producer pushed ahead.
private final class CountingTransport: LlamaCompletionStreamingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let lines: [String]
    private var read = 0
    private var cancelled = false

    init(lines: [String]) { self.lines = lines }

    var linesRead: Int { lock.withLock { read } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    func open(request: URLRequest) async throws -> LlamaCompletionHTTPStream {
        LlamaCompletionHTTPStream(
            statusCode: 200,
            lines: AsyncThrowingStream(unfolding: { [self] in
                lock.withLock {
                    guard read < lines.count else { return nil }
                    defer { read += 1 }
                    return lines[read]
                }
            }),
            cancel: { [self] in lock.withLock { cancelled = true } }
        )
    }
}

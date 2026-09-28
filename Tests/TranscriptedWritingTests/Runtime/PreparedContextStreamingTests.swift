import TranscriptedWritingCore
import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// A streamed request now prepares its context once and hands the same
/// prepared form to every partial and to the final pass. What the writer
/// sees must be exactly what the per-call path produced, partial by partial
/// — including the partials the echo and grounding checks withhold.
///
/// The expected sequences below were recorded from the pre-refactor engine.
@Suite("Prepared context streaming equivalence")
struct PreparedContextStreamingTests {
    private static let scene = ScreenScene.Scene(
        mode: .replying,
        conversationTurns: [
            .init(speaker: .other, text: "can you confirm the deck is ready for review?"),
            .init(speaker: .other, text: "I can join the call at 9am if that helps"),
        ],
        referenceSnippets: ["room 204 is booked for the workshop with Dana"]
    )

    /// One llama.cpp token per frame, the shape that drives a partial per
    /// complete word.
    private static func frames(_ tokens: [String]) -> [String] {
        tokens.map { #"data: {"content":"\#($0)"}"# }
            + [#"data: {"stop":true,"tokens_predicted":\#(tokens.count),"stopped_eos":true}"#]
    }

    private func run(
        profile: TildeProductProfile,
        tokens: [String],
        context: String,
        scene: ScreenScene.Scene?
    ) async throws -> (partials: [String], final: String?, reason: SuggestionDecisionReason) {
        let engine = LlamaCompletionEngine(
            baseURL: URL(string: "http://127.0.0.1:17891")!,
            diagnostics: .disabled,
            transport: OneTokenPerFrameTransport(lines: Self.frames(tokens)),
            productProfile: profile
        )
        let collector = PartialCollector()
        let decision = try await engine.decide(
            textBeforeCursor: context,
            appBundleIdentifier: "com.apple.TextEdit",
            scene: scene,
            onPartialSuggestion: { partial, _ in collector.append(partial.visibleText) }
        )
        return (collector.texts, decision.suggestion?.visibleText, decision.reason)
    }

    @Test("Production: every partial and the final match the recorded per-call sequence")
    func productionSequenceIsUnchanged() async throws {
        let result = try await run(
            profile: .production,
            tokens: [" we", " will", " head", " out", " after", " the", " last", " one"],
            context: "Thanks, I think ",
            scene: Self.scene
        )
        #expect(result.partials == [
            "we",
            "we will head",
            "we will head out",
            "we will head out after",
            "we will head out after the last",
        ])
        #expect(result.final == "we will head out after the last one")
        #expect(result.reason == .shown)
    }

    @Test("The typed-prefix echo trim behaves the same across every partial")
    func prefixTrimIsUnchangedAcrossPartials() async throws {
        // The live 2705 bug shape: the model re-types the tail of what is
        // already on screen. The trim depends only on the typed context, so
        // preparing it once must not move where the trim lands.
        let result = try await run(
            profile: .production,
            tokens: [" I", " will", " try", " to", " get", " back", " to", " you"],
            context: "Sure, I will ",
            scene: nil
        )
        #expect(result.partials == [
            "try",
            "try to get",
            "try to get back",
        ])
        #expect(result.final == "try to get back to you")
    }

    @Test("The 9B profile withholds an unsupported fact at the partial and at the final")
    func groundedProfileWithholdsAcrossPartials() async throws {
        let result = try await run(
            profile: .preview9B,
            tokens: [" arrive", " at", " 5pm", " sharp"],
            context: "The meeting is at 4pm and I'll ",
            scene: Self.scene
        )
        #expect(result.partials == ["arrive"])
        #expect(result.final == nil)
        #expect(result.reason == .unsupportedFact)
    }

    @Test("A scene echo is withheld at the partial and at the final")
    func sceneEchoIsWithheldAcrossPartials() async throws {
        let result = try await run(
            profile: .production,
            tokens: [" the", " deck", " is", " ready", " for", " review"],
            context: "I think ",
            scene: Self.scene
        )
        #expect(result.partials == ["the"])
        #expect(result.final == nil)
        #expect(result.reason == .sceneEcho)
    }
}

/// Collects partial visible texts in arrival order. `onPartialSuggestion`
/// runs inside the stream loop on this test's task, one call at a time.
private final class PartialCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ text: String) {
        lock.lock()
        storage.append(text)
        lock.unlock()
    }

    var texts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct OneTokenPerFrameTransport: LlamaCompletionStreamingTransport {
    let lines: [String]

    func open(request: URLRequest) async throws -> LlamaCompletionHTTPStream {
        LlamaCompletionHTTPStream(
            statusCode: 200,
            lines: AsyncThrowingStream { continuation in
                for line in lines { continuation.yield(line) }
                continuation.finish()
            },
            cancel: {}
        )
    }
}

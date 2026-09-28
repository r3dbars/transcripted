import TranscriptedWritingCore
import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// Q12 nominated a wider scene-echo character floor and names-and-numbers
/// factual grounding as frozen validation candidates. Both are live in the
/// isolated "Tilde 9B Preview" identity only. These cases pin the isolation:
/// production and Model Preview must decide exactly what they decided
/// before, on the same input, through the same engine.
@Suite("Profile-derived display filters")
struct ProfileDisplayFilterTests {
    private static let scene = ScreenScene.Scene(
        mode: .replying,
        conversationTurns: [
            .init(speaker: .other, text: "can you confirm the deck is ready for review?"),
        ],
        referenceSnippets: []
    )

    private func engine(
        _ profile: TildeProductProfile,
        _ lines: [String]
    ) -> LlamaCompletionEngine {
        LlamaCompletionEngine(
            baseURL: URL(string: "http://127.0.0.1:17891")!,
            diagnostics: .disabled,
            transport: FrameTransport(lines: lines),
            productProfile: profile
        )
    }

    private static let echoFrames = [
        #"data: {"content":" the deck is ready"}"#,
        #"data: {"stop":true,"tokens_predicted":4,"stopped_eos":true}"#,
    ]

    private static let inventedFactFrames = [
        #"data: {"content":" arrive at 5pm"}"#,
        #"data: {"stop":true,"tokens_predicted":3,"stopped_eos":true}"#,
    ]

    @Test("Shipping profiles still reject a short scene echo at the 10-character floor")
    func shippingProfilesKeepTheNarrowEchoFloor() async throws {
        for profile in [TildeProductProfile.production] {
            let suggestion = try await engine(profile, Self.echoFrames).suggestion(
                textBeforeCursor: "I think ",
                appBundleIdentifier: "com.apple.TextEdit",
                scene: Self.scene
            )
            #expect(suggestion == nil, "\(profile.rawValue) must keep rejecting this echo")
        }
    }

    @Test("The 9B preview shows the short overlap its wider floor permits")
    func preview9BUsesTheWiderEchoFloor() async throws {
        let suggestion = try await engine(.preview9B, Self.echoFrames).suggestion(
            textBeforeCursor: "I think ",
            appBundleIdentifier: "com.apple.TextEdit",
            scene: Self.scene
        )
        #expect(suggestion?.visibleText.isEmpty == false)
    }

    @Test("Shipping profiles do not ground: an invented time is still shown")
    func shippingProfilesDoNotGround() async throws {
        for profile in [TildeProductProfile.production] {
            let suggestion = try await engine(profile, Self.inventedFactFrames).suggestion(
                textBeforeCursor: "The meeting is at 4pm and I'll ",
                appBundleIdentifier: "com.apple.TextEdit",
                scene: nil
            )
            #expect(
                suggestion?.visibleText.contains("5pm") == true,
                "\(profile.rawValue) must behave exactly as before"
            )
        }
    }

    @Test("The 9B preview falls silent on an unsupported fact")
    func preview9BGroundsAndFailsClosed() async throws {
        let suggestion = try await engine(.preview9B, Self.inventedFactFrames).suggestion(
            textBeforeCursor: "The meeting is at 4pm and I'll ",
            appBundleIdentifier: "com.apple.TextEdit",
            scene: nil
        )
        #expect(suggestion == nil)
    }

    @Test("A grounded fact still reaches the 9B preview")
    func preview9BShowsGroundedFacts() async throws {
        let suggestion = try await engine(.preview9B, [
            #"data: {"content":" arrive at 4pm"}"#,
            #"data: {"stop":true,"tokens_predicted":3,"stopped_eos":true}"#,
        ]).suggestion(
            textBeforeCursor: "The meeting is at 4pm and I'll ",
            appBundleIdentifier: "com.apple.TextEdit",
            scene: nil
        )
        #expect(suggestion?.visibleText.contains("4pm") == true)
    }

    @Test("The 9B preview never streams an ungrounded partial")
    func preview9BPartialsAreGroundedToo() async throws {
        let partials = VisibleTextCollector()
        _ = try await engine(.preview9B, [
            #"data: {"content":" arrive"}"#,
            #"data: {"content":" at"}"#,
            #"data: {"content":" 5pm"}"#,
            #"data: {"content":" sharp "}"#,
            #"data: {"stop":true,"tokens_predicted":4,"stopped_eos":true}"#,
        ]).suggestion(
            textBeforeCursor: "The meeting is at 4pm and I'll ",
            appBundleIdentifier: "com.apple.TextEdit",
            scene: nil,
            onPartialSuggestion: { partial, _ in partials.append(partial.visibleText) }
        )
        #expect(!partials.values.contains { $0.contains("5pm") })
    }
}

private final class VisibleTextCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ value: String) { lock.withLock { stored.append(value) } }
}

private struct FrameTransport: LlamaCompletionStreamingTransport {
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

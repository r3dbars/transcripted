import Foundation
import Testing
@testable import TranscriptedWritingRuntime
@testable import TranscriptedWritingCore

/// Streaming must survive personalization. `PartialResponseSink` used to be
/// constructed disabled whenever "Personal suggestions (experimental)" was on,
/// so turning the toggle on silently cost every request its word-by-word
/// ghost. These tests drive the gate directly — `write` is injected, so no
/// socket, no llama helper, and no `PersonalHistoryController` are involved.
@Suite("Personal streaming gate")
struct GhostBrainServerHostStreamingGateTests {
    private final class Writer: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        private var failing = false

        var written: [String] { lock.withLock { storage } }

        func fail() { lock.withLock { failing = true } }

        var write: @Sendable (GhostBrainResponse) -> Bool {
            { [self] response in
                lock.lock()
                defer { lock.unlock() }
                guard !failing else { return false }
                storage.append(response.suggestion ?? "")
                return true
            }
        }
    }

    private func makeSink(
        writer: Writer,
        enabled: Bool = true,
        holdingForPersonal: Bool,
        holdNanoseconds: UInt64 = 60_000_000_000
    ) -> GhostBrainServerHost.PartialResponseSink {
        GhostBrainServerHost.PartialResponseSink(
            enabled: enabled,
            holdingForPersonal: holdingForPersonal,
            register: .prose,
            holdDeadlineNanoseconds: holdNanoseconds,
            targetIsCurrent: { true },
            write: writer.write
        )
    }

    private let replacement = PersonalNextWordPrediction(word: "tomorrow", support: 4, total: 4)

    @Test("Personal suggestions off: every stable prefix streams, with no hold")
    func personalOffStreams() {
        let writer = Writer()
        let sink = makeSink(writer: writer, holdingForPersonal: false)

        sink.send(CompletionSuggestion(text: "meet you "))
        sink.send(CompletionSuggestion(text: "meet you tonight "))

        #expect(writer.written == ["meet you", "meet you tonight"])
        #expect(sink.didStream)
        #expect(sink.holdDiagnostics()["outcome"] == "not-held")
        #expect(sink.holdDiagnostics()["heldMilliseconds"] == "0")
    }

    @Test("A peer that did not ask for streaming still receives no partials")
    func unstreamedPeerGetsNothing() {
        let writer = Writer()
        let sink = makeSink(writer: writer, enabled: false, holdingForPersonal: true)

        sink.send(CompletionSuggestion(text: "meet you "))
        sink.resolvePersonal(nil)

        #expect(writer.written.isEmpty)
        #expect(!sink.didStream)
        #expect(sink.holdDiagnostics()["outcome"] == "not-held")
    }

    @Test("Personal on, late answer: the first prefix is held, then the window releases it")
    func personalOnWithLateAnswerStreams() async {
        let writer = Writer()
        let sink = makeSink(writer: writer, holdingForPersonal: true, holdNanoseconds: 2_000_000)

        sink.send(CompletionSuggestion(text: "afternoon works "))
        // Held: the personal lookup has not answered, and its answer could
        // still have replaced this ghost's first word.
        #expect(writer.written.isEmpty)

        for _ in 0..<500 where writer.written.isEmpty {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(writer.written == ["afternoon works"])
        #expect(sink.didStream)
        #expect(sink.holdDiagnostics()["outcome"] == "expired")

        // Streaming continues normally once released.
        sink.send(CompletionSuggestion(text: "afternoon works great "))
        #expect(writer.written == ["afternoon works", "afternoon works great"])

        // The late answer arrives after the prefix is on screen: the
        // terminal line must honour the base ghost, never rewrite it.
        sink.resolvePersonal(replacement)
        let final = PersonalSuggestionPolicy.finalSuggestion(
            baseGhost: "afternoon works great",
            personalPrediction: replacement,
            streamedPrefix: sink.didStream
        )
        #expect(final.text == "afternoon works great")
        #expect(final.source == .base)
        #expect(writer.written == ["afternoon works", "afternoon works great"])
    }

    @Test("Personal on, fast replacement: nothing is shown and the request goes final-only")
    func personalOnWithFastReplacementIsFinalOnly() {
        let writer = Writer()
        let sink = makeSink(writer: writer, holdingForPersonal: true)

        sink.send(CompletionSuggestion(text: "afternoon works "))
        #expect(writer.written.isEmpty)
        sink.resolvePersonal(replacement)

        #expect(writer.written.isEmpty)
        #expect(!sink.didStream)
        #expect(sink.holdDiagnostics()["outcome"] == "final-only")

        // Later prefixes from the same generation stay suppressed.
        sink.send(CompletionSuggestion(text: "afternoon works great "))
        #expect(writer.written.isEmpty)

        let final = PersonalSuggestionPolicy.finalSuggestion(
            baseGhost: "afternoon works great",
            personalPrediction: replacement,
            streamedPrefix: sink.didStream
        )
        #expect(final.text == "tomorrow")
        #expect(final.source == .personal)
    }

    @Test("Personal on, agreement: the held prefix is released and streaming resumes")
    func personalOnWithAgreementStreams() {
        let writer = Writer()
        let sink = makeSink(writer: writer, holdingForPersonal: true)

        sink.send(CompletionSuggestion(text: "Tomorrow works "))
        #expect(writer.written.isEmpty)
        sink.resolvePersonal(replacement)

        #expect(writer.written == ["Tomorrow works"])
        #expect(sink.didStream)
        #expect(sink.holdDiagnostics()["outcome"] == "streamed")
        sink.send(CompletionSuggestion(text: "Tomorrow works great "))
        #expect(writer.written == ["Tomorrow works", "Tomorrow works great"])

        let final = PersonalSuggestionPolicy.finalSuggestion(
            baseGhost: "Tomorrow works great",
            personalPrediction: replacement,
            streamedPrefix: sink.didStream
        )
        #expect(final.text == "Tomorrow works great")
        #expect(final.source == .agreed)
    }

    @Test("Personal on, empty answer before the first prefix: nothing is ever held")
    func personalOnResolvingEmptyNeverHolds() {
        let writer = Writer()
        let sink = makeSink(writer: writer, holdingForPersonal: true)

        sink.resolvePersonal(nil)
        sink.send(CompletionSuggestion(text: "meet you "))

        #expect(writer.written == ["meet you"])
        #expect(sink.holdDiagnostics()["outcome"] == "not-held")
        #expect(sink.holdDiagnostics()["heldMilliseconds"] == "0")
    }

    @Test("Only the newest held prefix is released, and only before the terminal line")
    func finishSuppressesAHeldPrefix() {
        let writer = Writer()
        let sink = makeSink(writer: writer, holdingForPersonal: true)

        sink.send(CompletionSuggestion(text: "meet you "))
        sink.send(CompletionSuggestion(text: "meet you at "))
        #expect(writer.written.isEmpty)
        // The generator finished while the gate was still holding: the
        // terminal line is next, so the held prefix must never be flushed.
        sink.finish()
        sink.expireHold()
        sink.resolvePersonal(nil)

        #expect(writer.written.isEmpty)
        #expect(!sink.didStream)
    }

    @Test("A failed partial write reports once and stops the stream")
    func writeFailureCancelsOnce() {
        let writer = Writer()
        let sink = makeSink(writer: writer, holdingForPersonal: false)
        let failures = Counter()
        sink.onWriteFailure = { failures.increment() }
        writer.fail()

        sink.send(CompletionSuggestion(text: "meet you "))
        sink.send(CompletionSuggestion(text: "meet you at "))

        #expect(failures.value == 1)
        #expect(!sink.didStream)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}

@Suite("Personal stream hold diagnostics")
struct PersonalStreamHoldDiagnosticsTests {
    @Test("Every hold outcome and the held duration print literally instead of as a redacted length")
    func holdOutcomesSurviveTheRedactor() {
        for outcome in GhostBrainServerHost.PartialResponseSink.HoldOutcome.allCases {
            #expect(
                DiagnosticsMetadataRedactor.logSafeField(forKey: "outcome", value: outcome.rawValue)
                    == "outcome=\(outcome.rawValue)"
            )
        }
        #expect(DiagnosticsMetadataRedactor.logSafeField(forKey: "heldMilliseconds", value: "42") == "heldMilliseconds=42")
        for reason in ["permissions", "size", "header", "authentication", "schema", "read"] {
            #expect(DiagnosticsMetadataRedactor.logSafeField(forKey: "reason", value: reason) == "reason=\(reason)")
        }
    }
}

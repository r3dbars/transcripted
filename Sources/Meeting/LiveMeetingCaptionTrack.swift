import Foundation

/// The model boundary. Tests hold individual operations open to prove
/// ownership and cleanup without loading models or opening audio devices.
protocol LiveMeetingCaptionRecognizing: Sendable {
    func loadModels() async throws
    func process(_ samples: [Float]) async throws
    func partialTranscript() async -> String
    func endOfUtteranceDetected() async -> Bool
    func reset() async
    func cleanup() async
}

/// Drives one FluidAudio streaming Parakeet EOU recognizer for one capture
/// track. One per track: the recognizer holds a single decoder and endpoint
/// state, so mixing mic and call audio would corrupt both.
///
/// Partials are read after each feed rather than through FluidAudio's
/// callbacks, so a partial can never land after the utterance it belongs to
/// was committed.
actor LiveMeetingCaptionTrack {
    enum Event: Equatable, Sendable {
        /// The utterance in progress so far; the decoder may still rewrite it.
        case partial(String)
        /// A finished utterance.
        case utterance(String)
    }

    enum LoadResult: Equatable, Sendable {
        case ready
        case failed
    }

    /// The decoder's own endpointing can go quiet mid-utterance and never
    /// fire, freezing on stale text. A turn also closes after this long with
    /// no new words, or once it has run this long. FluidVoice ships the same
    /// two fallbacks.
    static let quietCloseSeconds: Double = 2.5
    static let longestUtteranceSeconds: Double = 20
    /// One encoder step per feed, so a yield (a dictation's final pass
    /// starting) waits behind at most one chunk, never a second of them.
    private let feedSamples: Int
    /// Zeros pushed through before a reset so the audio still sitting in the
    /// recognizer's buffer (up to one chunk) is decoded, not dropped.
    private let flushSamples: Int

    nonisolated let queue = LiveMeetingCaptionSampleQueue()
    /// `eouDebounceMs: 0` closes at the end-of-utterance token itself.
    /// FluidAudio's default waits ~1.3 s to confirm it, and its decoder skips
    /// every chunk in that window, so speech resuming after a short pause was
    /// never decoded.
    private let manager: any LiveMeetingCaptionRecognizing
    private var onEvent: (@Sendable (Event, Int) async -> Void)?
    private var eventSequence = 0
    private var shouldYield: (@Sendable () async -> Bool)?
    private var drainTask: Task<Void, Never>?
    private var lastPartial = ""
    private var lastPartialAt: TimeInterval?
    private var utteranceSamples = 0
    private var needsReset = false

    private let onFailure: @Sendable (String, String) -> Void

    init(recognizer: any LiveMeetingCaptionRecognizing, feedSamples: Int = 5_120,
         flushSamples: Int = 10_080, onFailure: @escaping @Sendable (String, String) -> Void = { _, _ in }) {
        precondition(feedSamples > 0 && flushSamples > 0)
        manager = recognizer
        self.feedSamples = feedSamples
        self.flushSamples = flushSamples
        self.onFailure = onFailure
    }

    /// Downloads (first time only) and loads the model, then pays CoreML's
    /// first-inference cost on a second of silence so it doesn't back up
    /// real audio.
    /// `beforeWarmup` runs between loading and the warmup inference, so a
    /// caller can hold the Neural Engine work off while something else needs
    /// it.
    func load(beforeWarmup: (@Sendable () async -> Void)? = nil) async -> LoadResult {
        do {
            try await manager.loadModels()
            // Stopped while loading: don't keep the models until next time.
            if Task.isCancelled {
                await manager.cleanup()
                return .failed
            }
        } catch {
            // A later model may fail after the encoder was assigned. The
            // app-lifetime dictation track must not retain that partial load.
            await manager.cleanup()
            onFailure("Live transcript model failed to load", String(describing: type(of: error)))
            return .failed
        }
        await beforeWarmup?()
        guard !Task.isCancelled else {
            await manager.cleanup()
            return .failed
        }
        try? await manager.process([Float](repeating: 0, count: 16_000))
        await manager.reset()
        needsReset = false
        return .ready
    }

    func start(
        shouldYield: @escaping @Sendable () async -> Bool,
        onEvent: @escaping @Sendable (Event, Int) async -> Void
    ) {
        self.onEvent = onEvent
        self.shouldYield = shouldYield
        drainTask?.cancel()
        // Utility: the live transcript must never compete with dictation or
        // the UI at user-initiated priority.
        drainTask = Task(priority: .utility) { [weak self] in await self?.drain() }
    }

    /// Stops feeding and frees the model. Words still being heard are
    /// dropped; the saved transcript covers them.
    func stop() async {
        onEvent = nil
        shouldYield = nil
        drainTask?.cancel()
        await drainTask?.value
        drainTask = nil
        queue.removeAll()
        lastPartial = ""
        lastPartialAt = nil
        utteranceSamples = 0
        await manager.cleanup()
    }

    /// Stops feeding, but keeps the model loaded for the next `start`.
    /// The dictation preview's track lives for
    /// the whole app session this way. The queue is left alone: the caller
    /// clears it when the take ends, and the next take may already be
    /// filling it.
    func pause() async {
        onEvent = nil
        shouldYield = nil
        drainTask?.cancel()
        await drainTask?.value
        drainTask = nil
        lastPartial = ""
        lastPartialAt = nil
        utteranceSamples = 0
        // Reset allocates model caches. Wait until the next take has the
        // inference slot instead of guessing when this take's final pass ends.
        needsReset = true
    }

    /// An awaited flush may outlive the feed's initial admission check.
    /// Recheck before each inference/reset and preserve its remaining tail
    /// while a dictation owns the compute path. Cancellation abandons only
    /// provisional work; the recording's final transcript is independent.
    private func waitForInferencePermission() async -> Bool {
        while !Task.isCancelled {
            if await shouldYield?() != true { return !Task.isCancelled }
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return false }
        }
        return false
    }

    private func drain() async {
        while !Task.isCancelled {
            guard await waitForInferencePermission() else { return }
            if needsReset {
                await manager.reset()
                needsReset = false
                continue
            }
            guard queue.count >= feedSamples else {
                await closeIfQuiet()
                try? await Task.sleep(for: .milliseconds(120))
                continue
            }
            let (samples, overflowed) = queue.take(limit: feedSamples)
            if overflowed {
                await closeUtterance()
            }
            await feed(samples)
        }
    }

    private func feed(_ samples: [Float]) async {
        guard await waitForInferencePermission() else { return }
        do {
            try await manager.process(samples)
        } catch {
            onFailure("Live transcript feed failed", String(describing: type(of: error)))
            // FluidAudio only shifts its buffer after a successful prediction.
            // Do not append a flush to failed input: it could run several steps
            // in one call. Keep the words already heard and reset under the gate.
            await commitUtterance()
            return
        }
        // The 20 s ceiling counts from the first words, not the silence before.
        if lastPartial.isEmpty { utteranceSamples = 0 }
        utteranceSamples += samples.count
        let partial = await manager.partialTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
        if await manager.endOfUtteranceDetected() {
            lastPartial = partial
            await closeUtterance()
            return
        }
        if partial != lastPartial {
            lastPartial = partial
            lastPartialAt = ProcessInfo.processInfo.systemUptime
            if !partial.isEmpty { await emit(.partial(partial)) }
        }
        if !lastPartial.isEmpty, Double(utteranceSamples) / 16_000 > Self.longestUtteranceSeconds {
            await closeUtterance()
        } else {
            await closeIfQuiet()
        }
    }

    private func closeIfQuiet() async {
        guard !lastPartial.isEmpty, let lastPartialAt,
              ProcessInfo.processInfo.systemUptime - lastPartialAt > Self.quietCloseSeconds else { return }
        await closeUtterance()
    }

    /// Commits what was heard and starts the decoder fresh for the next turn.
    /// The audio still buffered in the recognizer is decoded first (pushed
    /// through with a chunk of silence); a bare reset would drop it.
    private func closeUtterance() async {
        // A full 630 ms flush can run two encoder steps. Submit at most one
        // shift at a time so final transcription can claim priority between them.
        var remaining = flushSamples
        do {
            while remaining > 0 {
                guard await waitForInferencePermission() else { return }
                let count = min(feedSamples, remaining)
                try await manager.process([Float](repeating: 0, count: count))
                remaining -= count
                let flushed = await manager.partialTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
                if !flushed.isEmpty { lastPartial = flushed }
            }
        } catch {
            // Failed predictions may leave unshifted input. Reset before any
            // more audio is admitted, retaining the words already heard.
        }
        await commitUtterance()
    }

    private func commitUtterance() async {
        guard await waitForInferencePermission() else { return }
        let text = lastPartial
        lastPartial = ""
        lastPartialAt = nil
        utteranceSamples = 0
        await manager.reset()
        if !text.isEmpty { await emit(.utterance(text)) }
    }

    /// Awaited, so events reach the log in the order they happened.
    private func emit(_ event: Event) async {
        eventSequence += 1
        await onEvent?(event, eventSequence)
    }

}

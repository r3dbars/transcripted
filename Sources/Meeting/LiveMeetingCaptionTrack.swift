import Foundation
@preconcurrency import AVFoundation
import FluidAudio
import QuartzCore
import TranscriptedCore

/// Drives one FluidAudio streaming Parakeet EOU recognizer for one capture
/// track. One per track: the recognizer holds a single decoder and endpoint
/// state, so mixing mic and call audio would corrupt both.
///
/// Partials are read after each feed rather than through FluidAudio's
/// callbacks, so a partial can never land after the utterance it belongs to
/// was committed.
actor LiveMeetingCaptionTrack {
    enum Event: Sendable {
        /// The utterance in progress so far; the decoder may still rewrite it.
        case partial(String)
        /// A finished utterance.
        case utterance(String)
    }

    enum LoadResult: Sendable {
        case ready
        case failed
    }

    static let chunkSize: StreamingChunkSize = .ms320
    /// The decoder's own endpointing can go quiet mid-utterance and never
    /// fire, freezing on stale text. A turn also closes after this long with
    /// no new words, or once it has run this long. FluidVoice ships the same
    /// two fallbacks.
    static let quietCloseSeconds: Double = 2.5
    static let longestUtteranceSeconds: Double = 20
    /// One encoder step per feed, so a yield (a dictation's final pass
    /// starting) waits behind at most one chunk, never a second of them.
    private static let feedSamples = LiveMeetingCaptionTrack.chunkSize.shiftSamples
    /// Zeros pushed through before a reset so the audio still sitting in the
    /// recognizer's buffer (up to one chunk) is decoded, not dropped.
    private static let flushSamples = LiveMeetingCaptionTrack.chunkSize.chunkSamples
    /// One encoder step of new audio. Waking for less only re-reads the
    /// same partial.
    private static let minimumFeedSamples = LiveMeetingCaptionTrack.chunkSize.shiftSamples

    nonisolated let queue = LiveMeetingCaptionSampleQueue()
    /// `eouDebounceMs: 0` closes at the end-of-utterance token itself.
    /// FluidAudio's default waits ~1.3 s to confirm it, and its decoder skips
    /// every chunk in that window, so speech resuming after a short pause was
    /// never decoded.
    private let manager = StreamingEouAsrManager(chunkSize: LiveMeetingCaptionTrack.chunkSize, eouDebounceMs: 0)
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    private var onEvent: (@Sendable (Event, Int) async -> Void)?
    private var eventSequence = 0
    private var shouldYield: (@Sendable () async -> Bool)?
    private var drainTask: Task<Void, Never>?
    private var lastPartial = ""
    private var lastPartialAt: CFTimeInterval?
    private var utteranceSamples = 0

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
            TranscriptedCore.AppLogger.pipeline.warning("Live transcript model failed to load", ["error_type": String(describing: type(of: error))])
            return .failed
        }
        await beforeWarmup?()
        if let silence = buffer(from: [Float](repeating: 0, count: 16_000)) {
            try? await manager.appendAudio(silence)
            try? await manager.processBufferedAudio()
        }
        await manager.reset()
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

    /// Stops feeding and starts the decoder fresh, but keeps the model
    /// loaded for the next `start`. The dictation preview's track lives for
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
        await manager.reset()
    }

    private func drain() async {
        while !Task.isCancelled {
            guard queue.count >= Self.minimumFeedSamples else {
                // Closing runs the recognizer too (the flush), so it waits
                // out a yield like feeding does.
                if let shouldYield, await shouldYield() {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                await closeIfQuiet()
                try? await Task.sleep(for: .milliseconds(120))
                continue
            }
            if let shouldYield, await shouldYield() {
                // A dictation has the Neural Engine; audio waits in the queue
                // and the transcript catches up after. Saved-meeting jobs
                // don't pause it: they can run for minutes, past the queue.
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            let (samples, overflowed) = queue.take(limit: Self.feedSamples)
            if overflowed {
                await closeUtterance()
            }
            await feed(samples)
        }
    }

    private func feed(_ samples: [Float]) async {
        guard let pcm = buffer(from: samples) else { return }
        do {
            try await manager.appendAudio(pcm)
            try await manager.processBufferedAudio()
        } catch {
            TranscriptedCore.AppLogger.pipeline.warning("Live transcript feed failed", ["error_type": String(describing: type(of: error))])
            await closeUtterance()
            return
        }
        // The 20 s ceiling counts from the first words, not the silence before.
        if lastPartial.isEmpty { utteranceSamples = 0 }
        utteranceSamples += samples.count
        let partial = await manager.getPartialTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
        if await manager.eouDetected {
            lastPartial = partial
            await closeUtterance()
            return
        }
        if partial != lastPartial {
            lastPartial = partial
            lastPartialAt = CACurrentMediaTime()
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
              CACurrentMediaTime() - lastPartialAt > Self.quietCloseSeconds else { return }
        await closeUtterance()
    }

    /// Commits what was heard and starts the decoder fresh for the next turn.
    /// The audio still buffered in the recognizer is decoded first (pushed
    /// through with a chunk of silence); a bare reset would drop it.
    private func closeUtterance() async {
        if let silence = buffer(from: [Float](repeating: 0, count: Self.flushSamples)) {
            do {
                try await manager.appendAudio(silence)
                try await manager.processBufferedAudio()
                let flushed = await manager.getPartialTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
                if !flushed.isEmpty { lastPartial = flushed }
            } catch {
                // Keep what was already heard.
            }
        }
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

    private func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format, !samples.isEmpty,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = pcm.floatChannelData?[0] else { return nil }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return pcm
    }
}

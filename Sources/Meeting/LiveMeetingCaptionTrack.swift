import Foundation
@preconcurrency import AVFoundation
import FluidAudio
import QuartzCore
import TranscriptedCore

/// 16 kHz mono samples waiting for one track's recognizer. Filled from the
/// live-PCM delivery queue (never a CoreAudio callback), drained by the
/// track. Bounded: past `capacity` the oldest audio goes and the track is
/// told, so it can close the utterance it was in.
final class LiveMeetingCaptionSampleQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var overflowed = false
    let capacity: Int

    /// 30 seconds rides out a dictation (the tracks pause while one runs)
    /// and the first model load.
    init(capacity: Int = 16_000 * 30) {
        self.capacity = max(1, capacity)
    }

    func append(_ newSamples: [Float]) {
        lock.withLock {
            samples.append(contentsOf: newSamples)
            if samples.count > capacity {
                samples.removeFirst(samples.count - capacity)
                overflowed = true
            }
        }
    }

    /// Up to `limit` samples in arrival order, and whether audio was lost
    /// since the last take.
    func take(limit: Int) -> (samples: [Float], overflowed: Bool) {
        lock.withLock {
            let count = min(limit, samples.count)
            let taken = Array(samples.prefix(count))
            samples.removeFirst(count)
            defer { overflowed = false }
            return (taken, overflowed)
        }
    }

    func removeAll() {
        lock.withLock {
            samples.removeAll()
            overflowed = false
        }
    }
}

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
    private static let feedSamples = 16_000

    nonisolated let queue = LiveMeetingCaptionSampleQueue()
    private let manager = StreamingEouAsrManager(chunkSize: LiveMeetingCaptionTrack.chunkSize)
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    private var onEvent: (@Sendable (Event) -> Void)?
    private var shouldYield: (@Sendable () async -> Bool)?
    private var drainTask: Task<Void, Never>?
    private var lastPartial = ""
    private var lastPartialAt: CFTimeInterval?
    private var utteranceSamples = 0

    /// Downloads (first time only) and loads the model, then pays CoreML's
    /// first-inference cost on a second of silence so it doesn't back up
    /// real audio.
    func load() async -> LoadResult {
        do {
            try await manager.loadModels()
        } catch {
            TranscriptedCore.AppLogger.pipeline.warning("Live transcript model failed to load", ["error_type": String(describing: type(of: error))])
            return .failed
        }
        if let silence = buffer(from: [Float](repeating: 0, count: 16_000)) {
            try? await manager.appendAudio(silence)
            try? await manager.processBufferedAudio()
        }
        await manager.reset()
        return .ready
    }

    func start(
        shouldYield: @escaping @Sendable () async -> Bool,
        onEvent: @escaping @Sendable (Event) -> Void
    ) {
        self.onEvent = onEvent
        self.shouldYield = shouldYield
        drainTask?.cancel()
        drainTask = Task { [weak self] in await self?.drain() }
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

    private func drain() async {
        while !Task.isCancelled {
            if let shouldYield, await shouldYield() {
                // Dictation has the Neural Engine; audio waits in the queue.
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            let (samples, overflowed) = queue.take(limit: Self.feedSamples)
            if overflowed {
                await closeUtterance()
            }
            guard !samples.isEmpty else {
                await closeIfQuiet()
                try? await Task.sleep(for: .milliseconds(60))
                continue
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
            if !partial.isEmpty { onEvent?(.partial(partial)) }
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
    private func closeUtterance() async {
        let text = lastPartial
        lastPartial = ""
        lastPartialAt = nil
        utteranceSamples = 0
        await manager.reset()
        if !text.isEmpty { onEvent?(.utterance(text)) }
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

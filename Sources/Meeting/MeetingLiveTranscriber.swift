// MeetingLiveTranscriber.swift
// Wraps a single FluidAudio `StreamingEouAsrManager` to produce live
// transcription preview for one audio source (mic OR system). Used by
// MeetingSessionController which owns two instances — one per stream —
// so the meeting overlay can display mic and system transcripts in
// parallel while a recording is underway.
//
// This is PREVIEW-ONLY. The authoritative transcript is still produced
// by TranscriptedCore's offline pipeline after stopRecording(). If any
// step here fails (model load, inference, format conversion), the meeting
// recording and final transcript are completely unaffected — we just stop
// updating the live preview text.
//
// Threading:
//   - `ingest(buffer:)` is `nonisolated` so it can be called synchronously
//     from the CoreAudio capture thread (via TranscriptedCore's new
//     `onMicPCMBuffer` / `onSystemPCMBuffer` hooks).
//   - It resamples + downmixes under an NSLock and kicks detached Tasks
//     to feed the chunk to the async `StreamingEouAsrManager.process(...)`.
//   - The @Published `liveText` state is mutated on MainActor (via the
//     EOU partial/commit callbacks, which themselves hop to main).
//
// Cost: ~120 MB per instance, loaded from the same cached model the
// dictation path uses (no extra download on second run).

import AVFoundation
import Combine
import FluidAudio
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class MeetingLiveTranscriber: ObservableObject {
    struct Update {
        enum Kind {
            case partial
            case committed
            case reset
        }

        let source: Source
        let kind: Kind
        let text: String
        let timestamp: Date
    }


    /// The stream this transcriber is attached to. Purely for logging +
    /// distinguishing log lines in EventReporter; the ASR path is identical.
    enum Source: String {
        case mic
        case system
    }

    // MARK: - Published state

    /// Partial + committed transcript shown in the overlay's expanded panel.
    /// Updated as EOU emits chunks (partial) and commits utterances on silence.
    @Published private(set) var liveText: String = ""

    /// True once `start()` has successfully loaded the model. Reads of
    /// `ingest(buffer:)` before this do nothing.
    @Published private(set) var isReady: Bool = false

    /// Emits source-aware preview updates so the overlay can thread mic and
    /// system speech into a single back-and-forth conversation view.
    var onUpdate: ((Update) -> Void)?

    // MARK: - Configuration

    let source: Source
    private let modelDir: URL

    // MARK: - Streaming internals

    // `nonisolated(unsafe)` on these mirrors the pattern used by Draft's
    // ParakeetEngine for its dictation streaming path: the audio thread
    // writes to `pendingSamples` under `samplesLock`, while MainActor
    // setup reads/writes `eou` once. The lock and the "write once then
    // only read" pattern together give us effective thread safety without
    // crossing actor boundaries on the hot path.
    private nonisolated(unsafe) var eou: StreamingEouAsrManager?
    private nonisolated(unsafe) var pendingSamples: [Float] = []
    private let samplesLock = NSLock()

    // Feed ~320ms of 16kHz audio per chunk, matching the EOU shift size
    // used by ParakeetEngine. 5120 samples * (1 / 16000) = 320ms.
    private nonisolated let chunkSamples: Int = 5120

    // Cached PCM format: EOU always wants 16kHz mono Float32.
    // `nonisolated` so `ingest(buffer:)` can read it from the audio thread.
    private nonisolated let pcmFormat: AVAudioFormat? = AVAudioFormat(
        standardFormatWithSampleRate: 16000,
        channels: 1
    )

    // Committed text is the "final" utterances emitted by EOU after silence.
    // Partial text is the current in-progress chunk. liveText = committed + partial.
    private var committedText: String = ""

    // MARK: - Init

    init(source: Source, modelDir: URL) {
        self.source = source
        self.modelDir = modelDir
    }

    // MARK: - Lifecycle

    /// Load the EOU model and wire partial + commit callbacks. Safe to
    /// call multiple times — second call is a no-op. Non-fatal on failure:
    /// `isReady` stays false and `ingest(buffer:)` becomes a drop-on-floor.
    func start() async {
        guard eou == nil else { return }

        let manager = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 1280)
        do {
            try await manager.loadModels(modelDir: modelDir)
        } catch {
            print("⚠️ MEETING LIVE [\(source.rawValue)] | model load failed: \(error.localizedDescription)")
            return
        }

        // Partial callback: fires on every chunk with the latest decoder
        // output. Replaces the currently-displayed partial text; the
        // committed portion stays intact.
        await manager.setPartialCallback { [weak self] partial in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let trimmed = partial.trimmingCharacters(in: .whitespaces)
                self.liveText = self.committedText.isEmpty
                    ? trimmed
                    : (trimmed.isEmpty ? self.committedText : self.committedText + " " + trimmed)
                self.onUpdate?(Update(
                    source: self.source,
                    kind: .partial,
                    text: trimmed,
                    timestamp: Date()
                ))
            }
        }

        // EOU (end-of-utterance) callback: fires after the silence debounce
        // window. The partial becomes "committed" — it will no longer be
        // replaced on the next chunk.
        await manager.setEouCallback { [weak self] utterance in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let trimmed = utterance.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                self.committedText = self.committedText.isEmpty
                    ? trimmed
                    : self.committedText + " " + trimmed
                self.liveText = self.committedText
                self.onUpdate?(Update(
                    source: self.source,
                    kind: .committed,
                    text: trimmed,
                    timestamp: Date()
                ))
            }
        }

        self.eou = manager
        self.isReady = true
        print("✅ MEETING LIVE [\(source.rawValue)] | streaming model ready")
    }

    /// Stop the stream and clear state. Called when a meeting recording
    /// ends — the final offline transcript is authoritative, so the live
    /// preview can be discarded.
    func stop() async {
        guard let manager = eou else { return }
        await manager.reset()

        samplesLock.lock()
        pendingSamples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

        committedText = ""
        liveText = ""
        onUpdate?(Update(source: source, kind: .reset, text: "", timestamp: Date()))
    }

    // MARK: - Ingest (audio-thread entry point)

    /// Consume a PCM buffer from the CoreAudio capture thread. Down-mixes to
    /// mono, resamples to 16kHz, accumulates in a lock-protected queue, and
    /// fires `process(audioBuffer:)` on the ASR manager once a full 320ms
    /// chunk has been collected.
    ///
    /// This method is `nonisolated` so it can be called synchronously from
    /// `Audio.onMicPCMBuffer` / `Audio.onSystemPCMBuffer` without a MainActor
    /// hop. It does NO I/O and no allocations beyond the resampled sample
    /// array and a short-lived `AVAudioPCMBuffer` for the chunk handoff.
    nonisolated func ingest(buffer: AVAudioPCMBuffer) {
        // Read `eou` once under the lock to avoid a torn read. If the
        // manager hasn't loaded yet (start() hasn't completed), just drop
        // the buffer — we'll pick up on the next one after loading.
        samplesLock.lock()
        let managerReady = (eou != nil)
        samplesLock.unlock()
        guard managerReady else { return }

        // Extract mono Float32 samples at the buffer's native rate.
        guard let monoSamples = Self.monoSamples(from: buffer) else { return }
        let nativeRate = buffer.format.sampleRate
        let resampled = AudioResampler.resample(monoSamples, from: nativeRate, to: 16000)
        guard !resampled.isEmpty else { return }

        // Append and drain any full chunks. We batch into an array of
        // chunks under the lock, then feed them outside the lock to avoid
        // holding it across an async suspension point.
        samplesLock.lock()
        pendingSamples.append(contentsOf: resampled)

        var chunks: [[Float]] = []
        while pendingSamples.count >= chunkSamples {
            chunks.append(Array(pendingSamples.prefix(chunkSamples)))
            pendingSamples.removeFirst(chunkSamples)
        }
        samplesLock.unlock()

        guard !chunks.isEmpty else { return }

        // Build PCM buffers off the audio thread as detached Tasks so the
        // real-time capture thread returns quickly. The ASR manager serializes
        // process() calls internally, so ordering is preserved.
        for chunk in chunks {
            guard let pcm = Self.makePCMBuffer(from: chunk, format: pcmFormat) else { continue }
            Task.detached { [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.eou?.process(audioBuffer: pcm)
                } catch {
                    // Swallow — live preview is best-effort. A failure here
                    // does not affect the recording or final transcript.
                }
            }
        }
    }

    // MARK: - Helpers

    /// Down-mix a multi-channel buffer to mono Float32. For mono input this
    /// is a direct copy of channel 0's samples.
    private nonisolated static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }

        if !buffer.format.isInterleaved, let channelData = buffer.floatChannelData {
            if channelCount == 1 {
                return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
            }

            var out = [Float](repeating: 0, count: frameCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += channelData[ch][frame]
                }
                out[frame] = sum / Float(channelCount)
            }
            return out
        }

        let totalSamples = frameCount * channelCount
        guard let mData = buffer.audioBufferList.pointee.mBuffers.mData else { return nil }

        if buffer.format.commonFormat == .pcmFormatFloat32 {
            let interleaved = mData.bindMemory(to: Float.self, capacity: totalSamples)
            if channelCount == 1 {
                return Array(UnsafeBufferPointer(start: interleaved, count: frameCount))
            }

            var out = [Float](repeating: 0, count: frameCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += interleaved[frame * channelCount + ch]
                }
                out[frame] = sum / Float(channelCount)
            }
            return out
        }

        if buffer.format.commonFormat == .pcmFormatInt16 {
            let interleaved = mData.bindMemory(to: Int16.self, capacity: totalSamples)
            var out = [Float](repeating: 0, count: frameCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += Float(interleaved[frame * channelCount + ch]) / Float(Int16.max)
                }
                out[frame] = sum / Float(channelCount)
            }
            return out
        }

        return nil
    }

    /// Wrap a Float array in an AVAudioPCMBuffer matching `pcmFormat`
    /// (16kHz mono Float32).
    private nonisolated static func makePCMBuffer(from samples: [Float], format: AVAudioFormat?) -> AVAudioPCMBuffer? {
        guard let format else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let dst = buffer.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { src in
            dst.update(from: src.baseAddress!, count: samples.count)
        }
        return buffer
    }
}

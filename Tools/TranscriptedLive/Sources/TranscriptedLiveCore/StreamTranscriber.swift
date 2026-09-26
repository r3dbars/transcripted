import AVFoundation
import FluidAudio
import Foundation

/// One finished utterance: `t` is seconds into the recording where it started.
public struct LiveUtterance: Codable, Equatable, Sendable {
    public let t: Double
    public let speaker: String
    public let text: String

    public init(t: Double, speaker: String, text: String) {
        self.t = t
        self.speaker = speaker
        self.text = text
    }
}

/// Turns the EOU manager's ever-growing transcript into discrete utterances.
///
/// FluidAudio's callbacks hand over the whole transcript accumulated since the
/// last reset, so each utterance is the part after what was already emitted.
/// The callbacks run synchronously inside the manager's actor, hence the lock.
final class TranscriptSink: @unchecked Sendable {
    private let lock = NSLock()
    private var emitted = ""
    private var latest = ""
    private var finals: [String] = []

    func onEou(_ transcript: String) {
        lock.lock()
        defer { lock.unlock() }
        latest = transcript
        let delta = Self.delta(from: emitted, to: transcript)
        emitted = transcript
        if !delta.isEmpty { finals.append(delta) }
    }

    func onPartial(_ transcript: String) {
        lock.lock()
        defer { lock.unlock() }
        latest = transcript
    }

    /// The utterances finished since the last drain.
    func drainFinals() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let drained = finals
        finals.removeAll()
        return drained
    }

    /// Text decoded after the last finished utterance.
    var partial: String {
        lock.lock()
        defer { lock.unlock() }
        return Self.delta(from: emitted, to: latest)
    }

    /// Ends the in-progress utterance by hand (a speaker who never pauses).
    /// Mid-stream the last word stays pending, since the decoder may still be
    /// adding subword pieces to it; at the end of a stream everything goes.
    func forceFinal(keepingLastWord: Bool = false) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard latest.count > emitted.count else { return nil }
        var cut = latest.endIndex
        if keepingLastWord {
            let tailStart = latest.index(latest.startIndex, offsetBy: emitted.count)
            guard let lastSpace = latest[tailStart...].lastIndex(of: " ") else { return nil }
            cut = lastSpace
        }
        let delta = Self.delta(from: emitted, to: String(latest[..<cut]))
        emitted = String(latest[..<cut])
        return delta.isEmpty ? nil : delta
    }

    var accumulatedLength: Int {
        lock.lock()
        defer { lock.unlock() }
        return latest.count
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        emitted = ""
        latest = ""
        finals.removeAll()
    }

    static func delta(from emitted: String, to transcript: String) -> String {
        let tail: Substring
        if transcript.hasPrefix(emitted) {
            tail = transcript.dropFirst(emitted.count)
        } else if transcript.count > emitted.count {
            tail = transcript.dropFirst(emitted.count)
        } else {
            return ""
        }
        return tail
            .replacingOccurrences(of: "<EOU>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Keeps one AVAudioConverter alive across calls so chunk edges resample
/// smoothly instead of restarting the filter every 250 ms.
final class MonoResampler {
    static let targetRate: Double = 16_000

    let inputRate: Double
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    init(inputRate: Double) {
        self.inputRate = inputRate
        inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false)!
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.targetRate, channels: 1, interleaved: false)!
        converter = inputRate == Self.targetRate ? nil : AVAudioConverter(from: inputFormat, to: outputFormat)
    }

    func resample(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard let converter else { return samples }
        guard let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return []
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            input.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }

        let capacity = AVAudioFrameCount(Double(samples.count) * Self.targetRate / inputRate) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }

        var handedOver = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if handedOver {
                // noDataNow, not endOfStream: the converter keeps its filter state.
                status.pointee = .noDataNow
                return nil
            }
            handedOver = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

/// One speaker's live transcription: mic ("you") or system audio ("them").
public actor StreamTranscriber {
    /// A speaker who talks this long without a pause gets split anyway.
    static let maxUtteranceWords = 45
    /// Past this, the manager is reset at the next quiet moment to bound work.
    static let resetAfterCharacters = 6_000

    public nonisolated let speaker: String
    private let manager: StreamingEouAsrManager
    private let sink = TranscriptSink()
    private var resampler: MonoResampler?
    private var utteranceStart: Double?

    /// `pauseMs` is how long a speaker must stop before their line is final.
    public init(speaker: String, chunkSize: StreamingChunkSize = .ms320, pauseMs: Int = 640) {
        self.speaker = speaker
        self.manager = StreamingEouAsrManager(chunkSize: chunkSize, eouDebounceMs: pauseMs)
    }

    /// Downloads the model on first use (FluidAudio's cache), then loads it.
    public func load() async throws {
        try await manager.loadModels(to: nil, configuration: nil, progressHandler: nil)
        let sink = self.sink
        await manager.setEouCallback { transcript in sink.onEou(transcript) }
        await manager.setPartialCallback { transcript in sink.onPartial(transcript) }
    }

    /// Feeds mono samples at `sampleRate`. `startSeconds` is the audio position
    /// of the first sample, used to timestamp utterances.
    public func feed(_ samples: [Float], sampleRate: Double, startSeconds: Double) async throws -> [LiveUtterance] {
        guard !samples.isEmpty else { return [] }
        if resampler?.inputRate != sampleRate {
            resampler = MonoResampler(inputRate: sampleRate)
        }
        let resampled = resampler!.resample(samples)
        if !resampled.isEmpty, let buffer = Self.buffer(resampled) {
            _ = try await manager.process(audioBuffer: buffer)
        }

        let endSeconds = startSeconds + Double(samples.count) / sampleRate
        if utteranceStart == nil, !sink.partial.isEmpty {
            utteranceStart = startSeconds
        }

        var texts = sink.drainFinals()
        if texts.isEmpty, sink.partial.split(separator: " ").count >= Self.maxUtteranceWords,
           let forced = sink.forceFinal(keepingLastWord: true) {
            texts.append(forced)
        }

        let utterances = texts.map { LiveUtterance(t: utteranceStart ?? startSeconds, speaker: speaker, text: $0) }
        if !utterances.isEmpty {
            utteranceStart = sink.partial.isEmpty ? nil : endSeconds
        }

        if sink.partial.isEmpty, sink.accumulatedLength > Self.resetAfterCharacters {
            await manager.reset()
            sink.clear()
        }
        return utterances
    }

    /// Text heard since the last finished utterance (the "ghost" line).
    public func partialText() -> String {
        sink.partial
    }

    /// Ends the stream: whatever is still pending becomes a last utterance.
    public func flush(atSeconds seconds: Double) async throws -> [LiveUtterance] {
        _ = try await manager.finish()
        var texts = sink.drainFinals()
        if let forced = sink.forceFinal() { texts.append(forced) }
        let utterances = texts.map { LiveUtterance(t: utteranceStart ?? seconds, speaker: speaker, text: $0) }
        await reset()
        return utterances
    }

    public func reset() async {
        await manager.reset()
        sink.clear()
        resampler = nil
        utteranceStart = nil
    }

    private static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: MonoResampler.targetRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }
}

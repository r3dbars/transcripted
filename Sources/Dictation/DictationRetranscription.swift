// DictationRetranscription.swift
// Transcribe again: run local STT over a saved take's kept audio file and
// replace that entry's text in its day file.

import AVFoundation
import Foundation

/// Re-transcribes one saved dictation from its kept audio file.
///
/// File-based only: the audio is decoded with `AVAudioFile` and
/// `AVAudioConverter`. Nothing here builds an `AVAudioEngine` or touches an
/// input node, so a Bluetooth headset set as the default input is never
/// opened (and never flips into call mode). The caller passes the
/// transcriber, so the model and its busy rules stay with `STTRouter`.
enum DictationRetranscription {
    enum Failure: Error, Equatable {
        /// The entry predates Entry IDs, so it can't be targeted safely.
        case missingEntryID
        /// The audio file couldn't be decoded.
        case unreadableAudio
        /// The model heard no words; the old text stays.
        case noWords

        var message: String {
            switch self {
            case .missingEntryID:
                return "This dictation was saved by an older version and can't be transcribed again."
            case .unreadableAudio:
                return "Transcripted couldn't read this dictation's audio. It may have been moved or deleted."
            case .noWords:
                return "Transcripted didn't hear any words this time, so the original text was kept."
            }
        }
    }

    /// Decodes `audioURL`, transcribes it, cleans the text the way a live take
    /// is cleaned, and rewrites the entry. Returns the rewrite result; the day
    /// file is untouched when this throws.
    static func run(
        entry: SavedDictationEntry,
        audioURL: URL,
        cleanupEnabled: Bool,
        loadSamples: @escaping @Sendable (URL) throws -> [Float] = loadSamples16k,
        transcribe: ([Float]) async throws -> String
    ) async throws -> DictationEntryTextRewrite.Result {
        guard let entryID = entry.entryID, !entryID.isEmpty else { throw Failure.missingEntryID }
        let samples: [Float]
        do {
            samples = try await Task.detached(priority: .userInitiated) {
                try loadSamples(audioURL)
            }.value
        } catch {
            throw Failure.unreadableAudio
        }
        guard !samples.isEmpty else { throw Failure.unreadableAudio }

        let raw = try await transcribe(samples)
        let text = cleanedText(raw, cleanupEnabled: cleanupEnabled)
        guard !text.isEmpty else { throw Failure.noWords }

        let url = entry.url
        let createdAt = entry.createdAt
        return try await Task.detached(priority: .userInitiated) {
            try DictationTranscriptStore.replaceEntryText(
                entryID: entryID,
                in: url,
                with: text,
                createdAt: createdAt
            )
        }.value
    }

    /// Same cleanup rule as a live take: filler cleanup when it's on, else
    /// just trimmed.
    static func cleanedText(_ raw: String, cleanupEnabled: Bool) -> String {
        if cleanupEnabled {
            return DictationFillerCleanupPolicy.clean(raw).text
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 16 kHz mono Float32 samples from an audio file (M4A or WAV).
    @Sendable
    static func loadSamples16k(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(clamping: file.length)
        guard frameCount > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else { return [] }
        try file.read(into: input)

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw Failure.unreadableAudio
        }
        converter.downmix = true
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4_096
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw Failure.unreadableAudio
        }

        var delivered = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .endOfStream
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil,
              let channel = output.floatChannelData?[0] else {
            throw Failure.unreadableAudio
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

// FailedRecordingSignalProbe.swift
// Bounded "does this saved artifact still contain something worth transcribing"
// check, used to decide whether a failed meeting should offer retry.
//
// Retry availability used to be derived purely from the persisted failure
// message. That is wrong for two reasons: the message describes what an older
// build could not do, and it says nothing about which of the two capture
// sources actually survived. A recording whose microphone track broke while
// system audio recorded cleanly is fully transcribable — the pipeline already
// drops an unusable microphone and continues (see `TranscriptionPipeline`) —
// but a stale `microphone_audio_unusable` label kept the button hidden.
//
// This probe answers the factual half: is there audible signal in this file?
//
// The result is deliberately three-valued. A wrong `.absent` would hide the
// retry button on a recording that actually has audio, which is the very bug
// this work exists to fix — so `.absent` is only ever reported after the whole
// artifact has been examined. When a file is too long to finish inside the
// scan budget the answer is `.inconclusive`, and callers keep retry offered.

import Foundation
import AVFoundation

public enum FailedRecordingSignalProbe {
    public enum Result: Equatable, Sendable {
        /// Audible signal found. Retry has something to work with.
        case present
        /// The entire artifact was examined and none of it carries signal.
        /// Retrying could only reproduce the original failure.
        case absent
        /// Unreadable, or longer than the scan budget allows. Callers must stay
        /// optimistic — never suppress retry on this.
        case inconclusive
    }

    /// Length of each decoded window. `AudioSignalRecovery.hasUsableCaptureSignal`
    /// needs 0.2s of cumulative active audio, so this is generous while keeping
    /// peak memory to roughly one window of mono float samples.
    static let probeWindowSeconds: Double = 8

    /// Ceiling on how much audio one file may decode before the probe gives up
    /// and reports `.inconclusive`. Chosen to cover ordinary meeting lengths, so
    /// in practice silence verdicts are definitive; a marathon recording simply
    /// keeps its retry button rather than risking a wrong suppression.
    static let maxScannedSeconds: Double = 20 * 60

    public static func probe(url: URL) -> Result {
        guard let file = try? AVAudioFile(forReading: url) else { return .inconclusive }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard AudioRecordingFormatPolicy.isUsableSampleRate(sampleRate),
              format.channelCount > 0 else {
            return .inconclusive
        }
        // A zero-length artifact is fully examined by definition: there is
        // nothing in it, which is exactly what `.absent` means.
        guard file.length > 0 else { return .absent }

        let windowFrames = AVAudioFrameCount(max(1, Int(sampleRate * probeWindowSeconds)))
        let budgetFrames = Int64(maxScannedSeconds * sampleRate)

        var position: Int64 = 0
        while position < file.length {
            if position >= budgetFrames {
                // Ran out of budget with audio still unexamined, so silence
                // cannot be asserted.
                return .inconclusive
            }
            guard let samples = readMonoWindow(
                file: file,
                startFrame: position,
                frameCount: windowFrames
            ) else {
                return .inconclusive
            }
            if samples.isEmpty { break }
            if AudioSignalRecovery.hasUsableCaptureSignal(samples: samples, sampleRate: sampleRate) {
                return .present
            }
            position += Int64(samples.count)
        }
        return .absent
    }

    private static func readMonoWindow(
        file: AVAudioFile,
        startFrame: Int64,
        frameCount: AVAudioFrameCount
    ) -> [Float]? {
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }

        file.framePosition = startFrame
        do {
            try file.read(into: buffer, frameCount: frameCount)
        } catch {
            return nil
        }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return [] }
        guard let floatData = buffer.floatChannelData else { return nil }
        let channelCount = Int(format.channelCount)
        guard channelCount > 0 else { return nil }

        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: floatData[0], count: frameLength))
        }

        var samples = [Float](repeating: 0, count: frameLength)
        for frame in 0..<frameLength {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += floatData[channel][frame]
            }
            samples[frame] = sum / Float(channelCount)
        }
        return samples
    }
}

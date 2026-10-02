// DictationPreviewSampleSink.swift
// A copy of the dictation mic audio for the island's live preview. The two
// capture paths (engine tap and pinned-mic IOProc) already append each
// buffer to `pendingSamples` on their capture queue, never the real-time
// thread; while a sink is attached they append the same mono samples here
// too, inside the same lock. The preview drains it on a utility task, so
// the take's own audio, its timing and the final transcription never wait
// on the preview.

@preconcurrency import AVFoundation
import Foundation

final class DictationPreviewSampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [(samples: [Float], sampleRate: Double)] = []
    private var storedSeconds = 0.0
    /// Past this much unread audio everything unread is dropped; the preview
    /// is far behind anyway and the final transcription has every sample.
    /// Dropping it all keeps the capture queue's work constant.
    let capacitySeconds: Double
    /// Only `take()` touches the converter, from one pump task at a time.
    private var converter: (sampleRate: Double, converter: AVAudioConverter)?

    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )

    init(capacitySeconds: Double = 30) {
        self.capacitySeconds = max(1, capacitySeconds)
    }

    /// Called on a capture queue with the take's mono samples.
    func append(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        lock.withLock {
            if storedSeconds > capacitySeconds {
                segments.removeAll()
                storedSeconds = 0
            }
            if let last = segments.last, last.sampleRate == sampleRate {
                segments[segments.count - 1].samples.append(contentsOf: samples)
            } else {
                segments.append((samples, sampleRate))
            }
            storedSeconds += Double(samples.count) / sampleRate
        }
    }

    /// Everything captured since the last take, as 16 kHz mono. The
    /// converter low-passes before decimating and keeps its filter state
    /// across calls, like a continuous stream.
    func take() -> [Float] {
        let taken = lock.withLock { () -> [(samples: [Float], sampleRate: Double)] in
            defer {
                segments.removeAll(keepingCapacity: true)
                storedSeconds = 0
            }
            return segments
        }
        var output: [Float] = []
        for segment in taken {
            output.append(contentsOf: convert(segment.samples, from: segment.sampleRate))
        }
        return output
    }

    private func convert(_ samples: [Float], from sampleRate: Double) -> [Float] {
        guard sampleRate != 16_000 else { return samples }
        guard let outputFormat = Self.outputFormat,
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0] else { return [] }
        if converter?.sampleRate != sampleRate {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat).map { (sampleRate, $0) }
        }
        guard let converter = converter?.converter else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount((Double(samples.count) * 16_000 / sampleRate).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        // `.noDataNow`, not end of stream: the filter state carries to the
        // next take() so chunk edges don't click.
        _ = converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let data = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
    }
}

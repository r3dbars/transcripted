// DictationPreviewSampleSink.swift
// A copy of the dictation mic audio for the island's live preview. The two
// capture paths (engine tap and pinned-mic IOProc) already append each
// buffer to `pendingSamples` on their capture queue, never the real-time
// thread; while a sink is attached they append the same mono samples here
// too, inside the same lock. The preview drains it on a utility task, so
// the take's own audio, its timing and the final transcription never wait
// on the preview.

import Foundation
import TranscriptedCore

final class DictationPreviewSampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [(samples: [Float], sampleRate: Double)] = []
    private var storedSeconds = 0.0
    /// Past this much unread audio the oldest goes; the preview is behind
    /// anyway and the final transcription has every sample.
    let capacitySeconds: Double

    init(capacitySeconds: Double = 30) {
        self.capacitySeconds = max(1, capacitySeconds)
    }

    /// Called on a capture queue with the take's mono samples.
    func append(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty, sampleRate > 0 else { return }
        lock.withLock {
            if let last = segments.last, last.sampleRate == sampleRate {
                segments[segments.count - 1].samples.append(contentsOf: samples)
            } else {
                segments.append((samples, sampleRate))
            }
            storedSeconds += Double(samples.count) / sampleRate
            while storedSeconds > capacitySeconds, let first = segments.first {
                let excess = Int(((storedSeconds - capacitySeconds) * first.sampleRate).rounded(.up))
                if excess >= first.samples.count, segments.count > 1 {
                    segments.removeFirst()
                    storedSeconds -= Double(first.samples.count) / first.sampleRate
                } else {
                    let dropped = min(excess, first.samples.count)
                    segments[0].samples.removeFirst(dropped)
                    storedSeconds -= Double(dropped) / first.sampleRate
                    break
                }
            }
        }
    }

    /// Everything captured since the last take, as 16 kHz mono.
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
            output.append(contentsOf: AudioResampler.resample(segment.samples, from: segment.sampleRate, to: 16_000))
        }
        return output
    }
}

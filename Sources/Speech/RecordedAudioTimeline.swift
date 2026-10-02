import Foundation

struct RecordedAudioSegment: Equatable {
    let sampleRate: Double
    var samples: [Float]

    var durationSeconds: Double {
        guard ParakeetAudioFormatReadinessPolicy.isUsableCaptureSampleRate(sampleRate) else { return 0 }
        return Double(samples.count) / sampleRate
    }
}

struct RecordedAudioTimeline {
    private(set) var segments: [RecordedAudioSegment] = []

    var isEmpty: Bool { totalSourceSampleCount == 0 }

    var totalSourceSampleCount: Int {
        segments.reduce(0) { $0 + $1.samples.count }
    }

    var totalDurationSeconds: Double {
        segments.reduce(0) { $0 + $1.durationSeconds }
    }

    mutating func append(_ samples: [Float], sampleRate: Double) {
        guard !samples.isEmpty,
              ParakeetAudioFormatReadinessPolicy.isUsableCaptureSampleRate(sampleRate) else { return }

        if let lastIndex = segments.indices.last, segments[lastIndex].sampleRate == sampleRate {
            segments[lastIndex].samples.append(contentsOf: samples)
        } else {
            segments.append(RecordedAudioSegment(sampleRate: sampleRate, samples: samples))
        }
    }

    /// Appends a drained segment at its own captured rate. Pending tap audio
    /// joins the take this way, so a route change mid-take keeps both rates.
    mutating func append(_ segment: RecordedAudioSegment) {
        append(segment.samples, sampleRate: segment.sampleRate)
    }

    /// Retain the newest audio by duration, even when Bluetooth changes rates.
    /// A sample-count limit based on the latest rate would trim the wrong amount.
    @discardableResult
    mutating func trimToLatest(durationSeconds limit: Double) -> Double {
        guard limit.isFinite, limit >= 0 else { return 0 }
        let originalDuration = totalDurationSeconds
        var excess = originalDuration - limit
        while excess > 0, let first = segments.first {
            if first.durationSeconds <= excess {
                excess -= first.durationSeconds
                segments.removeFirst()
            } else {
                let samplesToRemove = min(first.samples.count, Int(ceil(excess * first.sampleRate)))
                segments[0].samples.removeFirst(samplesToRemove)
                break
            }
        }
        return max(0, originalDuration - totalDurationSeconds)
    }

    mutating func drain() -> [RecordedAudioSegment] {
        let drained = segments
        segments.removeAll(keepingCapacity: true)
        return drained
    }

    mutating func removeAll(keepingCapacity: Bool = true) {
        if keepingCapacity {
            segments.removeAll(keepingCapacity: true)
        } else {
            segments.removeAll()
        }
    }
}

extension RecordedAudioTimeline {
    /// Converts each segment from its own captured rate and joins them in
    /// order. A route change mid-take (AirPods dropping to 24 kHz, say) leaves
    /// segments at different rates; treating them as one rate would warp the audio.
    static func speechSamples(
        from segments: [RecordedAudioSegment],
        resample: (_ samples: [Float], _ sampleRate: Double) throws -> [Float]
    ) rethrows -> [Float] {
        var combined: [Float] = []
        for segment in segments {
            combined.append(contentsOf: try resample(segment.samples, segment.sampleRate))
        }
        return combined
    }
}

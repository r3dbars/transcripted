import Foundation

struct RecordedAudioSegment: Equatable {
    let sampleRate: Double
    var samples: [Float]

    var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
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
        guard !samples.isEmpty, sampleRate > 0 else { return }

        if let lastIndex = segments.indices.last, segments[lastIndex].sampleRate == sampleRate {
            segments[lastIndex].samples.append(contentsOf: samples)
        } else {
            segments.append(RecordedAudioSegment(sampleRate: sampleRate, samples: samples))
        }
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

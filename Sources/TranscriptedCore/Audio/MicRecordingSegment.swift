import Foundation

struct MicRecordingSegment: Equatable {
    let url: URL
    let gapBeforeDuration: TimeInterval

    init(url: URL, gapBeforeDuration: TimeInterval = 0) {
        self.url = url
        self.gapBeforeDuration = gapBeforeDuration.isFinite ? max(0, gapBeforeDuration) : 0
    }
}

enum MicRecordingMergePlan {
    private static let minimumUsableSampleRate: Double = 8_000
    private static let maximumUsableSampleRate: Double = 384_000

    static func silenceSampleCount(before segment: MicRecordingSegment, sampleRate: Double) -> Int {
        guard isUsableSampleRate(sampleRate),
              segment.gapBeforeDuration.isFinite else { return 0 }
        let rawSampleCount = (segment.gapBeforeDuration * sampleRate).rounded()
        guard rawSampleCount.isFinite,
              rawSampleCount >= Double(Int.min),
              rawSampleCount <= Double(Int.max) else { return 0 }
        return max(0, Int(rawSampleCount))
    }

    private static func isUsableSampleRate(_ sampleRate: Double) -> Bool {
        sampleRate.isFinite
            && sampleRate >= minimumUsableSampleRate
            && sampleRate <= maximumUsableSampleRate
    }
}

import Foundation

struct MicRecordingSegment: Equatable {
    let url: URL
    let gapBeforeDuration: TimeInterval

    init(url: URL, gapBeforeDuration: TimeInterval = 0) {
        self.url = url
        self.gapBeforeDuration = max(0, gapBeforeDuration)
    }
}

enum MicRecordingMergePlan {
    static func silenceSampleCount(before segment: MicRecordingSegment, sampleRate: Double) -> Int {
        guard sampleRate > 0 else { return 0 }
        return max(0, Int((segment.gapBeforeDuration * sampleRate).rounded()))
    }
}

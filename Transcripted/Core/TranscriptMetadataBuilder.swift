import Foundation

/// Recording health information for transcript metadata (Phase 3)
/// Captures quality metrics to be embedded in transcript YAML frontmatter
struct RecordingHealthInfo {
    /// Capture quality rating based on buffer success rate
    enum CaptureQuality: String {
        case excellent = "excellent"  // >= 98%
        case good = "good"            // 90-97%
        case fair = "fair"            // 80-89%
        case degraded = "degraded"    // < 80%

        static func from(successRate: Double) -> CaptureQuality {
            switch successRate {
            case 0.98...: return .excellent
            case 0.90..<0.98: return .good
            case 0.80..<0.90: return .fair
            default: return .degraded
            }
        }
    }

    let captureQuality: CaptureQuality
    let audioGaps: Int
    let deviceSwitches: Int
    let gapDescriptions: [String]

    /// Create health info from Audio instance
    @available(macOS 26.0, *)
    static func from(audio: Audio, systemCapture: SystemAudioCapture?) -> RecordingHealthInfo {
        let successRate = systemCapture?.bufferSuccessRate ?? 1.0
        return RecordingHealthInfo(
            captureQuality: CaptureQuality.from(successRate: successRate),
            audioGaps: audio.recordingGaps.count,
            deviceSwitches: audio.deviceSwitchCount,
            gapDescriptions: audio.recordingGaps.map { $0.description }
        )
    }

    /// Default "no issues" health info
    static var perfect: RecordingHealthInfo {
        RecordingHealthInfo(
            captureQuality: .excellent,
            audioGaps: 0,
            deviceSwitches: 0,
            gapDescriptions: []
        )
    }
}

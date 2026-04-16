import Foundation

/// Recording health information for transcript metadata (Phase 3)
/// Captures quality metrics to be embedded in transcript YAML frontmatter
public struct RecordingHealthInfo {
    /// Capture quality rating based on buffer success rate
    public enum CaptureQuality: String {
        case excellent = "excellent"  // >= 98%
        case good = "good"            // 90-97%
        case fair = "fair"            // 80-89%
        case degraded = "degraded"    // < 80%

        public static func from(successRate: Double) -> CaptureQuality {
            switch successRate {
            case 0.98...: return .excellent
            case 0.90..<0.98: return .good
            case 0.80..<0.90: return .fair
            default: return .degraded
            }
        }
    }

    public let captureQuality: CaptureQuality
    public let audioGaps: Int
    public let deviceSwitches: Int
    public let gapDescriptions: [String]

    public init(captureQuality: CaptureQuality, audioGaps: Int, deviceSwitches: Int, gapDescriptions: [String]) {
        self.captureQuality = captureQuality
        self.audioGaps = audioGaps
        self.deviceSwitches = deviceSwitches
        self.gapDescriptions = gapDescriptions
    }

    /// Create health info from Audio instance.
    public static func from(audio: Audio, systemCapture: (any SystemAudioCaptureEngine)?) -> RecordingHealthInfo {
        let successRate: Double = {
            if audio.systemAudioFailed || audio.systemAudioStatus == .failed {
                return 0.0
            }
            return systemCapture?.bufferSuccessRate ?? 1.0
        }()

        let baseQuality = CaptureQuality.from(successRate: successRate)
        let adjustedQuality: CaptureQuality
        if audio.deviceSwitchCount >= 3 {
            adjustedQuality = .degraded
        } else if audio.deviceSwitchCount >= 1 || !audio.recordingGaps.isEmpty {
            switch baseQuality {
            case .excellent:
                adjustedQuality = .good
            case .good:
                adjustedQuality = .fair
            case .fair, .degraded:
                adjustedQuality = baseQuality
            }
        } else {
            adjustedQuality = baseQuality
        }

        return RecordingHealthInfo(
            captureQuality: adjustedQuality,
            audioGaps: audio.recordingGaps.count,
            deviceSwitches: audio.deviceSwitchCount,
            gapDescriptions: audio.recordingGaps.map { $0.description }
        )
    }

    /// Default "no issues" health info
    public static var perfect: RecordingHealthInfo {
        RecordingHealthInfo(
            captureQuality: .excellent,
            audioGaps: 0,
            deviceSwitches: 0,
            gapDescriptions: []
        )
    }
}

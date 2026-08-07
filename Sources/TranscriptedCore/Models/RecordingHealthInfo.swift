import Foundation

/// Recording health information for transcript metadata.
/// Captures quality metrics that get embedded in transcript YAML frontmatter.
public struct RecordingHealthInfo: Sendable {
    /// Capture quality rating based on buffer success rate.
    public enum CaptureQuality: String, Sendable {
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
    /// Issue #500: the host classified this recording as quiet-mic attenuation
    /// from a foreign call app holding the device in voice mode. Optional and
    /// defaulted so existing call sites stay source-compatible; classification
    /// stays app-side and only facts cross the library boundary.
    public let micAttenuatedByCallApp: Bool?
    /// MeetingMicBoostPromptOutcome rawValue from the host's in-meeting prompt.
    public let micBoostPrompt: String?
    /// True when only microphone audio was available for recovery/transcription.
    public let systemAudioMissing: Bool?
    /// True when microphone audio was missing or could not contribute usable
    /// speech. The system-audio transcript was still saved as a partial result.
    public let microphoneAudioUnusable: Bool?

    public init(
        captureQuality: CaptureQuality,
        audioGaps: Int,
        deviceSwitches: Int,
        gapDescriptions: [String],
        micAttenuatedByCallApp: Bool? = nil,
        micBoostPrompt: String? = nil,
        systemAudioMissing: Bool? = nil,
        microphoneAudioUnusable: Bool? = nil
    ) {
        self.captureQuality = captureQuality
        self.audioGaps = audioGaps
        self.deviceSwitches = deviceSwitches
        self.gapDescriptions = gapDescriptions
        self.micAttenuatedByCallApp = micAttenuatedByCallApp
        self.micBoostPrompt = micBoostPrompt
        self.systemAudioMissing = systemAudioMissing
        self.microphoneAudioUnusable = microphoneAudioUnusable
    }

    public func markingSystemAudioMissing() -> RecordingHealthInfo {
        RecordingHealthInfo(
            captureQuality: .degraded,
            audioGaps: audioGaps,
            deviceSwitches: deviceSwitches,
            gapDescriptions: gapDescriptions,
            micAttenuatedByCallApp: micAttenuatedByCallApp,
            micBoostPrompt: micBoostPrompt,
            systemAudioMissing: true,
            microphoneAudioUnusable: microphoneAudioUnusable
        )
    }

    public func markingMicAttenuatedByCallApp(micBoostPrompt: String) -> RecordingHealthInfo {
        RecordingHealthInfo(
            captureQuality: captureQuality,
            audioGaps: audioGaps,
            deviceSwitches: deviceSwitches,
            gapDescriptions: gapDescriptions,
            micAttenuatedByCallApp: true,
            micBoostPrompt: micBoostPrompt,
            systemAudioMissing: systemAudioMissing,
            microphoneAudioUnusable: microphoneAudioUnusable
        )
    }

    public func markingSystemAudioDegraded() -> RecordingHealthInfo {
        RecordingHealthInfo(
            captureQuality: .degraded,
            audioGaps: audioGaps,
            deviceSwitches: deviceSwitches,
            gapDescriptions: gapDescriptions,
            micAttenuatedByCallApp: micAttenuatedByCallApp,
            micBoostPrompt: micBoostPrompt,
            systemAudioMissing: systemAudioMissing,
            microphoneAudioUnusable: microphoneAudioUnusable
        )
    }

    public func markingMicrophoneAudioUnusable() -> RecordingHealthInfo {
        RecordingHealthInfo(
            captureQuality: .degraded,
            audioGaps: audioGaps,
            deviceSwitches: deviceSwitches,
            gapDescriptions: gapDescriptions,
            micAttenuatedByCallApp: micAttenuatedByCallApp,
            micBoostPrompt: micBoostPrompt,
            systemAudioMissing: systemAudioMissing,
            microphoneAudioUnusable: true
        )
    }

    /// Create health info from Audio instance.
    /// Build a health snapshot from the live `Audio` object.
    ///
    /// `overrideSystemAudioStatus` lets the caller pass a status value that
    /// was captured BEFORE `Audio.stop()` reset live UI state. Callers that
    /// snapshot health AFTER stop must pass the pre-stop status here, or
    /// the `.failed` check below will silently miss real system-audio
    /// failures (because stop sets status to `.unknown`).
    public static func from(
        audio: Audio,
        systemCapture: (any SystemAudioCaptureEngine)?,
        overrideSystemAudioStatus: SystemAudioStatus? = nil
    ) -> RecordingHealthInfo {
        let effectiveSystemAudioStatus = overrideSystemAudioStatus ?? audio.systemAudioStatus
        let successRate: Double = {
            if audio.systemAudioFailed
                || effectiveSystemAudioStatus == .failed
                || effectiveSystemAudioStatus == .silent {
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

    /// Default "no issues" health info.
    public static var perfect: RecordingHealthInfo {
        RecordingHealthInfo(
            captureQuality: .excellent,
            audioGaps: 0,
            deviceSwitches: 0,
            gapDescriptions: []
        )
    }
}

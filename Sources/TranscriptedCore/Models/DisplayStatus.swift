import Foundation
import AVFoundation

// MARK: - Display Status for UI (Goal-Gradient Effect)
// Users are more motivated when they can see visible progress
// Simplified to 4 user-focused phases for cognitive clarity

public enum DisplayStatus: Equatable {
    case idle

    // Processing phases
    case gettingReady                    // 0-15%: Loading audio, initial setup
    case transcribing(progress: Double)  // 15-75%: Active transcription
    case finishing                       // 95-100%: Saving, final steps

    // Completion states
    case transcriptSaved                 // Complete — transcript saved
    case failed(message: String)         // Error state

    /// Computed progress value (0.0 to 1.0) for UI progress bar
    public var progress: Double {
        switch self {
        case .idle:
            return 0.0
        case .gettingReady:
            return 0.10
        case .transcribing(let p):
            // Map transcription progress (0-1) to (0.15-0.75)
            return 0.15 + (p * 0.60)
        case .finishing:
            return 0.97
        case .transcriptSaved:
            return 1.0
        case .failed:
            return 0.0
        }
    }

    /// User-friendly status text (outcome-oriented, not technical)
    public var statusText: String {
        switch self {
        case .idle:
            return "Ready"
        case .gettingReady:
            return "Preparing..."
        case .transcribing:
            return "Transcribing..."
        case .finishing:
            return "Almost done..."
        case .transcriptSaved:
            return "Saved"
        case .failed(let message):
            return message
        }
    }

    /// Icon for the status (SF Symbol name)
    public var icon: String {
        switch self {
        case .idle:
            return "circle"
        case .gettingReady, .transcribing, .finishing:
            return "arrow.triangle.2.circlepath"
        case .transcriptSaved:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    /// Whether this is a "processing" state (show progress indicator)
    public var isProcessing: Bool {
        switch self {
        case .gettingReady, .transcribing, .finishing:
            return true
        default:
            return false
        }
    }
}

public struct TranscriptionTask: Identifiable {
    public let id: UUID
    public let micURL: URL
    public let systemURL: URL?
    public let outputFolder: URL
    public let startTime: Date
    public let healthInfo: RecordingHealthInfo?

    public init(micURL: URL, systemURL: URL?, outputFolder: URL, healthInfo: RecordingHealthInfo? = nil) {
        self.id = UUID()
        self.micURL = micURL
        self.systemURL = systemURL
        self.outputFolder = outputFolder
        self.startTime = Date()
        self.healthInfo = healthInfo
    }
}

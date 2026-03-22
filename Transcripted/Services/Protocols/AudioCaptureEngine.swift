import Foundation
import Combine

// MARK: - Audio Capture Engine Protocol
// Conformer: Audio

protocol AudioCaptureEngine: ObservableObject {
    /// Whether audio is currently being recorded
    var isRecording: Bool { get }

    /// Current audio level (0.0 to 1.0+)
    var audioLevel: Float { get }

    /// Duration of current recording in seconds
    var recordingDuration: TimeInterval { get }

    /// System audio capture health status
    var systemAudioStatus: SystemAudioStatus { get }

    /// URL of the mic audio file for the current/last recording
    var micAudioFileURL: URL? { get }

    /// URL of the system audio file for the current/last recording
    var systemAudioFileURL: URL? { get }

    /// Start recording
    func start()

    /// Stop recording
    func stop()

    /// Callback when recording starts
    var onRecordingStart: (() -> Void)? { get set }

    /// Callback when recording completes with audio file URLs
    var onRecordingComplete: ((URL?, URL?) -> Void)? { get set }

    /// Create health info snapshot for transcript metadata
    func createHealthInfo() -> RecordingHealthInfo
}

import Foundation
import QuartzCore
@preconcurrency import AVFoundation
import CoreAudio
import Combine
import Synchronization

// Per-recording requests (language, system audio) that apply to the
// next recording and stay fixed for the active one.
extension Audio {
    /// Persisted with the recording journal for crash recovery. Changes apply
    /// to the next recording only, never to an active capture or its recovery.
    public var recordingLanguageSelection: TranscriptionLanguageSelection {
        get {
            recordingLanguageLock.lock()
            defer { recordingLanguageLock.unlock() }
            return requestedRecordingLanguage
        }
        set {
            recordingLanguageLock.lock()
            requestedRecordingLanguage = newValue
            recordingLanguageLock.unlock()
        }
    }

    var languageSelectionForCurrentRecording: TranscriptionLanguageSelection {
        recordingLanguageLock.lock()
        defer { recordingLanguageLock.unlock() }
        return activeRecordingLanguage
    }

    /// False when the user chose to record only their mic. The next
    /// recording then never builds the system-audio tap, so it can't raise
    /// the macOS System Audio Recording box or hold a silent tap open. Set
    /// before `start()`; like the language, it applies to the next recording.
    public var capturesSystemAudio: Bool {
        get {
            systemAudioCaptureRequestLock.lock()
            defer { systemAudioCaptureRequestLock.unlock() }
            return requestedCapturesSystemAudio
        }
        set {
            systemAudioCaptureRequestLock.lock()
            requestedCapturesSystemAudio = newValue
            systemAudioCaptureRequestLock.unlock()
        }
    }

    /// Whether the current recording runs the system-audio tap. Fixed at
    /// start so a later change to `capturesSystemAudio` can't strand it.
    public var currentRecordingCapturesSystemAudio: Bool {
        systemAudioCaptureRequestLock.lock()
        defer { systemAudioCaptureRequestLock.unlock() }
        return activeRecordingCapturesSystemAudio
    }
}

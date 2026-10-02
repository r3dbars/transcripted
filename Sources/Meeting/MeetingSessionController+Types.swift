// MeetingSessionController+Types.swift
// Nested types and statics of MeetingSessionController, plus the diagnosticName
// and prompt/warmup bridge extensions.

import AppKit
import Combine
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
extension MeetingSessionController {
    enum StartTrigger: String {
        case hotkey = "hotkey"
        case menu = "menu"
        case onboarding = "onboarding"
        case detectedPrompt = "detected_prompt"
        case fileImport = "file_import"
        case savedMeetingRetranscription = "saved_meeting_retranscription"
        case unknown = "unknown"
    }

    enum StopReason: String {
        case hotkeyToggle = "hotkey_toggle"
        case overlayStopButton = "overlay_stop_button"
        case menuBarStopButton = "menu_bar_stop_button"
        case quitConfirmation = "quit_confirmation"
        case audioInactivityPrompt = "audio_inactivity_prompt"
        case audioInactivityTimeout = "audio_inactivity_timeout"
        case audioRouteWarning = "audio_route_warning"
        case systemAudioWarning = "system_audio_warning"
        case unknown = "unknown"
    }

    enum RecordingCancelReason: String {
        case discardButton = "discard_button"
        case unknown = "unknown"
    }

    enum TranscriptionCancelReason: String {
        case userRequested = "user_requested"
        case unknown = "unknown"
    }

    typealias TerminalTranscriptionOutcome = MeetingTerminalTranscriptionOutcome

    struct RecordingStopSnapshot {
        let telemetryIdentity: UUID?
        let trigger: StartTrigger
        let systemAudioStatus: SystemAudioStatus
        let durationSeconds: TimeInterval
        var durationMilliseconds: Int { Int(durationSeconds * 1000) }
        let healthInfo: RecordingHealthInfo
        let pipelineSnapshot: AudioPipelineDiagnosticsSnapshot
        let suggestedTitle: String?
        let recordingStartedAt: Date?
        let languageSelection: TranscriptionLanguageSelection
        let sttModel: TranscriptionModelChoice
        let isMicOnlyByChoice: Bool
        /// The system-audio tap never ran ("Record Just My Mic"). Unlike
        /// `isMicOnlyByChoice`, false when "Turn It On" got no macOS answer
        /// and the tap still ran.
        let skippedSystemAudioTap: Bool
    }

    /// How long the person was recording, Record to Stop. The duration timer
    /// can lag, so the start timestamp wins when it says longer. Unknown when
    /// neither is available, which makes Core keep the audio.
    static func recordingSessionLength(timerSeconds: TimeInterval, startedAt: Date?, now: Date = Date()) -> TimeInterval? {
        let wallClock = startedAt.map { now.timeIntervalSince($0) }
        let length = max(timerSeconds, wallClock ?? 0)
        guard length > 0 else { return nil }
        return length
    }

    /// Telemetry category for a discarded accidental start. Kept out of
    /// `MeetingFailureKind` on purpose: it is not a failure, and nothing on
    /// screen should ever classify or explain it as one.
    static let accidentalStartFailureKind = "accidental_start"
}

extension MeetingSessionController.State {
    var diagnosticName: String {
        switch self {
        case .idle: return "idle"
        case .loadingModels: return "loading_models"
        case .ready: return "ready"
        case .startingRecording: return "starting_recording"
        case .recording: return "recording"
        case .stoppingRecording: return "stopping_recording"
        case .transcribing: return "transcribing"
        case .error: return "error"
        }
    }
}

extension DisplayStatus {
    var diagnosticName: String {
        switch self {
        case .idle: return "idle"
        case .gettingReady: return "getting_ready"
        case .transcribing: return "transcribing"
        case .finishing: return "finishing"
        case .transcriptSaved: return "transcript_saved"
        case .discardedAccidentalStart: return "discarded_accidental_start"
        case .failed: return "failed"
        }
    }
}

extension MeetingWarmupMeetingState {
    init(_ state: DiarizationModelState) {
        switch state {
        case .notLoaded:
            self = .notLoaded
        case .loading:
            self = .loading
        case .ready:
            self = .ready
        case .failed(let message):
            self = .failed(message)
        }
    }
}

extension DiarizationModelState {
    var diagnosticName: String {
        switch self {
        case .notLoaded: return "not_loaded"
        case .loading: return "loading"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }
}

extension SystemAudioStatus {
    var diagnosticName: String {
        switch self {
        case .unknown: return "unknown"
        case .healthy: return "healthy"
        case .reconnecting: return "reconnecting"
        case .silent: return "silent"
        case .failed: return "failed"
        }
    }
}

@available(macOS 14.0, *)
extension MeetingPromptSessionPromptState {
    init(_ state: MeetingSessionController.State) {
        switch state {
        case .idle:
            self = .idle
        case .loadingModels:
            self = .loadingModels
        case .ready:
            self = .ready
        // Starting/stopping are treated as "recording" here on purpose: a
        // detected-meeting prompt must not fire while capture is engaging or
        // tearing down any more than while it's steady-state recording.
        case .startingRecording, .recording, .stoppingRecording:
            self = .recording
        case .transcribing:
            self = .transcribing
        case .error:
            self = .error
        }
    }
}

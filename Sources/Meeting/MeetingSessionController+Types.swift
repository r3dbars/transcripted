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
        /// macOS said System Audio Recording access was on for this
        /// recording. Read only when no system audio was heard.
        let systemAudioAccessConfirmedByMacOS: Bool

        /// What the saved file says about system audio. Telemetry ignores
        /// the macOS answer so it keeps counting silent system tracks.
        func systemSignalEvidence(observed: Bool, forTelemetry: Bool = false) -> Bool? {
            MeetingMicOnlyRecordingPolicy.systemAudioSignalEvidence(
                observed: observed,
                micOnlyByChoice: isMicOnlyByChoice,
                accessConfirmedByMacOS: !forTelemetry && systemAudioAccessConfirmedByMacOS
            )
        }
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

/// What the transcription pipeline is doing, as the UI sees it. The session
/// keeps its Core `DisplayStatus` for its own bookkeeping; UI modules read
/// this Meeting-owned copy so they never have to name the Core type.
enum MeetingTranscriptionStatus: Equatable {
    case idle
    case gettingReady
    case transcribing(progress: Double)
    case finishing
    case transcriptSaved
    case failed(message: String)
    case discardedAccidentalStart

    init(_ status: DisplayStatus) {
        switch status {
        case .idle: self = .idle
        case .gettingReady: self = .gettingReady
        case .transcribing(let progress): self = .transcribing(progress: progress)
        case .finishing: self = .finishing
        case .transcriptSaved: self = .transcriptSaved
        case .failed(let message): self = .failed(message: message)
        case .discardedAccidentalStart: self = .discardedAccidentalStart
        }
    }

    /// Progress bar value (0...1). Delegates to `DisplayStatus` so the
    /// phase-to-percent mapping stays in one place.
    var progress: Double { coreStatus.progress }

    var isProcessing: Bool { coreStatus.isProcessing }

    private var coreStatus: DisplayStatus {
        switch self {
        case .idle: return .idle
        case .gettingReady: return .gettingReady
        case .transcribing(let progress): return .transcribing(progress: progress)
        case .finishing: return .finishing
        case .transcriptSaved: return .transcriptSaved
        case .failed(let message): return .failed(message: message)
        case .discardedAccidentalStart: return .discardedAccidentalStart
        }
    }
}

/// Result of the one bounded input-route stabilization attempt, as the
/// overlay sees it. Same four outcomes as Core's
/// `CaptureRouteStabilizationOutcome`, owned here so UI modules don't name it.
enum MeetingRouteWarning: Equatable {
    case notNeeded
    case switchedToBuiltIn
    case builtInUnavailable
    case switchFailed

    init(_ outcome: CaptureRouteStabilizationOutcome) {
        switch outcome {
        case .notNeeded: self = .notNeeded
        case .switchedToBuiltIn: self = .switchedToBuiltIn
        case .builtInUnavailable: self = .builtInUnavailable
        case .switchFailed: self = .switchFailed
        }
    }
}

@available(macOS 14.0, *)
@MainActor
extension MeetingSessionController {
    /// Current transcription status for UI readers.
    var transcriptionStatus: MeetingTranscriptionStatus {
        MeetingTranscriptionStatus(displayStatus)
    }

    /// Transcription status changes for UI subscribers (emits the current
    /// value on subscribe, like `$displayStatus`).
    var transcriptionStatusPublisher: AnyPublisher<MeetingTranscriptionStatus, Never> {
        $displayStatus
            .map(MeetingTranscriptionStatus.init)
            .eraseToAnyPublisher()
    }

    /// Route-stabilization warning changes for UI subscribers (emits the
    /// current value on subscribe, like `$audioRouteWarning`).
    var routeWarningPublisher: AnyPublisher<MeetingRouteWarning?, Never> {
        $audioRouteWarning
            .map { $0.map(MeetingRouteWarning.init) }
            .eraseToAnyPublisher()
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

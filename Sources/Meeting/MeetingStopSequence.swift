// MeetingStopSequence.swift
// The ordering rules of the meeting stop paths, pulled out of
// MeetingSessionController so tests can run them against a fake capture.
// Foundation-only on purpose: it compiles in the fast-test runner.

import Foundation

/// The parts of the live meeting capture the stop paths read or drive.
/// `MeetingCaptureBridge` conforms; tests use a fake that records calls.
@MainActor
protocol MeetingCaptureControlling: AnyObject {
    /// This capture saw real system-audio PCM (not just a granted permission).
    var hasObservedSystemAudioSignal: Bool { get }
    /// Draining the system-audio tail failed after stop.
    var systemAudioFinalizationFailed: Bool { get }
    /// macOS explicitly refused system audio when this capture started.
    var systemAudioStartPermissionExplicitlyDenied: Bool { get }
    /// Wait for the shared-meeting-mic dictation handler to finish its queue.
    func flushSharedDictationMicHandler() async
}

/// What the capture itself says about system audio, read in one place so the
/// unverified-audio warning, saved health and the grant action never fall
/// back to a cached permission answer.
struct MeetingCaptureHealthEvidence: Equatable {
    let systemAudioSignalVerified: Bool
    let systemAudioFinalizationFailed: Bool
    /// Show "Grant System Audio Access" only for a typed denial.
    let systemAudioPermissionRecoveryNeeded: Bool

    @MainActor
    static func make(capture: MeetingCaptureControlling) -> MeetingCaptureHealthEvidence {
        MeetingCaptureHealthEvidence(
            systemAudioSignalVerified: capture.hasObservedSystemAudioSignal,
            systemAudioFinalizationFailed: capture.systemAudioFinalizationFailed,
            systemAudioPermissionRecoveryNeeded: MeetingRecordingStartGate.shouldOfferSystemAudioPermissionRecovery(
                explicitSystemAudioPermissionDenialObserved: capture.systemAudioStartPermissionExplicitlyDenied
            )
        )
    }
}

enum MeetingStopSequence {
    static let unexpectedStopReason: StaticString = "unexpected_capture_stop"

    /// Capture and the shared relay have already stopped. Release the capture
    /// gate before slow archive I/O, and never overwrite a newer user action.
    @MainActor
    static func archiveUnexpectedStop(
        releaseCapture: () -> Void,
        archive: () async -> Bool,
        stillOwnsCompletion: () -> Bool,
        finish: (Bool) -> Void
    ) async -> Bool {
        releaseCapture()
        let preserved = await archive()
        if stillOwnsCompletion() { finish(preserved) }
        return preserved
    }

    /// Which terminal ended an app-initiated stop.
    enum StopTerminal: Equatable {
        /// Stop timed out; the meeting went to the failed queue.
        case timedOut
        /// Neither track produced a file.
        case noAudio
        /// At least one track survived; degraded capture was reported and the
        /// meeting goes on to transcription.
        case continueToTranscription
    }

    /// The first half of an unexpected capture stop. Only a session still in
    /// `.recording` reacts: app-initiated stops leave `.recording` before
    /// capture tears down. It leaves `.recording` before any suspension, so
    /// stop and cancel (which need `.recording`) can't interleave, then drains
    /// the shared PCM relay and hands the mic back to in-flight dictation.
    /// Returns false (and does nothing) when the stop isn't unexpected.
    @MainActor
    static func unexpectedStop(
        state: MeetingSessionState,
        transition: (_ to: MeetingSessionState, _ reason: StaticString) -> Void,
        quietLiveWarnings: () -> Void,
        capture: MeetingCaptureControlling,
        clearRelay: () -> Void,
        resumeDictation: () async -> Void
    ) async -> Bool {
        guard case .recording = state else { return false }
        transition(.stoppingRecording, unexpectedStopReason)
        quietLiveWarnings()
        await capture.flushSharedDictationMicHandler()
        clearRelay()
        await resumeDictation()
        return true
    }

    /// Picks exactly one terminal for a finished stop. The typed timeout and
    /// no-audio terminals are the canonical Sentry issues for those failures,
    /// so they return before the generic degraded-capture report runs.
    static func stopTerminal(
        stopResult: CaptureStopResult,
        files: (micURL: URL?, systemURL: URL?),
        onTimeout: () -> Void,
        onNoAudio: () -> Void,
        report: () -> Void
    ) -> StopTerminal {
        if stopResult.didTimeOut {
            onTimeout()
            return .timedOut
        }
        guard files.micURL != nil || files.systemURL != nil else {
            onNoAudio()
            return .noAudio
        }
        report()
        return .continueToTranscription
    }
}

// MeetingCaptureBridge.swift
// Thin bridge to TranscriptedCore's Audio class. Owns one `Audio` instance,
// re-publishes the properties the meeting UI needs, and exposes a closure-based
// "recording completed" signal that the session controller can await.
//
// Why a bridge rather than using `Audio` directly from MeetingSessionController:
//   1. `Audio` is NOT @MainActor — it runs on the CoreAudio thread. Putting a
//      direct reference inside a @MainActor object forces us to hop threads on
//      every property read. The bridge is @MainActor and exposes @Published
//      mirrors so AppKit bindings stay on the main thread.
//   2. `Audio`'s public callback surface is `onRecordingComplete: ((URL?, URL?) -> Void)?`,
//      which is awkward to await. The bridge converts that into an async-friendly
//      `startRecording()` / `stopAndAwaitFiles()` pair.
//   3. Keeping the bridge isolated from the pipeline lets Lane C swap in a mock
//      for preview/testing without touching CoreAudio.

import AppKit
import AVFoundation
import Combine
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class MeetingCaptureBridge: ObservableObject {

    // MARK: - Published state (mirrored from Core's Audio)

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var audioLevel: Float = 0          // mic-only level (preserved for existing callers)
    @Published private(set) var systemLevel: Float = 0         // system audio level (latest frame from Core's rolling history)
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var systemAudioStatus: SystemAudioStatus = .unknown
    @Published private(set) var errorMessage: String?

    // MARK: - Underlying capture

    /// Core's CoreAudio capture. NOT @MainActor — UI updates come via the
    /// Combine subscriptions below, which hop to main automatically.
    let audio: Audio

    private var cancellables: Set<AnyCancellable> = []
    private let completionAttempt = MeetingCaptureAttempt<CaptureStopResult>()
    private let startAttempt = MeetingCaptureAttempt<Bool>()
    private var timedOutStopCompletionHandler: ((CaptureStopResult) -> Void)?
    var micLivePreviewHandler: ((AVAudioPCMBuffer) -> Void)?
    var sharedDictationMicHandler: ((AVAudioPCMBuffer) -> Void)?

    init(audio: Audio = Audio()) {
        self.audio = audio
        wireCallbacks()
        wireSubscriptions()
    }

    deinit {
        startAttempt.reset()?.resume(returning: false)
        completionAttempt.reset()?.resume(returning: CaptureStopResult(
            micURL: audio.micAudioFileURL,
            systemURL: audio.systemAudioFileURL,
            didTimeOut: false
        ))
        // Combine cancellables auto-release. Audio's own deinit tears down CoreAudio.
    }

    // MARK: - Recording lifecycle

    /// Start a new recording session. Returns immediately; the session remains
    /// active until `stopAndAwaitFiles()` is called.
    func startRecording() async -> Bool {
        completionAttempt.reset()?.resume(returning: currentStopResult())
        if audio.isRecording { return true }

        errorMessage = nil

        // Apply the user's microphone-processing choice before each
        // recording. VPIO defaults off (no Zoom ducking); enable only when
        // the user has explicitly opted in for Safari/Firefox WebRTC
        // calls. Read once at start; mid-session changes don't take effect
        // until the next recording.
        audio.enableVoiceProcessing = MicrophoneProcessingPreferences.isVoiceProcessingEnabled()

        return await withCheckedContinuation { continuation in
            startAttempt.reset()?.resume(returning: false)
            let attemptID = startAttempt.begin(continuation)

            audio.start()

            startAttempt.setTimeoutTask(Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: TranscriptedConstants.meetingStartTimeout)
                guard let self,
                      let continuation = self.startAttempt.resetIfCurrent(attemptID) else { return }
                self.errorMessage = AudioCaptureStartState.timeoutFailureMessage(
                    existingErrorMessage: self.errorMessage
                )
                self.audio.stop()
                continuation.resume(returning: false)
            })
        }
    }

    /// Stop the current recording and wait for Core's Audio to finish writing
    /// the mic + system WAV files to disk. Returns a result that distinguishes
    /// natural completion (`didTimeOut == false`) from `meetingStopTimeout`
    /// expiry (`didTimeOut == true`). On timeout the WAV header may not be
    /// fully patched, so the caller should treat the audio as failed-but-
    /// recoverable rather than enqueuing it for transcription directly.
    func stopAndAwaitFiles(
        onTimedOutCompletion: ((CaptureStopResult) -> Void)? = nil
    ) async -> CaptureStopResult {
        guard audio.isRecording else {
            return currentStopResult()
        }
        let stopTimeout = TranscriptedConstants.meetingStopTimeout(
            forRecordingDuration: max(recordingDuration, audio.recordingDuration)
        )

        return await withCheckedContinuation { continuation in
            let attemptID = completionAttempt.begin(continuation)
            audio.stop()

            completionAttempt.setTimeoutTask(Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: stopTimeout)
                guard let self,
                      let continuation = self.completionAttempt.resetIfCurrent(attemptID) else { return }

                EventReporter.shared.capture(
                    level: .error,
                    engine: "meeting",
                    event: "recording_stop_timeout",
                    message: "Meeting recording stop timed out while waiting for audio files to close",
                    context: self.audio.createPipelineDiagnosticsSnapshot().privacySafeContext.merging(
                        [
                            "mic_file_available": "\(self.audio.micAudioFileURL != nil)",
                            "system_file_available": "\(self.audio.systemAudioFileURL != nil)",
                            "stop_timeout_seconds": "\(stopTimeout / 1_000_000_000)",
                        ],
                        uniquingKeysWith: { _, new in new }
                    )
                )
                self.timedOutStopCompletionHandler = onTimedOutCompletion
                continuation.resume(returning: self.currentStopResult(didTimeOut: true))
            })
        }
    }

    /// Stop the current recording, wait for file handles to close, then remove
    /// the just-captured scratch audio instead of handing it to transcription.
    func stopAndDiscardFiles() async -> CaptureStopResult {
        let result = await stopAndAwaitFiles()
        MeetingRecordingCleanup.discardFiles(micURL: result.micURL, systemURL: result.systemURL)
        audio.micAudioFileURL = nil
        audio.systemAudioFileURL = nil
        return result
    }

    func pipelineDiagnosticsSnapshot(
        overrideSystemAudioStatus: SystemAudioStatus? = nil
    ) -> AudioPipelineDiagnosticsSnapshot {
        audio.createPipelineDiagnosticsSnapshot(overrideSystemAudioStatus: overrideSystemAudioStatus)
    }

    func routeVolumeDiagnosticsContext(currentPhase: String) -> [String: String] {
        audio.createRouteVolumeDiagnosticsContext(currentPhase: currentPhase)
    }

    // MARK: - Private

    private func finishPendingStartAttemptIfPossible() {
        switch AudioCaptureStartState.meetingCaptureOutcome(
            isRecording: audio.isRecording,
            systemAudioFileURL: audio.systemAudioFileURL,
            errorMessage: errorMessage
        ) {
        case .waiting:
            return
        case .ready:
            startAttempt.reset()?.resume(returning: true)
        case .failed(let message):
            guard let continuation = startAttempt.reset() else { return }
            errorMessage = message
            if audio.isRecording {
                audio.stop()
            }
            continuation.resume(returning: false)
        }
    }

    private func wireCallbacks() {
        audio.onRecordingComplete = { [weak self] micURL, systemURL in
            // This closure fires on whichever queue Core's Audio dispatches from.
            // Hop to main and resume the continuation exactly once.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = CaptureStopResult(
                    micURL: micURL,
                    systemURL: systemURL,
                    didTimeOut: false
                )
                if let continuation = self.completionAttempt.reset() {
                    self.timedOutStopCompletionHandler = nil
                    continuation.resume(returning: result)
                    return
                }

                let handler = self.timedOutStopCompletionHandler
                self.timedOutStopCompletionHandler = nil
                handler?(result)
            }
        }

        // Capture-lifecycle cues used to live inside Core (NSSound("Tink") on
        // start, NSSound("Pop") on stop). Core no longer depends on AppKit for
        // cosmetic UI; the host plays the sounds here. Audio fires the cue from
        // the main queue (via DispatchQueue.main.async / MainActor.run inside
        // the lifecycle helpers), but we still bounce through Task @MainActor
        // to match the rest of the bridge's threading discipline.
        audio.onCaptureLifecycleCue = { cue in
            Task { @MainActor in
                switch cue {
                case .recordingStarted:
                    NSSound(named: "Tink")?.play()
                case .recordingStopped:
                    NSSound(named: "Pop")?.play()
                }
            }
        }
    }

    private func wireSubscriptions() {
        // Each @Published on Audio feeds our main-actor mirror. The erase/assign
        // pattern matches how STTRouter wraps ParakeetEngine today.
        audio.$isRecording
            .receive(on: RunLoop.main)
            .assign(to: &$isRecording)

        audio.$audioLevel
            .receive(on: RunLoop.main)
            .assign(to: &$audioLevel)

        // System audio level is published as a rolling 15-frame history by Core.
        // We take the most recent frame as the current "system level" for the UI.
        audio.$systemAudioLevelHistory
            .map { $0.last ?? 0 }
            .receive(on: RunLoop.main)
            .assign(to: &$systemLevel)

        audio.$recordingDuration
            .receive(on: RunLoop.main)
            .assign(to: &$recordingDuration)

        audio.$systemAudioStatus
            .receive(on: RunLoop.main)
            .assign(to: &$systemAudioStatus)

        audio.$error
            .receive(on: RunLoop.main)
            .sink { [weak self] errorMessage in
                guard let self else { return }
                self.errorMessage = errorMessage
                self.finishPendingStartAttemptIfPossible()
            }
            .store(in: &cancellables)

        sinkStartAttemptTriggers(from: audio.$isRecording)
        sinkStartAttemptTriggers(from: audio.$systemAudioFileURL)
    }

    private func currentStopResult(didTimeOut: Bool = false) -> CaptureStopResult {
        CaptureStopResult(
            micURL: audio.micAudioFileURL,
            systemURL: audio.systemAudioFileURL,
            didTimeOut: didTimeOut
        )
    }

    private func sinkStartAttemptTriggers<Output>(
        from publisher: Published<Output>.Publisher
    ) {
        publisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.finishPendingStartAttemptIfPossible()
            }
            .store(in: &cancellables)
    }
}

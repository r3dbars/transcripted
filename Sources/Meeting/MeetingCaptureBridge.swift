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

/// Result of a stop request. `didTimeOut == true` means we did not receive
/// `Audio.onRecordingComplete` within `meetingStopTimeout`, so the WAV files
/// at the returned URLs may not be fully finalized — the controller should
/// route the audio to the failed queue rather than enqueuing for transcription.
struct CaptureStopResult {
    let micURL: URL?
    let systemURL: URL?
    let didTimeOut: Bool
}

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

    /// Fulfilled when Core's Audio reports recording completed. Cleared each
    /// time `startRecording` runs so back-to-back sessions do not leak state.
    private var completionContinuation: CheckedContinuation<CaptureStopResult, Never>?
    private var completionAttemptID: UUID?
    private var completionTimeoutTask: Task<Void, Never>?
    private var startContinuation: CheckedContinuation<Bool, Never>?
    private var startAttemptID: UUID?
    private var startTimeoutTask: Task<Void, Never>?

    init(audio: Audio = Audio()) {
        self.audio = audio
        wireCallbacks()
        wireSubscriptions()
    }

    deinit {
        startTimeoutTask?.cancel()
        startContinuation?.resume(returning: false)
        completionTimeoutTask?.cancel()
        completionContinuation?.resume(returning: CaptureStopResult(
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
        resetCompletionAttempt()?.resume(returning: currentStopResult())
        if audio.isRecording { return true }

        errorMessage = nil

        return await withCheckedContinuation { continuation in
            resetStartAttempt()?.resume(returning: false)

            let attemptID = UUID()
            startAttemptID = attemptID
            startContinuation = continuation

            audio.start()

            startTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: TranscriptedConstants.meetingStartTimeout)
                guard let self,
                      self.startAttemptID == attemptID,
                      let continuation = self.startContinuation else { return }
                self.errorMessage = AudioCaptureStartState.timeoutFailureMessage(
                    existingErrorMessage: self.errorMessage
                )
                _ = self.resetStartAttempt()
                if self.audio.isRecording {
                    self.audio.stop()
                }
                continuation.resume(returning: false)
            }
        }
    }

    /// Stop the current recording and wait for Core's Audio to finish writing
    /// the mic + system WAV files to disk. Returns a result that distinguishes
    /// natural completion (`didTimeOut == false`) from `meetingStopTimeout`
    /// expiry (`didTimeOut == true`). On timeout the WAV header may not be
    /// fully patched, so the caller should treat the audio as failed-but-
    /// recoverable rather than enqueuing it for transcription directly.
    func stopAndAwaitFiles() async -> CaptureStopResult {
        guard audio.isRecording else {
            return currentStopResult()
        }

        return await withCheckedContinuation { continuation in
            completionTimeoutTask?.cancel()
            let attemptID = UUID()
            completionAttemptID = attemptID
            self.completionContinuation = continuation
            self.audio.stop()

            completionTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: TranscriptedConstants.meetingStopTimeout)
                guard let self,
                      self.completionAttemptID == attemptID,
                      let continuation = self.completionContinuation else { return }

                _ = self.resetCompletionAttempt()
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "meeting",
                    event: "recording_stop_timeout",
                    message: "Meeting recording stop timed out while waiting for audio files to close",
                    context: [
                        "mic_file_available": "\(self.audio.micAudioFileURL != nil)",
                        "system_file_available": "\(self.audio.systemAudioFileURL != nil)",
                    ]
                )
                continuation.resume(returning: self.currentStopResult(didTimeOut: true))
            }
        }
    }

    /// Stop the current recording, wait for file handles to close, then remove
    /// the just-captured scratch audio instead of handing it to transcription.
    func stopAndDiscardFiles() async -> (micURL: URL?, systemURL: URL?) {
        let result = await stopAndAwaitFiles()
        MeetingRecordingCleanup.discardFiles(micURL: result.micURL, systemURL: result.systemURL)
        audio.micAudioFileURL = nil
        audio.systemAudioFileURL = nil
        return (result.micURL, result.systemURL)
    }

    /// Snapshot of Core's recording health metadata for transcript
    /// frontmatter.
    ///
    /// `overrideSystemAudioStatus` lets the caller pass the system-audio
    /// status they captured BEFORE `stopAndAwaitFiles()` ran — useful
    /// because `Audio.stop()` resets `systemAudioStatus` to `.unknown` as
    /// part of its UI cleanup, which would otherwise mask a real `.failed`
    /// outcome in the resulting `captureQuality`.
    func healthInfo(
        overrideSystemAudioStatus: SystemAudioStatus? = nil
    ) -> RecordingHealthInfo {
        audio.createHealthInfo(overrideSystemAudioStatus: overrideSystemAudioStatus)
    }

    // MARK: - Live PCM buffer routing (dual-stream preview)
    //
    // These forward TranscriptedCore's new live-buffer hooks through the
    // bridge so MeetingSessionController can route mic + system buffers to
    // a pair of StreamingEouAsrManager instances without touching the
    // Audio class directly. Fired on the CoreAudio capture thread — the
    // handler MUST be real-time safe (no I/O, no locks held across async,
    // no allocations beyond small copies). See Audio.swift's
    // `onMicPCMBuffer` docstring in TranscriptedCore for the full contract.

    /// Install a live-preview handler for mic buffers, or clear with `nil`.
    /// Call once before `startRecording()`; do not reassign mid-session.
    func setMicLivePreviewHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        audio.onMicPCMBuffer = handler
    }

    /// Install a live-preview handler for system-audio buffers, or clear
    /// with `nil`. Call once before `startRecording()`; do not reassign
    /// mid-session.
    func setSystemLivePreviewHandler(_ handler: ((AVAudioPCMBuffer) -> Void)?) {
        audio.onSystemPCMBuffer = handler
    }

    // MARK: - Private

    private func finishPendingStartAttemptIfPossible() {
        guard let continuation = startContinuation else { return }

        switch AudioCaptureStartState.meetingCaptureOutcome(
            isRecording: audio.isRecording,
            systemAudioFileURL: audio.systemAudioFileURL,
            errorMessage: errorMessage
        ) {
        case .waiting:
            return
        case .ready:
            _ = resetStartAttempt()
            continuation.resume(returning: true)
        case .failed(let message):
            _ = resetStartAttempt()
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
                let continuation = self.resetCompletionAttempt()
                continuation?.resume(returning: CaptureStopResult(
                    micURL: micURL,
                    systemURL: systemURL,
                    didTimeOut: false
                ))
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

    private func resetStartAttempt() -> CheckedContinuation<Bool, Never>? {
        let continuation = startContinuation
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        startContinuation = nil
        startAttemptID = nil
        return continuation
    }

    private func resetCompletionAttempt() -> CheckedContinuation<CaptureStopResult, Never>? {
        let continuation = completionContinuation
        completionTimeoutTask?.cancel()
        completionTimeoutTask = nil
        completionContinuation = nil
        completionAttemptID = nil
        return continuation
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

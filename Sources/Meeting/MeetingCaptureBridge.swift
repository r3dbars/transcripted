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

    /// Fulfilled when Core's Audio reports recording completed. Cleared each
    /// time `startRecording` runs so back-to-back sessions do not leak state.
    private var completionContinuation: CheckedContinuation<(micURL: URL?, systemURL: URL?), Never>?
    private var startContinuation: CheckedContinuation<Bool, Never>?

    init(audio: Audio = Audio()) {
        self.audio = audio
        wireCallbacks()
        wireSubscriptions()
    }

    deinit {
        // Combine cancellables auto-release. Audio's own deinit tears down CoreAudio.
    }

    // MARK: - Recording lifecycle

    /// Start a new recording session. Returns immediately; the session remains
    /// active until `stopAndAwaitFiles()` is called.
    func startRecording() async -> Bool {
        if let continuation = completionContinuation {
            completionContinuation = nil
            continuation.resume(returning: (audio.micAudioFileURL, audio.systemAudioFileURL))
        }
        if audio.isRecording { return true }

        errorMessage = nil

        return await withCheckedContinuation { continuation in
            startContinuation?.resume(returning: false)
            startContinuation = continuation

            audio.start()

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: TranscriptedConstants.meetingStartTimeout)
                guard let self, let continuation = self.startContinuation else { return }
                self.errorMessage = AudioCaptureStartState.timeoutFailureMessage(
                    existingErrorMessage: self.errorMessage
                )
                self.startContinuation = nil
                if self.audio.isRecording {
                    self.audio.stop()
                }
                continuation.resume(returning: false)
            }
        }
    }

    /// Stop the current recording and wait for Core's Audio to finish writing
    /// the mic + system WAV files to disk. Returns the URLs of both files (system
    /// may be nil if capture failed or was disabled).
    func stopAndAwaitFiles() async -> (micURL: URL?, systemURL: URL?) {
        guard audio.isRecording else {
            return (audio.micAudioFileURL, audio.systemAudioFileURL)
        }

        return await withCheckedContinuation { continuation in
            self.completionContinuation = continuation
            self.audio.stop()
        }
    }

    /// Stop the current recording, wait for file handles to close, then remove
    /// the just-captured scratch audio instead of handing it to transcription.
    func stopAndDiscardFiles() async -> (micURL: URL?, systemURL: URL?) {
        let files = await stopAndAwaitFiles()
        MeetingRecordingCleanup.discardFiles(micURL: files.micURL, systemURL: files.systemURL)
        audio.micAudioFileURL = nil
        audio.systemAudioFileURL = nil
        return files
    }

    /// Snapshot of Core's recording health metadata for transcript frontmatter.
    func healthInfo() -> RecordingHealthInfo {
        audio.createHealthInfo()
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
            startContinuation = nil
            continuation.resume(returning: true)
        case .failed(let message):
            startContinuation = nil
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
                let continuation = self.completionContinuation
                self.completionContinuation = nil
                continuation?.resume(returning: (micURL, systemURL))
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

        audio.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.finishPendingStartAttemptIfPossible()
            }
            .store(in: &cancellables)

        audio.$systemAudioFileURL
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.finishPendingStartAttemptIfPossible()
            }
            .store(in: &cancellables)
    }
}

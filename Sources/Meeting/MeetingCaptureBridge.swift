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

import Combine
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class MeetingCaptureBridge: ObservableObject {

    // MARK: - Published state (mirrored from Core's Audio)

    @Published private(set) var isRecording: Bool = false
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var systemAudioStatus: SystemAudioStatus = .unknown

    // MARK: - Underlying capture

    /// Core's CoreAudio capture. NOT @MainActor — UI updates come via the
    /// Combine subscriptions below, which hop to main automatically.
    let audio: Audio

    private var cancellables: Set<AnyCancellable> = []

    /// Fulfilled when Core's Audio reports recording completed. Cleared each
    /// time `startRecording` runs so back-to-back sessions do not leak state.
    private var completionContinuation: CheckedContinuation<(micURL: URL?, systemURL: URL?), Never>?

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
    func startRecording() {
        guard !audio.isRecording else { return }
        audio.start()
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

    /// Snapshot of Core's recording health metadata for transcript frontmatter.
    func healthInfo() -> RecordingHealthInfo {
        audio.createHealthInfo()
    }

    // MARK: - Private

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

        audio.$recordingDuration
            .receive(on: RunLoop.main)
            .assign(to: &$recordingDuration)

        audio.$systemAudioStatus
            .receive(on: RunLoop.main)
            .assign(to: &$systemAudioStatus)
    }
}

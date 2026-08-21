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
    @Published private(set) var startFailureStage: AudioCaptureStartFailureStage = .unknown
    @Published private(set) var errorMessage: String?
    var systemAudioStartPermissionExplicitlyDenied: Bool {
        audio.systemAudioStartPermissionExplicitlyDenied
    }
    /// One-shot per recording: true once Core fired the issue #500
    /// `.micAttenuatedByForeignVoiceProcessing` cue. Reset at the next start.
    @Published private(set) var micAttenuationCueObserved: Bool = false
    /// One-shot per recording: set only after Core detects a real Bluetooth
    /// mic route outage and performs its bounded stabilization decision.
    @Published private(set) var routeStabilityWarningOutcome: CaptureRouteStabilizationOutcome?

    var onUnexpectedRecordingComplete: ((CaptureStopResult) -> Void)?
    /// One stable recovery seam for completions that arrive after their
    /// per-stop closure's bounded retention window.
    var onExpiredTimedOutRecordingComplete: ((UUID?, CaptureStopResult) -> Void)?
    /// A stop never completed within the bounded callback window. Core has
    /// transferred its journal from the live finalizer to recovery ownership.
    var onRecordingJournalFinalizationAbandoned: (() -> Void)?

    // MARK: - Underlying capture

    /// Core's CoreAudio capture. NOT @MainActor — UI updates come via the
    /// Combine subscriptions below, which hop to main automatically.
    let audio: Audio

    private var cancellables: Set<AnyCancellable> = []
    private let completionAttempt = MeetingCaptureAttempt<CaptureStopResult>()
    private let startAttempt = MeetingCaptureAttempt<Bool>()
    let micPCMRelay = MeetingMicPCMRelay()
    private var timedOutStopCompletions = TimedOutStopCompletionRegistry()
    private var timedOutStopCompletionExpiryTasks: [UInt64: Task<Void, Never>] = [:]
    private var expectedStopGeneration: UInt64?

    init(audio: Audio? = nil) {
        self.audio = audio ?? Audio(
            sleepWakeNotifications: AudioSleepWakeNotifications(
                center: NSWorkspace.shared.notificationCenter,
                willSleepName: Notification.Name("NSWorkspaceWillSleepNotification"),
                didWakeName: Notification.Name("NSWorkspaceDidWakeNotification")
            )
        )
        let micPCMRelay = self.micPCMRelay
        self.audio.onMicPCMBuffer = { [weak micPCMRelay] buffer in
            micPCMRelay?.enqueue(buffer)
        }
        wireCallbacks()
        wireSubscriptions()
    }

    // `isolated deinit` (available on this toolchain without any extra
    // language-mode flag — verified with `swiftc -typecheck` against a
    // standalone repro) keeps this teardown compiler-checked on MainActor
    // instead of relying on every release site happening to run there.
    // `MeetingCaptureAttempt` is itself @MainActor now, so a plain
    // (nonisolated) deinit could no longer touch `startAttempt`/
    // `completionAttempt` at all; isolating the whole deinit is simpler than
    // splitting teardown into an explicit `invalidate()`/`shutdown()` call
    // for a bridge whose only owner (`MeetingSessionController`) doesn't
    // need bespoke teardown sequencing before releasing it.
    isolated deinit {
        timedOutStopCompletionExpiryTasks.values.forEach { $0.cancel() }
        for continuation in startAttempt.reset() {
            continuation.resume(returning: false)
        }
        let stopResult = CaptureStopResult(
            micURL: audio.micAudioFileURL,
            systemURL: audio.systemAudioFileURL,
            didTimeOut: false
        )
        for continuation in completionAttempt.reset() {
            continuation.resume(returning: stopResult)
        }
        // Combine cancellables auto-release. Audio's own deinit tears down CoreAudio.
    }

    // MARK: - Recording lifecycle

    /// Start a new recording session. Returns immediately; the session remains
    /// active until `stopAndAwaitFiles()` is called.
    func startRecording() async -> Bool {
        expectedStopGeneration = nil
        let staleStopResult = currentStopResult()
        for continuation in completionAttempt.reset() {
            continuation.resume(returning: staleStopResult)
        }
        if audio.isRecording { return true }

        // Keep the immediately preceding timed-out stop across this start so
        // its generation-tagged callback can still reach its failed row. Once
        // another stop has advanced Core's generation, older journals/rows own
        // recovery and their retained closures can be released.
        let prunedGenerations = timedOutStopCompletions.prune(
            olderThan: audio.currentRecordingSessionGeneration
        )
        var abandonedJournalFinalization = false
        for generation in prunedGenerations {
            timedOutStopCompletionExpiryTasks.removeValue(forKey: generation)?.cancel()
            abandonedJournalFinalization = audio.abandonRecordingJournalFinalization(
                forStopGeneration: generation
            ) || abandonedJournalFinalization
        }
        if abandonedJournalFinalization {
            onRecordingJournalFinalizationAbandoned?()
        }

        errorMessage = nil
        startFailureStage = .unknown
        micAttenuationCueObserved = false
        routeStabilityWarningOutcome = nil

        // Apply the user's microphone-processing choice before each recording.
        // Read once at start; mid-session changes don't take effect until the
        // next recording except the explicit Boost Mic consent path below.
        let micProcessingMode = MicrophoneProcessingPreferences.mode()
        audio.enableVoiceProcessing = micProcessingMode.usesAppleVoiceProcessing
        audio.enableSoftwareAGC = micProcessingMode.allowsSoftwareAutogainFallback

        return await withCheckedContinuation { continuation in
            for pending in startAttempt.reset() {
                pending.resume(returning: false)
            }
            let attemptID = startAttempt.begin(continuation)

            audio.start()

            startAttempt.setTimeoutTask(Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: TranscriptedConstants.meetingStartTimeout)
                guard let self else { return }
                let waiters = self.startAttempt.resetIfCurrent(attemptID)
                guard !waiters.isEmpty else { return }
                let timeoutStage = AudioCaptureStartState.timeoutFailureStage(
                    micAudioStreaming: self.audio.micAudioStreaming,
                    systemAudioStreaming: self.audio.systemAudioStreaming
                )
                if self.audio.startFailureStage == .unknown, timeoutStage != .unknown {
                    self.audio.recordStartFailureStage(timeoutStage)
                }
                self.errorMessage = AudioCaptureStartState.timeoutFailureMessage(
                    existingErrorMessage: self.errorMessage,
                    micAudioStreaming: self.audio.micAudioStreaming,
                    systemAudioStreaming: self.audio.systemAudioStreaming
                )
                self.audio.stop()
                for continuation in waiters {
                    continuation.resume(returning: false)
                }
            })
        }
    }

    /// Stop the current recording and wait for Core's Audio to finish writing
    /// the mic + system WAV files to disk. Returns a result that distinguishes
    /// natural completion (`didTimeOut == false`) from `meetingStopTimeout`
    /// expiry (`didTimeOut == true`). On timeout the WAV header may not be
    /// fully patched, so the caller should treat the audio as failed-but-
    /// recoverable rather than enqueuing it for transcription directly.
    ///
    /// If a stop is already in flight, this call joins it instead of issuing
    /// its own `audio.stop()` — every joined caller gets the exact same
    /// result. In that case `timedOutOwner`/`onTimedOutCompletion` are
    /// ignored: only the first (attempt-owning) caller's values govern the
    /// shared attempt, since there is only one real completion event to
    /// route. Today's only concurrent caller of this method is
    /// `stopAndDiscardFiles()`, and `MeetingSessionController`'s state
    /// machine does not issue two overlapping stops in practice — this join
    /// path exists to make that guarantee compiler/type-level instead of
    /// convention-level.
    func stopAndAwaitFiles(
        timedOutOwner: TimedOutStopCompletionOwner? = nil,
        onTimedOutCompletion: ((CaptureStopResult) -> Void)? = nil
    ) async -> CaptureStopResult {
        return await withCheckedContinuation { continuation in
            // A second overlapping stop call (e.g. two callers racing to stop
            // the same recording before Core's completion callback fires)
            // must NOT start its own attempt: that would call `audio.stop()`
            // again, mint a fresh completionAttempt token, and displace the
            // first attempt's continuation with a fabricated "complete"
            // result while the WAV writers may still be closing — and once
            // displaced, the *real* completion (when it lands) would resolve
            // whichever continuation happens to be stored, not the one that
            // actually asked for it. Instead, join the attempt already in
            // flight and wait for the exact same eventual result — there is
            // only one underlying `audio.stop()` call and one real
            // completion event to own, so every caller must observe it.
            //
            // This check must run *before* consulting `audio.isRecording`:
            // Core's `Audio.stop()` flips `isRecording` false from a
            // `DispatchQueue.main.async` block queued before the slow
            // CoreAudio teardown / WAV finalization even starts (see
            // `Audio.stop()`'s "unfreeze the UI immediately" comment), so a
            // second call landing in that window would already see
            // `audio.isRecording == false` despite the real completion still
            // being outstanding. `completionAttempt`'s own active/inactive
            // state — not `audio.isRecording` — is the source of truth for
            // whether a stop is already in flight.
            if completionAttempt.joinIfActive(continuation) {
                return
            }

            guard audio.isRecording else {
                continuation.resume(returning: currentStopResult())
                return
            }

            let stopTimeout = TranscriptedConstants.meetingStopTimeout(
                forRecordingDuration: max(recordingDuration, audio.recordingDuration)
            )
            // Ask the epoch for the next session's generation instead of
            // hand-predicting with `current &+ 1`, which the SupersessionEpoch
            // docs call out as racy against a concurrent begin().
            let stopGeneration = audio.predictedNextRecordingSessionGeneration()
            expectedStopGeneration = stopGeneration
            let attemptID = completionAttempt.begin(continuation)
            audio.stop()

            completionAttempt.setTimeoutTask(Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: stopTimeout)
                guard let self else { return }
                let waiters = self.completionAttempt.resetIfCurrent(attemptID)
                guard !waiters.isEmpty else { return }

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
                self.expectedStopGeneration = nil
                self.timedOutStopCompletions.register(
                    generation: stopGeneration,
                    owner: timedOutOwner,
                    handler: onTimedOutCompletion
                )
                self.scheduleTimedOutStopCompletionExpiry(generation: stopGeneration)
                let timedOutResult = self.currentStopResult(didTimeOut: true)
                for continuation in waiters {
                    continuation.resume(returning: timedOutResult)
                }
            })
        }
    }

    /// Stop the current recording, wait for file handles to close, then remove
    /// the just-captured scratch audio instead of handing it to transcription.
    func stopAndDiscardFiles() async -> CaptureStopResult {
        let result = await stopAndAwaitFiles(timedOutOwner: .discard) { [weak self] lateResult in
            self?.audio.discardFinalizedRecordingArtifacts(
                micAudioURL: lateResult.micURL,
                systemAudioURL: lateResult.systemURL
            )
        }
        audio.discardCurrentRecordingArtifacts(
            micAudioURL: result.micURL,
            systemAudioURL: result.systemURL
        )
        audio.micAudioFileURL = nil
        audio.systemAudioFileURL = nil
        return result
    }

    /// User consented to the mid-meeting mic boost. Persists the preference so
    /// future meetings start with VPIO armed, then restarts the live engine so
    /// THIS meeting picks it up (~1-2s gap, recorded as a mic segment gap).
    func armVoiceProcessingForActiveRecording() {
        MicrophoneProcessingPreferences.setVoiceProcessingEnabled(true)
        audio.restartCaptureForProcessingChange()
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
            micAudioFileURL: audio.micAudioFileURL,
            micAudioStreaming: audio.micAudioStreaming,
            systemAudioFileURL: audio.systemAudioFileURL,
            systemAudioStreaming: audio.systemAudioStreaming,
            errorMessage: errorMessage
        ) {
        case .waiting:
            return
        case .ready:
            for continuation in startAttempt.reset() {
                continuation.resume(returning: true)
            }
        case .failed(let message):
            let waiters = startAttempt.reset()
            guard !waiters.isEmpty else { return }
            errorMessage = message
            if audio.isRecording {
                audio.stop()
            }
            for continuation in waiters {
                continuation.resume(returning: false)
            }
        }
    }

    private func wireCallbacks() {
        audio.onRecordingCompleteWithGeneration = { [weak self] generation, micURL, systemURL, disposition in
            // This closure fires on whichever queue Core's Audio dispatches from.
            // Hop to main and resume the continuation exactly once.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let result = CaptureStopResult(
                    micURL: micURL,
                    systemURL: systemURL,
                    didTimeOut: false,
                    finalizationOwner: disposition == .journalRecoveryOwned
                        ? .recordingJournalRecovery
                        : .audioFinalizer
                )

                switch self.timedOutStopCompletions.resolve(generation: generation) {
                case .expired(let owner):
                    switch owner {
                    case .failedMeeting(let id):
                        self.onExpiredTimedOutRecordingComplete?(id, result)
                    case .discard:
                        self.audio.discardFinalizedRecordingArtifacts(
                            micAudioURL: result.micURL,
                            systemAudioURL: result.systemURL
                        )
                    case nil:
                        self.onExpiredTimedOutRecordingComplete?(nil, result)
                    }
                    return
                case .pending(let handler):
                    self.timedOutStopCompletionExpiryTasks
                        .removeValue(forKey: generation)?
                        .cancel()
                    handler?(result)
                    return
                case .unowned:
                    break
                }

                switch MeetingCaptureCompletionPolicy.disposition(
                    completionGeneration: generation,
                    expectedStopGeneration: self.expectedStopGeneration,
                    currentAudioGeneration: self.audio.currentRecordingSessionGeneration
                ) {
                case .expectedStop:
                    let waiters = self.completionAttempt.reset()
                    guard !waiters.isEmpty else { return }
                    self.expectedStopGeneration = nil
                    for continuation in waiters {
                        continuation.resume(returning: result)
                    }
                case .unexpectedCurrentStop:
                    self.onUnexpectedRecordingComplete?(result)
                case .stale:
                    return
                }
            }
        }

        // Keep the legacy callback unset on this bridge. Core still exposes it
        // for older embedders, but this host needs the generation to reject a
        // completion from a previous timed-out recording.

        // Capture-lifecycle cues used to live inside Core (NSSound("Tink") on
        // start, NSSound("Pop") on stop). Core no longer depends on AppKit for
        // cosmetic UI; the host plays the sounds here. Audio fires the cue from
        // the main queue (via DispatchQueue.main.async / MainActor.run inside
        // the lifecycle helpers), but we still bounce through Task @MainActor
        // to match the rest of the bridge's threading discipline.
        audio.onCaptureLifecycleCue = { [weak self] cue in
            Task { @MainActor [weak self] in
                switch cue {
                case .recordingStarted:
                    NSSound(named: "Tink")?.play()
                case .recordingStopped:
                    NSSound(named: "Pop")?.play()
                case .micAttenuatedByForeignVoiceProcessing:
                    self?.micAttenuationCueObserved = true
                case .meetingRouteStabilityWarning(let outcome):
                    self?.routeStabilityWarningOutcome = outcome
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

        audio.$startFailureStage
            .receive(on: RunLoop.main)
            .assign(to: &$startFailureStage)

        audio.$error
            .receive(on: RunLoop.main)
            .sink { [weak self] errorMessage in
                guard let self else { return }
                self.errorMessage = errorMessage
                self.finishPendingStartAttemptIfPossible()
            }
            .store(in: &cancellables)

        sinkStartAttemptTriggers(from: audio.$isRecording)
        sinkStartAttemptTriggers(from: audio.$micAudioFileURL)
        sinkStartAttemptTriggers(from: audio.$systemAudioFileURL)
        // Either tap can install (file URL assigned, isRecording true) yet
        // never stream. Re-evaluate readiness when each first buffer arrives
        // so a one-sided recording stays `.waiting` and fails the start
        // deadline instead of being reported as recording.
        sinkStartAttemptTriggers(from: audio.$micAudioStreaming)
        sinkStartAttemptTriggers(from: audio.$systemAudioStreaming)
    }

    private func currentStopResult(didTimeOut: Bool = false) -> CaptureStopResult {
        CaptureStopResult(
            micURL: audio.micAudioFileURL,
            systemURL: audio.systemAudioFileURL,
            didTimeOut: didTimeOut
        )
    }

    private func scheduleTimedOutStopCompletionExpiry(generation: UInt64) {
        timedOutStopCompletionExpiryTasks.removeValue(forKey: generation)?.cancel()
        timedOutStopCompletionExpiryTasks[generation] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: TranscriptedConstants.meetingMaximumStopTimeout
                )
            } catch {
                return
            }
            guard let self else { return }
            _ = self.timedOutStopCompletions.expire(generation: generation)
            if self.audio.abandonRecordingJournalFinalization(
                forStopGeneration: generation
            ) {
                self.onRecordingJournalFinalizationAbandoned?()
            }
            self.timedOutStopCompletionExpiryTasks.removeValue(forKey: generation)
        }
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

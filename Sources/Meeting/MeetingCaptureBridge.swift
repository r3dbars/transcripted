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
    var hasObservedSystemAudioSignal: Bool { audio.hasObservedSystemAudioSignal }
    /// Live: another app has been playing for a while but the system-audio
    /// tap hears only silence, even after reconnecting.
    var systemAudioNotHearingPlayback: Bool { audio.isSystemAudioNotHearingPlayback }
    /// Call audio came back only after a new tap or output: the silence was a
    /// real loss, not a quiet call.
    var systemAudioDidLosePlayback: Bool { audio.systemAudioDidLosePlayback }
    /// Silence-while-playing time before `systemAudioNotHearingPlayback` turns on.
    static var systemAudioUnheardReportSeconds: TimeInterval { Audio.systemAudioUnheardReportSeconds }
    var systemAudioFinalizationFailed: Bool { audio.systemAudioFinalizationFailed }
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
    /// Runs only while a Boost looked past an open call app that was not on
    /// the mic. See `watchCallAppsWhileBoosted`.
    private var boostMicrophoneSharingWatch: Task<Void, Never>?
    /// A call app launched after this recording started. Unlike one that was
    /// merely open at start, it is probably joining a call right now, so a
    /// Boost must not look past the latch it set.
    private(set) var callAppLaunchedDuringRecording = false
    /// True from the start of `startRecording` until it returns, so a call
    /// app launched during a slow start counts as launched mid-meeting.
    private var isStartingRecording = false
    /// One-shot scan of whether a call app holds the mic input. Runs off the
    /// main actor. Tests replace it.
    var callAppMicrophoneUseScan: @Sendable () -> Bool = {
        MicrophoneSharingPolicy.isCallAppUsingMicrophone(
            micInputBundleIDs: MicActivityMonitor.currentMicInputBundleIDs()
        )
    }

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
        CallAppMicrophoneSharingMonitor.shared.$runningCallAppBundleIDs
            .scan((previous: Set<String>(), current: Set<String>())) { ($0.current, $1) }
            .filter { !$0.current.subtracting($0.previous).isEmpty }
            .sink { [weak self] _ in
                // A call app launched (even a second one while another is
                // open, which a Boost may have looked past). Latch for this
                // meeting. Do not re-arm VPIO when it quits: that would cause
                // another gap and route change during capture.
                guard let self else { return }
                if self.audio.isRecording || self.isStartingRecording {
                    self.callAppLaunchedDuringRecording = true
                }
                self.shareMicrophoneWithCallApps()
            }
            .store(in: &cancellables)
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
        boostMicrophoneSharingWatch?.cancel()
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
    func startRecording(
        timeout: UInt64 = TranscriptedConstants.meetingStartTimeout,
        languageSelection: TranscriptionLanguageSelection = .automatic
    ) async -> Bool {
        expectedStopGeneration = nil
        let staleStopResult = currentStopResult()
        for continuation in completionAttempt.reset() {
            continuation.resume(returning: staleStopResult)
        }
        if audio.isRecording { return true }
        audio.recordingLanguageSelection = languageSelection

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
        // "Boost mic next meeting" from Home adds voice processing for this
        // meeting only and is used up once it applies. An open call app wins
        // at start (it may be about to take the mic for this very call),
        // except that the user's explicit Home request looks past one that
        // isn't on the mic, the same way the in-meeting Boost does.
        boostMicrophoneSharingWatch?.cancel()
        boostMicrophoneSharingWatch = nil
        let micProcessingMode = MicrophoneProcessingPreferences.mode()
        let boostRequestedForThisMeeting = MicrophoneProcessingPreferences.isBoostRequestedForNextMeeting()
        CallAppMicrophoneSharingMonitor.shared.refresh()
        callAppLaunchedDuringRecording = false
        isStartingRecording = true
        defer { isStartingRecording = false }
        var shareMicrophoneAtStart = CallAppMicrophoneSharingMonitor.shared.isCallAppRunning
        var boostLookedPastCallApp = false
        if shareMicrophoneAtStart, boostRequestedForThisMeeting, !(await callAppIsUsingMicrophone()),
           !callAppLaunchedDuringRecording {
            // (A call app launched during the scan keeps the latch.)
            shareMicrophoneAtStart = false
            boostLookedPastCallApp = true
        }
        audio.voiceProcessingSuppressedForMicrophoneSharing = shareMicrophoneAtStart
            || callAppLaunchedDuringRecording
        audio.meetingInputDeviceSelectionMode = MeetingMicrophonePreferences.usesSystemInput()
            ? .preserveDefault : .automatic
        audio.enableVoiceProcessing = micProcessingMode.usesAppleVoiceProcessing || boostRequestedForThisMeeting
        audio.enableSoftwareAGC = micProcessingMode.allowsSoftwareAutogainFallback

        let started = await withCheckedContinuation { continuation in
            for pending in startAttempt.reset() {
                pending.resume(returning: false)
            }
            let attemptID = startAttempt.begin(continuation)

            audio.start()

            startAttempt.setTimeoutTask(Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeout)
                guard let self else { return }
                let waiters = self.startAttempt.resetIfCurrent(attemptID)
                guard !waiters.isEmpty else { return }
                let timeoutStage = AudioCaptureStartState.timeoutFailureStage(
                    micAudioStreaming: self.audio.micAudioStreaming,
                    systemAudioStreaming: self.audio.systemAudioStreaming
                )
                let resolvedTimeoutStage = self.audio.startFailureStage == .unknown
                    ? timeoutStage
                    : self.audio.startFailureStage
                if self.audio.startFailureStage == .unknown, resolvedTimeoutStage != .unknown {
                    self.audio.recordStartFailureStage(resolvedTimeoutStage)
                }
                if self.startFailureStage == .unknown, resolvedTimeoutStage != .unknown {
                    // The Combine mirror is delivered asynchronously; publish
                    // the timeout stage before resuming the caller below.
                    self.startFailureStage = resolvedTimeoutStage
                }
                // Prefer an already-observed permission denial over the generic
                // timeout copy; the helper falls back to
                // `AudioCaptureStartState.timeoutFailureMessage` otherwise, so
                // the typed stage above and this message stay consistent.
                self.errorMessage = self.startTimeoutFailureMessage()
                self.audio.stop()
                for continuation in waiters {
                    continuation.resume(returning: false)
                }
            })
        }
        if started, boostLookedPastCallApp, !audio.voiceProcessingSuppressedForMicrophoneSharing {
            watchCallAppsWhileBoosted(generation: audio.currentRecordingSessionGeneration)
        }
        if started, boostRequestedForThisMeeting, !audio.voiceProcessingSuppressedForMicrophoneSharing {
            MicrophoneProcessingPreferences.clearNextMeetingBoostRequest()
        }
        return started
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

    enum MicBoostArmResult: String, Equatable {
        case armed
        /// A call app holds the mic, so Transcripted keeps sharing it on
        /// software autogain.
        case callAppUsingMicrophone = "call_app_using_microphone"
        /// The recording ended, or the mic kept recovering, before the boost
        /// could apply.
        case notApplied = "not_applied"
    }

    /// User consented to the mid-meeting mic boost. Arms VPIO for this
    /// recording only by restarting the live engine; the next start reads the
    /// saved mode again, so the boost (and the quieter call audio that comes
    /// with it) ends with this meeting. Never saves the preference.
    ///
    /// A call app that was open at start but is not holding the mic (Teams
    /// left open all day during a browser call) doesn't block the boost; one
    /// on the mic does, and so does one launched during this recording,
    /// since it is probably about to join. When a boost looks past an open
    /// call app, a watch hands the mic back if that app, or a newly launched
    /// one, joins a call.
    ///
    /// A mic recovery in progress can't take a processing change, so the
    /// boost waits for it (up to `micRecoveryRetries` tries) instead of being
    /// dropped.
    func armVoiceProcessingForActiveRecording(
        micRecoveryRetries: Int = 15,
        retryDelayNanoseconds: UInt64 = 1_000_000_000
    ) async -> MicBoostArmResult {
        let generation = audio.currentRecordingSessionGeneration
        guard !callAppLaunchedDuringRecording else { return .callAppUsingMicrophone }
        let wasSharingMicrophone = audio.voiceProcessingSuppressedForMicrophoneSharing
        // Scan even with nothing latched: a call helper can hold the mic
        // without its app being in the presence list.
        guard !(await callAppIsUsingMicrophone()) else { return .callAppUsingMicrophone }
        guard isStillRecording(generation) else { return .notApplied }
        // A call app launched during the scan latched again; keep that.
        guard !callAppLaunchedDuringRecording,
              audio.voiceProcessingSuppressedForMicrophoneSharing == wasSharingMicrophone else {
            return .callAppUsingMicrophone
        }
        var clearedCallAppGuard = false
        if wasSharingMicrophone {
            audio.voiceProcessingSuppressedForMicrophoneSharing = false
            clearedCallAppGuard = true
        }
        for attempt in 0...max(0, micRecoveryRetries) {
            guard isStillRecording(generation) else { break }
            if audio.voiceProcessingSuppressedForMicrophoneSharing {
                // A call app launched while this was waiting.
                return .callAppUsingMicrophone
            }
            if audio.restartCaptureForProcessingChange() {
                if clearedCallAppGuard { watchCallAppsWhileBoosted(generation: generation) }
                return .armed
            }
            if attempt < micRecoveryRetries {
                try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            }
        }
        if clearedCallAppGuard, isStillRecording(generation) {
            audio.voiceProcessingSuppressedForMicrophoneSharing = true
        }
        return .notApplied
    }

    private func isStillRecording(_ generation: UInt64) -> Bool {
        audio.isRecording && audio.currentRecordingSessionGeneration == generation
    }

    /// Whether a call app holds the mic input right now. Scans off the main
    /// actor.
    func callAppIsUsingMicrophone() async -> Bool {
        let scan = callAppMicrophoneUseScan
        return await Task.detached(priority: .userInitiated) { scan() }.value
    }

    /// Only while a Boost looked past an open call app: checks every couple
    /// of seconds whether a call app took the mic, and if so drops voice
    /// processing so the two don't fight over it. Ends with the recording.
    private func watchCallAppsWhileBoosted(generation: UInt64) {
        boostMicrophoneSharingWatch?.cancel()
        boostMicrophoneSharingWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled,
                      let self,
                      self.isStillRecording(generation),
                      !self.audio.voiceProcessingSuppressedForMicrophoneSharing else { return }
                if await self.callAppIsUsingMicrophone(), !Task.isCancelled, self.isStillRecording(generation) {
                    DiagnosticsTrail.record(
                        engine: "meeting",
                        event: "meeting_mic_boost_handed_back",
                        message: "A call app took the mic during a boosted meeting; back to software autogain"
                    )
                    self.shareMicrophoneWithCallApps()
                    return
                }
            }
        }
    }

    private func shareMicrophoneWithCallApps() {
        boostMicrophoneSharingWatch?.cancel()
        boostMicrophoneSharingWatch = nil
        audio.voiceProcessingSuppressedForMicrophoneSharing = true
        audio.reconcileMicrophoneSharing()
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

    /// Prefer an already-observed permission denial over a generic start-timeout
    /// message. An inconclusive first-run check uses the 120s permission
    /// budget; a known-grant start still uses 12s. If a denial already landed
    /// before that deadline, keep it.
    private func startTimeoutFailureMessage() -> String {
        let existing = [errorMessage, audio.error]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        if let existing, Self.namesPermissionDenial(existing) {
            return existing
        }
        if audio.systemAudioStartPermissionExplicitlyDenied {
            return existing ?? "Turn on System Audio Recording before recording a meeting."
        }
        return AudioCaptureStartState.timeoutFailureMessage(
            existingErrorMessage: existing,
            micAudioStreaming: audio.micAudioStreaming,
            systemAudioStreaming: audio.systemAudioStreaming
        )
    }

    private static func namesPermissionDenial(_ message: String) -> Bool {
        let normalized = message.lowercased()
        if MeetingStartFailureClassifier.kind(from: normalized) == "permission_missing" {
            return true
        }
        return normalized.contains("denied")
            || normalized.contains("turn on microphone")
            || normalized.contains("turn on system audio")
    }

    private func finishPendingStartAttemptIfPossible() {
        if startFailureStage == .unknown, audio.startFailureStage != .unknown {
            startFailureStage = audio.startFailureStage
        }
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
        //
        // DispatchQueue.main, not RunLoop.main: Combine's RunLoop scheduler
        // enqueues via RunLoop.perform, which only services .default mode, so
        // nothing is delivered while an NSMenu tracks or a modal runs. That
        // froze the pill's timer and both level meters behind the pill's own
        // context menu, the discard alert, and NSOpenPanel, and left the
        // success half of the start handshake on different mode behavior from
        // its 12s MainActor Task counterpart. MeetingOverlayController already
        // uses DispatchQueue.main for the same mirrors.
        audio.$isRecording
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRecording)

        audio.$audioLevel
            .receive(on: DispatchQueue.main)
            .assign(to: &$audioLevel)

        // System audio level is published as a rolling 15-frame history by Core.
        // We take the most recent frame as the current "system level" for the UI.
        audio.$systemAudioLevelHistory
            .map { $0.last ?? 0 }
            .receive(on: DispatchQueue.main)
            .assign(to: &$systemLevel)

        audio.$recordingDuration
            .receive(on: DispatchQueue.main)
            .assign(to: &$recordingDuration)

        audio.$systemAudioStatus
            .receive(on: DispatchQueue.main)
            .assign(to: &$systemAudioStatus)

        audio.$startFailureStage
            .receive(on: DispatchQueue.main)
            .assign(to: &$startFailureStage)

        audio.$error
            .receive(on: DispatchQueue.main)
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
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.finishPendingStartAttemptIfPossible()
            }
            .store(in: &cancellables)
    }
}

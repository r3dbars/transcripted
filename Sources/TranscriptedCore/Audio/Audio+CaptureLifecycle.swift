import Foundation
import QuartzCore
@preconcurrency import AVFoundation
import CoreAudio
import Combine
import Synchronization

// Start and stop: per-recording reset, start intents, the async start,
// streaming latches, and `stop()`.
extension Audio {
    func prepareForNewRecordingStart() {
        livePCMDelivery.setEnabled(false)
        // A fast retry can begin before stop()'s deferred main-thread cleanup.
        // Reset the old timer here so every recording gets a fresh watchdog
        // and buffer timestamp.
        stopWatchdog()
        error = nil
        systemAudioStartPermissionExplicitlyDenied = false
        startFailureStage = .unknown
        systemBufferCount = 0  // Reset debug counter (lock-protected)
        micBufferCount = 0
        micAudioStreaming = false  // Re-gate readiness on a fresh first buffer
        systemAudioStreaming = false  // Re-gate readiness on a fresh first buffer
        resetSignalDiagnostics()
        micCaptureTelemetry.reset(enabled: CaptureTelemetryPreferences.isEnabled())
        // Fresh instance = clean one-shot latch per recording.
        quietMicAttenuationDetector = QuietMicAttenuationDetector()
        recordingStartRouteVolumeSnapshot = AudioRouteVolumeSnapshot.captureDefaultRoute()
        resetRecordingStartCapturedInput()
        resetSilenceTracking()  // Start fresh silence tracking
        systemAudioCaptureRequestLock.lock()
        activeRecordingCapturesSystemAudio = requestedCapturesSystemAudio
        let capturesSystemAudioThisRecording = activeRecordingCapturesSystemAudio
        systemAudioCaptureRequestLock.unlock()
        // Assume healthy until we hear otherwise. A mic-only recording has no
        // system track to call healthy.
        systemAudioStatus = capturesSystemAudioThisRecording ? .healthy : .unknown
        systemAudioSilenceStart = nil  // Reset system audio silence tracking
        recordingLanguageLock.lock()
        activeRecordingLanguage = requestedRecordingLanguage
        recordingLanguageLock.unlock()
        let context = recordingArtifactOwner.beginContext(facts: currentArtifactFacts(),
            endpoint: initialRecordingJournal.forkForRecording())
        let sessionGeneration = context.captureGeneration
        micAudioWriteBackpressure.begin(generation: sessionGeneration)
        systemAudioWriteBackpressure.begin(generation: sessionGeneration)
        micHostPCMBufferFanout.begin(generation: sessionGeneration)
        writeBackpressureStopAdmission.begin(generation: sessionGeneration)
        beginWriteErrorTracking(generation: sessionGeneration)
        resetMeetingRouteState(forNewRecording: true)
        recordVoiceProcessingStartFallback(.none)

        // Reset capture artifacts so a previous session cannot make a new start
        // look ready before the fresh mic/system files exist.
        micAudioFileURL = nil
        systemAudioFileURL = nil
        lastSystemBufferTime = CACurrentMediaTime()
        resetSystemRecoveryWriteHold()

        // Reset health tracking for new recording session
        recordingGaps = []
        deviceSwitchCount = 0
        resetMicFormatRebuildCount()
        recoveryAttemptCount = 0
        sleepTimestamp = nil
        clearSystemSleepPending()
        lastRecoveryTime = nil
        lastRecoveryEndTime = nil
        micRecoveryGapAnchor = nil
        systemAudioFailed = false
    }

    public func recordStartFailureStage(_ stage: AudioCaptureStartFailureStage) {
        startFailureStage = stage
    }

    private func beginStartIntent() -> UUID {
        // Gate duplicate start requests while the permission prompt is open or
        // the async recorder setup is still being scheduled.
        isStarting = true
        let id = UUID()
        pendingStartIntentId = id
        return id
    }

    private func isCurrentStartIntent(_ id: UUID) -> Bool {
        pendingStartIntentId == id && isStarting && !isRecording
    }

    private func clearStartIntent(_ id: UUID) {
        if pendingStartIntentId == id {
            pendingStartIntentId = nil
        }
    }

    // MARK: - Start Recording

    public func start() {
        guard !isRecording, !isStarting else {
            AppLogger.audio.warning("Already recording or starting, ignoring duplicate start request")
            return
        }

        // A preflight failure can end an attempt before the async start path
        // reaches prepareForNewRecordingStart(). Clear the previous attempt's
        // typed stage before any validation can return.
        startFailureStage = .unknown

        let startIntentId = beginStartIntent()
        let paths = paths
        // Preflight writes a probe file and queries the volume; a sleeping
        // external or network library would freeze the UI if this ran on main.
        DispatchQueue.global(qos: .userInitiated).async {
            let validationResult = RecordingValidator.validateRecordingConditions(paths: paths)
            DispatchQueue.main.async {
                guard self.isCurrentStartIntent(startIntentId) else { return }
                guard validationResult.isValid else {
                    AppLogger.audio.error("Pre-flight check failed", ["error": validationResult.errorMessage ?? "Unknown error"])
                    self.clearStartIntent(startIntentId)
                    self.isStarting = false
                    self.error = validationResult.errorMessage
                    return
                }
                self.startAfterPreflight(startIntentId: startIntentId)
            }
        }
    }

    private func startAfterPreflight(startIntentId: UUID) {
        // Check microphone permission and request if not determined
        // This allows users who skipped permission during onboarding to grant it at record time
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if microphoneStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    guard self.isCurrentStartIntent(startIntentId) else {
                        AppLogger.audio.info("Ignoring stale microphone permission response after start was cancelled")
                        return
                    }

                    if granted {
                        // Permission granted, proceed with start
                        self.startAudioCaptureAsync(startIntentId: startIntentId)
                    } else {
                        // Permission denied — already on main via the outer dispatch
                        self.error = "Microphone permission required. Go to System Settings \u{2192} Privacy & Security \u{2192} Microphone and enable Transcripted, then try again."
                        self.isStarting = false
                        self.clearStartIntent(startIntentId)
                    }
                }
            }
            return
        } else if microphoneStatus == .denied {
            // Permission explicitly denied
            DispatchQueue.main.async {
                guard self.isCurrentStartIntent(startIntentId) else { return }
                self.error = "Microphone access denied. Go to System Settings \u{2192} Privacy & Security \u{2192} Microphone and enable Transcripted."
                self.isStarting = false
                self.clearStartIntent(startIntentId)
            }
            return
        }
        startAudioCaptureAsync(startIntentId: startIntentId)
    }

    /// Helper method to start audio capture asynchronously
    /// Used when permission is already granted or after permission request completes
    private func startAudioCaptureAsync(startIntentId: UUID) {
        guard isCurrentStartIntent(startIntentId) else {
            AppLogger.audio.info("Ignoring stale audio capture start request after start was cancelled")
            return
        }

        isStarting = true
        clearStartIntent(startIntentId)
        prepareForNewRecordingStart()
        let startGeneration = recordingSessionGeneration

        AppLogger.audio.info("Starting audio capture")

        onRecordingStart?()

        Task {
            do {
                try await startAudioCapture(sessionGeneration: startGeneration)
                await MainActor.run {
                    self.finishSuccessfulStartIfCurrent(startGeneration)
                }
            } catch {
                await MainActor.run {
                    guard self.recordingSessionGeneration == startGeneration else {
                        AppLogger.audio.info("Skipping stale start failure after session boundary", [
                            "startGeneration": "\(startGeneration)",
                            "currentGeneration": "\(self.recordingSessionGeneration)"
                        ])
                        return
                    }

                    if self.startFailureStage == .unknown {
                        self.recordStartFailureStage(
                            AudioTapInstallGuard.isTapInstallRaise(error) ? .microphoneTapRaised : .microphoneGraph
                        )
                    }
                    if let journalError = error as? MeetingRecordingJournalStartError {
                        switch journalError {
                        case .alreadyExists:
                            self.error = "Recording couldn't start because a previous recording has the same file name. Try again; the earlier recording was kept."
                        case .persistenceFailed:
                            self.error = "Recording couldn't start safely because its recovery record could not be saved. Check free disk space and Transcripted's local storage access, then try again."
                        }
                    } else {
                        self.error = "Recording failed to start: \(error.localizedDescription). Try quitting and reopening Transcripted."
                    }
                    self.isRecording = false
                    self.isStarting = false
                    self.stop()
                }
            }
        }
    }

    @MainActor
    private func finishSuccessfulStartIfCurrent(_ startGeneration: UInt64) {
        guard recordingSessionGeneration == startGeneration, isStarting else {
            AppLogger.audio.warning("Audio capture start finished after session boundary; stop() owns teardown", [
                "startGeneration": "\(startGeneration)",
                "currentGeneration": "\(recordingSessionGeneration)"
            ])
            return
        }

        isRecording = true
        isStarting = false
        // Zoom may have launched after this graph armed VPIO but before start
        // completed. Recheck after publishing recording intent, too.
        reconcileMicrophoneSharing()
        // Arm even when the graph has not delivered its first mic frame yet.
        // A Bluetooth-to-built-in handoff can pass device/rate validation and
        // `engine.start()` while still producing zero frames. The watchdog's
        // bounded, generation-guarded recovery then gets one chance before the
        // outer meeting-start deadline fails closed.
        if MicWatchdogArmingPolicy.shouldArmAfterSuccessfulStart(
            watchdogIsArmed: watchdogTimer != nil
        ) {
            startWatchdog()
        }
        restoreSystemAudioHealthyStatusAfterSuccessfulStart()
    }

    func restoreSystemAudioHealthyStatusAfterSuccessfulStart() {
        guard systemAudioFileURL != nil,
              !systemAudioFailed,
              systemAudioStatus == .unknown else {
            return
        }

        systemAudioStatus = .healthy
    }

    /// Records that the system-audio tap has started streaming for this
    /// recording. Called from the system buffer callback on its first buffer
    /// (on a CoreAudio dispatch thread), so it hops to main to publish
    /// `systemAudioStreaming`. Generation-guarded so a late buffer from a
    /// finished session cannot re-arm readiness. This is the signal that
    /// promotes meeting-capture readiness (`AudioCaptureStartState`) from
    /// `.waiting` to `.ready`: a tap that installs but never streams never sets
    /// it, so the start deadline fails it instead of reporting "recording".
    func markSystemAudioStreamingIfCurrent(sessionGeneration: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.recordingSessionGeneration == sessionGeneration else { return }
            self.systemAudioStreaming = true
        }
    }

    /// Records that the microphone tap delivered a usable buffer for this
    /// recording. Like the system-side latch, this is published on main and
    /// guarded against callbacks that outlive their recording generation.
    func markMicAudioStreamingIfCurrent(sessionGeneration: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.recordingSessionGeneration == sessionGeneration else { return }
            self.micAudioStreaming = true
        }
    }

    // MARK: - Stop Recording

    /// The generation of a stop() whose completion has not landed yet, while
    /// no newer recording has started. A second stop joins it: finalizing the
    /// same segments twice deletes the merged mic file the first one made.
    public internal(set) var inFlightStopGeneration: UInt64? {
        get { recordingGenerationClock.inFlightStopGeneration }
        set { recordingGenerationClock.inFlightStopGeneration = newValue }
    }

    public func stop() {
        if let inFlightStopGeneration {
            // A new start still in preflight has no generation yet; this stop cancels it.
            if isStarting, !isRecording {
                pendingStartIntentId = nil
                isStarting = false
            }
            AppLogger.audio.info("Ignoring repeat stop; this capture's stop is already finalizing", [
                "stopGeneration": "\(inFlightStopGeneration)"
            ])
            return
        }
        // Bump generation synchronously on the calling thread so any
        // concurrent recovery work that checks the generation immediately
        // sees the new session boundary.
        let captureGeneration = recordingSessionGeneration
        livePCMDelivery.setEnabled(false)
        let finishingCapture = systemAudioCaptureAttemptOwnership.captureOwned(by: captureGeneration)
        signalDiagnosticsLock.lock()
        finishingSystemSignalAttempt = finishingCapture
        signalDiagnosticsLock.unlock()
        finishingCapture?.beginFinishing()
        // Same rule for the mic: the input tap is torn down later, on a
        // background queue, and keeps delivering what the user said just
        // before Stop. Keep this recording's mic writes open for that tail
        // until the tap is gone; `closeMicrophone` closes it.
        micAudioWriteBackpressure.beginFinishing(generation: captureGeneration)
        pendingStartIntentId = nil
        _ = compatibilityArtifactContext()
        guard let artifactTicket = recordingArtifactOwner.sealStop(expectedCaptureGeneration: captureGeneration) else { return }
        let stopGeneration = artifactTicket.stopGeneration
        systemAudioWriteBackpressure.close(generation: captureGeneration)
        writeBackpressureStopAdmission.close(generation: captureGeneration)
        let cleanupGroup = DispatchGroup()
        cleanupGroup.enter()
        micHostPCMBufferFanout.close(generation: captureGeneration) {
            cleanupGroup.leave()
        }

        // Snapshot every reference the teardown will need so the
        // background queue closure isn't reading mutable instance state
        // while UI updates happen in parallel.
        let engineRef = self.engine
        let inputNodeRef = self.inputNode
        let pinnedMicrophoneRef = self.pinnedMicrophoneCapture
        let systemAudioCapture = systemAudioCaptureAttemptOwnership.captureOwned(
            by: captureGeneration
        )
        // A system setup still in flight treats this Stop as abandonment.
        // Claim the resolved file so that cleanup cannot delete a WAV this
        // Stop hands off; it gets nil if cleanup committed to deleting first.
        let resolvedSystemURL = resolvedSystemAudioFileURL(generation: captureGeneration)
        let finalSystemURL: URL?
        if let finishingCapture {
            finalSystemURL = finishingCapture.handOffRecordedFileToStop(resolvedSystemURL)
        } else {
            finalSystemURL = resolvedSystemURL
        }
        recordingArtifactOwner.commitStopSystemHandoff(artifactTicket, url: finalSystemURL)
        let cueHandler = self.onCaptureLifecycleCue

        // Update UI state immediately so the meeting widget unfreezes
        // before any of the slow CoreAudio teardown begins. Without this
        // dispatch, the user-visible "still spinning" state could last
        // hundreds of ms while AVAudioEngine drains in-flight callbacks
        // — the freeze Taylor reported on the meeting widget.
        DispatchQueue.main.async {
            guard self.recordingSessionGeneration == stopGeneration else {
                AppLogger.audio.info("Skipping stale stop UI reset because a newer session exists", [
                    "stopGeneration": "\(stopGeneration)",
                    "currentGeneration": "\(self.recordingSessionGeneration)"
                ])
                return
            }
            self.isRecording = false
            self.isStarting = false
            self.audioLevel = 0.0
            self.systemAudioStatus = .unknown  // Reset status when not recording
            self.stopTimer()
            self.stopWatchdog()
            cueHandler?(.recordingStopped)
        }

        // Native microphone and ScreenCaptureKit stops can each block. Start
        // them independently so a stuck backend cannot hold the other device
        // or its saved audio open. Finalization still waits for both backends.
        AudioStopCleanup.schedule(
            group: cleanupGroup,
            microphoneFileQueue: micAudioFileQueue,
            systemFileQueue: systemAudioFileQueue,
            stopMicrophone: {
                self.withAudioGraphLock {
                    guard self.recordingSessionGeneration == stopGeneration else {
                        AppLogger.audio.info("Skipping stale audio graph teardown because a newer session exists", [
                            "stopGeneration": "\(stopGeneration)",
                            "currentGeneration": "\(self.recordingSessionGeneration)"
                        ])
                        return
                    }

                    if let engineRef, let inputNodeRef {
                        AppLogger.audio.info("Stopping audio capture")
                        self.tearDownInputTapSafely(
                            engine: engineRef,
                            inputNode: inputNodeRef,
                            operation: "recording_stop"
                        )
                        self.disarmVoiceProcessing(on: inputNodeRef)
                        // Do not retain an idle VPIO graph if disarming failed.
                        self.engine = nil
                        self.inputNode = nil
                    }
                    if let pinnedMicrophoneRef {
                        self.finishPinnedMeetingMicrophone(pinnedMicrophoneRef)
                    }

                    // Drop the RealtimeAGC reference so gain history doesn't
                    // carry into the next recording. Safe here because the
                    // engine has stopped — no more tap callbacks can fire.
                    self.realtimeAGC = nil
                }
            },
            stopSystem: {
                // Generation checks already reject late callbacks; ownership
                // stays attached until the corresponding writer queue drains.
                systemAudioCapture?.finishAndDrain()
            },
            closeMicrophone: {
                // The tap is gone and every tail write it admitted is already
                // ahead of this block on the serial mic file queue.
                self.micAudioWriteBackpressure.close(generation: captureGeneration)
                _ = self.micArtifactTransactions.closeForStopOnQueue(ticket: artifactTicket)
                self.endMicWriteErrorTracking(generation: captureGeneration)
            },
            closeSystem: {
                let systemAudioAttempt = self.systemAudioCaptureAttemptOwnership.takeAttemptOwned(
                    by: captureGeneration,
                    invalidatingFor: stopGeneration
                )
                if let systemAudioAttempt {
                    if let systemAudioFileRef = systemAudioAttempt.writer {
                        systemAudioAttempt.capture.writeTimeline.finish(writer: systemAudioFileRef)
                        systemAudioFileRef.close()
                        AppLogger.audioSystem.info("Audio file closed", ["file": finalSystemURL?.lastPathComponent ?? "unknown"])
                    }
                }
                self.endSystemWriteErrorTracking(generation: captureGeneration)
            },
            completion: { [weak self] in
                guard let self else { return }
                let systemTimeline = systemAudioCapture?.writeTimeline.takeFinished()
                self.completeArtifactStop(artifactTicket, systemTimeline: systemTimeline)
            }
        )
    }
}

import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import QuartzCore

/// Extension handling mic device recovery, watchdog timer, and sleep/wake resilience.
/// Runs on background threads — NOT @MainActor.
extension Audio {

    /// Call under the graph lock right before `installTap`. Turns a route
    /// change that would crash the app into a normal failed attempt.
    func ensureMicTapFormatStillMatches(
        _ expected: AVAudioFormat,
        on inputNode: AVAudioInputNode,
        voiceProcessingEnabled: Bool,
        operation: String
    ) throws {
        let current = recordingFormat(
            for: inputNode,
            voiceProcessingEnabled: voiceProcessingEnabled
        )
        guard MicTapFormatPolicy.stillMatches(expected: expected, current: current) else {
            AppLogger.audioMic.warning("Microphone format changed before tap install", [
                "operation": operation,
                "expectedRate": "\(expected.sampleRate)",
                "currentRate": "\(current.sampleRate)",
                "expectedChannels": "\(expected.channelCount)",
                "currentChannels": "\(current.channelCount)"
            ])
            throw NSError(
                domain: "Audio",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey: "The microphone route did not become ready. Check your input device and try again."
                ]
            )
        }
    }

    /// Rebuilds a validated but not yet started meeting graph when the input
    /// format moved underneath it. Opening the AirPods mic is what flips them
    /// to their call profile, so the first graph usually sees 48 kHz and the
    /// hardware is at 24 kHz a moment later. Call before the mic file is
    /// created, since the file is sized for the graph's rate.
    func settleMeetingInputGraphFormat(
        _ graph: PreparedMeetingInputGraph,
        operation: String,
        sessionGeneration: UInt64
    ) throws -> PreparedMeetingInputGraph {
        var graph = graph
        for rebuild in 1...2 {
            guard sessionGeneration == recordingSessionGeneration else {
                throw AudioCaptureStaleSessionError()
            }
            let current = withAudioGraphLock {
                recordingFormat(
                    for: graph.inputNode,
                    voiceProcessingEnabled: graph.voiceProcessingEnabled
                )
            }
            if MicTapFormatPolicy.stillMatches(expected: graph.recordingFormat, current: current) {
                return graph
            }
            AppLogger.audioMic.warning("Microphone format changed after graph setup; rebuilding", [
                "operation": operation,
                "rebuild": "\(rebuild)",
                "expectedRate": "\(graph.recordingFormat.sampleRate)",
                "currentRate": "\(current.sampleRate)",
                "expectedChannels": "\(graph.recordingFormat.channelCount)",
                "currentChannels": "\(current.channelCount)"
            ])
            incrementMicFormatRebuildCount()
            let staleGraph = graph
            withAudioGraphLock {
                discardUnstartedInputGraph(
                    engine: staleGraph.engine,
                    inputNode: staleGraph.inputNode,
                    operation: "\(operation)_discard_route_changed"
                )
            }
            // Let CoreAudio finish the profile switch before reading it again.
            Thread.sleep(forTimeInterval: 0.3)
            graph = try makeReadyMeetingInputGraph(
                operation: "\(operation)_route_changed",
                resetMeetingSelectionBeforeRetry: false,
                sessionGeneration: sessionGeneration
            )
        }
        return graph
    }

    // MARK: - Watchdog Timer

    func startWatchdog() {
        lastBufferTime = CACurrentMediaTime()
        watchdogTimer?.invalidate()
        let watchdogGeneration = recordingSessionGeneration
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self,
                  MicWatchdogSessionPolicy.shouldRun(
                      watchdogGeneration: watchdogGeneration,
                      currentGeneration: self.recordingSessionGeneration,
                      isRecording: self.isRecording,
                      isRecovering: self.isMicRecovering,
                      isSystemSleepPending: self.isSystemSleepPending(for: watchdogGeneration)
                  ) else { return }

            // Also covers a call-app launch while another recovery was already
            // rebuilding the graph. A flowing mic is not proof Zoom can hear it.
            self.reconcileMicrophoneSharing()

            let timeSinceLastBuffer = CACurrentMediaTime() - self.lastBufferTime

            if timeSinceLastBuffer > AudioRecoveryTuning.Mic.stallTimeoutSeconds {
                // Enforce cooldown — don't attempt recovery more often than every 5s
                if let lastRecovery = self.lastRecoveryTime,
                   Date().timeIntervalSince(lastRecovery) < self.recoveryCooldown {
                    return  // Too soon, skip this tick
                }

                // Give up after too many failed recoveries
                if self.recoveryAttemptCount >= self.maxRecoveryAttempts {
                    AppLogger.audioMic.error("Max recovery attempts reached, stopping recording", [
                        "attempts": "\(self.recoveryAttemptCount)"
                    ])
                    let savedError = "Audio device unavailable \u{2014} recording stopped after \(self.recoveryAttemptCount) recovery attempts. Reconnect your microphone and try again."
                    DispatchQueue.main.async {
                        guard self.recordingSessionGeneration == watchdogGeneration,
                              self.isRecording,
                              !self.isMicRecovering else { return }
                        let expectedStopGeneration = self.predictedNextRecordingSessionGeneration()
                        self.stop()
                        guard self.recordingSessionGeneration == expectedStopGeneration else { return }
                        // Re-apply error after stop() clears it
                        self.error = savedError
                    }
                    return
                }

                // Audio stopped → device likely changed
                AppLogger.audioMic.warning("Audio device disconnected or changed, switching to default")
                // Dispatch to background — recovery uses Thread.sleep for HAL settle time
                DispatchQueue.global(qos: .userInitiated).async {
                    self.recoverFromDeviceChange(sessionGeneration: watchdogGeneration)
                }
            }
        }
    }

    func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    // MARK: - Device Recovery

    func recoverFromDeviceChange(
        sessionGeneration: UInt64,
        reason: MicCaptureRestartReason = .deviceChange,
        afterSystemWake: Bool = false,
        freshGraphRequested: Bool = false
    ) {
        // Ignore recovery work that belonged to an older recording session.
        guard sessionGeneration == recordingSessionGeneration else {
            AppLogger.audioMic.info("Skipping stale recovery request", [
                "expectedSession": "\(sessionGeneration)",
                "currentSession": "\(recordingSessionGeneration)"
            ])
            return
        }

        // A device-change recovery started as the Mac falls asleep cannot
        // get a frame back and would stop the recording. The wake handler
        // clears the mark and runs this recovery once the HAL has settled.
        if reason == .deviceChange, isSystemSleepPending(for: sessionGeneration) {
            AppLogger.audioMic.info("Deferring mic recovery until the system wakes")
            return
        }

        // The pinned recorder restarts itself on its own device and pads the
        // hole. It never rebuilds an engine graph, which would open the
        // default input first.
        if let pinnedCapture = withAudioGraphLock({ pinnedMicrophoneCapture }) {
            recoverPinnedMeetingMicrophone(
                pinnedCapture,
                sessionGeneration: sessionGeneration,
                reason: reason
            )
            return
        }

        // CRITICAL: Prevent concurrent recovery attempts, including across a
        // fast stop/start. The owner remains set until the old background
        // recovery returns, so its defer cannot clear a newer session's state.
        guard beginMicRecovery(for: sessionGeneration) else {
            AppLogger.audioMic.warning("Recovery already in progress, skipping duplicate request")
            return
        }
        defer {
            if sessionGeneration == recordingSessionGeneration { lastRecoveryEndTime = Date() }
            endMicRecovery(for: sessionGeneration)
        }
        guard sessionGeneration == recordingSessionGeneration else { return }
        lastRecoveryTime = Date()
        // Checked before any hardware is touched: a recording that Stop
        // already took, or that never opened a mic file, has nothing to
        // recover into, and building a graph would open the default input.
        guard micAudioFileQueue.sync(execute: {
            micAudioFileOwnership.recordingOwnsMicFile(sessionGeneration)
        }) else {
            AppLogger.audioMic.info("Skipping mic recovery; this recording no longer owns a mic file", [
                "session": "\(sessionGeneration)"
            ])
            return
        }

        // A failed earlier attempt can leave no published graph. Rebuild from
        // scratch then; returning here would skip the attempt count, so the
        // watchdog would never give up and the meeting would record silence.
        let currentEngine = engine
        let currentInputNode = inputNode

        // Track device switch for health monitoring. Deliberate processing
        // restarts and the restart after the Mac wakes stay out of
        // deviceSwitchCount so health metadata and capture_quality aren't
        // polluted (the sleep itself is recorded as a gap); recoveryAttemptCount stays
        // unconditional — it's the watchdog give-up safety counter and
        // resets on success below.
        let switchStart = Date()
        var lastMicBufferTime = lastBufferTime
        // A fresh-graph retry after a failed in-place restart is the same
        // switch, so it is not counted twice.
        if !freshGraphRequested,
           MicDeviceSwitchCountingPolicy.counts(reason: reason, afterSystemWake: afterSystemWake) {
            // Atomic read-modify-write: the SCK-path recovery-event
            // subscription can increment this same counter concurrently on
            // main (see `Audio.incrementDeviceSwitchCount()`), so a plain
            // `deviceSwitchCount += 1` here (get + separately-locked set)
            // could race and drop an increment from either side.
            incrementDeviceSwitchCount()
        }
        // The fresh-graph retry finishes the attempt that just failed in
        // place, so it does not spend another of the watchdog's attempts.
        if !freshGraphRequested {
            recoveryAttemptCount += 1
        }
        AppLogger.audioMic.debug("Recovering from device change", ["switchNumber": "\(deviceSwitchCount)", "maxAttempts": "\(maxRecoveryAttempts)"])

        // The pinned mic already failed in this streak, or never delivered a
        // frame at all. Try the built-in mic first this time.
        if MicRecoveryInputFallbackPolicy.shouldTryBuiltInFirst(
            reason: reason,
            recoveryAttemptNumber: recoveryAttemptCount,
            micHasDeliveredAudio: micBufferCount > 0,
            inPlaceRestartJustFailed: freshGraphRequested
        ) {
            pinBuiltInMeetingInputFallback(operation: "device_recovery")
        }
        // After a failed attempt the current graph is suspect; build fresh.
        let inPlaceSelection = inPlaceRestartSelection(
            reason: reason,
            freshGraphRequested: freshGraphRequested || recoveryAttemptCount > 1,
            engine: currentEngine,
            inputNode: currentInputNode
        )

        // Stop engine (but keep recording flag true), then reset to system
        // default. Keep graph mutation serialized with stop/start teardown so
        // a user stop during device recovery cannot race CoreAudio format
        // reads or tap replacement.
        var didResetGraph = false
        withAudioGraphLock {
            guard sessionGeneration == recordingSessionGeneration else {
                AppLogger.audioMic.info("Skipping stale recovery before graph reset", [
                    "expectedSession": "\(sessionGeneration)",
                    "currentSession": "\(recordingSessionGeneration)"
                ])
                return
            }
            if inPlaceSelection != nil, let currentEngine, let currentInputNode {
                // Keep the node bound to the pinned mic: no VPIO disarm and
                // no engine reset, just stop and drop the old tap.
                tearDownInputTapSafely(
                    engine: currentEngine,
                    inputNode: currentInputNode,
                    operation: "device_recovery_in_place"
                )
            } else if let currentEngine {
                if let currentInputNode {
                    tearDownInputTapSafely(
                        engine: currentEngine,
                        inputNode: currentInputNode,
                        operation: "device_recovery_reset"
                    )
                    disarmVoiceProcessing(
                        on: currentInputNode,
                        reason: "device_recovery_replace_graph"
                    )
                }
                currentEngine.reset()
            }
            didResetGraph = true
        }
        guard didResetGraph else {
            return
        }

        // HAL settle time - wait for audio hardware to stabilize after device change
        // Same approach the system-audio backend uses for its own recovery
        Thread.sleep(forTimeInterval: 0.1)  // 100ms

        // A new recording session may have started while the HAL was settling.
        guard sessionGeneration == recordingSessionGeneration else {
            AppLogger.audioMic.info("Skipping stale recovery after HAL settle", [
                "expectedSession": "\(sessionGeneration)",
                "currentSession": "\(recordingSessionGeneration)"
            ])
            return
        }

        // A rejected device bind can leave the node half-switched. Rebuild the
        // graph from scratch, retry once, and validate both device ID and
        // hardware format before installing another tap.
        let bluetoothInputWasSelected = reason == .deviceChange && meetingInputIsBluetooth()
        let unsettledGraph: PreparedMeetingInputGraph
        var usedInPlaceRestart = false
        do {
            if let inPlaceSelection,
               let currentEngine,
               let currentInputNode,
               let inPlaceGraph = try prepareInPlaceMeetingInputGraph(
                   engine: currentEngine,
                   inputNode: currentInputNode,
                   selection: inPlaceSelection,
                   sessionGeneration: sessionGeneration
               ) {
                unsettledGraph = inPlaceGraph
                usedInPlaceRestart = true
            } else {
                unsettledGraph = try makeReadyMeetingInputGraph(
                    operation: "device_recovery",
                    resetMeetingSelectionBeforeRetry: MicRecoveryRetryPolicy
                        .shouldResetMeetingSelectionBeforeRetry(for: reason),
                    sessionGeneration: sessionGeneration,
                    routeWasUnstable: bluetoothInputWasSelected
                )
            }
        } catch {
            logMicRecoveryGraphPrepareFailure(error)
            return
        }

        let segmentAttempt = MicRecoverySegmentAttempt()
        defer {
            discardUnkeptMicRecoverySegment(segmentAttempt, sessionGeneration: sessionGeneration)
        }

        func failRestart(_ error: Error, engine: AVAudioEngine, inputNode: AVAudioInputNode) {
            failMicRecoveryRestart(
                error,
                engine: engine,
                inputNode: inputNode,
                sessionGeneration: sessionGeneration,
                reason: reason,
                afterSystemWake: afterSystemWake,
                usedInPlaceRestart: usedInPlaceRestart
            )
        }

        // Settle the route, size the recovery segment from the settled graph,
        // then recheck the format and install the tap under the graph lock.
        // `engine.start()` only proves the graph was accepted; the frame wait
        // after this proves the selected microphone delivers.
        var settledGraphForFailure: PreparedMeetingInputGraph?
        var bufferCountBeforeRestart = 0
        let restarted: (graph: PreparedMeetingInputGraph, segment: MicRecoverySegmentStart)
        do {
            restarted = try MeetingMicGraphStartSequence.run(
                unsettledGraph,
                settle: { graph in
                    // Opening a Bluetooth mic after a wake or reconnect can
                    // flip it to its call profile, same as at start. Rebuild
                    // on the settled route before the recovery segment is
                    // sized for the old rate. A reused in-place graph was
                    // already validated on the pinned mic.
                    let settled = usedInPlaceRestart
                        ? graph
                        : try settleMeetingInputGraphFormat(
                            graph,
                            operation: "device_recovery",
                            sessionGeneration: sessionGeneration
                        )
                    settledGraphForFailure = settled
                    return settled
                },
                createSegment: { graph in
                    try createMicRecoverySegment(
                        for: graph,
                        attempt: segmentAttempt,
                        usedInPlaceRestart: usedInPlaceRestart,
                        sessionGeneration: sessionGeneration,
                        switchStart: switchStart,
                        lastMicBufferTime: &lastMicBufferTime
                    )
                },
                checkFormat: { graph in
                    try ensureMicTapFormatStillMatches(
                        graph.recordingFormat,
                        on: graph.inputNode,
                        voiceProcessingEnabled: graph.voiceProcessingEnabled,
                        operation: "device_recovery"
                    )
                },
                installTap: { graph, segment in
                    let micWriteContext = segment.writeContext
                    try AudioTapInstallGuard.run(operation: "device_recovery") {
                        graph.inputNode.installTap(onBus: 0, bufferSize: 4096, format: graph.recordingFormat) { [weak self] buffer, _ in
                            self?.handleMicBuffer(buffer, writeContext: micWriteContext)
                        }
                    }
                },
                withinGraphLock: { graph, checkAndInstallTap in
                    let engine = graph.engine
                    let newInputNode = graph.inputNode
                    bufferCountBeforeRestart = micBufferCount
                    try withAudioGraphLock {
                        guard sessionGeneration == recordingSessionGeneration else {
                            throw AudioCaptureStaleSessionError()
                        }
                        // Reinstall tap using shared buffer handler
                        tearDownInputTapSafely(
                            engine: engine,
                            inputNode: newInputNode,
                            operation: "device_recovery_restart"
                        )
                        try checkAndInstallTap()
                        do {
                            engine.prepare()
                            try engine.start()
                        } catch {
                            tearDownInputTapSafely(
                                engine: engine,
                                inputNode: newInputNode,
                                operation: "device_recovery_restart_failed"
                            )
                            throw error
                        }
                    }
                }
            )
        } catch {
            let failure = error as? MeetingMicGraphStartSequence.Failure
            switch failure?.step {
            case .settle:
                logMicRecoveryGraphPrepareFailure(failure?.underlying ?? error)
            case .checkFormat, .installTap:
                if let settledGraphForFailure {
                    failRestart(
                        failure?.underlying ?? error,
                        engine: settledGraphForFailure.engine,
                        inputNode: settledGraphForFailure.inputNode
                    )
                }
            case .createSegment, nil:
                // The segment step logged why it stopped; no retry from here.
                break
            }
            return
        }

        let engine = restarted.graph.engine
        let newInputNode = restarted.graph.inputNode
        let fileURL = restarted.segment.url
        do {
            guard waitForMicBuffer(
                after: bufferCountBeforeRestart,
                sessionGeneration: sessionGeneration,
                timeout: 2.0
            ) else {
                // Stop ends the wait early. That is not a failed restart and
                // must not log as one or schedule a retry.
                guard sessionGeneration == recordingSessionGeneration else {
                    throw AudioCaptureStaleSessionError()
                }
                throw NSError(
                    domain: "Audio",
                    code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "The microphone restarted but did not deliver audio."]
                )
            }
            guard sessionGeneration == recordingSessionGeneration else {
                throw AudioCaptureStaleSessionError()
            }
            // A reused node could be re-bound by the route change as it
            // restarts. Frames from another mic are a failed attempt, so the
            // retry builds a fresh graph on the pinned mic.
            if usedInPlaceRestart, let pinnedID = inPlaceSelection?.selectedInput.id,
               withAudioGraphLock({ newInputNode.auAudioUnit.deviceID }) != pinnedID {
                throw NSError(
                    domain: "Audio",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "The microphone restarted on a different input."]
                )
            }

            // Recovery notices are status, not errors. `Audio.error` is a
            // terminal bridge channel and must only carry real failures.
            AppLogger.audioMic.info(
                reason == .processingChange
                    ? "Microphone processing restart confirmed by audio frame"
                    : "Microphone device recovery confirmed by audio frame"
            )

            // Record the true missing-buffer interval. The watchdog only
            // invokes recovery after buffers have already been absent for a
            // few seconds, so measuring from recovery start undercounts the
            // timeline gap and desyncs mic/system audio after device switches.
            let monotonicGapDuration = CACurrentMediaTime() - lastMicBufferTime
            let wallClockGapDuration = Date().timeIntervalSince(switchStart)
            let gapDuration = max(0, max(monotonicGapDuration, wallClockGapDuration))
            let gap = AudioGap(
                start: Date(timeIntervalSinceNow: -gapDuration),
                duration: gapDuration,
                reason: reason == .processingChange ? "Mic processing change" : "Device switch"
            )
            let finalized = finalizeRegisteredMicRecoverySegment(
                gap: gap,
                segmentURL: fileURL,
                sessionGeneration: sessionGeneration
            )
            guard finalized else {
                throw AudioCaptureStaleSessionError()
            }
            if segmentAttempt.url != nil {
                segmentAttempt.shouldKeep = true
            }
            AppLogger.audioMic.info("Device recovery complete, recording continues", ["gap": gap.description])
        } catch {
            failRestart(error, engine: engine, inputNode: newInputNode)
        }
    }

    /// The pinned selection when this recovery may reuse the current graph.
    private func inPlaceRestartSelection(
        reason: MicCaptureRestartReason,
        freshGraphRequested: Bool,
        engine: AVAudioEngine?,
        inputNode: AVAudioInputNode?
    ) -> MeetingInputDeviceSelection? {
        guard engine != nil, let inputNode,
              let selection = meetingInputSelectionSnapshot() else { return nil }
        let pinned = selection.selectedInput
        let boundInputID = withAudioGraphLock { inputNode.auAudioUnit.deviceID }
        let canRestart = MicInPlaceRestartPolicy.canRestartInPlace(
            reason: reason,
            freshGraphRequested: freshGraphRequested,
            pinnedInputID: pinned.id,
            pinnedInputIsBluetooth: pinned.transport == .bluetooth || pinned.transport == .bluetoothLE,
            pinnedInputIsAlive: ((try? pinned.id.readNominalSampleRate()) ?? 0) > 0,
            boundInputID: boundInputID,
            voiceProcessingEnabled: voiceProcessingEnabled
        )
        return canRestart ? selection : nil
    }

    /// Validate the current, stopped graph for reuse. Returns nil when it
    /// must be rebuilt instead; throws only for a stale session.
    private func prepareInPlaceMeetingInputGraph(
        engine: AVAudioEngine,
        inputNode: AVAudioInputNode,
        selection: MeetingInputDeviceSelection,
        sessionGeneration: UInt64
    ) throws -> PreparedMeetingInputGraph? {
        try withAudioGraphLock { () throws -> PreparedMeetingInputGraph? in
            guard sessionGeneration == recordingSessionGeneration else {
                throw AudioCaptureStaleSessionError()
            }
            guard engine === self.engine, inputNode === self.inputNode,
                  inputNode.auAudioUnit.deviceID == selection.selectedInput.id else {
                AppLogger.audioMic.info("Mic graph changed before in-place restart; rebuilding")
                return nil
            }
            let recordingFormat = self.recordingFormat(
                for: inputNode,
                voiceProcessingEnabled: false
            )
            guard let recordingSnapshot = AudioRecordingFormatPolicy.snapshot(recordingFormat),
                  MicInPlaceRestartPolicy.formatStillMatchesDevice(
                      capturedSampleRate: recordingSnapshot.sampleRate,
                      deviceNominalSampleRate: try? selection.selectedInput.id.readNominalSampleRate()
                  ) else {
                AppLogger.audioMic.info("Mic format moved since the graph was built; rebuilding", [
                    "capturedRate": "\(recordingFormat.sampleRate)"
                ])
                return nil
            }
            return PreparedMeetingInputGraph(
                engine: engine,
                inputNode: inputNode,
                recordingFormat: recordingFormat,
                recordingSnapshot: recordingSnapshot,
                voiceProcessingEnabled: false
            )
        }
    }

    /// One failed recovery no longer ends the meeting: system audio keeps
    /// recording and the watchdog retries on its cooldown, trying the
    /// built-in mic first from the second attempt on. The watchdog still
    /// stops the recording with an error after `maxRecoveryAttempts` in a row.
    func logMicRecoveryWillRetry(stage: String) {
        AppLogger.audioMic.warning("Microphone recovery attempt failed; recording continues and will retry", [
            "stage": stage,
            "attempt": "\(recoveryAttemptCount)",
            "maxAttempts": "\(maxRecoveryAttempts)"
        ])
    }

    func waitForMicBuffer(
        after previousBufferCount: Int,
        sessionGeneration: UInt64,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            guard sessionGeneration == recordingSessionGeneration else { return false }
            if MicRecoveryReadinessPolicy.deliveredNewBuffer(
                before: previousBufferCount,
                after: micBufferCount
            ) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard sessionGeneration == recordingSessionGeneration else { return false }
        return MicRecoveryReadinessPolicy.deliveredNewBuffer(
            before: previousBufferCount,
            after: micBufferCount
        )
    }
}

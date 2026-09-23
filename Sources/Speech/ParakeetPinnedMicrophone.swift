// ParakeetPinnedMicrophone.swift
// Dictation's pinned-device mic path. When the pinned-microphone switch is on
// and Apple voice processing is not requested, dictation records the selected
// input through `PinnedMicrophoneCapture` (a Core Audio IOProc on that one
// device) instead of `AVAudioEngine`. A fresh engine's input node binds the
// macOS default input before it can be pointed anywhere else, which pulls a
// Bluetooth headset into call mode even when the Mac mic is the one we want.
// Nothing here opens the default input.
//
// The seam into ParakeetEngine is deliberately small: startRecording asks
// `startPinnedDictationRecordingIfEnabled` after its shared reset, the stop
// path hands off to `stopPinnedDictationRecording`, and prewarm, readiness
// recovery, wake, config-change recovery, cancel and cleanup each take one
// early branch. Samples land in the same `pendingSamples` timeline as the
// engine tap, so transcription, recovery and persistence are unchanged.

@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import TranscriptedCore

/// One pinned dictation recording. `delivery` closes the sample gate the same
/// way `ParakeetAudioStartCancellationState` does for the engine tap, so a
/// late callback can never append into the next recording.
final class ParakeetPinnedDictationRecording: @unchecked Sendable {
    let capture: PinnedMicrophoneCapture
    let selection: DictationInputDeviceSelection
    let delivery = ParakeetAudioStartCancellationState()

    init(capture: PinnedMicrophoneCapture, selection: DictationInputDeviceSelection) {
        self.capture = capture
        self.selection = selection
    }
}

private struct PreparedPinnedDictationMicrophone: @unchecked Sendable {
    let capture: PinnedMicrophoneCapture
    let selection: DictationInputDeviceSelection
    let format: AVAudioFormat
}

private enum PinnedDictationPrepareResult: @unchecked Sendable {
    case prepared(PreparedPinnedDictationMicrophone)
    case notNeeded
    case unavailable(String)
}

extension ParakeetEngine {
    /// Budget for the device lookup plus IOProc setup. Longer than a plain
    /// HAL read because it also starts the device.
    private static var pinnedDictationStartTimeout: UInt64 {
        TranscriptedConstants.systemInputOperationTimeout * 2
    }

    /// True when the pinned recorder may be used: the switch is on and Apple
    /// voice processing is not requested. Each start still keeps the engine
    /// unless the macOS input is a Bluetooth headset that dictation skips
    /// (`PinnedDictationInputPolicy.recorderIsNeeded`).
    func usesPinnedDictationMicrophone() -> Bool {
        guard PinnedMicrophoneCapturePreferences.isEnabled() else { return false }
        // Apple voice processing only exists on the AVAudioEngine path.
        let voiceProcessingRequested = MicrophoneProcessingPreferences.isVoiceProcessingEnabled()
            && !ZoomMicrophoneSharingMonitor.shared.isZoomRunning
        return !voiceProcessingRequested
    }

    /// Prewarm and readiness recovery while the macOS input is a Bluetooth
    /// headset. Touching the engine here is exactly what binds that input,
    /// so readiness is simply marked; the start validates the device.
    func markPinnedDictationInputReady() {
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        prewarmRetryCount = 0
        scheduleInputDeviceNameRefresh()
        guard !recoveryState.inputFormatReady || recoveryState.isRecovering else { return }
        recoveryState.markFormatReady()
        publishRecoveryState()
    }

    /// Idle warmup and readiness recovery touch the macOS default input.
    /// Skip them only while that input is a Bluetooth headset, which is the
    /// one case the pinned recorder exists for; everyone else keeps the
    /// engine's fast start. An unreadable route counts as a headset.
    func pinnedDictationSkipsEngineWarmup() async -> Bool {
        let defaultIsBluetooth = try? await Self.systemInputWorkCoordinator.run(
            operation: "pinned_dictation_default_input_class",
            timeoutNanoseconds: TranscriptedConstants.systemInputOperationTimeout
        ) { () -> Bool in
            guard let selection = try? CoreAudioInputDeviceLookup.preferredDictationInputSelection() else {
                return true
            }
            return DictationInputDeviceSelectionPolicy.deviceClass(for: selection.defaultInput) == "bluetooth"
        }
        return defaultIsBluetooth ?? true
    }

    /// Idle wake with the pinned switch on. Mirrors the idle route-change
    /// path: invalidate the dormant graph and validate on the next use,
    /// without stopping or rebuilding an engine (which would bind the input).
    func deferPinnedDictationInputReadinessAfterWake() {
        audioGraphGeneration += 1
        _ = cancelAudioWatchdog()
        isEnginePrewarmed = false
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        prewarmRetryCount = 0
        recoveryState.deferUntilNextUse()
        publishRecoveryState()
    }

    /// Returns nil when the engine path should run instead: switch off, voice
    /// processing on, a route the engine can't hurt, or a device that can't be
    /// recorded this way. Otherwise returns whether the pinned recording
    /// started. Every Core Audio call runs on the timed system-input queue.
    func startPinnedDictationRecordingIfEnabled(
        owner: ParakeetAudioEngineQueueOwnerToken
    ) async -> Bool? {
        guard usesPinnedDictationMicrophone() else { return nil }
        // Mirror the meeting mic's Bluetooth isolation: unless the user chose
        // to record the macOS input, a Bluetooth headset that is the default
        // input stays out of it.
        let prefersBuiltInBluetoothInput = !MeetingMicrophonePreferences.usesSystemInput()
        let startedAt = CFAbsoluteTimeGetCurrent()

        let result: PinnedDictationPrepareResult
        do {
            result = try await Self.systemInputWorkCoordinator.run(
                operation: "pinned_dictation_prepare",
                timeoutNanoseconds: Self.pinnedDictationStartTimeout,
                cleanupAfterLateCompletion: { late in
                    if case let .prepared(prepared) = late { prepared.capture.stop() }
                }
            ) { () -> PinnedDictationPrepareResult in
                let selection: DictationInputDeviceSelection
                do {
                    selection = try Self.pinnedDictationInputSelection(
                        prefersBuiltInBluetoothInput: prefersBuiltInBluetoothInput
                    )
                } catch {
                    return .unavailable("selection: \(error.localizedDescription)")
                }
                guard PinnedDictationInputPolicy.recorderIsNeeded(for: selection) else {
                    return .notNeeded
                }
                let capture = PinnedMicrophoneCapture(
                    deviceID: selection.selectedInput.id,
                    configuration: .init(padsGapsWithSilence: false)
                )
                do {
                    let format = try capture.prepare()
                    return .prepared(PreparedPinnedDictationMicrophone(
                        capture: capture,
                        selection: selection,
                        format: format
                    ))
                } catch {
                    capture.stop()
                    return .unavailable("prepare: \(error.localizedDescription)")
                }
            }
        } catch {
            AppLogger.transcription.warning("PARAKEET | pinned microphone setup timed out; using the audio engine", [
                "error": error.localizedDescription
            ])
            reportPinnedDictationEngineFallback(stage: "setup_timeout")
            return nil
        }

        let prepared: PreparedPinnedDictationMicrophone
        switch result {
        case .notNeeded:
            // The macOS input isn't a Bluetooth headset (or there's nothing
            // else to record), so the engine binds exactly what we'd pin.
            return nil
        case let .unavailable(reason):
            AppLogger.transcription.warning("PARAKEET | pinned microphone unavailable; using the audio engine", [
                "reason": reason
            ])
            reportPinnedDictationEngineFallback(stage: "unavailable")
            return nil
        case let .prepared(value):
            prepared = value
        }

        // Stop, cancel or wake may have run while the lookup was suspended.
        guard pinnedDictationStartIsCurrent(owner) else {
            stopPinnedCaptureOffMain(prepared.capture)
            return false
        }

        let recording = ParakeetPinnedDictationRecording(
            capture: prepared.capture,
            selection: prepared.selection
        )
        let delivery = recording.delivery
        // Both closures are formed here, on the main actor, like the engine
        // tap's; the capture calls them from its own queue.
        let bufferCallback: (AVAudioPCMBuffer) -> Void = { [weak self] buffer in
            self?.admitPinnedDictationBuffer(buffer, delivery: delivery)
        }
        let eventHandler: (PinnedMicrophoneCaptureEvent) -> Void = { [weak self, weak recording] event in
            Task { @MainActor in
                guard let self, let recording else { return }
                self.handlePinnedDictationEvent(event, recording: recording)
            }
        }
        let capture = prepared.capture
        let startError: String?
        do {
            startError = try await Self.systemInputWorkCoordinator.run(
                operation: "pinned_dictation_start",
                timeoutNanoseconds: Self.pinnedDictationStartTimeout,
                cleanupAfterLateCompletion: { _ in capture.stop() }
            ) { () -> String? in
                do {
                    try capture.start(bufferCallback: bufferCallback, eventHandler: eventHandler)
                    return nil
                } catch {
                    capture.stop()
                    return error.localizedDescription
                }
            }
        } catch {
            startError = "start timed out: \(error.localizedDescription)"
        }
        if let startError {
            delivery.cancel()
            stopPinnedCaptureOffMain(capture)
            AppLogger.transcription.warning("PARAKEET | pinned microphone did not start; using the audio engine", [
                "error": startError
            ])
            reportPinnedDictationEngineFallback(stage: "start_failed")
            guard pinnedDictationStartIsCurrent(owner) else { return false }
            return nil
        }
        guard pinnedDictationStartIsCurrent(owner) else {
            delivery.cancel()
            stopPinnedCaptureOffMain(capture)
            return false
        }

        // A capture left by a start that lost its reset should never keep
        // appending next to this one.
        discardPinnedDictationRecording()
        pinnedDictationRecording = recording
        updateCachedInputDeviceSelection(prepared.selection)
        updateNativeSampleRate(prepared.format.sampleRate)
        isRecording = true
        if !recoveryState.inputFormatReady || recoveryState.isRecovering {
            recoveryState.markFormatReady()
            publishRecoveryState()
        }

        let startMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        AppLogger.transcription.info("PARAKEET | recording started on the pinned microphone", [
            "backend": PinnedMicrophoneCapture.diagnosticBackendName,
            "reason": prepared.selection.reason.rawValue,
            "selectedTransport": prepared.selection.selectedInput.transport.rawValue,
            "defaultInputOverridden": "\(prepared.selection.didOverrideDefault)",
            "sampleRate": "\(prepared.format.sampleRate)",
            "channels": "\(prepared.format.channelCount)",
            "startMs": "\(startMs)"
        ])
        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "pinned_microphone_recording_started",
            message: "Dictation started on the pinned microphone",
            context: [
                "backend": PinnedMicrophoneCapture.diagnosticBackendName,
                "reason": prepared.selection.reason.rawValue,
                "selected_input_class": DictationInputDeviceSelectionPolicy.deviceClass(
                    for: prepared.selection.selectedInput
                ),
                "default_input_overridden": "\(prepared.selection.didOverrideDefault)",
                "start_ms": "\(startMs)"
            ]
        )
        return true
    }

    private func pinnedDictationStartIsCurrent(_ owner: ParakeetAudioEngineQueueOwnerToken) -> Bool {
        ownsAudioEngineQueue(owner) && !isShuttingDown && !Task.isCancelled && !isRecording
    }

    /// `AudioDeviceStop` and `DestroyIOProcID` can block on a slow driver.
    private func stopPinnedCaptureOffMain(_ capture: PinnedMicrophoneCapture) {
        Task.detached(priority: .userInitiated) { capture.stop() }
    }

    /// The engine path this falls back to opens the macOS input first, so a
    /// Bluetooth default goes back into call mode. Counted so a rise shows up.
    private func reportPinnedDictationEngineFallback(stage: String) {
        EventReporter.shared.capture(
            level: .warning,
            engine: "parakeet",
            event: "pinned_microphone_fell_back_to_engine",
            message: "Pinned dictation microphone unavailable; using the audio engine",
            context: ["stage": stage]
        )
    }

    /// Runs on the capture's queue. Same admission as the engine tap in
    /// `installTapAndStartEngine`: rate-aware append, capacity trim, first
    /// sample and truncation events, and throttled level metering.
    func admitPinnedDictationBuffer(
        _ buffer: AVAudioPCMBuffer,
        delivery: ParakeetAudioStartCancellationState
    ) {
        guard delivery.canDeliverSamples,
              let monoSamples = MicrophoneDownmix.monoSamples(from: buffer) else { return }
        let frameLength = monoSamples.count
        guard frameLength > 0 else { return }
        let channelCount = buffer.format.channelCount
        let effectiveSampleRate = ParakeetTapSampleRatePolicy.effectiveSampleRate(
            bufferSampleRate: buffer.format.sampleRate
        )
        let hasNonZeroSignal = ParakeetSampleSignalPolicy.hasNonZeroSignal(monoSamples)
        let sampleArrivalTime = CFAbsoluteTimeGetCurrent()
        let admitted = pendingSamplesLock.withLock { () -> (firstSample: Bool, droppedSeconds: Double)? in
            guard delivery.canDeliverSamples else { return nil }
            nativeSampleRate = effectiveSampleRate
            let firstSample = !didReceiveAudioSamples
            didReceiveAudioSamples = true
            if hasNonZeroSignal { didReceiveNonZeroAudioSamples = true }
            lastAudioSampleAt = sampleArrivalTime
            pendingSamples.append(monoSamples, sampleRate: effectiveSampleRate)
            var droppedSeconds = 0.0
            let capacitySeconds = Double(TranscriptedConstants.audioBufferCapacitySeconds)
            if pendingSamples.totalDurationSeconds > capacitySeconds + 1 {
                let dropped = pendingSamples.trimToLatest(durationSeconds: capacitySeconds)
                if !didReportPendingSampleTruncation {
                    didReportPendingSampleTruncation = true
                    droppedSeconds = dropped
                }
            }
            return (firstSample, droppedSeconds)
        }
        guard let admitted else { return }

        if admitted.firstSample {
            let startToFirstSampleMs = audioStartReferenceTime.map {
                Int((CFAbsoluteTimeGetCurrent() - $0) * 1000)
            }
            Task { @MainActor in
                var context = [
                    "sample_rate": "\(effectiveSampleRate)",
                    "channels": "\(channelCount)",
                    "frames": "\(frameLength)",
                    "sample_signal_started": "\(hasNonZeroSignal)",
                    "backend": PinnedMicrophoneCapture.diagnosticBackendName
                ]
                if let startToFirstSampleMs {
                    context["start_to_first_sample_ms"] = "\(startToFirstSampleMs)"
                }
                EventReporter.shared.capture(level: .info, engine: "parakeet", event: "audio_samples_detected",
                    message: "Audio samples started flowing",
                    context: context)
            }
        }

        if admitted.droppedSeconds > 0 {
            let droppedSeconds = admitted.droppedSeconds
            Task { @MainActor in
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: "audio_buffer_truncated",
                    message: "Recording exceeded the audio buffer capacity; oldest audio was dropped",
                    context: [
                        "dropped_seconds": String(format: "%.1f", droppedSeconds),
                        "capacity_seconds": "\(Int(TranscriptedConstants.audioBufferCapacitySeconds))",
                    ]
                )
            }
        }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevelUpdate > TranscriptedConstants.audioMeteringInterval else { return }
        lastLevelUpdate = now
        let normalized = DictationAudioLevelMeter.normalizedLevel(from: buffer)
        Task { @MainActor [weak self] in
            guard delivery.canDeliverSamples else { return }
            self?.audioLevel = normalized
        }
    }

    private func handlePinnedDictationEvent(
        _ event: PinnedMicrophoneCaptureEvent,
        recording: ParakeetPinnedDictationRecording
    ) {
        guard pinnedDictationRecording === recording, isRecording else { return }
        switch event {
        case let .gap(seconds, _):
            AppLogger.transcription.info("PARAKEET | pinned microphone resumed after a gap", [
                "gapSeconds": String(format: "%.2f", seconds)
            ])
        case let .restarted(trigger):
            AppLogger.transcription.warning("PARAKEET | pinned microphone restarted on the same device", [
                "trigger": trigger.rawValue
            ])
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "pinned_microphone_restarted",
                message: "Pinned dictation microphone restarted on the same device",
                context: ["trigger": trigger.rawValue]
            )
        case .deviceLost:
            Task { @MainActor [weak self] in
                await self?.replacePinnedDictationMicrophone(recording, because: .deviceLost)
            }
        case .silentInput:
            Task { @MainActor [weak self] in
                await self?.replacePinnedDictationMicrophone(recording, because: .silentInput)
            }
        case let .failed(message):
            AppLogger.transcription.error("PARAKEET | pinned microphone failed", ["error": message])
            interruptPinnedDictationRecording(recording, reason: "capture_failed")
        }
    }

    /// The automatic pick, then PinnedDictationInputPolicy: a mic the user
    /// chose, or a wired/USB mic on a Mac without a built-in one, instead of
    /// the Bluetooth headset. Runs on the system-input work queue.
    nonisolated private static func pinnedDictationInputSelection(
        prefersBuiltInBluetoothInput: Bool,
        excludingDeviceID: AudioDeviceID? = nil
    ) throws -> DictationInputDeviceSelection {
        // A closed MacBook's own mic is listed but hears nothing.
        let lidClosed = MacLidState.isClosed()
        var automatic = try CoreAudioInputDeviceLookup.preferredDictationInputSelection(
            prefersBuiltInBluetoothInput: prefersBuiltInBluetoothInput,
            lidClosed: lidClosed
        )
        if let excludingDeviceID, automatic.selectedInput.id == excludingDeviceID,
           automatic.defaultInput.id != excludingDeviceID {
            // The automatic pick is the mic that just died or went silent.
            automatic = DictationInputDeviceSelection(
                defaultInput: automatic.defaultInput,
                selectedInput: automatic.defaultInput,
                defaultOutput: automatic.defaultOutput,
                reason: .noBuiltInFallbackAvailable
            )
        }
        guard PinnedDictationInputPolicy.mayReplace(automatic),
              var availableInputs = try? CoreAudioInputDeviceLookup.availableInputDevices() else {
            return automatic
        }
        if let excludingDeviceID {
            availableInputs.removeAll { $0.id == excludingDeviceID }
        }
        return PinnedDictationInputPolicy.selection(
            automatic: automatic,
            availableInputs: availableInputs,
            preferredUID: DictationPersistentInputPreferences.preferredDeviceUID(),
            lidClosed: lidClosed
        )
    }

    enum PinnedDictationReplacementCause: String {
        case deviceLost = "device_lost"
        case silentInput = "silent_input"
    }

    /// The pinned device went away (unplugged USB mic, disconnected headset),
    /// or it delivers only exact zeros (a closed MacBook's mic). Pick again
    /// without that device and keep recording into this dictation. A lost
    /// device gets a few tries while the HAL settles; a silent one keeps
    /// recording where it is if nothing else can hear the user.
    private func replacePinnedDictationMicrophone(
        _ recording: ParakeetPinnedDictationRecording,
        because cause: PinnedDictationReplacementCause
    ) async {
        guard pinnedDictationRecording === recording, isRecording else { return }
        let prefersBuiltInBluetoothInput = !MeetingMicrophonePreferences.usesSystemInput()
        let capture = recording.capture
        let failedDeviceID = capture.deviceID
        let attempts = cause == .deviceLost ? 3 : 1
        var switched: DictationInputDeviceSelection?
        for attempt in 0..<attempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard pinnedDictationRecording === recording, isRecording else { return }
            }
            switched = try? await Self.systemInputWorkCoordinator.run(
                operation: "pinned_dictation_switch_device",
                timeoutNanoseconds: Self.pinnedDictationStartTimeout
            ) { () -> DictationInputDeviceSelection? in
                guard let selection = try? Self.pinnedDictationInputSelection(
                    prefersBuiltInBluetoothInput: prefersBuiltInBluetoothInput,
                    excludingDeviceID: failedDeviceID
                ), selection.selectedInput.id != failedDeviceID else { return nil }
                do {
                    try capture.switchDevice(to: selection.selectedInput.id)
                    return selection
                } catch {
                    return nil
                }
            }
            guard pinnedDictationRecording === recording, isRecording else { return }
            if switched != nil { break }
        }
        guard let switched else {
            if cause == .deviceLost {
                interruptPinnedDictationRecording(recording, reason: "device_lost")
            } else {
                AppLogger.transcription.warning("PARAKEET | pinned microphone is silent and no other input is available")
                reportPinnedDictationSilentInput(selection: recording.selection, action: "kept")
            }
            return
        }
        updateCachedInputDeviceSelection(switched)
        AppLogger.transcription.info("PARAKEET | pinned microphone moved to another input", [
            "cause": cause.rawValue,
            "reason": switched.reason.rawValue,
            "selectedTransport": switched.selectedInput.transport.rawValue
        ])
        if cause == .silentInput {
            reportPinnedDictationSilentInput(selection: recording.selection, action: "switched")
        }
        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "pinned_microphone_device_switched",
            message: "Pinned dictation microphone moved to another input",
            context: ["reason": switched.reason.rawValue]
        )
    }

    private func reportPinnedDictationSilentInput(
        selection: DictationInputDeviceSelection,
        action: String
    ) {
        EventReporter.shared.capture(
            level: .warning,
            engine: "parakeet",
            event: "pinned_microphone_silent_input",
            message: "Pinned dictation microphone delivered only silence",
            context: [
                "selected_input_class": DictationInputDeviceSelectionPolicy.deviceClass(
                    for: selection.selectedInput
                ),
                "action": action
            ]
        )
    }

    /// Ends a pinned recording that can't continue. Everything already heard
    /// is kept for the recovery prompt, the same as a wake interruption.
    func interruptPinnedDictationRecording(
        _ recording: ParakeetPinnedDictationRecording,
        reason: String
    ) {
        guard pinnedDictationRecording === recording else { return }
        recording.delivery.cancel()
        pinnedDictationRecording = nil
        let capture = recording.capture
        Task.detached(priority: .userInitiated) { capture.stop() }
        let wasRecording = isRecording
        if wasRecording {
            preserveCurrentRecordingBuffersForRecovery()
            isRecording = false
            audioLevel = 0
            interruptRecordingPreservingRecoveredTimeline()
        }
        // A wake is routine; a capture that failed or lost its device with
        // nowhere to go is a real failure worth a Sentry event.
        EventReporter.shared.capture(
            level: reason == "system_wake" ? .warning : .error,
            engine: "parakeet",
            event: "recording_interrupted",
            message: "Pinned dictation microphone could not continue",
            context: [
                "reason": reason,
                "was_recording": "\(wasRecording)",
                "mic_backend": PinnedMicrophoneCapture.diagnosticBackendName
            ]
        )
    }

    /// User stop for the pinned path. Delivers the words captured just before
    /// Stop, then releases the device. Recording state stays set until the
    /// drain finishes so wake and route handlers keep treating it as live.
    func stopPinnedDictationRecording() async {
        guard let recording = pinnedDictationRecording else { return }
        let capture = recording.capture
        await Task.detached(priority: .userInitiated) {
            capture.finishAndDrain()
        }.value
        recording.delivery.cancel()
        if pinnedDictationRecording === recording {
            pinnedDictationRecording = nil
        }
        let segments = pendingSamplesLock.withLock { pendingSamples.drain() }
        for segment in segments {
            recoveredRecordingTimeline.append(segment.samples, sampleRate: segment.sampleRate)
        }
        isRecording = false
        audioLevel = 0
        let diagnostics = capture.diagnostics
        let stoppedDuration = recoveredRecordingTimeline.totalDurationSeconds
        AppLogger.transcription.info("PARAKEET | pinned recording stopped", [
            "seconds": String(format: "%.1f", stoppedDuration),
            "restarts": "\(diagnostics.restarts)",
            "gaps": "\(diagnostics.gaps)",
            "droppedCallbacks": "\(diagnostics.droppedCallbacks)"
        ])
    }

    /// Cancel and cleanup: drop the recording without delivering its tail.
    func discardPinnedDictationRecording() {
        guard let recording = pinnedDictationRecording else { return }
        recording.delivery.cancel()
        pinnedDictationRecording = nil
        let capture = recording.capture
        Task.detached(priority: .userInitiated) { capture.stop() }
    }
}

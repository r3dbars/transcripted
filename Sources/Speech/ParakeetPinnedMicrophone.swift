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
    case unavailable(String)
}

extension ParakeetEngine {
    /// Budget for the device lookup plus IOProc setup. Longer than a plain
    /// HAL read because it also starts the device.
    private static var pinnedDictationStartTimeout: UInt64 {
        TranscriptedConstants.systemInputOperationTimeout * 2
    }

    /// True when the next dictation should use the pinned recorder.
    func usesPinnedDictationMicrophone() -> Bool {
        guard PinnedMicrophoneCapturePreferences.isEnabled() else { return false }
        // Apple voice processing only exists on the AVAudioEngine path.
        let voiceProcessingRequested = MicrophoneProcessingPreferences.isVoiceProcessingEnabled()
            && !ZoomMicrophoneSharingMonitor.shared.isZoomRunning
        return !voiceProcessingRequested
    }

    /// Prewarm and readiness recovery for the pinned path. There is no idle
    /// graph to validate, and touching the engine here is exactly what binds
    /// the default input, so readiness is simply marked.
    func markPinnedDictationInputReady() {
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        prewarmRetryCount = 0
        scheduleInputDeviceNameRefresh()
        guard !recoveryState.inputFormatReady || recoveryState.isRecovering else { return }
        recoveryState.markFormatReady()
        publishRecoveryState()
    }

    /// Returns nil when the engine path should run instead (switch off, voice
    /// processing on, or the device can't be recorded this way). Otherwise
    /// returns whether the pinned recording started.
    func startPinnedDictationRecordingIfEnabled(
        owner: ParakeetAudioEngineQueueOwnerToken
    ) async -> Bool? {
        guard usesPinnedDictationMicrophone() else { return nil }
        // Mirror the meeting mic's Bluetooth isolation: unless the user chose
        // to record the macOS input, a Bluetooth headset that is the default
        // input stays out of it and the built-in mic is used.
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
        guard ownsAudioEngineQueue(owner), !isShuttingDown, !Task.isCancelled, !isRecording else {
            prepared.capture.stop()
            return false
        }

        let recording = ParakeetPinnedDictationRecording(
            capture: prepared.capture,
            selection: prepared.selection
        )
        let delivery = recording.delivery
        do {
            try prepared.capture.start(
                bufferCallback: { [weak self] buffer in
                    self?.admitPinnedDictationBuffer(buffer, delivery: delivery)
                },
                eventHandler: { [weak self, weak recording] event in
                    // Runs on the capture's queue; recording state is MainActor.
                    Task { @MainActor in
                        guard let self, let recording else { return }
                        self.handlePinnedDictationEvent(event, recording: recording)
                    }
                }
            )
        } catch {
            delivery.cancel()
            prepared.capture.stop()
            AppLogger.transcription.warning("PARAKEET | pinned microphone did not start; using the audio engine", [
                "error": error.localizedDescription
            ])
            reportPinnedDictationEngineFallback(stage: "start_failed")
            return nil
        }

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
                await self?.replaceLostPinnedDictationMicrophone(recording)
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
        prefersBuiltInBluetoothInput: Bool
    ) throws -> DictationInputDeviceSelection {
        let automatic = try CoreAudioInputDeviceLookup.preferredDictationInputSelection(
            prefersBuiltInBluetoothInput: prefersBuiltInBluetoothInput
        )
        guard PinnedDictationInputPolicy.mayReplace(automatic),
              let availableInputs = try? CoreAudioInputDeviceLookup.availableInputDevices() else {
            return automatic
        }
        return PinnedDictationInputPolicy.selection(
            automatic: automatic,
            availableInputs: availableInputs,
            preferredUID: DictationPersistentInputPreferences.preferredDeviceUID()
        )
    }

    /// The pinned device went away (unplugged USB mic, disconnected headset).
    /// Pick again with the same rules and keep recording into this dictation.
    private func replaceLostPinnedDictationMicrophone(
        _ recording: ParakeetPinnedDictationRecording
    ) async {
        guard pinnedDictationRecording === recording, isRecording else { return }
        let prefersBuiltInBluetoothInput = !MeetingMicrophonePreferences.usesSystemInput()
        let capture = recording.capture
        let switched: DictationInputDeviceSelection?
        do {
            switched = try await Self.systemInputWorkCoordinator.run(
                operation: "pinned_dictation_switch_device",
                timeoutNanoseconds: Self.pinnedDictationStartTimeout
            ) { () -> DictationInputDeviceSelection? in
                guard let selection = try? Self.pinnedDictationInputSelection(
                    prefersBuiltInBluetoothInput: prefersBuiltInBluetoothInput
                ) else { return nil }
                do {
                    try capture.switchDevice(to: selection.selectedInput.id)
                    return selection
                } catch {
                    return nil
                }
            }
        } catch {
            switched = nil
        }
        guard pinnedDictationRecording === recording, isRecording else { return }
        guard let switched else {
            interruptPinnedDictationRecording(recording, reason: "device_lost")
            return
        }
        updateCachedInputDeviceSelection(switched)
        AppLogger.transcription.info("PARAKEET | pinned microphone moved to another input", [
            "reason": switched.reason.rawValue,
            "selectedTransport": switched.selectedInput.transport.rawValue
        ])
        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "pinned_microphone_device_switched",
            message: "Pinned dictation microphone moved to another input",
            context: ["reason": switched.reason.rawValue]
        )
    }

    /// Ends a pinned recording that can't continue. Everything already heard
    /// is kept for the recovery prompt, the same as a wake interruption.
    private func interruptPinnedDictationRecording(
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
        EventReporter.shared.capture(
            level: .warning,
            engine: "parakeet",
            event: "recording_interrupted",
            message: "Pinned dictation microphone could not continue",
            context: ["reason": reason, "was_recording": "\(wasRecording)"]
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

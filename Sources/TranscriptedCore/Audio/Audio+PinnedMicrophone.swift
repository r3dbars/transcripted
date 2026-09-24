import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import Synchronization

/// A meeting mic recorded through `PinnedMicrophoneCapture`, ready to start.
struct PreparedPinnedMeetingMicrophone {
    let capture: PinnedMicrophoneCapture
    let deviceID: AudioDeviceID
    let recordingFormat: AVAudioFormat
    let recordingSnapshot: AudioRecordingFormatSnapshot
}

/// The meeting mic's pinned-device path. When `usesPinnedMicrophoneCapture`
/// is on and Apple voice processing is not requested, the meeting records the
/// selected input through a Core Audio IOProc on that device instead of an
/// `AVAudioEngine` input node. Nothing here opens the macOS default input, so
/// a Bluetooth headset that is the default input (but not the selected mic)
/// never gets pulled into call mode by a start, restart, recovery or wake.
///
/// The seam into the existing lifecycle is deliberately small:
/// `startAudioCapture` asks `preparePinnedMeetingMicrophoneIfEnabled` first,
/// `recoverFromDeviceChange` hands off to `recoverPinnedMeetingMicrophone`,
/// and `stop()` calls `finishPinnedMeetingMicrophone`. Buffers go through the
/// same `handleMicBuffer` as the engine tap, so writing, AGC, metering, the
/// watchdog and borrowed-mic dictation are unchanged. The capture pads its own
/// holes with silence, so a mic hiccup never needs a recovery segment file.
extension Audio {
    /// True while this meeting's mic records through the pinned recorder.
    /// The in-meeting mic boost turns on Apple voice processing, which needs
    /// the audio engine and puts a Bluetooth headset back in call mode, so
    /// the host must not offer it while this is true.
    public var isRecordingThroughPinnedMicrophone: Bool {
        pinnedMicrophoneRecording.load(ordering: .acquiring)
    }

    /// Returns nil when the engine path should be used instead: the switch is
    /// off, voice processing is requested, the engine can't hurt this route,
    /// or the selected device can't be recorded this way. Publishes the
    /// capture so Stop can always find it.
    func preparePinnedMeetingMicrophoneIfEnabled(
        operation: String,
        sessionGeneration: UInt64
    ) throws -> PreparedPinnedMeetingMicrophone? {
        retirePinnedMeetingMicrophone(operation: "\(operation)_replace")
        guard usesPinnedMicrophoneCapture else { return nil }
        guard !shouldArmVoiceProcessing else {
            AppLogger.audioMic.info("Pinned microphone skipped because Apple voice processing is on", [
                "operation": operation
            ])
            return nil
        }

        let selection: MeetingInputDeviceSelection
        if let pinnedSelection = meetingInputSelectionSnapshot() {
            selection = pinnedSelection
        } else {
            do {
                selection = try MeetingInputDeviceLookup.preferredInputSelection(
                    mode: meetingInputDeviceSelectionModeForCurrentRecording
                )
            } catch {
                AppLogger.audioMic.warning("Pinned microphone selection unavailable; using the audio engine", [
                    "operation": operation,
                    "error": error.localizedDescription
                ])
                return nil
            }
        }

        // Only a Bluetooth headset that is the macOS input, while we record a
        // different mic, is hurt by the engine. Everywhere else the engine
        // binds the same device, so its proven path is kept.
        guard MeetingInputDeviceSelectionPolicy.pinnedRecorderIsNeeded(for: selection) else {
            AppLogger.audioMic.info("Pinned microphone not needed for this route; using the audio engine", [
                "operation": operation,
                "reason": selection.reason.rawValue
            ])
            return nil
        }

        let deviceID = selection.selectedInput.id
        let capture = PinnedMicrophoneCapture(deviceID: deviceID)
        let format: AVAudioFormat
        do {
            format = try capture.prepare()
        } catch {
            capture.stop()
            AppLogger.audioMic.warning("Pinned microphone unavailable for this input; using the audio engine", [
                "operation": operation,
                "selectedTransport": selection.selectedInput.transport.rawValue,
                "error": error.localizedDescription
            ])
            return nil
        }
        guard let snapshot = AudioRecordingFormatPolicy.snapshot(format) else {
            capture.stop()
            AppLogger.audioMic.warning("Pinned microphone format unusable; using the audio engine", [
                "operation": operation,
                "sampleRate": "\(format.sampleRate)",
                "channels": "\(format.channelCount)"
            ])
            return nil
        }

        try withAudioGraphLock {
            guard sessionGeneration == recordingSessionGeneration else {
                capture.stop()
                throw AudioCaptureStaleSessionError()
            }
            // An idle or leftover engine graph must not keep the mic open
            // beside the pinned recorder.
            if let currentEngine = engine, let currentInputNode = inputNode {
                discardUnstartedInputGraph(
                    engine: currentEngine,
                    inputNode: currentInputNode,
                    operation: "\(operation)_pinned_replace_graph"
                )
            }
            pinnedMicrophoneCapture = capture
            voiceProcessingEnabled = false
        }
        setMeetingInputSelection(selection)
        AppLogger.audioMic.info("Meeting microphone pinned through Core Audio", [
            "operation": operation,
            "backend": PinnedMicrophoneCapture.diagnosticBackendName,
            "reason": selection.reason.rawValue,
            "selectedTransport": selection.selectedInput.transport.rawValue,
            "defaultInputOverridden": "\(selection.didOverrideDefault)",
            "sampleRate": "\(snapshot.sampleRate)",
            "channels": "\(snapshot.channelCount)"
        ])
        return PreparedPinnedMeetingMicrophone(
            capture: capture,
            deviceID: deviceID,
            recordingFormat: format,
            recordingSnapshot: snapshot
        )
    }

    func startPinnedMeetingMicrophone(
        _ prepared: PreparedPinnedMeetingMicrophone,
        writeContext: MicPCMWriteContext,
        sessionGeneration: UInt64
    ) throws {
        let capture = prepared.capture
        try withAudioGraphLock {
            guard sessionGeneration == recordingSessionGeneration,
                  pinnedMicrophoneCapture === capture else {
                throw AudioCaptureStaleSessionError()
            }
            try capture.start(
                bufferCallback: { [weak self] buffer in
                    self?.handleMicBuffer(buffer, writeContext: writeContext)
                },
                eventHandler: { [weak self, weak capture] event in
                    guard let self, let capture else { return }
                    self.handlePinnedMeetingMicrophoneEvent(
                        event,
                        capture: capture,
                        sessionGeneration: sessionGeneration
                    )
                }
            )
        }
    }

    /// Runs on the capture's queue. Anything that takes the audio graph lock
    /// is dispatched: Stop holds that lock while it drains this capture.
    func handlePinnedMeetingMicrophoneEvent(
        _ event: PinnedMicrophoneCaptureEvent,
        capture: PinnedMicrophoneCapture,
        sessionGeneration: UInt64
    ) {
        guard sessionGeneration == recordingSessionGeneration else { return }
        switch event {
        case let .gap(seconds, paddedSeconds):
            AppLogger.audioMic.info("Pinned microphone resumed after a gap", [
                "gapSeconds": String(format: "%.2f", seconds),
                "paddedSeconds": String(format: "%.2f", paddedSeconds)
            ])
            if seconds >= 0.5 {
                appendRecordingGap(AudioGap(
                    start: Date(timeIntervalSinceNow: -seconds),
                    duration: seconds,
                    reason: "Mic interruption"
                ))
            }
        case let .restarted(trigger):
            AppLogger.audioMic.warning("Pinned microphone restarted on the same device", [
                "trigger": trigger.rawValue
            ])
        case .deviceLost:
            AppLogger.audioMic.warning("Pinned microphone device went away")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.replacePinnedMeetingMicrophone(
                    capture,
                    sessionGeneration: sessionGeneration,
                    because: .deviceLost
                )
            }
        case .silentInput:
            AppLogger.audioMic.warning("Pinned microphone delivers only silence")
            // Exact zeros also come from a mic muted on purpose. Only the
            // closed MacBook's own mic is known dead; moving off a muted mic
            // would record someone who chose not to be heard.
            guard let selection = meetingInputSelectionSnapshot(),
                  selection.selectedInput.id == capture.deviceID,
                  MeetingInputDeviceSelectionPolicy.isLidMicrophone(selection.selectedInput),
                  MacLidState.isClosed() else {
                AppLogger.audioMic.info("Keeping the silent pinned microphone; it is not a closed lid's mic")
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.replacePinnedMeetingMicrophone(
                    capture,
                    sessionGeneration: sessionGeneration,
                    because: .silentInput
                )
            }
        case let .failed(message):
            AppLogger.audioMic.error("Pinned microphone failed", ["error": message])
            stopForPinnedMicrophoneFailure(sessionGeneration: sessionGeneration)
        }
    }

    enum PinnedMeetingMicrophoneReplacementCause: String {
        case deviceLost = "device_lost"
        case silentInput = "silent_input"
    }

    /// The pinned device disappeared (unplugged USB mic, disconnected
    /// headset) or delivers only exact zeros (a closed MacBook's mic). Pick
    /// again without it, using the meeting's selection rules, and keep
    /// recording into the same file; the hole is padded like any other. A
    /// lost device gets a few tries while the HAL settles and only then ends
    /// the meeting; a silent one stays put if nothing else can hear the user.
    /// If another recovery holds the slot, the watchdog re-dispatches this
    /// while the capture still waits for a device.
    func replacePinnedMeetingMicrophone(
        _ capture: PinnedMicrophoneCapture,
        sessionGeneration: UInt64,
        because cause: PinnedMeetingMicrophoneReplacementCause
    ) {
        guard sessionGeneration == recordingSessionGeneration,
              withAudioGraphLock({ pinnedMicrophoneCapture === capture }) else { return }
        guard beginMicRecovery(for: sessionGeneration) else { return }
        defer { endMicRecovery(for: sessionGeneration) }

        resetMeetingRouteState()
        let failedDeviceID = capture.deviceID
        let attempts = cause == .deviceLost ? 3 : 1
        var lastError: Error?
        for attempt in 0..<attempts {
            if attempt > 0 {
                Thread.sleep(forTimeInterval: 0.4)
            }
            guard sessionGeneration == recordingSessionGeneration else { return }
            do {
                let selection = try MeetingInputDeviceLookup.preferredInputSelection(
                    mode: meetingInputDeviceSelectionModeForCurrentRecording,
                    excludingDeviceID: failedDeviceID
                )
                guard selection.selectedInput.id != failedDeviceID else {
                    throw PinnedMicrophoneReplacementUnavailable()
                }
                guard sessionGeneration == recordingSessionGeneration else { return }
                try withAudioGraphLock {
                    guard sessionGeneration == recordingSessionGeneration,
                          pinnedMicrophoneCapture === capture else {
                        throw AudioCaptureStaleSessionError()
                    }
                    try capture.switchDevice(to: selection.selectedInput.id)
                }
                setMeetingInputSelection(selection)
                incrementDeviceSwitchCount()
                AppLogger.audioMic.info("Pinned microphone moved to another input", [
                    "cause": cause.rawValue,
                    "reason": selection.reason.rawValue,
                    "selectedTransport": selection.selectedInput.transport.rawValue
                ])
                return
            } catch is AudioCaptureStaleSessionError {
                return
            } catch {
                lastError = error
            }
        }
        guard cause == .deviceLost else {
            AppLogger.audioMic.warning("Pinned microphone is silent and no other input is available")
            return
        }
        AppLogger.audioMic.error("Pinned microphone could not move to another input", [
            "error": lastError?.localizedDescription ?? "unknown"
        ])
        stopForPinnedMicrophoneFailure(sessionGeneration: sessionGeneration)
    }

    /// `recoverFromDeviceChange` for the pinned path. The capture already
    /// restarts itself on a stall and pads the hole, so the watchdog only asks
    /// it to check. A flowing mic is never rebuilt, and a rebuild only ever
    /// reopens the same device.
    func recoverPinnedMeetingMicrophone(
        _ capture: PinnedMicrophoneCapture,
        sessionGeneration: UInt64,
        reason: MicCaptureRestartReason
    ) {
        guard sessionGeneration == recordingSessionGeneration else { return }
        switch reason {
        case .deviceChange:
            if capture.isWaitingForDevice {
                // A replacement that lost the recovery slot, or never ran.
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.replacePinnedMeetingMicrophone(
                        capture,
                        sessionGeneration: sessionGeneration,
                        because: .deviceLost
                    )
                }
            } else {
                capture.restartIfStalled()
            }
        case .processingChange:
            // Apple voice processing needs the engine path. Switching
            // backends mid-meeting would split the recording, so the choice
            // applies from the next meeting.
            AppLogger.audioMic.info("Microphone processing change applies at the next meeting on the pinned recorder")
        }
    }

    /// Stop's teardown. Delivers the words captured just before Stop through
    /// the stop-tail path, then releases the device.
    func finishPinnedMeetingMicrophone(_ capture: PinnedMicrophoneCapture) {
        let diagnostics = capture.diagnostics
        capture.finishAndDrain()
        if pinnedMicrophoneCapture === capture {
            pinnedMicrophoneCapture = nil
        }
        AppLogger.audioMic.info("Pinned microphone stopped", [
            "restarts": "\(diagnostics.restarts)",
            "gaps": "\(diagnostics.gaps)",
            "paddedSeconds": String(format: "%.2f", diagnostics.paddedSeconds),
            "droppedCallbacks": "\(diagnostics.droppedCallbacks)"
        ])
    }

    /// Drops a pinned capture left from an earlier recording (for example a
    /// stop whose teardown was skipped because this start had begun).
    func retirePinnedMeetingMicrophone(operation: String) {
        let retired: PinnedMicrophoneCapture? = withAudioGraphLock {
            let current = pinnedMicrophoneCapture
            pinnedMicrophoneCapture = nil
            return current
        }
        guard let retired else { return }
        retired.stop()
        AppLogger.audioMic.info("Retired previous pinned microphone", ["operation": operation])
    }

    private func stopForPinnedMicrophoneFailure(sessionGeneration: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.recordingSessionGeneration == sessionGeneration,
                  self.isRecording else { return }
            let expectedStopGeneration = self.predictedNextRecordingSessionGeneration()
            self.stop()
            guard self.recordingSessionGeneration == expectedStopGeneration else { return }
            self.error = "Microphone recovery failed. Reconnect your audio device or try quitting and reopening Transcripted."
        }
    }
}

private struct PinnedMicrophoneReplacementUnavailable: LocalizedError {
    var errorDescription: String? { "No other microphone is available" }
}

import Foundation
import QuartzCore
@preconcurrency import AVFoundation
import CoreAudio
import Combine
import Synchronization

// Meeting mic AVAudioEngine graph: build, validate, publish, discard,
// and safe input-tap teardown. Every `AVAudioEngine()` / `.inputNode`
// touch binds the macOS default input first; with AirPods as the default
// that flips them into call mode. See Sources/Speech/AGENTS.md.
extension Audio {
    func tearDownInputTapSafely(
        engine: AVAudioEngine,
        inputNode: AVAudioInputNode,
        operation: String
    ) {
        let steps = AudioInputTapTeardownPolicy.steps(engineIsRunning: engine.isRunning)
        for step in steps {
            switch step {
            case .stopEngine:
                AppLogger.audioMic.info("Stopping mic engine before removing input tap", [
                    "operation": operation
                ])
                engine.stop()
            case .waitForStoppedInputCallbacks:
                Thread.sleep(forTimeInterval: AudioInputTapTeardownPolicy.inputCallbackDrainDelay)
            case .removeInputTap:
                inputNode.removeTap(onBus: 0)
            }
        }
    }

    /// Whether the device the meeting mic is bound to still exists. Nil when
    /// there is no graph or no bound device to ask about.
    func boundMicDeviceIsAlive() -> Bool? {
        let deviceID: AudioDeviceID? = withAudioGraphLock {
            guard let inputNode else { return nil }
            let deviceID = inputNode.auAudioUnit.deviceID
            return deviceID.isValid ? deviceID : nil
        }
        guard let deviceID else { return nil }
        // A device that vanished can't answer at all, which counts as dead.
        return (try? deviceID.readIsAlive()) ?? false
    }

    @discardableResult
    func ensureEngineInitialized() throws -> (AVAudioEngine, AVAudioInputNode) {
        // Delay AVAudioEngine/input-node access until recording actually
        // begins. Launch-time warmup can construct Audio long before the
        // user has explicitly asked to record anything.
        if engine == nil {
            engine = AVAudioEngine()
        }

        if inputNode == nil, let engine {
            inputNode = engine.inputNode
            AppLogger.audioMic.info("Using system default microphone")
        }

        guard let engine, let inputNode else {
            throw NSError(
                domain: "Audio",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Engine not initialized"]
            )
        }

        return (engine, inputNode)
    }

    /// Create a detached mic graph instead of inheriting one used by
    /// monitoring or a failed device switch. The new graph is not published
    /// on `self` until its device and format are validated for the current
    /// recording generation, so a concurrent Stop cannot miss a newly claimed
    /// audio device.
    func makeDetachedFreshInputEngine() -> (AVAudioEngine, AVAudioInputNode) {
        if let currentEngine = engine {
            if currentEngine.isRunning, let currentInputNode = inputNode {
                tearDownInputTapSafely(
                    engine: currentEngine,
                    inputNode: currentInputNode,
                    operation: "start_recording_replace_graph"
                )
            }
            if let currentInputNode = inputNode {
                disarmVoiceProcessing(
                    on: currentInputNode,
                    reason: "start_recording_replace_graph"
                )
            }
            currentEngine.reset()
            engine = nil
            inputNode = nil
        }

        let freshEngine = AVAudioEngine()
        let freshInputNode = freshEngine.inputNode
        voiceProcessingEnabled = false
        AppLogger.audioMic.info("Created detached fresh microphone graph")
        return (freshEngine, freshInputNode)
    }

    func discardUnstartedInputGraph(
        engine discardedEngine: AVAudioEngine,
        inputNode discardedInputNode: AVAudioInputNode,
        operation: String
    ) {
        let ownsPublishedGraph = engine === discardedEngine
        if discardedEngine.isRunning {
            tearDownInputTapSafely(
                engine: discardedEngine,
                inputNode: discardedInputNode,
                operation: operation
            )
        }
        if ownsPublishedGraph {
            disarmVoiceProcessing(on: discardedInputNode, reason: operation)
        } else if discardedInputNode.isVoiceProcessingEnabled {
            do {
                try discardedInputNode.setVoiceProcessingEnabled(false)
            } catch {
                AppLogger.audioMic.warning("Detached voice processing disable failed", [
                    "operation": operation,
                    "error": error.localizedDescription
                ])
            }
        }
        discardedEngine.reset()
        if ownsPublishedGraph {
            engine = nil
            inputNode = nil
            voiceProcessingEnabled = false
        } else if engine == nil {
            voiceProcessingEnabled = false
        }
    }

    struct PreparedMeetingInputGraph {
        let engine: AVAudioEngine
        let inputNode: AVAudioInputNode
        let recordingFormat: AVAudioFormat
        let recordingSnapshot: AudioRecordingFormatSnapshot
        let voiceProcessingEnabled: Bool
    }

    /// Build and validate a meeting microphone graph. A failed device bind
    /// taints the entire graph: CoreAudio may expose the requested device ID
    /// while retaining the previous device's format and delivering no frames.
    /// Each retry therefore starts from a new AVAudioEngine/input node.
    func makeReadyMeetingInputGraph(
        operation: String,
        resetMeetingSelectionBeforeRetry: Bool,
        sessionGeneration: UInt64,
        routeWasUnstable: Bool = false,
        dropsFailedPickOnRetry: Bool = false
    ) throws -> PreparedMeetingInputGraph {
        var lastError: Error?
        // Result of the most recent `armVoiceProcessing` call, threaded out of
        // the attempt so the retry can tell "VPIO was requested but did not
        // become active" apart from every other first-attempt failure.
        var lastAttemptVoiceProcessingActive: Bool?
        var voiceProcessingFallbackEngaged = false

        // Attempts 0 and 1 use the chosen mic. Attempt 2 runs only when both
        // failed and a different built-in mic exists: recording on the Mac's
        // own mic beats failing the meeting start or ending the meeting.
        for attempt in 0..<3 {
            guard sessionGeneration == recordingSessionGeneration else {
                throw AudioCaptureStaleSessionError()
            }

            if attempt == 2 {
                guard pinBuiltInMeetingInputFallback(operation: operation) else { break }
                Thread.sleep(forTimeInterval: 0.3)
            } else if attempt > 0 {
                // Bounded, meeting-only start fallback: when the user asked
                // for Apple voice processing but arming it did not take, the
                // failed wrap can leave the fresh input node with an
                // untrustworthy device identity, so re-arming identically just
                // fails the retry the same way and the start dies looking like
                // a microphone problem. Run the one existing retry on the
                // standard non-VPIO path instead. Permission gating and the
                // mic/system readiness latches downstream are untouched.
                var retriesWithoutVoiceProcessing = false
                if VoiceProcessingStartFallbackPolicy.shouldRetryWithoutVoiceProcessing(
                    voiceProcessingRequested: shouldArmVoiceProcessing,
                    previousAttemptVoiceProcessingActive: lastAttemptVoiceProcessingActive,
                    fallbackAlreadyEngaged: voiceProcessingFallbackEngaged
                ) {
                    retriesWithoutVoiceProcessing = true
                    voiceProcessingFallbackEngaged = true
                    recordVoiceProcessingStartFallback(.attempted)
                    AppLogger.audioMic.warning("Voice processing was requested but did not become active; retrying capture start without it", [
                        "operation": operation,
                        "error": lastError?.localizedDescription ?? "unknown"
                    ])
                }
                // Start only, and only when the first attempt was on the
                // picked mic and failed for a reason other than voice
                // processing: recovery keeps the pick so it comes back.
                if attempt == 1,
                   dropsFailedPickOnRetry,
                   !retriesWithoutVoiceProcessing,
                   lastAttemptedMeetingSelectionReason == .userChosenInput,
                   dropMeetingPreferredInputDeviceForCurrentRecording() {
                    // A picked mic that is plugged in but would not start
                    // must not cost the meeting: the retry runs the automatic
                    // choice, which is what this Mac records without a pick.
                    AppLogger.audioMic.warning("Picked meeting microphone did not start; retrying with the automatic choice", [
                        "operation": operation,
                        "error": lastError?.localizedDescription ?? "unknown"
                    ])
                    resetMeetingRouteState()
                } else if resetMeetingSelectionBeforeRetry {
                    resetMeetingRouteState()
                }
                // Let CoreAudio settle without blocking Stop's graph teardown.
                Thread.sleep(forTimeInterval: 0.3)
            }

            guard sessionGeneration == recordingSessionGeneration else {
                throw AudioCaptureStaleSessionError()
            }

            do {
                let preparedGraph = try withAudioGraphLock { () throws -> PreparedMeetingInputGraph in
                    guard sessionGeneration == recordingSessionGeneration else {
                        throw AudioCaptureStaleSessionError()
                    }

                    let (freshEngine, freshInputNode) = makeDetachedFreshInputEngine()
                    do {
                        let attemptOperation = attempt == 0 ? operation
                            : attempt == 1 ? "\(operation)_retry"
                            : "\(operation)_builtin_fallback"
                        let selectionOutcome = applyMeetingInputDevice(
                            to: freshInputNode,
                            operation: attemptOperation,
                            routeWasUnstable: routeWasUnstable
                        )
                        guard !MeetingInputDeviceSelectionPolicy.shouldAbortMeetingStart(
                            after: selectionOutcome
                        ) else {
                            throw NSError(
                                domain: "Audio",
                                code: 4,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "Could not safely switch microphones. Check your input device and try again."
                                ]
                            )
                        }

                        // Verify the selected physical microphone before VPIO
                        // replaces the node's device identity with its private
                        // wrapper. The wrapper ID is not a reliable indication
                        // of which physical input CoreAudio already bound.
                        // `armVoiceProcessing` returns both the pre-wrap device
                        // ID and the resulting VPIO state as one atomic value,
                        // so route readiness and format selection below thread
                        // that same value through instead of separately
                        // capturing the device ID beforehand and re-reading
                        // the ambient `voiceProcessingEnabled` cache after.
                        let selection = meetingInputSelectionSnapshot()
                        let voiceProcessingBind = armVoiceProcessing(
                            on: freshInputNode,
                            suppressedByStartFallback: voiceProcessingFallbackEngaged
                        )
                        lastAttemptVoiceProcessingActive = voiceProcessingBind.enabled
                        let recordingFormat = self.recordingFormat(
                            for: freshInputNode,
                            voiceProcessingEnabled: voiceProcessingBind.enabled
                        )
                        guard let recordingSnapshot = AudioRecordingFormatPolicy.snapshot(recordingFormat) else {
                            throw NSError(
                                domain: "Audio",
                                code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "Invalid input format"]
                            )
                        }

                        let selectedNominalRate = selection.flatMap {
                            try? $0.selectedInput.id.readNominalSampleRate()
                        }
                        let actualInputDeviceID = freshInputNode.auAudioUnit.deviceID
                        let routeReadiness = MeetingInputDeviceSelectionPolicy.routeReadiness(
                            selection: selection,
                            boundInputDeviceIDBeforeVoiceProcessing: voiceProcessingBind.boundInputDeviceIDBeforeWrap,
                            actualInputDeviceID: actualInputDeviceID,
                            capturedSampleRate: recordingSnapshot.sampleRate,
                            selectedNominalSampleRate: selectedNominalRate,
                            voiceProcessingEnabled: voiceProcessingBind.enabled
                        )
                        guard routeReadiness == .ready else {
                            AppLogger.audioMic.warning("Meeting microphone route did not settle", [
                                "attempt": "\(attempt + 1)",
                                "operation": operation,
                                "outcome": routeReadiness.rawValue,
                                "capturedRate": "\(recordingSnapshot.sampleRate)",
                                "selectedNominalRate": selectedNominalRate.map { "\($0)" } ?? "unknown"
                            ])
                            throw NSError(
                                domain: "Audio",
                                code: 5,
                                userInfo: [
                                    NSLocalizedDescriptionKey: "The microphone route did not become ready. Check your input device and try again."
                                ]
                            )
                        }

                        guard sessionGeneration == recordingSessionGeneration else {
                            throw AudioCaptureStaleSessionError()
                        }

                        // Publish only after this detached graph is fully
                        // validated for the still-current recording session.
                        engine = freshEngine
                        inputNode = freshInputNode
                        return PreparedMeetingInputGraph(
                            engine: freshEngine,
                            inputNode: freshInputNode,
                            recordingFormat: recordingFormat,
                            recordingSnapshot: recordingSnapshot,
                            voiceProcessingEnabled: voiceProcessingBind.enabled
                        )
                    } catch {
                        discardUnstartedInputGraph(
                            engine: freshEngine,
                            inputNode: freshInputNode,
                            operation: "\(operation)_discard_attempt"
                        )
                        throw error
                    }
                }

                guard sessionGeneration == recordingSessionGeneration else {
                    withAudioGraphLock {
                        discardUnstartedInputGraph(
                            engine: preparedGraph.engine,
                            inputNode: preparedGraph.inputNode,
                            operation: "\(operation)_discard_stale"
                        )
                    }
                    throw AudioCaptureStaleSessionError()
                }
                return preparedGraph
            } catch {
                if error is AudioCaptureStaleSessionError {
                    throw error
                }
                lastError = error
                AppLogger.audioMic.warning("Meeting microphone graph attempt failed", [
                    "attempt": "\(attempt + 1)",
                    "operation": operation,
                    "error": error.localizedDescription
                ])
            }
        }

        if meetingRouteStabilizationOutcomeValue == CaptureRouteStabilizationOutcome.switchFailed.rawValue {
            emitMeetingRouteStabilityWarningIfNeeded(outcome: .switchFailed)
        }
        let terminalError = lastError ?? NSError(
            domain: "Audio",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "The microphone route did not become ready."]
        )
        guard voiceProcessingFallbackEngaged else {
            throw terminalError
        }
        // Both the VPIO attempt and the non-VPIO fallback failed. Name the
        // voice-processing angle so the failure stops classifying as a bare
        // microphone/permission dead end, and keep the fallback attempt's real
        // error both in the message and as the underlying error.
        throw NSError(
            domain: "Audio",
            code: 7,
            userInfo: [
                NSLocalizedDescriptionKey: "Apple voice processing could not be activated, and the standard microphone path also failed: \(terminalError.localizedDescription)",
                NSUnderlyingErrorKey: terminalError
            ]
        )
    }
}

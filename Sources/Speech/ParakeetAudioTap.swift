// ParakeetAudioTap.swift
// AVAudioEngine tap install and engine start for dictation, the dictation
// voice-processing (VPIO) toggle, and the mono downmix. Split out of
// ParakeetEngine.swift.
//
// The tap closure runs on AVAudioEngine's IO/tap thread. Keep it free of
// new captures, logging, locks, and ObjC calls; it only appends into
// `pendingSamples` under `pendingSamplesLock` and hops to the main actor
// for events and the level meter.
//
// These are internal collaborator methods on ParakeetEngine. ParakeetEngine
// (ParakeetEngine.swift) stays the public-API owner and @MainActor home for
// the state; this file only groups one slice of its implementation.

@preconcurrency import AVFoundation
import Foundation
import TranscriptedCore

extension ParakeetEngine {
    /// Installs the dictation tap and starts the engine through
    /// `ParakeetAudioGraph.start`, which owns the lease checks, the call-app
    /// refresh before the voice-processing choice, and the commit.
    /// `attemptEngine` and `attemptQueue` name the graph this attempt began
    /// on, so a start that loses it cleans up there, not on the successor.
    func installTapAndStartEngine(
        startLeaseOwner: ParakeetAudioEngineQueueOwnerToken,
        attemptEngine: AVAudioEngine,
        attemptQueue: DispatchQueue,
        selection: DictationInputDeviceSelection?
    ) async throws -> ParakeetAudioStartOutcome {
        let driver = audioGraph.driver
        return try await audioGraph.start(
            owner: startLeaseOwner,
            holder: self,
            callApps: ParakeetCallAppPresence(
                refresh: { CallAppMicrophoneSharingMonitor.shared.refresh() },
                isRunning: { CallAppMicrophoneSharingMonitor.shared.isCallAppRunning }
            ),
            voiceProcessingEnabled: { callAppRunning in
                let decision = DictationVoiceProcessingRoutePolicy.decision(
                    requested: DictationVoiceProcessingRoutePolicy.isRequested(
                        savedPreference: MicrophoneProcessingPreferences.isVoiceProcessingEnabled(),
                        callAppRunning: callAppRunning
                    ),
                    selection: selection
                )
                if decision == .deferredForSplitBluetoothOutput {
                    AppLogger.transcription.info(
                        "PARAKEET | Apple voice processing deferred for split Bluetooth output route"
                    )
                }
                return decision.shouldEnable
            },
            wasPrewarmed: isEnginePrewarmed,
            timeoutNanoseconds: TranscriptedConstants.audioStartOperationTimeout,
            makeTapHandler: { [weak self] lease in
                self?.makeDictationTapHandler(lease: lease) ?? { _ in }
            },
            cleanUpLateStart: {
                attemptQueue.async {
                    driver.cleanUpLateStart(attemptEngine)
                }
            },
            recheckCallApps: {
                // A call app can launch while the worker starts the graph, and
                // the launch observer can't recover a graph an in-flight start
                // still owns. This task runs after the start's MainActor turn.
                Task { @MainActor [weak self] in
                    await self?.shareMicrophoneWithCallAppIfNeeded()
                }
            }
        )
    }

    /// The tap block for one start. `ParakeetAudioGraph.start` already drops
    /// buffers once the lease is cancelled; the second check under the
    /// buffer lock keeps a cancelled tap out of the next recording.
    private func makeDictationTapHandler(
        lease: ParakeetAudioStartLease
    ) -> (AVAudioPCMBuffer) -> Void {
        // Meters every buffer of this start for the island's waveform.
        let levelWindow = DictationAudioLevelWindow()
        return { [weak self] buffer in
            guard let self,
                  let monoSamples = self.extractMonoSamples(from: buffer) else { return }
            let frameLength = monoSamples.count
            guard frameLength > 0 else { return }
            let bufferFormat = Self.audioFormatSummary(buffer.format)
            let effectiveSampleRate = ParakeetTapSampleRatePolicy.effectiveSampleRate(
                bufferSampleRate: bufferFormat.sampleRate
            )
            let hasNonZeroSignal = ParakeetSampleSignalPolicy.hasNonZeroSignal(monoSamples)
            let sampleArrivalTime = CFAbsoluteTimeGetCurrent()
            let admitted = self.pendingSamplesLock.withLock { () -> (firstSample: Bool, droppedSeconds: Double)? in
                // Recheck admission after acquiring the buffer lock: a cancelled
                // tap must not append into the next recording's timeline.
                guard lease.canDeliverSamples else { return nil }
                self.nativeSampleRate = effectiveSampleRate
                let firstSample = !self.didReceiveAudioSamples
                self.didReceiveAudioSamples = true
                if hasNonZeroSignal { self.didReceiveNonZeroAudioSamples = true }
                self.lastAudioSampleAt = sampleArrivalTime
                if self.firstAudioSampleAt == nil { self.firstAudioSampleAt = sampleArrivalTime }
                self.pendingSamples.append(monoSamples, sampleRate: effectiveSampleRate)
                self.previewSink?.append(monoSamples, sampleRate: effectiveSampleRate)
                var droppedSeconds = 0.0
                let capacitySeconds = Double(TranscriptedConstants.audioBufferCapacitySeconds)
                if self.pendingSamples.totalDurationSeconds > capacitySeconds + 1 {
                    let dropped = self.pendingSamples.trimToLatest(
                        durationSeconds: capacitySeconds
                    )
                    if !self.didReportPendingSampleTruncation {
                        self.didReportPendingSampleTruncation = true
                        droppedSeconds = dropped
                    }
                }
                return (firstSample, droppedSeconds)
            }
            guard let admitted else { return }

            if admitted.firstSample {
                let startToFirstSampleMs = self.audioStartReferenceTime.map {
                    Int((CFAbsoluteTimeGetCurrent() - $0) * 1000)
                }
                Task { @MainActor in
                    var context = [
                        "sample_rate": "\(effectiveSampleRate)",
                        "channels": "\(bufferFormat.channelCount)",
                        "frames": "\(frameLength)",
                        "sample_signal_started": "\(hasNonZeroSignal)"
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

            // Every buffer counts toward the waveform; a reading comes about
            // 25 times a second and takes one hop to the main actor.
            guard let reading = levelWindow.add(buffer) else { return }
            Task { @MainActor [weak self] in
                guard lease.canDeliverSamples else { return }
                self?.audioLevels.update(reading)
            }
        }
    }

    /// Share the user-consented issue #500 VPIO path with dictation. Meeting
    /// capture owns the prompt; dictation just honors the stable mic-processing
    /// preference on each new recording start.
    @discardableResult
    nonisolated static func applyDictationVoiceProcessingPreference(
        _ enabled: Bool,
        to inputNode: AVAudioInputNode
    ) -> Bool {
        guard inputNode.isVoiceProcessingEnabled != enabled else { return true }
        do {
            try inputNode.setVoiceProcessingEnabled(enabled)
            if enabled {
                inputNode.isVoiceProcessingAGCEnabled = true
                if #available(macOS 14.0, *) {
                    inputNode.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: false,
                        duckingLevel: .min
                    )
                }
            }
            return inputNode.isVoiceProcessingEnabled == enabled
        } catch {
            let action = enabled ? "enable" : "disable"
            Task { @MainActor in
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: "dictation_voice_processing_unavailable",
                    message: "Could not \(action) dictation voice processing",
                    context: ["requested": "\(enabled)"]
                )
            }
            return false
        }
    }

    private func extractMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        MicrophoneDownmix.monoSamples(from: buffer)
    }
}

extension ParakeetEngine {
    /// Adapts the live `AVAudioInputNode` to the compiled dictation steps in
    /// `ParakeetStartRecordingFailurePolicy.swift`. Built from an `inputNode`
    /// the caller already touched, so it creates no new input node (that bind
    /// is what flips a default AirPods input into call mode).
    fileprivate struct LiveDictationTapNode: ParakeetDictationTapInputNode {
        let inputNode: AVAudioInputNode

        func removeInputTap() {
            inputNode.removeTap(onBus: 0)
        }

        func applyVoiceProcessingPreference(_ enabled: Bool) -> Bool {
            ParakeetEngine.applyDictationVoiceProcessingPreference(enabled, to: inputNode)
        }

        var liveInputFormat: AVAudioFormat { inputNode.inputFormat(forBus: 0) }
        var liveOutputFormat: AVAudioFormat { inputNode.outputFormat(forBus: 0) }
        var isVoiceProcessingActive: Bool { inputNode.isVoiceProcessingEnabled }
    }
}

/// The start-side AVAudioEngine calls behind `ParakeetAudioGraph.start`.
/// `prepareTap` reads `engine.inputNode`, which on a fresh engine binds the
/// macOS default input. With AirPods as the default input that is the call
/// that flips them into call mode; it runs after the start's lease check and
/// after the input snapshot moved the app's AUHAL input off a Bluetooth
/// default, exactly where the pre-seam code touched it.
extension ParakeetAVAudioEngineGraphDriver: ParakeetAudioGraphStartDriver {
    func prepareTap(
        on engine: AVAudioEngine,
        voiceProcessingEnabled: Bool,
        isCurrent: () -> Bool,
        stageTimings: inout [String: Int]
    ) throws -> AVAudioFormat {
        try ParakeetDictationTapPreparation.prepare(
            ParakeetEngine.LiveDictationTapNode(inputNode: engine.inputNode),
            voiceProcessingEnabled: voiceProcessingEnabled,
            isCurrent: isCurrent,
            stageTimings: &stageTimings
        )
    }

    func installTap(
        on engine: AVAudioEngine,
        format: AVAudioFormat,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void
    ) throws {
        let inputNode = engine.inputNode
        // A route change after the format read makes installTap raise an
        // Objective-C exception; the guard turns it into a failed start.
        try AudioTapInstallGuard.run(operation: "dictation_start") {
            inputNode.installTap(onBus: 0, bufferSize: TranscriptedConstants.audioTapBufferSize, format: format) { buffer, _ in
                onBuffer(buffer)
            }
        }
    }

    func isRunning(_ engine: AVAudioEngine) -> Bool {
        engine.isRunning
    }

    func start(_ engine: AVAudioEngine) throws {
        try engine.start()
    }
}

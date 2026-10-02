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
    func installTapAndStartEngine(
        startLeaseOwner: ParakeetAudioEngineQueueOwnerToken,
        startCancellationState: ParakeetAudioStartCancellationState,
        voiceProcessingEnabled: Bool
    ) async throws -> ParakeetAudioStartSnapshot {
        let wasPrewarmed = isEnginePrewarmed
        let workOwnership = audioEngineWorkOwnership
        let startWorkIsCurrent: () -> Bool = { [workOwnership] in
            startCancellationState.canRunWork
                && workOwnership.isActive(
                    owner: startLeaseOwner,
                    phase: .audioStart
                )
        }
        return try await runTimedAudioEngineWork(
            operation: "start_recording",
            isWorkCurrent: startWorkIsCurrent,
            cleanupAfterCancellation: Self.cleanUpLateAudioStart(on:),
            cleanupAfterLateCompletion: Self.cleanUpLateAudioStart(on:)
        ) { audioEngine in
            guard startWorkIsCurrent() else { throw CancellationError() }
            let workStartedAt = CFAbsoluteTimeGetCurrent()
            var stageTimings: [String: Int] = [:]
            let inputNode = audioEngine.inputNode
            let tapFormat = try ParakeetDictationTapPreparation.prepare(
                LiveDictationTapNode(inputNode: inputNode),
                voiceProcessingEnabled: voiceProcessingEnabled,
                isCurrent: startWorkIsCurrent,
                stageTimings: &stageTimings
            )
            let tapInstallStartedAt = CFAbsoluteTimeGetCurrent()
            // A route change after the format read makes installTap raise an
            // Objective-C exception; the guard turns it into a failed start.
            try AudioTapInstallGuard.run(operation: "dictation_start") { inputNode.installTap(onBus: 0, bufferSize: TranscriptedConstants.audioTapBufferSize, format: tapFormat) { [weak self] buffer, _ in
                guard startCancellationState.canDeliverSamples else { return }
                guard let self = self,
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
                    guard startCancellationState.canDeliverSamples else { return nil }
                    self.nativeSampleRate = effectiveSampleRate
                    let firstSample = !self.didReceiveAudioSamples
                    self.didReceiveAudioSamples = true
                    if hasNonZeroSignal { self.didReceiveNonZeroAudioSamples = true }
                    self.lastAudioSampleAt = sampleArrivalTime
                    if self.firstAudioSampleAt == nil { self.firstAudioSampleAt = sampleArrivalTime }
                    self.pendingSamples.append(monoSamples, sampleRate: effectiveSampleRate)
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

                let now = CFAbsoluteTimeGetCurrent()
                guard now - self.lastLevelUpdate > TranscriptedConstants.audioMeteringInterval else { return }
                self.lastLevelUpdate = now

                let normalized = DictationAudioLevelMeter.normalizedLevel(from: buffer)

                Task { @MainActor [weak self] in
                    guard startCancellationState.canDeliverSamples else { return }
                    self?.audioLevel = normalized
                }
            } }
            guard startWorkIsCurrent() else { throw CancellationError() }
            stageTimings["audio_tap_install_ms"] = Self.elapsedMilliseconds(since: tapInstallStartedAt)

            let engineWasRunning = audioEngine.isRunning
            if !wasPrewarmed || !audioEngine.isRunning {
                stageTimings["audio_engine_prepare_ms"] = 0
                let engineStartStartedAt = CFAbsoluteTimeGetCurrent()
                guard startWorkIsCurrent() else { throw CancellationError() }
                try audioEngine.start()
                guard startWorkIsCurrent() else { throw CancellationError() }
                stageTimings["audio_engine_start_ms"] = Self.elapsedMilliseconds(since: engineStartStartedAt)
            } else {
                stageTimings["audio_engine_prepare_ms"] = 0
                stageTimings["audio_engine_start_ms"] = 0
            }
            stageTimings["audio_start_work_ms"] = Self.elapsedMilliseconds(since: workStartedAt)
            return ParakeetAudioStartSnapshot(
                engineWasRunning: engineWasRunning,
                stageTimings: stageTimings
            )
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

// ParakeetInputRoute.swift
// Dictation input route for ParakeetEngine: the cached input selection,
// the format snapshot that binds the app's own AUHAL to the chosen mic
// (audioInputSnapshot), format readiness, input-selection reporting, and
// the route diagnostics/analytics context builders. Split out of
// ParakeetEngine.swift.
//
// AirPods: audioInputSnapshot touches `audioEngine.inputNode`, which binds
// the macOS default input on a fresh engine. The selection is loaded and
// the config-change ignore window armed before that read, and the
// override is applied to this engine's AUHAL only; nothing here writes the
// Mac-wide default input. Read Sources/Speech/AGENTS.md before changing it.
//
// These are internal collaborator methods on ParakeetEngine. ParakeetEngine
// (ParakeetEngine.swift) stays the public-API owner and @MainActor home for
// the state; this file only groups one slice of its implementation.

@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import TranscriptedCore

extension ParakeetEngine {
    static func elapsedMilliseconds(since start: CFAbsoluteTime) -> Int {
        max(0, Int((CFAbsoluteTimeGetCurrent() - start) * 1000))
    }

    func updateCachedInputDeviceName(_ deviceName: String) {
        cachedInputDeviceName = deviceName
    }

    func updateCachedInputDeviceSelection(_ selection: DictationInputDeviceSelection) {
        cachedInputDeviceName = selection.selectedInput.name
        cachedInputDeviceSelection = selection
        if stableAudioRouteIdentity == nil {
            stableAudioRouteIdentity = ParakeetAudioRouteIdentity(selection: selection)
        }
        routeTransitionDebounceState.seedStableRouteIfNeeded(
            categoricalAudioRoute(for: selection)
        )
    }

    func categoricalAudioRoute(
        for selection: DictationInputDeviceSelection
    ) -> ParakeetCategoricalAudioRoute {
        let context = dictationRouteAnalyticsContext(selection: selection)
        return ParakeetCategoricalAudioRoute(
            inputDeviceClass: context["input_device_class"] ?? "unknown",
            outputDeviceClass: context["output_device_class"] ?? "unknown",
            routeShape: context["route_shape"] ?? "unknown"
        )
    }

    nonisolated static func audioFormatSummary(_ format: AVAudioFormat) -> ParakeetAudioFormatSummary {
        ParakeetAudioFormatSummary(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount
        )
    }

    func audioFormatReadiness(
        outputFormat: ParakeetAudioFormatSummary,
        hwFormat: ParakeetAudioFormatSummary,
        selection: DictationInputDeviceSelection?
    ) -> ParakeetAudioFormatReadiness {
        ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: outputFormat.sampleRate,
            outputChannelCount: outputFormat.channelCount,
            inputSampleRate: hwFormat.sampleRate,
            inputChannelCount: hwFormat.channelCount,
            selectedInputClass: selectedInputClass(for: selection),
            outputDeviceClass: defaultOutputClass(for: selection),
            selectionOverrodeDefault: selection?.didOverrideDefault ?? false,
            selectionReason: selection?.reason
        )
    }

    func selectedInputClass(for selection: DictationInputDeviceSelection?) -> String {
        if let selection {
            return DictationInputDeviceSelectionPolicy.deviceClass(for: selection.selectedInput)
        }
        return inputDeviceClass(for: inputDeviceName)
    }

    func defaultOutputClass(for selection: DictationInputDeviceSelection?) -> String {
        selection?.defaultOutput.map(DictationInputDeviceSelectionPolicy.deviceClass(for:)) ?? "unknown"
    }

    func audioFormatContext(
        outputFormat: ParakeetAudioFormatSummary,
        hwFormat: ParakeetAudioFormatSummary,
        selection: DictationInputDeviceSelection?,
        readiness: ParakeetAudioFormatReadiness
    ) -> [String: String] {
        var context = [
            "format_readiness": readiness.rawValue,
            "output_rate_hz": String(format: "%.0f", outputFormat.sampleRate),
            "output_channels": "\(outputFormat.channelCount)",
            "input_rate_hz": String(format: "%.0f", hwFormat.sampleRate),
            "hw_channels": "\(hwFormat.channelCount)",
            "hfp_suspected": "\(ParakeetRouteDiagnosticsPolicy.isLikelyBluetoothHandsFreeProfile(inputClass: selectedInputClass(for: selection), outputDeviceClass: defaultOutputClass(for: selection), inputRate: hwFormat.sampleRate, outputRate: outputFormat.sampleRate))",
            "input_device_class": selectedInputClass(for: selection),
            "selection_overrode_default": "\(selection?.didOverrideDefault ?? false)",
            "recovering": "\(recoveryState.isRecovering)",
            "format_ready": "\(recoveryState.inputFormatReady)",
            "generation": "\(recoveryState.generation)",
        ]

        if let selection {
            context["selection_reason"] = selection.reason.rawValue
            context["default_input_class"] = DictationInputDeviceSelectionPolicy.deviceClass(for: selection.defaultInput)
            context["selected_input_class"] = DictationInputDeviceSelectionPolicy.deviceClass(for: selection.selectedInput)
            if let defaultOutput = selection.defaultOutput {
                context["default_output_class"] = DictationInputDeviceSelectionPolicy.deviceClass(for: defaultOutput)
            }
        }

        return context
    }

    func dictationRouteDiagnosticsContext(
        outputFormat: ParakeetAudioFormatSummary? = nil,
        hwFormat: ParakeetAudioFormatSummary? = nil,
        selection: DictationInputDeviceSelection?,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var context = dictationRouteAnalyticsContext(
            outputFormat: outputFormat,
            hwFormat: hwFormat,
            selection: selection
        )
        context["generation"] = "\(recoveryState.generation)"

        for (key, value) in extra {
            context[key] = value
        }

        return context
    }

    func dictationRouteAnalyticsContext(
        outputFormat: ParakeetAudioFormatSummary? = nil,
        hwFormat: ParakeetAudioFormatSummary? = nil,
        selection: DictationInputDeviceSelection?,
        extra: [String: String] = [:]
    ) -> [String: String] {
        let selectedClass = selectedInputClass(for: selection)
        let defaultInputClass = selection.map { DictationInputDeviceSelectionPolicy.deviceClass(for: $0.defaultInput) } ?? "unknown"
        let defaultOutputClass = selection?.defaultOutput.map { DictationInputDeviceSelectionPolicy.deviceClass(for: $0) } ?? "unknown"
        let outputRate = outputFormat?.sampleRate
        let inputRate = hwFormat?.sampleRate

        var context: [String: String] = [
            "default_input_class": defaultInputClass,
            "default_output_class": defaultOutputClass,
            "format_ready": "\(recoveryState.inputFormatReady)",
            "hfp_suspected": "\(ParakeetRouteDiagnosticsPolicy.isLikelyBluetoothHandsFreeProfile(inputClass: selectedClass, outputDeviceClass: defaultOutputClass, inputRate: inputRate, outputRate: outputRate))",
            "input_device_class": selectedClass,
            "output_device_class": defaultOutputClass,
            "recovering": "\(recoveryState.isRecovering)",
            "route_shape": ParakeetRouteDiagnosticsPolicy.routeShape(
                selectedInputClass: selectedClass,
                outputDeviceClass: defaultOutputClass
            ),
            "sample_flow_started": "\(didReceiveAudioSamples)",
            "sample_signal_started": "\(didReceiveNonZeroAudioSamples)",
            "selection_overrode_default": "\(selection?.didOverrideDefault ?? false)",
            "selection_reason": selection?.reason.rawValue ?? "unknown",
            "selected_input_class": selectedClass,
        ]

        if let outputFormat {
            context["output_rate_hz"] = String(format: "%.0f", outputFormat.sampleRate)
            context["output_channels"] = "\(outputFormat.channelCount)"
        }

        if let hwFormat {
            context["input_rate_hz"] = String(format: "%.0f", hwFormat.sampleRate)
            context["input_channels"] = "\(hwFormat.channelCount)"
        }

        for (key, value) in extra {
            context[key] = value
        }

        return context
    }

    /// `isEngineWorkCurrent` has no default on purpose: a caller holding a
    /// lease a stop can claim must pass it, or graph work queued behind a
    /// stuck CoreAudio call still reads `inputNode` (and binds the default
    /// input) after the stop. Only an unleased caller passes nil.
    func audioInputSnapshot(
        operation: String,
        recoveryGeneration: UInt64? = nil,
        allowsBuiltInBluetoothFallback: Bool = true,
        isEngineWorkCurrent: (() -> Bool)?
    ) async throws -> ParakeetAudioInputSnapshot {
        let operationOwner = currentAudioEngineQueueOwnerToken()
        let snapshotStartedAt = CFAbsoluteTimeGetCurrent()
        let selectionStartedAt = CFAbsoluteTimeGetCurrent()
        var selectionLoadMs = 0
        // Selection is serialized on the system-input worker, a failed lookup
        // fails closed, and the ignore window is armed before the graph read
        // below touches the input node (`ParakeetAudioInputSelectionAdmission`).
        let selection = try await ParakeetAudioInputSelectionAdmission.admit(
            loadSelection: {
                let loadedSelection = try await Self.systemInputWorkCoordinator.run(
                    operation: "\(operation)_selection",
                    timeoutNanoseconds: TranscriptedConstants.systemInputOperationTimeout
                ) {
                    Self.loadDictationInputDeviceSelection(
                        allowsBuiltInBluetoothFallback: allowsBuiltInBluetoothFallback
                    )
                }
                selectionLoadMs = Self.elapsedMilliseconds(since: selectionStartedAt)
                return loadedSelection
            },
            ownsGraph: { ownsAudioEngineQueue(operationOwner) },
            needsIgnoreWindow: { selection in
                selection.didOverrideDefault
                    || cachedInputDeviceSelection?.selectedInput.id != selection.selectedInput.id
            },
            armIgnoreWindow: {
                // Avoid touching the current default input before the override is applied.
                // On AirPods routes, even a short read of the default input can briefly
                // pull playback toward headset-mode audio.
                ignoreInputSelectionConfigChangesUntil = CFAbsoluteTimeGetCurrent()
                    + TranscriptedConstants.selfInducedConfigChangeIgnoreWindow
            },
            isRecoveryStale: {
                recoveryGeneration.map { recoveryState.isStale(generation: $0) } ?? false
            }
        )
        var stageTimings = [
            "audio_input_selection_load_ms": selectionLoadMs
        ]
        let snapshotReadStartedAt = CFAbsoluteTimeGetCurrent()
        let snapshotResult: (
            outputFormat: ParakeetAudioFormatSummary,
            hwFormat: ParakeetAudioFormatSummary,
            selectionApplication: ParakeetInputDeviceApplication?,
            engineWasRunning: Bool
        )
        let bindingIntent = auhalBindingIntent
        do {
            snapshotResult = try await runTimedAudioEngineWork(
                operation: "\(operation)_snapshot",
                isWorkCurrent: isEngineWorkCurrent
            ) { audioEngine in
                // Voice processing can wrap the physical mic in a private
                // aggregate. Unwrap a stopped graph before verifying its next
                // input; the start path reapplies the current route preference.
                let reading = ParakeetDictationInputSnapshotRead.read(
                    LiveDictationSnapshotGraph(
                        engine: audioEngine,
                        inputNode: audioEngine.inputNode,
                        selection: selection,
                        bindingIntent: bindingIntent
                    )
                )
                return (
                    outputFormat: reading.outputFormat,
                    hwFormat: reading.hwFormat,
                    selectionApplication: reading.selectionApplication,
                    engineWasRunning: reading.engineWasRunning
                )
            }
        } catch {
            guard ownsAudioEngineQueue(operationOwner) else { throw CancellationError() }
            throw error
        }
        guard ownsAudioEngineQueue(operationOwner) else { throw CancellationError() }
        stageTimings["audio_input_snapshot_read_ms"] = Self.elapsedMilliseconds(since: snapshotReadStartedAt)
        stageTimings["audio_input_total_ms"] = Self.elapsedMilliseconds(since: snapshotStartedAt)
        let snapshot = ParakeetAudioInputSnapshot(
            outputFormat: snapshotResult.outputFormat,
            hwFormat: snapshotResult.hwFormat,
            selection: selection,
            selectionApplication: snapshotResult.selectionApplication,
            engineWasRunning: snapshotResult.engineWasRunning,
            stageTimings: stageTimings
        )
        if let recoveryGeneration, recoveryState.isStale(generation: recoveryGeneration) {
            throw CancellationError()
        }
        guard ownsAudioEngineQueue(operationOwner) else { throw CancellationError() }
        let settled = try await DictationInputBindingSequence.settle(
            applicationErrorDescription: snapshot.selectionApplication?.errorDescription,
            didApplyOverride: snapshot.selectionApplication?.didApplyOverride == true,
            checkCurrent: {
                guard self.ownsAudioEngineQueue(operationOwner) else { throw CancellationError() }
                if let recoveryGeneration, self.recoveryState.isStale(generation: recoveryGeneration) {
                    throw CancellationError()
                }
            },
            report: { report in
                switch report {
                case .issued:
                    self.recordInputSelection(snapshot.selectionApplication, operation: operation, bindingVerified: false)
                case .settleFailed(let bindingError):
                    if let application = snapshot.selectionApplication {
                        let failedApplication = ParakeetInputDeviceApplication(
                            selection: application.selection,
                            didApplyOverride: false,
                            reportKey: nil,
                            errorDescription: bindingError.localizedDescription
                        )
                        self.recordInputSelection(failedApplication, operation: operation, bindingVerified: false)
                    }
                case .verified:
                    self.recordInputSelection(snapshot.selectionApplication, operation: operation, bindingVerified: true)
                }
            },
            settle: {
                let settledSnapshotStartedAt = CFAbsoluteTimeGetCurrent()
                let settledSnapshotResult = try await DictationInputDeviceBindingPolicy.waitForBinding(
                    initialDelayNanoseconds: DictationInputDeviceBindingPolicy.initialSettleDelay(for: selection),
                    isCurrent: {
                        self.ownsAudioEngineQueue(operationOwner)
                            && isEngineWorkCurrent?() != false
                            && recoveryGeneration.map { !self.recoveryState.isStale(generation: $0) } != false
                    }
                ) { remainingNanoseconds in
                    try await self.runTimedAudioEngineWork(
                        operation: "\(operation)_settled_snapshot",
                        timeoutNanoseconds: min(remainingNanoseconds, TranscriptedConstants.audioStartOperationTimeout),
                        isWorkCurrent: isEngineWorkCurrent
                    ) { audioEngine in
                        let inputNode = audioEngine.inputNode
                        try DictationInputDeviceBindingPolicy.verify(
                            selectedDeviceID: selection.selectedInput.id,
                            boundDeviceID: inputNode.auAudioUnit.deviceID
                        )
                        return (
                            outputFormat: Self.audioFormatSummary(inputNode.outputFormat(forBus: 0)),
                            hwFormat: Self.audioFormatSummary(inputNode.inputFormat(forBus: 0)),
                            engineWasRunning: audioEngine.isRunning
                        )
                    }
                }
                stageTimings["audio_input_settled_snapshot_read_ms"] = Self.elapsedMilliseconds(since: settledSnapshotStartedAt)
                stageTimings["audio_input_total_ms"] = Self.elapsedMilliseconds(since: snapshotStartedAt)
                return ParakeetAudioInputSnapshot(
                    outputFormat: settledSnapshotResult.outputFormat,
                    hwFormat: settledSnapshotResult.hwFormat,
                    selection: selection,
                    selectionApplication: snapshot.selectionApplication,
                    engineWasRunning: settledSnapshotResult.engineWasRunning,
                    stageTimings: stageTimings
                )
            }
        )
        // No route command was issued: the first snapshot already stands.
        guard let settledSnapshot = settled else {
            return snapshot
        }
        let readiness = audioFormatReadiness(
            outputFormat: settledSnapshot.outputFormat,
            hwFormat: settledSnapshot.hwFormat,
            selection: settledSnapshot.selection
        )
        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "dictation_input_device_override_settled",
            message: "Dictation input override settled before reading microphone format",
            context: audioFormatContext(
                outputFormat: settledSnapshot.outputFormat,
                hwFormat: settledSnapshot.hwFormat,
                selection: settledSnapshot.selection,
                readiness: readiness
            ).merging(
                ["operation": operation],
                uniquingKeysWith: { current, _ in current }
            )
        )
        return settledSnapshot
    }

    @discardableResult
    private nonisolated static func applyPreferredDictationInputDevice(
        _ selection: DictationInputDeviceSelection?,
        to inputNode: AVAudioInputNode,
        on audioEngine: AVAudioEngine,
        bindingIntent: ParakeetAUHALBindingIntent
    ) -> ParakeetInputDeviceApplication? {
        guard let selection else { return nil }
        do {
            let didBind = try DictationInputDeviceBindingPolicy.apply(
                selection: selection,
                currentDeviceID: { inputNode.auAudioUnit.deviceID },
                setDeviceID: { selectedID in
                    try ParakeetInputBindingWrite.perform(
                        intent: bindingIntent,
                        engine: audioEngine,
                        route: ParakeetAudioRouteIdentity(selection: selection)
                    ) {
                        try inputNode.auAudioUnit.setDeviceID(selectedID)
                    }
                }
            )
            return ParakeetInputDeviceApplication(
                selection: selection,
                didApplyOverride: didBind,
                reportKey: didBind ? "\(selection.defaultInput.id)->\(selection.selectedInput.id)" : nil,
                errorDescription: nil
            )
        } catch {
            return ParakeetInputDeviceApplication(
                selection: selection,
                didApplyOverride: false,
                reportKey: nil,
                errorDescription: error.localizedDescription
            )
        }
    }

    private func recordInputSelection(
        _ application: ParakeetInputDeviceApplication?,
        operation: String,
        bindingVerified: Bool
    ) {
        guard let application else { return }
        let selection = application.selection
        // Keep the analytics cache fresh from the selection just applied. When
        // the override failed the cache is slightly optimistic about the
        // selected input; analytics tolerates that, and the failure event
        // below records the truth.
        cachedInputDeviceSelection = selection

        if let errorDescription = application.errorDescription {
            ignoreInputSelectionConfigChangesUntil = 0
            cachedInputDeviceName = selection.defaultInput.name
            var context = inputSelectionContext(selection, operation: operation)
            context["error"] = errorDescription
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "dictation_input_device_selection_failed",
                message: "Failed to apply preferred dictation input device",
                context: context
            )
            return
        }

        guard selection.didOverrideDefault else {
            cachedInputDeviceName = selection.selectedInput.name
            lastInputSelectionReportKey = nil
            return
        }

        cachedInputDeviceName = selection.selectedInput.name
        guard DictationInputSelectionReportPolicy.shouldReportAutoSelection(
            bindingVerified: bindingVerified,
            didApplyOverride: application.didApplyOverride,
            reportKey: application.reportKey,
            lastReportKey: lastInputSelectionReportKey
        ), let reportKey = application.reportKey else { return }

        lastInputSelectionReportKey = reportKey
        AppLogger.transcription.info("PARAKEET | using \(selection.selectedInput.name) instead of \(selection.defaultInput.name) to avoid Bluetooth headset mode")
        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "dictation_input_device_auto_selected",
            message: "Dictation input changed away from Bluetooth headset microphone",
            context: inputSelectionContext(selection, operation: operation)
        )
    }

    func inputSelectionContext(
        _ selection: DictationInputDeviceSelection,
        operation: String? = nil
    ) -> [String: String] {
        var context = [
            "audio_device": selection.selectedInput.name,
            "default_input_device": selection.defaultInput.name,
            "selected_input_device": selection.selectedInput.name,
            "default_input_class": DictationInputDeviceSelectionPolicy.deviceClass(for: selection.defaultInput),
            "selected_input_class": DictationInputDeviceSelectionPolicy.deviceClass(for: selection.selectedInput),
            "selection_reason": selection.reason.rawValue,
            "selection_overrode_default": "\(selection.didOverrideDefault)"
        ]

        if let defaultOutput = selection.defaultOutput {
            context["default_output_device"] = defaultOutput.name
            context["default_output_class"] = DictationInputDeviceSelectionPolicy.deviceClass(for: defaultOutput)
        }

        if let operation {
            context["operation"] = operation
        }

        return context
    }

    func inputDeviceClass(for deviceName: String) -> String {
        DictationInputDeviceSelectionPolicy.deviceClass(forName: deviceName)
    }
}

extension ParakeetEngine {
    /// Same idea for the `audioInputSnapshot` reads; binds only the app's own AUHAL.
    fileprivate struct LiveDictationSnapshotGraph: ParakeetDictationInputSnapshotGraph {
        let engine: AVAudioEngine
        let inputNode: AVAudioInputNode
        let selection: DictationInputDeviceSelection?
        let bindingIntent: ParakeetAUHALBindingIntent

        var isGraphRunning: Bool { engine.isRunning }

        func releaseVoiceProcessing() {
            ParakeetEngine.applyDictationVoiceProcessingPreference(false, to: inputNode)
        }

        func applySelectedInputDevice() -> ParakeetInputDeviceApplication? {
            ParakeetEngine.applyPreferredDictationInputDevice(
                selection, to: inputNode, on: engine,
                bindingIntent: bindingIntent
            )
        }

        var outputFormatSummary: ParakeetAudioFormatSummary {
            ParakeetEngine.audioFormatSummary(inputNode.outputFormat(forBus: 0))
        }

        var inputFormatSummary: ParakeetAudioFormatSummary {
            ParakeetEngine.audioFormatSummary(inputNode.inputFormat(forBus: 0))
        }
    }
}

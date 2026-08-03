// BluetoothRouteContractTests.swift
//
// Two kinds of coverage live in this file; they are NOT the same strength of proof:
//
// REAL BEHAVIORAL COVERAGE (compiled): the route-selection / readiness / recovery suites
// exercise Foundation-pure decision types compiled into the fast-test runner —
// DictationInputDeviceSelectionPolicy, ParakeetRouteDiagnosticsPolicy,
// ParakeetAudioFormatReadinessPolicy, ParakeetDeviceRecoveryReadinessPolicy /
// TimeoutPolicy, ParakeetTapSampleRatePolicy, ParakeetRecoveryState, and
// RecordedAudioTimeline. These run the real logic over mocked devices and assert real
// outputs (selection, route shape, HFP suspicion, readiness, recovery generations).
// NOTE: these are MOCKED route contracts — automated policy proof, not hardware proof;
// real connected AirPods/Bluetooth hardware still needs manual verification.
//
// IMPLEMENTATION-PINNING STRUCTURAL CONTRACTS (NOT compiled): the suites
// "engine tap wiring keeps sample-rate pinning" and "input override happens before
// format reads" read Sources/Speech/ParakeetEngine.swift as TEXT and grep for relative
// ordering of statements inside installTapAndStartEngine / audioInputSnapshot.
// ParakeetEngine is CoreAudio/Carbon-wired and is NOT compiled into this Foundation-only
// runner, so these greps pin source structure, not runtime behavior. They guard REAL
// invariants behind real AirPods bugs: the dictation tap must derive its sample rate from
// CoreAudio's delivered buffer.format (not the AirPods HFP hardware rate), and the forced
// input override must be applied BEFORE any input/output format read so AirPods are moved
// off the headset mic before the format is sampled. They are intentionally kept as
// source-text contracts rather than a runtime seam: extracting one would restructure
// real-time CoreAudio tap/format-read control flow, which is too risky to refactor for
// testability. The system default input override must also happen before format reads
// so macOS moves AirPods off the headset microphone route before recording starts.
// The "QA report names mocked proof boundary" suite is a docs/report
// consistency check, not a runtime check. If you move/rename these functions or reorder
// their statements, update both the source and these greps together.

import Foundation

func testBluetoothRouteContract() {
    runSuite("Bluetooth route contract - output plus built-in mic fallback stays explicit") {
        let airPodsInput = bluetoothDevice(1, "Justin's AirPods Pro", inputChannels: 1)
        let airPodsOutput = bluetoothDevice(2, "Justin's AirPods Pro", inputChannels: 0)
        let macBookMic = bluetoothRouteBuiltInDevice(3, "MacBook Pro Microphone")

        let selection = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: airPodsInput,
            defaultOutput: airPodsOutput,
            availableInputs: [airPodsInput, macBookMic]
        )

        assertEqual(selection.selectedInput, macBookMic, "Bluetooth headset playback should use the local built-in mic when available")
        assertEqual(selection.defaultOutput, airPodsOutput, "Bluetooth output should remain visible in the mocked route")
        assertEqual(selection.reason, .preferredBuiltInForBluetoothHeadset, "fallback reason should stay queryable in logs and tests")
        assertTrue(selection.didOverrideDefault, "built-in fallback should be reported as an input override")

        let routeShape = ParakeetRouteDiagnosticsPolicy.routeShape(
            selectedInputClass: DictationInputDeviceSelectionPolicy.deviceClass(for: selection.selectedInput),
            outputDeviceClass: DictationInputDeviceSelectionPolicy.deviceClass(for: airPodsOutput)
        )
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 48_000,
            outputChannelCount: 1,
            inputSampleRate: 48_000,
            inputChannelCount: 1,
            selectedInputClass: "built_in",
            outputDeviceClass: "bluetooth",
            selectionOverrodeDefault: true,
            selectionReason: .preferredBuiltInForBluetoothHeadset
        )

        assertEqual(routeShape, "built_in_input_to_bluetooth_output", "fallback route shape should stay stable for automation")
        assertEqual(readiness, .ready, "settled built-in fallback with Bluetooth output should be ready")
        assertFalse(
            ParakeetRouteDiagnosticsPolicy.isLikelyBluetoothHandsFreeProfile(
                inputClass: "built_in",
                outputDeviceClass: "bluetooth",
                inputRate: 48_000,
                outputRate: 48_000
            ),
            "settled 48k Bluetooth output fallback should not look like HFP"
        )
    }

    runSuite("Bluetooth route contract - HFP speech bus is unsafe for forced built-in fallback") {
        for hfpOutputRate in [8_000.0, 16_000.0, 24_000.0] {
            let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
                outputSampleRate: hfpOutputRate,
                outputChannelCount: 1,
                inputSampleRate: 48_000,
                inputChannelCount: 1,
                selectedInputClass: "built_in",
                outputDeviceClass: "bluetooth",
                selectionOverrodeDefault: true,
                selectionReason: .preferredBuiltInForBluetoothHeadset
            )

            assertEqual(readiness, .routeNotSettled, "forced built-in fallback should wait on HFP-style output rate \(Int(hfpOutputRate))")
            assertEqual(readiness.startFailureReason, .audioRouteNotSettled, "HFP fallback waits should stay recoverable")
            assertTrue(
                ParakeetRouteDiagnosticsPolicy.isLikelyBluetoothHandsFreeProfile(
                    inputClass: "built_in",
                    outputDeviceClass: "bluetooth",
                    inputRate: 48_000,
                    outputRate: hfpOutputRate
                ),
                "low-rate Bluetooth output plus 48k built-in input should be marked HFP-suspected"
            )
        }
    }

    runSuite("Bluetooth route contract - recovery attempt suppresses built-in fallback") {
        let airPodsInput = bluetoothDevice(1, "Justin's AirPods Pro", inputChannels: 1)
        let airPodsOutput = bluetoothDevice(2, "Justin's AirPods Pro", inputChannels: 0)
        let macBookMic = bluetoothRouteBuiltInDevice(3, "MacBook Pro Microphone")

        let selection = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: airPodsInput,
            defaultOutput: airPodsOutput,
            availableInputs: [airPodsInput, macBookMic],
            allowsBuiltInBluetoothFallback: false
        )

        let routeShape = ParakeetRouteDiagnosticsPolicy.routeShape(
            selectedInputClass: DictationInputDeviceSelectionPolicy.deviceClass(for: selection.selectedInput),
            outputDeviceClass: DictationInputDeviceSelectionPolicy.deviceClass(for: airPodsOutput)
        )

        assertEqual(selection.selectedInput, airPodsInput, "recovery attempts should get one matched Bluetooth route chance")
        assertFalse(selection.didOverrideDefault, "suppressed fallback should not report an override")
        assertEqual(selection.reason, .builtInFallbackSuppressedForRecoveryAttempt, "suppression reason should stay stable")
        assertEqual(routeShape, "bluetooth_input_to_bluetooth_output", "suppressed fallback should expose the matched Bluetooth route shape")
    }

    runSuite("Bluetooth route contract - suppressed recovery route waits on Bluetooth speech output") {
        for outputRate in [8_000.0, 16_000.0, 24_000.0] {
            let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
                outputSampleRate: outputRate,
                outputChannelCount: 3,
                inputSampleRate: 48_000,
                inputChannelCount: 1,
                selectedInputClass: "bluetooth",
                outputDeviceClass: "bluetooth",
                selectionOverrodeDefault: false,
                selectionReason: .builtInFallbackSuppressedForRecoveryAttempt
            )

            assertEqual(readiness, .routeNotSettled, "recovery should not start recording on the low-rate Bluetooth speech bus \(outputRate)")
            assertEqual(readiness.startFailureReason, .audioRouteNotSettled, "suppressed recovery routes should stay recoverable")
        }
    }

    runSuite("Bluetooth route contract - settled suppressed recovery route can record") {
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 48_000,
            outputChannelCount: 1,
            inputSampleRate: 24_000,
            inputChannelCount: 1,
            selectedInputClass: "bluetooth",
            outputDeviceClass: "bluetooth",
            selectionOverrodeDefault: false,
            selectionReason: .builtInFallbackSuppressedForRecoveryAttempt
        )

        assertEqual(readiness, .ready, "settled Bluetooth recovery capture should not be blocked")
    }

    runSuite("Bluetooth route contract - native AirPods HFP capture stays allowed") {
        let readiness = ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: 48_000,
            outputChannelCount: 1,
            inputSampleRate: 24_000,
            inputChannelCount: 1,
            selectedInputClass: "bluetooth",
            outputDeviceClass: "bluetooth",
            selectionOverrodeDefault: false
        )

        assertEqual(readiness, .ready, "native Bluetooth capture with 24k hardware and 48k tap output should remain usable")
        assertTrue(
            ParakeetRouteDiagnosticsPolicy.isLikelyBluetoothHandsFreeProfile(
                inputClass: "bluetooth",
                outputDeviceClass: "bluetooth",
                inputRate: 24_000,
                outputRate: 48_000
            ),
            "native AirPods HFP capture should be visible in diagnostics without being blocked"
        )
    }

    runSuite("Bluetooth route contract - route settling timeout interrupts active dictation only") {
        let activeTimeout = ParakeetDeviceRecoveryTimeoutPolicy.action(wasRecording: true)
        let idleTimeout = ParakeetDeviceRecoveryTimeoutPolicy.action(wasRecording: false)

        assertEqual(activeTimeout.rebuildStrategy, .abandonBlockedAudioGraph, "active recovery timeout should abandon a blocked graph")
        assertTrue(activeTimeout.failureAction.markRecordingInterrupted, "active dictation must surface interruption after route timeout")
        assertTrue(activeTimeout.failureAction.reportSentryFailure, "active dictation timeout should stay visible")
        assertFalse(idleTimeout.failureAction.markRecordingInterrupted, "idle route settling should not invent a recording interruption")
        assertFalse(idleTimeout.failureAction.reportSentryFailure, "idle route settling should stay local-only")
    }

    runSuite("Bluetooth route contract - rapid route changes keep only the newest dictation recovery") {
        var state = ParakeetRecoveryState()
        let staleGeneration = state.beginConfigChange()
        let currentGeneration = state.beginConfigChange()

        assertFalse(state.finishRecovery(success: true, generation: staleGeneration), "stale Bluetooth settle completion must not mark the graph ready")
        assertFalse(state.timeoutRecovery(generation: staleGeneration), "stale Bluetooth timeout must not poison the latest route")
        assertTrue(state.finishRecovery(success: true, generation: currentGeneration), "latest mocked route should own recovery completion")
        assertTrue(state.canStartRecording, "successful latest recovery should unblock dictation starts")
    }

    runSuite("Bluetooth route contract - mocked device changes settle through connect and disconnect") {
        let airPodsInput = bluetoothDevice(1, "Justin's AirPods Pro", inputChannels: 1)
        let airPodsOutput = bluetoothDevice(2, "Justin's AirPods Pro", inputChannels: 0)
        let macBookMic = bluetoothRouteBuiltInDevice(3, "MacBook Pro Microphone")
        let macBookSpeakers = bluetoothRouteBuiltInDevice(4, "MacBook Pro Speakers", inputChannels: 0)
        var recovery = ParakeetRecoveryState()

        func routeShape(for selection: DictationInputDeviceSelection) -> String {
            ParakeetRouteDiagnosticsPolicy.routeShape(
                selectedInputClass: DictationInputDeviceSelectionPolicy.deviceClass(for: selection.selectedInput),
                outputDeviceClass: selection.defaultOutput.map(DictationInputDeviceSelectionPolicy.deviceClass(for:)) ?? "unknown"
            )
        }

        func readiness(
            for selection: DictationInputDeviceSelection,
            outputSampleRate: Double,
            inputSampleRate: Double
        ) -> ParakeetAudioFormatReadiness {
            ParakeetAudioFormatReadinessPolicy.readiness(
                outputSampleRate: outputSampleRate,
                outputChannelCount: 1,
                inputSampleRate: inputSampleRate,
                inputChannelCount: 1,
                selectedInputClass: DictationInputDeviceSelectionPolicy.deviceClass(for: selection.selectedInput),
                outputDeviceClass: selection.defaultOutput.map(DictationInputDeviceSelectionPolicy.deviceClass(for:)) ?? "unknown",
                selectionOverrodeDefault: selection.didOverrideDefault,
                selectionReason: selection.reason
            )
        }

        let baseline = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: macBookMic,
            defaultOutput: macBookSpeakers,
            availableInputs: [macBookMic]
        )
        assertEqual(baseline.reason, .defaultIsSafe, "built-in input/output should be the stable baseline")
        assertEqual(routeShape(for: baseline), "built_in_input_to_built_in_output", "baseline route shape should be queryable")
        assertEqual(
            readiness(for: baseline, outputSampleRate: 48_000, inputSampleRate: 48_000),
            .ready,
            "baseline built-in route should be ready"
        )

        let outputOnlyGeneration = recovery.beginConfigChange()
        let outputOnlyBluetooth = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: macBookMic,
            defaultOutput: airPodsOutput,
            availableInputs: [macBookMic]
        )
        let outputOnlyReadiness = readiness(
            for: outputOnlyBluetooth,
            outputSampleRate: 48_000,
            inputSampleRate: 48_000
        )
        assertEqual(outputOnlyBluetooth.reason, .defaultIsSafe, "output-only Bluetooth should not force an input override")
        assertFalse(outputOnlyBluetooth.didOverrideDefault, "built-in mic should stay selected when only Bluetooth output changes")
        assertEqual(routeShape(for: outputOnlyBluetooth), "built_in_input_to_bluetooth_output", "output-only Bluetooth route should stay visible")
        assertEqual(outputOnlyReadiness, .ready, "output-only Bluetooth at a settled 48k route should be ready")
        assertEqual(ParakeetDeviceRecoveryReadinessPolicy.action(for: outputOnlyReadiness), .finishRecovery, "ready output-only route should finish recovery")
        assertTrue(recovery.finishRecovery(success: true, generation: outputOnlyGeneration), "output-only route connect should settle the current generation")

        let headsetConnectGeneration = recovery.beginConfigChange()
        let headsetConnect = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: airPodsInput,
            defaultOutput: airPodsOutput,
            availableInputs: [airPodsInput, macBookMic]
        )
        let lowRateReadiness = readiness(
            for: headsetConnect,
            outputSampleRate: 24_000,
            inputSampleRate: 48_000
        )
        assertEqual(headsetConnect.selectedInput, macBookMic, "Bluetooth headset connect should prefer the built-in mic")
        assertEqual(headsetConnect.reason, .preferredBuiltInForBluetoothHeadset, "built-in override should stay explicit")
        assertEqual(lowRateReadiness, .routeNotSettled, "low-rate Bluetooth output should wait before dictation starts")
        assertEqual(ParakeetDeviceRecoveryReadinessPolicy.action(for: lowRateReadiness), .keepWaiting, "unsettled mocked route should keep recovery active")
        assertFalse(recovery.canStartRecording, "dictation should stay blocked while the mocked connect route is settling")

        let settledReadiness = readiness(
            for: headsetConnect,
            outputSampleRate: 48_000,
            inputSampleRate: 48_000
        )
        assertEqual(settledReadiness, .ready, "same connected route should become ready after the output sample rate settles")
        assertEqual(ParakeetDeviceRecoveryReadinessPolicy.action(for: settledReadiness), .finishRecovery, "settled route should finish recovery")
        assertTrue(recovery.finishRecovery(success: true, generation: headsetConnectGeneration), "settled headset connect should own the current generation")
        assertTrue(recovery.canStartRecording, "dictation should start after the mocked connect route settles")

        let disconnectGeneration = recovery.beginConfigChange()
        let disconnected = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: macBookMic,
            defaultOutput: macBookSpeakers,
            availableInputs: [macBookMic]
        )
        let disconnectReadiness = readiness(
            for: disconnected,
            outputSampleRate: 48_000,
            inputSampleRate: 48_000
        )
        assertEqual(disconnected.reason, .defaultIsSafe, "Bluetooth disconnect should return to the safe built-in route")
        assertEqual(routeShape(for: disconnected), "built_in_input_to_built_in_output", "disconnect should expose the built-in route shape")
        assertEqual(disconnectReadiness, .ready, "disconnect back to built-in should be ready")
        assertTrue(recovery.finishRecovery(success: true, generation: disconnectGeneration), "disconnect should settle the newest generation")
        assertTrue(recovery.canStartRecording, "dictation should be startable after Bluetooth disconnect settles")
    }

    runSuite("Bluetooth route contract - tap buffer sample rate pins dictation timeline") {
        let effectiveSampleRate = ParakeetTapSampleRatePolicy.effectiveSampleRate(
            bufferSampleRate: 48_000,
            hardwareSampleRate: 24_000
        )
        var timeline = RecordedAudioTimeline()

        timeline.append(Array(repeating: 0.1, count: 4_800), sampleRate: effectiveSampleRate)
        timeline.append(Array(repeating: 0.2, count: 4_800), sampleRate: effectiveSampleRate)

        assertEqual(effectiveSampleRate, 48_000, "AirPods HFP hardware metadata must not replace the tap-buffer rate")
        assertEqual(timeline.segments.count, 1, "same tap-buffer rate should keep the recovered dictation timeline stable")
        assertEqual(timeline.segments.first?.sampleRate, 48_000, "recorded timeline should preserve the pinned tap rate")
    }

    runSuite("Bluetooth route contract - engine tap and final inference keep sample-rate pinning") {
        let source = readSourceFixture("Sources/Speech/ParakeetEngine.swift")
        guard let tapStart = source.range(of: "private func installTapAndStartEngine"),
              let tapEnd = source.range(of: "func removeRecordingTap", range: tapStart.upperBound..<source.endIndex),
              let inferenceStart = source.range(of: "private func drainRecordedSamplesForInference"),
              let inferenceEnd = source.range(of: "// MARK: - Transcription", range: inferenceStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find dictation tap and final inference wiring")
            return
        }
        let tapBody = String(source[tapStart.lowerBound..<tapEnd.lowerBound])
        let inferenceBody = String(source[inferenceStart.lowerBound..<inferenceEnd.lowerBound])

        guard let installTap = tapBody.range(of: "inputNode.installTap(onBus: 0, bufferSize: TranscriptedConstants.audioTapBufferSize, format: nil)"),
              let bufferFormat = tapBody.range(of: "Self.audioFormatSummary(buffer.format)"),
              let effectiveRate = tapBody.range(of: "ParakeetTapSampleRatePolicy.effectiveSampleRate"),
              let nativeRate = tapBody.range(of: "self.nativeSampleRate = effectiveSampleRate"),
              let inputRate = inferenceBody.range(of: "let inputRate = safeNativeSampleRate()"),
              let resampleRate = inferenceBody.range(of: "from: inputRate") else {
            assertTrue(false, "dictation tap should use the delivered buffer format for sample-rate bookkeeping")
            return
        }

        assertTrue(installTap.lowerBound < bufferFormat.lowerBound, "tap should be installed with CoreAudio's delivered buffer format")
        assertTrue(bufferFormat.lowerBound < effectiveRate.lowerBound, "buffer.format should feed the sample-rate policy")
        assertTrue(effectiveRate.lowerBound < nativeRate.lowerBound, "nativeSampleRate should track the effective tap-buffer rate")
        assertTrue(inputRate.lowerBound < resampleRate.lowerBound, "final inference should resample from the pinned tap-buffer rate")
    }

    runSuite("Bluetooth route contract - input override happens before format reads") {
        let source = readSourceFixture("Sources/Speech/ParakeetEngine.swift")
        guard let snapshotStart = source.range(of: "func audioInputSnapshot"),
              let snapshotEnd = source.range(of: "private func installTapAndStartEngine", range: snapshotStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find dictation audioInputSnapshot")
            return
        }
        let snapshotBody = String(source[snapshotStart.lowerBound..<snapshotEnd.lowerBound])

        guard let loadSelection = snapshotBody.range(of: "let selection = try await Self.systemInputWorkCoordinator.run"),
              let serializedSelectionLookup = snapshotBody.range(of: "Self.loadDictationInputDeviceSelection"),
              let avoidDefaultRead = snapshotBody.range(of: "Avoid touching the current default input before the override is applied."),
              let serializedSystemInputOverride = snapshotBody.range(of: "systemInputOverrideError = try await Self.systemInputWorkCoordinator.run"),
              let systemInputOverride = snapshotBody.range(of: "Self.applyPreferredSystemInputDevice(for: selection)"),
              let applyOverride = snapshotBody.range(of: "Self.applyPreferredDictationInputDevice(selection, to: inputNode)"),
              let outputFormatRead = snapshotBody.range(of: "inputNode.outputFormat(forBus: 0)"),
              let inputFormatRead = snapshotBody.range(of: "inputNode.inputFormat(forBus: 0)") else {
            assertTrue(false, "audioInputSnapshot should keep the AirPods override-before-read contract")
            return
        }

        assertTrue(loadSelection.lowerBound < serializedSelectionLookup.lowerBound, "selection should be serialized with system-input restore work")
        assertTrue(serializedSelectionLookup.lowerBound < avoidDefaultRead.lowerBound, "selection should be loaded before the no-default-read guard")
        assertTrue(avoidDefaultRead.lowerBound < serializedSystemInputOverride.lowerBound, "override guard should be set before changing system input")
        assertTrue(serializedSystemInputOverride.lowerBound < systemInputOverride.lowerBound, "system input apply should use the shared serial coordinator")
        assertTrue(systemInputOverride.lowerBound < applyOverride.lowerBound, "system input should move off AirPods before touching the input node")
        assertTrue(applyOverride.lowerBound < outputFormatRead.lowerBound, "forced input override should happen before output format reads")
        assertTrue(applyOverride.lowerBound < inputFormatRead.lowerBound, "forced input override should happen before hardware input format reads")
    }

    runSuite("Bluetooth route contract - system input override restores after recording") {
        let source = readSourceFixture("Sources/Speech/ParakeetEngine.swift")
        guard let snapshotStart = source.range(of: "func audioInputSnapshot"),
              let snapshotEnd = source.range(of: "private func installTapAndStartEngine", range: snapshotStart.upperBound..<source.endIndex),
              let startStart = source.range(of: "func startRecording(isRecoveryAttempt: Bool = false) async -> Bool"),
              let startEnd = source.range(of: "private func extractMonoSamples", range: startStart.upperBound..<source.endIndex),
              let cleanupStart = source.range(of: "// MARK: - Cleanup"),
              let cleanupEnd = source.range(of: "deinit", range: cleanupStart.upperBound..<source.endIndex),
              let stopStart = source.range(of: "func stopRecording() async"),
              let stopEnd = source.range(of: "// MARK: - Recorded Audio Buffering", range: stopStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find dictation audioInputSnapshot and stopRecording")
            return
        }
        let snapshotBody = String(source[snapshotStart.lowerBound..<snapshotEnd.lowerBound])
        let startBody = String(source[startStart.lowerBound..<startEnd.lowerBound])
        let cleanupBody = String(source[cleanupStart.lowerBound..<cleanupEnd.lowerBound])
        let stopBody = String(source[stopStart.lowerBound..<stopEnd.lowerBound])

        assertTrue(
            snapshotBody.contains("pendingSystemInputRestore.replace(")
                && snapshotBody.contains("ownedBy: systemInputOverrideOwner"),
            "start_recording should remember the prior system input under the exact audio-graph owner"
        )
        assertTrue(
            snapshotBody.contains("operation: \"\\(operation)_system_input_stale_recovery\""),
            "superseded recovery snapshots should restore the temporary system input before throwing cancellation"
        )
        assertTrue(
            snapshotBody.contains("func restoreSystemInputAfterOwnershipLoss(stage: String) async")
                && snapshotBody.contains("let systemInputRestoreTarget = pendingSystemInputRestore.take(")
                && snapshotBody.contains("ownedBy: systemInputOverrideOwner")
                && snapshotBody.contains("await restoreSystemInputIfStillTemporary("),
            "stale cleanup should restore only after consuming its matching system-input owner lease"
        )
        for stage in ["override", "snapshot_failure", "snapshot_success"] {
            assertTrue(
                snapshotBody.contains("await restoreSystemInputAfterOwnershipLoss(stage: \"\(stage)\")"),
                "\(stage) ownership loss must restore the route before throwing"
            )
        }
        assertTrue(
            startBody.contains("func failAudioStart() async -> Bool"),
            "failed starts should share one bounded-retry path"
        )
        assertFalse(
            startBody.contains("restorePendingSystemInputAfterRecording"),
            "retryable start failures should keep the temporary built-in input stable instead of restoring and reapplying it"
        )
        assertTrue(
            stopBody.contains("operation: \"stop_recording\"")
                && stopBody.contains("ownedBy: pendingRestoreOwner"),
            "normal stop should restore the prior system input only for its captured owner"
        )
        assertTrue(
            stopBody.contains("operation: \"stop_recording_idle\"")
                && stopBody.contains("ownedBy: pendingRestoreOwner"),
            "canceled or interrupted start paths should restore only their captured temporary input"
        )
        assertTrue(
            cleanupBody.contains("schedulePendingSystemInputRestore(ownedBy: pendingRestoreOwner, operation: \"cancel\")"),
            "explicit cancellation should restore its owned temporary input even though cancel() is synchronous"
        )
        assertTrue(
            cleanupBody.contains("schedulePendingSystemInputRestore(ownedBy: pendingRestoreOwner, operation: \"cleanup\")"),
            "quit cleanup should restore its owned temporary input even though cleanup() is synchronous"
        )
        let systemInputSource = readSourceFixture("Sources/Speech/ParakeetSystemInputCoordination.swift")
        assertTrue(
            systemInputSource.contains("restoreError = try await Self.systemInputWorkCoordinator.run")
                && systemInputSource.contains("Self.systemInputWorkCoordinator.schedule(")
                && systemInputSource.contains("timeoutNanoseconds: TranscriptedConstants.systemInputOperationTimeout")
                && systemInputSource.contains("reconcileSystemInputAfterLateCompletion"),
            "awaited and scheduled restores should use bounded replaceable work with late-write reconciliation"
        )
        assertTrue(
            cleanupBody.contains("operation: \"abandon_blocked_recording_start\"")
                && cleanupBody.contains("ownedBy: pendingRestoreOwner"),
            "blocked-start abandonment should restore only the temporary input owned by that start"
        )
        assertTrue(
            cleanupBody.contains("operation: \"reset_after_failed_recording_start\"")
                && cleanupBody.contains("ownedBy: pendingRestoreOwner"),
            "final failed-start cleanup should restore its owned temporary input after retries are exhausted"
        )
        assertTrue(
            source.contains("DictationPersistentInputPreferences.setTemporaryRecoveryMarker(recoveryMarker)"),
            "temporary system-input ownership must survive a crash during dictation"
        )
        assertTrue(
            source.contains("DictationPersistentInputPreferences.setTemporaryRecoveryMarker(nil)"),
            "successful restoration must clear the temporary crash marker"
        )
    }

    runSuite("Bluetooth route contract - active startup owns its config changes") {
        // Device-change detection/recovery lives in ParakeetDeviceRecovery.swift
        // (codebase audit 2026-07-08 wave 2).
        let source = readSourceFixture("Sources/Speech/ParakeetDeviceRecovery.swift")
        guard let handlerStart = source.range(of: "private func handleAudioConfigChange("),
              let handlerEnd = source.range(of: "private func recordStableRouteChangeAnalytics", range: handlerStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find the audio config-change handler")
            return
        }
        let handlerBody = String(source[handlerStart.lowerBound..<handlerEnd.lowerBound])
        guard let startupGuard = handlerBody.range(of: "if audioStartInProgress"),
              let generationBump = handlerBody.range(of: "audioGraphGeneration += 1") else {
            assertTrue(false, "startup config changes should be ignored before recovery mutates the graph")
            return
        }
        assertTrue(
            startupGuard.lowerBound < generationBump.lowerBound,
            "recording startup should own route validation before config recovery can rebuild the graph"
        )
    }

    runSuite("Bluetooth route contract - route telemetry commits only after debounce without gating recovery") {
        let source = readSourceFixture("Sources/Speech/ParakeetDeviceRecovery.swift")
        guard let handlerStart = source.range(of: "private func handleAudioConfigChange("),
              let handlerEnd = source.range(of: "private func recordStableRouteChangeAnalytics", range: handlerStart.upperBound..<source.endIndex),
              let reporterEnd = source.range(of: "// MARK: - Recovery execution", range: handlerEnd.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find the route debounce and reporter bodies")
            return
        }
        let handler = String(source[handlerStart.lowerBound..<handlerEnd.lowerBound])
        let reporter = String(source[handlerEnd.lowerBound..<reporterEnd.lowerBound])

        guard let debounceSleep = handler.range(of: "Task.sleep(nanoseconds: TranscriptedConstants.audioConfigChangeDebounceDelay)"),
              let stableReport = handler.range(of: "recordStableRouteChangeAnalytics("),
              let recovery = handler.range(of: "self.attemptDeviceRecovery()") else {
            assertTrue(false, "debounced route handling should report and then continue recovery")
            return
        }

        assertTrue(debounceSleep.lowerBound < stableReport.lowerBound, "route analytics must wait until the config-change burst settles")
        assertTrue(stableReport.lowerBound < recovery.lowerBound, "the stable-route lookup should be scheduled without gating the unconditional recovery call")
        assertTrue(reporter.contains("commitPendingRoute()"), "analytics should require a genuinely new categorical route")
        assertTrue(reporter.contains("dictation_audio_route_changed"), "a stable transition should keep the existing product event")
        assertFalse(handler.contains("AnalyticsReporter.track("), "raw config notifications must not emit analytics before debounce")
    }

    runSuite("Bluetooth route contract - stable recovery echoes do not retire another engine") {
        let source = readSourceFixture("Sources/Speech/ParakeetDeviceRecovery.swift")
        guard let strategyStart = source.range(of: "switch graphStrategy"),
              let reuseCase = source.range(of: "case .reuseCurrentGraph:", range: strategyStart.upperBound..<source.endIndex),
              let rebuildCase = source.range(of: "case .rebuildGraph:", range: reuseCase.upperBound..<source.endIndex),
              let strategyEnd = source.range(
                of: "// Cancel any in-flight recovery",
                range: rebuildCase.upperBound..<source.endIndex
              ) else {
            assertTrue(false, "test should find the config-change graph strategy branches")
            return
        }

        let reuseBody = String(source[reuseCase.upperBound..<rebuildCase.lowerBound])
        let rebuildBody = String(source[rebuildCase.upperBound..<strategyEnd.lowerBound])
        assertFalse(
            reuseBody.contains("rebuildAudioEngine"),
            "a stable same-route engine echo must keep the current graph instead of creating another retirement echo"
        )
        assertTrue(
            rebuildBody.contains("rebuildAudioEngine(reason: \"configuration_change\")"),
            "real or unproven route changes must keep the full graph replacement path"
        )
    }

    runSuite("Bluetooth route contract - persistent input follows reconnects and restores on shutdown") {
        let source = readSourceFixture("Sources/Speech/PersistentDictationInputController.swift")
        guard let start = source.range(of: "func start()"),
              let stop = source.range(of: "func stopAndRestore()"),
              let install = source.range(of: "private func installDefaultInputListener()"),
              let installDeviceList = source.range(of: "private func installDeviceListListener()"),
              let remove = source.range(of: "private func removeDefaultInputListener()"),
              let removeDeviceList = source.range(of: "private func removeDeviceListListener()"),
              let restore = source.range(of: "private func restoreIfStillOwned") else {
            assertTrue(false, "persistent input controller should expose bounded lifecycle seams")
            return
        }

        assertTrue(start.lowerBound < install.lowerBound, "controller startup should install its reconnect listener")
        assertTrue(install.lowerBound < remove.lowerBound, "listener teardown should remain paired with installation")
        assertTrue(installDeviceList.lowerBound < removeDeviceList.lowerBound, "USB device-list monitoring should have paired teardown")
        assertTrue(stop.lowerBound < restore.lowerBound, "shutdown should route through ownership-safe restoration")
        assertTrue(
            source.contains("preferenceEnabled: DictationPersistentInputPreferences.isEnabled()")
                && source.contains("hasRecoveryMarker: DictationPersistentInputPreferences.recoveryMarker() != nil")
                && source.contains("shouldRecoverInheritedTemporaryOverride: shouldRecoverInheritedTemporaryOverride"),
            "device changes must retry inherited crash restoration without treating current-session overrides as inherited"
        )
        assertTrue(
            source.contains("guard currentInput == activeOverride.selectedInput else"),
            "restoration must not overwrite a microphone the user changed outside Transcripted"
        )
        assertTrue(
            source.contains("mSelector: kAudioHardwarePropertyDevices"),
            "the saved preferred microphone should be reconsidered when USB devices reconnect"
        )
        assertTrue(
            source.contains("scheduleTopologyRefresh(defaultInputChanged: true)")
                && source.contains("scheduleTopologyRefresh(deviceListChanged: true)"),
            "default-input changes must remain distinguishable from device reconnects"
        )
        assertTrue(
            source.contains("dictation_persistent_input_external_selection_preserved")
                && source.contains("runtimeOwnershipRelinquished = true"),
            "an external microphone selection must relinquish persistent runtime ownership"
        )
    }

    runSuite("Bluetooth route contract - preference changes wait for active dictation") {
        let source = readSourceFixture("Sources/Speech/PersistentDictationInputController.swift")
        guard let observerStart = source.range(of: "forName: .dictationPersistentInputPreferenceChanged"),
              let observerEnd = source.range(of: "installDefaultInputListener()", range: observerStart.upperBound..<source.endIndex),
              let schedulerStart = source.range(of: "private func scheduleTopologyRefresh("),
              let schedulerEnd = source.range(of: "private func reconcileCurrentPreference(", range: schedulerStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find the preference observer and deferred refresh scheduler")
            return
        }

        let observerBody = String(source[observerStart.lowerBound..<observerEnd.lowerBound])
        let schedulerBody = String(source[schedulerStart.lowerBound..<schedulerEnd.lowerBound])
        assertTrue(
            observerBody.contains("scheduleTopologyRefresh(preferenceChanged: true)"),
            "preference notifications must enter the same deferred maintenance path as route changes"
        )
        assertFalse(
            observerBody.contains("reconcileCurrentPreference()"),
            "preference notifications must never reconcile the system input directly during dictation"
        )
        guard let deferCheck = schedulerBody.range(of: "DictationPersistentInputRefreshPolicy.shouldDefer("),
              let reconcile = schedulerBody.range(of: "self.reconcileCurrentPreference(") else {
            assertTrue(false, "deferred refresh should wait for dictation before reconciling")
            return
        }
        assertTrue(
            deferCheck.lowerBound < reconcile.lowerBound,
            "system input reconciliation must happen only after the active-dictation wait"
        )
        assertTrue(
            schedulerBody.contains("topologyRefreshTask?.cancel()"),
            "repeated preference notifications should coalesce into one post-dictation refresh"
        )
    }

    runSuite("Bluetooth route contract - QA report names mocked proof boundary") {
        let bench = readSourceFixture("scripts/ops/transcripted-qa-bench.sh")
        let benchDoc = readSourceFixture("docs/qa-test-bench.md")
        let dailyDoc = readSourceFixture("docs/audio-reliability-daily-check.md")
        let gates = readSourceFixture(".agents/qa-gates.yml")

        let boundary = "Mocked Bluetooth/AirPods route contracts are automated policy proof, not hardware proof."
        let manualProof = "Real connected AirPods/Bluetooth hardware remains manual proof."

        for content in [bench, benchDoc, dailyDoc, gates] {
            assertTrue(content.contains(boundary), "Bluetooth route docs/report should include the mocked proof boundary")
            assertTrue(content.contains(manualProof), "Bluetooth route docs/report should keep real hardware proof manual")
        }
    }
}

private func bluetoothDevice(
    _ id: UInt32,
    _ name: String,
    inputChannels: UInt32
) -> DictationAudioDevice {
    DictationAudioDevice(
        id: id,
        name: name,
        transport: .bluetooth,
        inputChannelCount: inputChannels
    )
}

private func bluetoothRouteBuiltInDevice(
    _ id: UInt32,
    _ name: String,
    inputChannels: UInt32 = 1
) -> DictationAudioDevice {
    DictationAudioDevice(
        id: id,
        name: name,
        transport: .builtIn,
        inputChannelCount: inputChannels
    )
}

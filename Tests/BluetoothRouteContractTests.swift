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

    runSuite("Bluetooth route contract - engine tap wiring keeps sample-rate pinning") {
        let source = readBluetoothRouteContractFile("Sources/Speech/ParakeetEngine.swift")
        guard let tapStart = source.range(of: "private func installTapAndStartEngine"),
              let tapEnd = source.range(of: "private func removeRecordingTap", range: tapStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find dictation tap wiring")
            return
        }
        let tapBody = String(source[tapStart.lowerBound..<tapEnd.lowerBound])

        guard let installTap = tapBody.range(of: "inputNode.installTap(onBus: 0, bufferSize: TranscriptedConstants.audioTapBufferSize, format: nil)"),
              let bufferFormat = tapBody.range(of: "Self.audioFormatSummary(buffer.format)"),
              let effectiveRate = tapBody.range(of: "ParakeetTapSampleRatePolicy.effectiveSampleRate"),
              let nativeRate = tapBody.range(of: "self.nativeSampleRate = effectiveSampleRate"),
              let resampleRate = tapBody.range(of: "from: effectiveSampleRate") else {
            assertTrue(false, "dictation tap should use the delivered buffer format for sample-rate bookkeeping")
            return
        }

        assertTrue(installTap.lowerBound < bufferFormat.lowerBound, "tap should be installed with CoreAudio's delivered buffer format")
        assertTrue(bufferFormat.lowerBound < effectiveRate.lowerBound, "buffer.format should feed the sample-rate policy")
        assertTrue(effectiveRate.lowerBound < nativeRate.lowerBound, "nativeSampleRate should track the effective tap-buffer rate")
        assertTrue(nativeRate.lowerBound < resampleRate.lowerBound, "downstream resampling should use the pinned tap-buffer rate")
    }

    runSuite("Bluetooth route contract - input override happens before format reads") {
        let source = readBluetoothRouteContractFile("Sources/Speech/ParakeetEngine.swift")
        guard let snapshotStart = source.range(of: "private func audioInputSnapshot"),
              let snapshotEnd = source.range(of: "private func installTapAndStartEngine", range: snapshotStart.upperBound..<source.endIndex) else {
            assertTrue(false, "test should find dictation audioInputSnapshot")
            return
        }
        let snapshotBody = String(source[snapshotStart.lowerBound..<snapshotEnd.lowerBound])

        guard let loadSelection = snapshotBody.range(of: "let selection = Self.loadDictationInputDeviceSelection"),
              let avoidDefaultRead = snapshotBody.range(of: "Avoid touching the current default input before the override is applied."),
              let applyOverride = snapshotBody.range(of: "Self.applyPreferredDictationInputDevice(selection, to: inputNode)"),
              let outputFormatRead = snapshotBody.range(of: "inputNode.outputFormat(forBus: 0)"),
              let inputFormatRead = snapshotBody.range(of: "inputNode.inputFormat(forBus: 0)") else {
            assertTrue(false, "audioInputSnapshot should keep the AirPods override-before-read contract")
            return
        }

        assertTrue(loadSelection.lowerBound < avoidDefaultRead.lowerBound, "selection should be loaded before the no-default-read guard")
        assertTrue(avoidDefaultRead.lowerBound < applyOverride.lowerBound, "override guard should be set before touching the input node")
        assertTrue(applyOverride.lowerBound < outputFormatRead.lowerBound, "forced input override should happen before output format reads")
        assertTrue(applyOverride.lowerBound < inputFormatRead.lowerBound, "forced input override should happen before hardware input format reads")
    }

    runSuite("Bluetooth route contract - QA report names mocked proof boundary") {
        let bench = readBluetoothRouteContractFile("scripts/ops/transcripted-qa-bench.sh")
        let benchDoc = readBluetoothRouteContractFile("docs/qa-test-bench.md")
        let dailyDoc = readBluetoothRouteContractFile("docs/audio-reliability-daily-check.md")
        let gates = readBluetoothRouteContractFile(".agents/qa-gates.yml")

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

private func readBluetoothRouteContractFile(_ relativePath: String) -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

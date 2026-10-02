// BluetoothRouteContractTests.swift
//
// AirPods and other Bluetooth routes, checked through inputs and outputs.
//
// Most suites run real decision code over mocked devices: input selection,
// route shape, HFP suspicion, readiness, recovery generations, the tap and
// snapshot steps (through a fake input node), the binding sequence, config-change
// admission and graph reuse, and persistent-input scheduling. These are MOCKED
// route contracts: automated policy proof, not hardware proof. Real connected
// AirPods/Bluetooth hardware still needs manual verification
// (`bash check.sh hardware`).
//
// Two suites still read source as text: a banned-call scan that no Parakeet
// file writes the Mac-wide default input (the snapshot ordering it used to
// pin is a behavior test in ParakeetAudioGraphTests), and TranscriptedApp
// awaiting the persistent input restore on quit, which the fast runner can't
// compile. The persistent controller itself runs against fakes in
// PersistentDictationInputControllerTests. The
// "QA report names mocked proof boundary" suite is a docs/report consistency
// check.

import AVFoundation
import Foundation

func testBluetoothRouteContract() async {
    runSuite("Bluetooth route contract - opt-in built-in mic recommendation stays explicit") {
        let airPodsInput = bluetoothDevice(1, "Justin's AirPods Pro", inputChannels: 1)
        let airPodsOutput = bluetoothDevice(2, "Justin's AirPods Pro", inputChannels: 0)
        let macBookMic = bluetoothRouteBuiltInDevice(3, "MacBook Pro Microphone")

        let selection = DictationInputDeviceSelectionPolicy.selection(
            defaultInput: airPodsInput,
            defaultOutput: airPodsOutput,
            availableInputs: [airPodsInput, macBookMic],
            prefersBuiltInBluetoothInput: true
        )

        assertEqual(selection.selectedInput, macBookMic, "the faster-start opt-in should recommend the local built-in mic when available")
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
            prefersBuiltInBluetoothInput: true,
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

    runSuite("Bluetooth route contract - fully-switched HFP and unsettled reads stay visible") {
        assertTrue(
            ParakeetRouteDiagnosticsPolicy.isLikelyBluetoothHandsFreeProfile(
                inputClass: "bluetooth",
                outputDeviceClass: "bluetooth",
                inputRate: 24_000,
                outputRate: 24_000
            ),
            "a fully-switched HFP route with both legs at speech rates must be marked suspected"
        )
        assertTrue(
            ParakeetRouteDiagnosticsPolicy.isLikelyBluetoothHandsFreeProfile(
                inputClass: "bluetooth",
                outputDeviceClass: "bluetooth",
                inputRate: 0,
                outputRate: 0
            ),
            "unsettled zero-rate reads on a Bluetooth route must be marked suspected"
        )
        assertTrue(
            ParakeetRouteDiagnosticsPolicy.isLikelyBluetoothHandsFreeProfile(
                inputClass: "built_in",
                outputDeviceClass: "bluetooth",
                inputRate: 48_000,
                outputRate: 0
            ),
            "an unreadable Bluetooth output leg during settling must be marked suspected"
        )
        assertFalse(
            ParakeetRouteDiagnosticsPolicy.isLikelyBluetoothHandsFreeProfile(
                inputClass: "built_in",
                outputDeviceClass: "bluetooth",
                inputRate: nil,
                outputRate: nil
            ),
            "unmeasured formats are not evidence of a degraded route"
        )
        assertFalse(
            ParakeetRouteDiagnosticsPolicy.isLikelyBluetoothHandsFreeProfile(
                inputClass: "built_in",
                outputDeviceClass: "built_in",
                inputRate: 0,
                outputRate: 0
            ),
            "non-Bluetooth routes must never be marked HFP-suspected"
        )
        assertTrue(
            ParakeetSampleSignalPolicy.shouldResetStartupAudio(
                sampleCount: 4_800,
                hasNonZeroSignal: false,
                isLikelyBluetoothHandsFreeRoute: ParakeetRouteDiagnosticsPolicy.isLikelyBluetoothHandsFreeProfile(
                    inputClass: "bluetooth",
                    outputDeviceClass: "bluetooth",
                    inputRate: 24_000,
                    outputRate: 24_000
                )
            ),
            "silent callbacks on a fully-switched HFP route must trigger the startup zombie reset"
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

    runSuite("Bluetooth route contract - opt-in mocked device changes settle through connect and disconnect") {
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
            availableInputs: [airPodsInput, macBookMic],
            prefersBuiltInBluetoothInput: true
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

    runSuite("Bluetooth route contract - the dictation tap reads formats only after voice processing is applied") {
        // Default input is AirPods; voice processing is on. VPIO can swap the
        // graph's formats, so the tap must not be sized from a pre-VPIO read.
        let node = FakeDictationTapNode(
            inputFormat: bluetoothRouteFormat(24_000),
            outputFormat: bluetoothRouteFormat(48_000)
        )
        var timings: [String: Int] = [:]
        let format = try? ParakeetDictationTapPreparation.prepare(
            node, voiceProcessingEnabled: true, isCurrent: { true }, stageTimings: &timings
        )

        assertEqual(format?.sampleRate, 48_000, "a VPIO tap uses the processed output format")
        guard let apply = node.events.firstIndex(of: "apply_vp:true"),
              let firstRead = node.events.firstIndex(where: { $0.hasPrefix("read_") }) else {
            assertTrue(false, "the tap step should apply VPIO and read formats; got \(node.events)")
            return
        }
        assertEqual(node.events.first, "remove_tap", "an old tap is cleared before anything else")
        assertTrue(apply < firstRead, "formats are read after VPIO is applied; got \(node.events)")
        assertTrue(timings["audio_tap_remove_ms"] != nil && timings["audio_voice_processing_apply_ms"] != nil, "stage timings stay reported")
    }

    runSuite("Bluetooth route contract - the tap follows the node's actual voice-processing state, not the request") {
        // AirPods HFP hardware at 24 kHz with a stale 48 kHz output bus. VPIO
        // was requested but did not engage, so a raw input tap must use the
        // live input rate; asking for the stale output rate would fail natively.
        let node = FakeDictationTapNode(
            inputFormat: bluetoothRouteFormat(24_000),
            outputFormat: bluetoothRouteFormat(48_000),
            applySucceeds: false
        )
        var timings: [String: Int] = [:]
        let format = try? ParakeetDictationTapPreparation.prepare(
            node, voiceProcessingEnabled: true, isCurrent: { true }, stageTimings: &timings
        )

        assertEqual(format?.sampleRate, 24_000, "a raw input tap uses the live hardware format")
    }

    runSuite("Bluetooth route contract - a failed voice-processing release stops the start before any tap") {
        // Mic sharing asked for VPIO off and the disable failed: shared capture
        // must not continue on a VPIO graph.
        let node = FakeDictationTapNode(
            inputFormat: bluetoothRouteFormat(48_000),
            outputFormat: bluetoothRouteFormat(48_000),
            voiceProcessingActive: true,
            applySucceeds: false
        )
        var timings: [String: Int] = [:]
        var threw = false
        do {
            _ = try ParakeetDictationTapPreparation.prepare(
                node, voiceProcessingEnabled: false, isCurrent: { true }, stageTimings: &timings
            )
        } catch {
            threw = true
        }

        assertTrue(threw, "a failed VPIO release must fail the start")
        assertFalse(node.events.contains { $0.hasPrefix("read_") }, "no tap format is resolved after a failed release")
    }

    runSuite("Bluetooth route contract - a superseded start reads no tap format") {
        let node = FakeDictationTapNode(
            inputFormat: bluetoothRouteFormat(48_000),
            outputFormat: bluetoothRouteFormat(48_000)
        )
        var timings: [String: Int] = [:]
        var cancelled = false
        do {
            _ = try ParakeetDictationTapPreparation.prepare(
                node, voiceProcessingEnabled: false, isCurrent: { false }, stageTimings: &timings
            )
        } catch is CancellationError {
            cancelled = true
        } catch {}

        assertTrue(cancelled, "a start that lost ownership is cancelled")
        assertFalse(node.events.contains { $0.hasPrefix("read_") }, "a cancelled start never touches the live formats")
    }

    runSuite("Bluetooth route contract - an unusable live tap format waits for the route to settle") {
        // Mid-switch AirPods can report a 0 Hz input. That must become the
        // recoverable route-settling failure, not a native installTap crash.
        let node = FakeDictationTapNode(
            inputFormat: bluetoothRouteFormat(0),
            outputFormat: bluetoothRouteFormat(48_000)
        )
        var timings: [String: Int] = [:]
        var reason: ParakeetStartRecordingFailureReason?
        do {
            _ = try ParakeetDictationTapPreparation.prepare(
                node, voiceProcessingEnabled: false, isCurrent: { true }, stageTimings: &timings
            )
        } catch {
            reason = ParakeetAudioFormatReadinessPolicy.startFailureReason(for: error as NSError)
        }

        assertEqual(reason, .audioRouteNotSettled, "an unsettled tap format uses the bounded route-settling recovery")
    }

    runSuite("Bluetooth route contract - final inference converts each segment from its own rate") {
        // The take started at 48 kHz, then AirPods flipped the route and the
        // tap delivered 24 kHz. Each segment must be converted from its own rate.
        var timeline = RecordedAudioTimeline()
        timeline.append(Array(repeating: 0.1, count: 480), sampleRate: 48_000)
        timeline.append(Array(repeating: 0.2, count: 240), sampleRate: 24_000)

        var calls: [(count: Int, rate: Double)] = []
        let samples = RecordedAudioTimeline.speechSamples(from: timeline.segments) { segment, rate in
            calls.append((segment.count, rate))
            return Array(repeating: Float(rate / 1_000), count: 2)
        }

        assertEqual(calls.map(\.rate), [48_000, 24_000], "each segment is resampled from the rate it was captured at")
        assertEqual(calls.map(\.count), [480, 240], "segments are converted whole, in capture order")
        assertEqual(samples, [48, 48, 24, 24], "converted segments are joined in capture order")
    }

    runSuite("Bluetooth route contract - the input override lands before any format read") {
        // AirPods are the macOS default; dictation pins the MacBook mic on its
        // own AUHAL. Reading a format before that bind can pull the headset
        // into call mode and samples the wrong route.
        let stopped = FakeDictationSnapshotGraph(isRunning: false)
        let reading = ParakeetDictationInputSnapshotRead.read(stopped)

        assertEqual(
            stopped.events,
            ["is_running", "release_vp", "apply_input", "read_output", "read_input", "is_running"],
            "a stopped graph unwraps VPIO, binds the mic, then reads formats"
        )
        assertEqual(reading.selectionApplication, "macbook-mic", "the bind result is carried to the snapshot")
        assertEqual(reading.hwFormat.sampleRate, 48_000, "the hardware format comes from the bound mic")

        let running = FakeDictationSnapshotGraph(isRunning: true)
        _ = ParakeetDictationInputSnapshotRead.read(running)
        assertFalse(running.events.contains("release_vp"), "a running graph keeps its voice-processing state")
        guard let apply = running.events.firstIndex(of: "apply_input"),
              let firstRead = running.events.firstIndex(where: { $0.hasPrefix("read_") }) else {
            assertTrue(false, "running graph should bind and read; got \(running.events)")
            return
        }
        assertTrue(apply < firstRead, "the override still precedes every format read on a running graph")
    }

    await runBluetoothBindingSequenceSuites()

    runSuite("Bluetooth route contract - only a verified binding reports the auto-selected mic") {
        let key = "1->3"
        assertFalse(
            DictationInputSelectionReportPolicy.shouldReportAutoSelection(
                bindingVerified: false, didApplyOverride: true, reportKey: key, lastReportKey: nil
            ),
            "an issued route command is not success"
        )
        assertTrue(
            DictationInputSelectionReportPolicy.shouldReportAutoSelection(
                bindingVerified: true, didApplyOverride: true, reportKey: key, lastReportKey: nil
            ),
            "a verified move off the AirPods mic is reported"
        )
        assertFalse(
            DictationInputSelectionReportPolicy.shouldReportAutoSelection(
                bindingVerified: true, didApplyOverride: true, reportKey: key, lastReportKey: key
            ),
            "the same route is reported once"
        )
        assertFalse(
            DictationInputSelectionReportPolicy.shouldReportAutoSelection(
                bindingVerified: true, didApplyOverride: false, reportKey: nil, lastReportKey: nil
            ),
            "no route command, nothing to report"
        )
    }

    runSuite("Bluetooth route contract - a failed selection lookup never reuses the pinned graph") {
        var failure: DictationInputDeviceBindingError?
        do {
            _ = try DictationInputDeviceBindingPolicy.requireSelection(nil)
        } catch let error as DictationInputDeviceBindingError {
            failure = error
        } catch {}
        assertEqual(failure, .selectionUnavailable, "an unknown selection fails closed instead of trusting the last bind")
    }

    runSuite("Bluetooth route contract - active startup owns its config changes") {
        // AirPods connect while dictation is starting: startup is mid-way through
        // moving AUHAL to the MacBook mic. Recovery must not rebuild under it.
        assertFalse(
            ParakeetConfigChangeAdmissionPolicy.admits(
                sharedMeetingMicClaimCurrent: false,
                audioStartInProgress: true,
                audioStopInProgress: false,
                pinnedRecordingActive: false
            ),
            "recording startup owns route validation"
        )
        assertFalse(
            ParakeetConfigChangeAdmissionPolicy.admits(
                sharedMeetingMicClaimCurrent: false,
                audioStartInProgress: false,
                audioStopInProgress: true,
                pinnedRecordingActive: false
            ),
            "a suspended stop must not be restarted by a route change"
        )
        assertFalse(
            ParakeetConfigChangeAdmissionPolicy.admits(
                sharedMeetingMicClaimCurrent: true,
                audioStartInProgress: false,
                audioStopInProgress: false,
                pinnedRecordingActive: false
            ),
            "a borrowed meeting mic belongs to meeting recovery"
        )
        assertFalse(
            ParakeetConfigChangeAdmissionPolicy.admits(
                sharedMeetingMicClaimCurrent: false,
                audioStartInProgress: false,
                audioStopInProgress: false,
                pinnedRecordingActive: true
            ),
            "the pinned recorder follows its own device; rebuilding would bind the default (AirPods) input"
        )
        assertTrue(
            ParakeetConfigChangeAdmissionPolicy.admits(
                sharedMeetingMicClaimCurrent: false,
                audioStartInProgress: false,
                audioStopInProgress: false,
                pinnedRecordingActive: false
            ),
            "with no owner, recovery handles the change"
        )
    }

    runSuite("Bluetooth route contract - a stable route echo keeps the current graph") {
        assertEqual(
            ParakeetConfigChangeGraphPolicy.action(
                strategy: .reuseCurrentGraph, releasedVoiceProcessing: true, forceForMicrophoneSharing: false
            ),
            .reuseCurrentGraph,
            "a same-route echo must not retire another engine"
        )
        assertEqual(
            ParakeetConfigChangeGraphPolicy.action(
                strategy: .rebuildGraph, releasedVoiceProcessing: true, forceForMicrophoneSharing: false
            ),
            .rebuildGraph(requiresFreshGraph: false),
            "a real route change replaces the graph and may reuse a retired one"
        )
        assertEqual(
            ParakeetConfigChangeGraphPolicy.action(
                strategy: .reuseCurrentGraph, releasedVoiceProcessing: false, forceForMicrophoneSharing: false
            ),
            .rebuildGraph(requiresFreshGraph: true),
            "a failed VPIO disarm never falls back to the same graph"
        )
        assertEqual(
            ParakeetConfigChangeGraphPolicy.action(
                strategy: .rebuildGraph, releasedVoiceProcessing: true, forceForMicrophoneSharing: true
            ),
            .rebuildGraph(requiresFreshGraph: true),
            "a call app sharing the mic gets a fresh graph"
        )
    }

    await runBluetoothDebounceSuites()
    await runPersistentInputSchedulerSuites()

    runSuite("Bluetooth route contract - quitting leaves another app's call alone") {
        assertTrue(
            DictationPersistentInputShutdownPolicy.shouldRestoreOnQuit(externalInputActive: false),
            "with no other capture, quitting restores the user's previous mic"
        )
        assertFalse(
            DictationPersistentInputShutdownPolicy.shouldRestoreOnQuit(externalInputActive: true),
            "another app on a call (say over AirPods) keeps its mic"
        )
        assertFalse(
            DictationPersistentInputShutdownPolicy.shouldRestoreOnQuit(externalInputActive: nil),
            "a blocked or unreadable activity check skips the restore and keeps the durable marker"
        )
    }

    runSuite("Bluetooth route contract - restoration never overwrites a mic chosen outside Transcripted") {
        assertTrue(
            DictationPersistentInputRestorePolicy.shouldRestorePrevious(currentInput: UInt32(3), ownedSelectedInput: UInt32(3)),
            "the input Transcripted chose is still active, so the previous one comes back"
        )
        assertFalse(
            DictationPersistentInputRestorePolicy.shouldRestorePrevious(currentInput: UInt32(1), ownedSelectedInput: UInt32(3)),
            "the user switched to AirPods themselves; leave them"
        )
    }

    runSuite("Bluetooth route contract - dictation never writes the Mac-wide default input") {
        // A banned-call check, not an ordering pin. The snapshot's ordering
        // (serialized selection, fail-closed lookup, ignore window armed before
        // the graph read) is a behavior test in ParakeetAudioGraphTests.swift.
        // The only legitimate Mac-wide input writes are
        // PersistentDictationInputController's, through DefaultInputDeviceMonitor.
        let speechFolder = "Sources/Speech"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: repoFixtureURL(speechFolder).path)) ?? [])
            .filter { $0.hasPrefix("Parakeet") && $0.hasSuffix(".swift") }
            .filter { $0 != "ParakeetAudioDeviceLookup.swift" } // declares the CoreAudio setter
            .sorted()
        assertTrue(names.count > 10, "the dictation engine files should be found")
        for name in names {
            let text = readSourceFixture("\(speechFolder)/\(name)")
            assertFalse(text.contains("setDefaultInputDeviceID("), "\(name) must not write the Mac-wide default input")
            assertFalse(text.contains("setDefaultInputDevice("), "\(name) must not write the Mac-wide default input")
        }
    }

    runSuite("Bluetooth route contract - app shutdown waits for persistent input restoration") {
        // Still source text: the quit path lives in TranscriptedApp, which the
        // fast runner can't compile. The controller's listener, relinquish, and
        // shutdown behavior is tested in PersistentDictationInputControllerTests.
        let app = readSourceFixture("Sources/App/TranscriptedApp.swift")
        assertTrue(app.contains("await self.persistentDictationInputController.stopAndRestore()"), "restoration must join asynchronous app shutdown")
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

// MARK: - Async suites

@MainActor
private func runBluetoothBindingSequenceSuites() async {
    // AirPods are the macOS default; dictation issues a bind to the MacBook mic.
    await runSuite("Bluetooth route contract - a failed bind can't publish format readiness") {
        var reports: [DictationInputBindingReport] = []
        var settled = false
        var failure: DictationInputDeviceBindingError?
        do {
            _ = try await DictationInputBindingSequence.settle(
                applicationErrorDescription: "AUHAL refused the device",
                didApplyOverride: false,
                checkCurrent: {},
                report: { reports.append($0) },
                settle: { () async throws -> String in settled = true; return "settled" }
            )
        } catch let error as DictationInputDeviceBindingError {
            failure = error
        } catch {}

        assertEqual(failure, .applicationFailed, "a failed route command uses the bounded route-settling recovery")
        assertEqual(reports, [.issued], "the failure is reported, never success")
        assertFalse(settled, "no settled snapshot is read after a failed command")
    }

    await runSuite("Bluetooth route contract - selection success waits for a verified binding") {
        var log: [String] = []
        let result = try? await DictationInputBindingSequence.settle(
            applicationErrorDescription: nil,
            didApplyOverride: true,
            checkCurrent: {},
            report: { log.append("report:\($0)") },
            settle: { () async throws -> String in
                log.append("settle")
                return "settled"
            }
        )

        assertEqual(result, "settled", "a changed route returns the settled snapshot")
        assertEqual(log, ["report:issued", "settle", "report:verified"], "success is reported only after settling")
    }

    await runSuite("Bluetooth route contract - a binding that never settles reports failure") {
        // AUHAL still reads back the AirPods after the settle window.
        var reports: [DictationInputBindingReport] = []
        var failure: DictationInputDeviceBindingError?
        do {
            _ = try await DictationInputBindingSequence.settle(
                applicationErrorDescription: nil,
                didApplyOverride: true,
                checkCurrent: {},
                report: { reports.append($0) },
                settle: { () async throws -> String in throw DictationInputDeviceBindingError.selectedDeviceNotBound }
            )
        } catch let error as DictationInputDeviceBindingError {
            failure = error
        } catch {}

        assertEqual(failure, .selectedDeviceNotBound, "the mismatch is thrown")
        assertEqual(reports, [.issued, .settleFailed(.selectedDeviceNotBound)], "a delayed mismatch reports failure, not success")
    }

    await runSuite("Bluetooth route contract - an unchanged route keeps the first snapshot") {
        var reports: [DictationInputBindingReport] = []
        var settled = false
        var threw = false
        var result: String? = "unset"
        do {
            result = try await DictationInputBindingSequence.settle(
                applicationErrorDescription: nil,
                didApplyOverride: false,
                checkCurrent: {},
                report: { reports.append($0) },
                settle: { () async throws -> String in settled = true; return "settled" }
            )
        } catch {
            threw = true
        }

        assertFalse(threw, "an unchanged, working route is not a failure")
        assertEqual(result, nil, "no route command means the first snapshot stands")
        assertFalse(settled, "no settle wait without a route command")
        assertEqual(reports, [.issued], "nothing is reported as verified")
    }

    await runSuite("Bluetooth route contract - a superseded settle reports nothing") {
        var reports: [DictationInputBindingReport] = []
        var cancelled = false
        do {
            _ = try await DictationInputBindingSequence.settle(
                applicationErrorDescription: nil,
                didApplyOverride: true,
                checkCurrent: { throw CancellationError() },
                report: { reports.append($0) },
                settle: { () async throws -> String in "settled" }
            )
        } catch is CancellationError {
            cancelled = true
        } catch {}

        assertTrue(cancelled, "a newer recovery or owner cancels the stale settle")
        assertEqual(reports, [.issued], "a stale settle never reports verified")
    }
}

@MainActor
private func runBluetoothDebounceSuites() async {
    await runSuite("Bluetooth route contract - route telemetry never gates recovery") {
        // An AirPods A -> B -> A burst: the route ends where it started, so
        // telemetry has nothing new, but recovery still has to run.
        var events: [String] = []
        await ParakeetConfigChangeDebounce.settle(
            sleep: { events.append("sleep") },
            isCancelled: { false },
            scheduleStableRouteReport: { events.append("schedule_report") },
            attemptRecovery: { events.append("recover") }
        )
        assertEqual(events, ["sleep", "schedule_report", "recover"], "telemetry waits for the debounce and recovery always follows")

        var route = ParakeetRouteTransitionDebounceState()
        let builtIn = ParakeetCategoricalAudioRoute(
            inputDeviceClass: "built_in", outputDeviceClass: "built_in", routeShape: "built_in_input_to_built_in_output"
        )
        let airPods = ParakeetCategoricalAudioRoute(
            inputDeviceClass: "bluetooth", outputDeviceClass: "bluetooth", routeShape: "bluetooth_input_to_bluetooth_output"
        )
        route.seedStableRouteIfNeeded(builtIn)
        route.observe(airPods)
        route.observe(builtIn)
        assertEqual(route.commitPendingRoute(), nil, "a burst that ends on the stable route emits no route event")
        route.observe(airPods)
        assertEqual(route.commitPendingRoute(), airPods, "a settled new route is reported once")
        assertEqual(route.commitPendingRoute(), nil, "and not again")
    }

    await runSuite("Bluetooth route contract - a newer route change replaces the debounced one") {
        var events: [String] = []
        await ParakeetConfigChangeDebounce.settle(
            sleep: { events.append("sleep") },
            isCancelled: { true },
            scheduleStableRouteReport: { events.append("schedule_report") },
            attemptRecovery: { events.append("recover") }
        )
        assertEqual(events, ["sleep"], "a cancelled debounce neither reports nor recovers")
    }
}

@MainActor
private final class PersistentInputSchedulerHarness {
    var monitoring = true
    var preferenceEnabled = true
    var hasRecoveryMarker = false
    var dictationActive = false
    var meetingActive = false
    var externalReadings: [Bool?] = []
    var delays = 0
    var onDelay: ((Int) -> Void)?
    var reconciles: [(defaultInputChanged: Bool, deviceListChanged: Bool, dictationActive: Bool)] = []

    lazy var scheduler = DictationPersistentInputRefreshScheduler(
        isMonitoring: { [unowned self] in self.monitoring },
        preferenceEnabled: { [unowned self] in self.preferenceEnabled },
        hasRecoveryMarker: { [unowned self] in self.hasRecoveryMarker },
        isDictationActive: { [unowned self] in self.dictationActive },
        isMeetingCaptureActive: { [unowned self] in self.meetingActive },
        readExternalInputActivity: { [unowned self] in
            self.externalReadings.isEmpty ? false : self.externalReadings.removeFirst()
        },
        delay: { [unowned self] in
            self.delays += 1
            self.onDelay?(self.delays)
            await Task.yield()
        },
        reconcile: { [unowned self] defaultInputChanged, deviceListChanged in
            self.reconciles.append((defaultInputChanged, deviceListChanged, self.dictationActive))
        }
    )

    func finish() async {
        await scheduler.refreshTask?.value
    }
}

@MainActor
private func runPersistentInputSchedulerSuites() async {
    // The persistent-input preference rewrites the Mac-wide default input
    // (for example moving it off AirPods). That write must never land under a
    // live capture.
    await runSuite("Bluetooth route contract - preference changes wait for active dictation") {
        let harness = PersistentInputSchedulerHarness()
        harness.dictationActive = true
        harness.onDelay = { count in if count >= 3 { harness.dictationActive = false } }
        harness.scheduler.schedule(preferenceChanged: true)
        await harness.finish()

        assertEqual(harness.reconciles.count, 1, "the change is applied once")
        assertEqual(harness.reconciles.first?.dictationActive, false, "only after dictation has finished")
        assertTrue(harness.delays >= 3, "maintenance kept waiting while dictation was live")
    }

    await runSuite("Bluetooth route contract - maintenance waits out meetings and other apps' capture") {
        let meeting = PersistentInputSchedulerHarness()
        meeting.meetingActive = true
        meeting.onDelay = { count in if count >= 2 { meeting.meetingActive = false } }
        meeting.scheduler.schedule(defaultInputChanged: true)
        await meeting.finish()
        assertEqual(meeting.reconciles.count, 1, "a meeting capture defers the write until it ends")
        assertTrue(meeting.delays >= 2, "the write waited for the meeting")

        // Another app on a call, then an unreadable reading, then idle.
        let external = PersistentInputSchedulerHarness()
        external.externalReadings = [true, nil, false]
        external.scheduler.schedule(deviceListChanged: true)
        await external.finish()
        assertEqual(external.reconciles.count, 1, "the write lands once another app is known idle")
        assertTrue(external.externalReadings.isEmpty, "busy and unknown readings both deferred the write")
    }

    await runSuite("Bluetooth route contract - repeated changes coalesce into one refresh") {
        let harness = PersistentInputSchedulerHarness()
        harness.scheduler.schedule(defaultInputChanged: true)
        let first = harness.scheduler.refreshTask
        harness.scheduler.schedule(deviceListChanged: true)
        harness.scheduler.schedule(preferenceChanged: true)
        await first?.value
        await harness.finish()

        assertEqual(harness.reconciles.count, 1, "a burst of notifications reconciles once")
        assertEqual(harness.reconciles.first?.defaultInputChanged, true, "a default-input change is kept")
        assertEqual(harness.reconciles.first?.deviceListChanged, true, "a reconnect is kept separately")
    }

    await runSuite("Bluetooth route contract - stopped maintenance ignores late listener callbacks") {
        let harness = PersistentInputSchedulerHarness()
        harness.monitoring = false
        harness.scheduler.schedule(defaultInputChanged: true)
        await harness.finish()
        assertTrue(harness.scheduler.refreshTask == nil, "nothing is scheduled after shutdown")
        assertEqual(harness.reconciles.count, 0, "and nothing is reconciled")

        let waiting = PersistentInputSchedulerHarness()
        waiting.dictationActive = true
        waiting.onDelay = { count in if count >= 3 { waiting.scheduler.cancel() } }
        waiting.scheduler.schedule(preferenceChanged: true)
        await waiting.finish()
        assertEqual(waiting.reconciles.count, 0, "stopping during a deferred wait drops the write")
    }

    await runSuite("Bluetooth route contract - maintenance runs only when it has work") {
        let idle = PersistentInputSchedulerHarness()
        idle.preferenceEnabled = false
        idle.scheduler.schedule(defaultInputChanged: true)
        await idle.finish()
        assertEqual(idle.reconciles.count, 0, "with the preference off and no marker, route changes are ignored")

        let turnedOff = PersistentInputSchedulerHarness()
        turnedOff.preferenceEnabled = false
        turnedOff.scheduler.schedule(preferenceChanged: true)
        await turnedOff.finish()
        assertEqual(turnedOff.reconciles.count, 1, "turning the preference off still reconciles, so the old mic comes back")

        let crashed = PersistentInputSchedulerHarness()
        crashed.preferenceEnabled = false
        crashed.hasRecoveryMarker = true
        crashed.scheduler.schedule(deviceListChanged: true)
        await crashed.finish()
        assertEqual(crashed.reconciles.count, 1, "a leftover crash marker retries restoration on device changes")
    }
}

// MARK: - Fakes

private func bluetoothRouteFormat(_ sampleRate: Double) -> AVAudioFormat {
    AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!
}

private final class FakeDictationTapNode: ParakeetDictationTapInputNode {
    private(set) var events: [String] = []
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private var voiceProcessing: Bool
    private let applySucceeds: Bool

    init(
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat,
        voiceProcessingActive: Bool = false,
        applySucceeds: Bool = true
    ) {
        input = inputFormat
        output = outputFormat
        voiceProcessing = voiceProcessingActive
        self.applySucceeds = applySucceeds
    }

    func removeInputTap() { events.append("remove_tap") }

    func applyVoiceProcessingPreference(_ enabled: Bool) -> Bool {
        events.append("apply_vp:\(enabled)")
        if applySucceeds { voiceProcessing = enabled }
        return voiceProcessing == enabled
    }

    var liveInputFormat: AVAudioFormat { events.append("read_input"); return input }
    var liveOutputFormat: AVAudioFormat { events.append("read_output"); return output }
    var isVoiceProcessingActive: Bool { events.append("read_vp"); return voiceProcessing }
}

private final class FakeDictationSnapshotGraph: ParakeetDictationInputSnapshotGraph {
    private(set) var events: [String] = []
    private let running: Bool

    init(isRunning: Bool) { running = isRunning }

    var isGraphRunning: Bool { events.append("is_running"); return running }
    func releaseVoiceProcessing() { events.append("release_vp") }
    func applySelectedInputDevice() -> String { events.append("apply_input"); return "macbook-mic" }
    var outputFormatSummary: ParakeetAudioFormatSummary {
        events.append("read_output")
        return ParakeetAudioFormatSummary(sampleRate: 48_000, channelCount: 1)
    }
    var inputFormatSummary: ParakeetAudioFormatSummary {
        events.append("read_input")
        return ParakeetAudioFormatSummary(sampleRate: 48_000, channelCount: 1)
    }
}

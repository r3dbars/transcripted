import Foundation

// AVAudioEngine capture lives in the app target. These contracts pin its
// ownership and ordering seams; live Zoom speech still needs a remote listener.
func testParakeetMicrophoneSharingSourceContract() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let engine = (try? String(contentsOf: root.appendingPathComponent("Sources/Speech/ParakeetEngine.swift"), encoding: .utf8)) ?? ""
    let recovery = (try? String(contentsOf: root.appendingPathComponent("Sources/Speech/ParakeetDeviceRecovery.swift"), encoding: .utf8)) ?? ""

    runSuite("Dictation keeps Zoom on a shared microphone without changing the saved mode") {
        assertTrue(
            engine.contains("requested: MicrophoneProcessingPreferences.isVoiceProcessingEnabled()\n                    && !ZoomMicrophoneSharingMonitor.shared.isZoomRunning"),
            "every normal or recovery start must suppress VPIO while Zoom is open"
        )
        assertFalse(engine.contains("MicrophoneProcessingPreferences.set"), "sharing must not rewrite the user's saved mode")
        assertTrue(engine.contains("ZoomMicrophoneSharingMonitor.shared.refresh()\n            let voiceProcessingDecision"), "explicit start must refresh process presence before choosing VPIO")
        assertTrue(engine.contains("ZoomMicrophoneSharingMonitor.shared.$isZoomRunning"), "Zoom launch must be observed during dictation")
        let committedStart = sharingSourceBlock(engine, from: "        isRecording = true\n        markFormatReadyAndPublish()", to: "        // Watchdog:")
        assertTrue(
            committedStart.contains("Task { @MainActor [weak self] in\n            await self?.shareMicrophoneWithZoomIfNeeded()"),
            "a Zoom launch during suspended engine start must be rechecked after start commits"
        )
    }

    runSuite("Zoom launch recovery only downgrades an owned active VPIO graph") {
        let handler = sharingSourceBlock(engine, from: "    private func shareMicrophoneWithZoomIfNeeded()", to: "    private func resetAudioGraphAfterStartFailure(")
        assertTrue(handler.contains("let usesVoiceProcessing = await runAudioEngineWork"), "VPIO state must be read on the graph queue")
        assertTrue(handler.contains("Self.existingInputNode(on: audioEngine)?.isVoiceProcessingEnabled == true"), "probe must not create an idle input node")
        for gate in ["sharedMeetingMicClaim == nil", "isRecording,", "!audioStartInProgress", "!audioStopInProgress", "!isShuttingDown"] {
            assertEqual(handler.components(separatedBy: gate).count - 1, 2, "\(gate) must gate both sides of the queue suspension")
        }
        let afterProbe = sharingSourceBlock(handler, from: "        guard usesVoiceProcessing,", to: "        // Reuse the owned recovery path")
        assertTrue(afterProbe.contains("ownsAudioEngineQueue(owner)"), "a stale graph probe must not restart the successor")
        assertTrue(handler.contains("await recoverForMicrophoneSharing()"), "downgrade must use the recording-preserving recovery path")
        let forcedRecovery = sharingSourceBlock(recovery, from: "    func recoverForMicrophoneSharing()", to: "    private func handleAudioConfigChange(")
        assertTrue(forcedRecovery.contains("forceForMicrophoneSharing: true"), "sharing downgrade must bypass local continuity success")
        let config = sharingSourceBlock(recovery, from: "    private func handleAudioConfigChange(", to: "    private func invalidateAudioGraphForIdleRouteChange()")
        assertTrue(config.contains("if !forceForMicrophoneSharing, ParakeetConfigChangeContinuityPolicy.shouldProbe("), "our healthy samples cannot suppress a Zoom sharing downgrade")
        assertTrue(config.contains("if !forceForMicrophoneSharing,\n           CFAbsoluteTimeGetCurrent() < ignoreInputSelectionConfigChangesUntil"), "self-generated route suppression cannot postpone Zoom sharing")
        assertTrue(config.contains("preserveCurrentRecordingBuffersForRecovery()"), "speech already captured must survive the downgrade")
        assertTrue(config.contains("if audioStopInProgress"), "sharing must retain the explicit-stop guard")
    }

    runSuite("Stopped and cancelled dictation graphs disarm VPIO without opening an idle microphone") {
        let teardown = sharingSourceBlock(engine, from: "    nonisolated static func safelyRemoveInputTap(", to: "    private func runAudioEngineWork")
        assertFalse(teardown.contains("audioEngine.inputNode"), "teardown must not lazily create an input node")
        assertTrue(teardown.contains("audioEngine.attachedNodes.compactMap { $0 as? AVAudioInputNode }.first"), "teardown must inspect only existing nodes")
        let tapRemoval = sharingSourceBlock(teardown, from: "    nonisolated static func safelyRemoveInputTap(", to: "    private nonisolated static func existingInputNode(")
        guard let stop = tapRemoval.range(of: "audioEngine.stop()"),
              let remove = tapRemoval.range(of: "inputNode?.removeTap(onBus: 0)"),
              let release = tapRemoval.range(of: "releaseStoppedVoiceProcessing(on: audioEngine)") else {
            assertTrue(false, "tap teardown must stop, remove, then disarm VPIO")
            return
        }
        assertTrue(stop.lowerBound < remove.lowerBound && remove.lowerBound < release.lowerBound, "VPIO must be disarmed after stopped input callbacks and tap removal")
        assertTrue(teardown.contains("guard !audioEngine.isRunning else { return false }"), "disarm must reject a running graph")
        assertTrue(teardown.contains("guard let inputNode = existingInputNode(on: audioEngine) else { return true }"), "an untouched graph is already released and must stay untouched")
        let lateStart = sharingSourceBlock(teardown, from: "    private nonisolated static func cleanUpLateAudioStart(", to: "    private func runAudioEngineWork")
        assertTrue(lateStart.contains("safelyRemoveInputTap(on: audioEngine)"), "cancelled and late starts must share VPIO cleanup")
        let idleStop = sharingSourceBlock(engine, from: "    func stopAudioEngine() async", to: "    private func shareMicrophoneWithZoomIfNeeded()")
        assertTrue(idleStop.contains("Self.releaseStoppedVoiceProcessing(on: audioEngine)"), "normal stop, cancel, and idle cleanup must release stopped VPIO")
    }

    runSuite("A failed VPIO disable never becomes shared capture or a retained idle graph") {
        let start = sharingSourceBlock(engine, from: "    private func installTapAndStartEngine(", to: "    func removeRecordingTap(")
        guard let disabledFailure = start.range(of: "guard voiceProcessingEnabled || appliedVoiceProcessing else {"),
              let throwFailure = start.range(of: "throw NSError", range: disabledFailure.upperBound..<start.endIndex),
              let tapInstall = start.range(of: "inputNode.installTap", range: throwFailure.upperBound..<start.endIndex) else {
            assertTrue(false, "failure to disable VPIO must throw before installing a shared capture tap")
            return
        }
        assertTrue(disabledFailure.lowerBound < throwFailure.lowerBound && throwFailure.lowerBound < tapInstall.lowerBound, "shared startup cannot continue with a failed VPIO disable")
        let disposal = sharingSourceBlock(engine, from: "    func discardStoppedVoiceProcessingGraph(", to: "    private func shareMicrophoneWithZoomIfNeeded()")
        assertTrue(disposal.contains("guard ownsAudioEngineQueue(owner), !isRecording else { return nil }"), "failure disposal must own the exact stopped graph")
        assertTrue(disposal.contains("audioEngine = AVAudioEngine()"), "failure disposal must drop the VPIO graph")
        assertFalse(disposal.contains("reserveRetiredAudioEngine"), "failed VPIO must not be retained for delayed graph retirement")
        let stop = sharingSourceBlock(engine, from: "    private func performStopRecording()", to: "    // MARK: - Recorded Audio Buffering")
        // The lifecycle helper name is part of the stop ownership contract.
        let stopBody = stop.isEmpty ? sharingSourceBlock(engine, from: "    func stopRecording() async", to: "    // MARK: - Recorded Audio Buffering") : stop
        guard let idle = stopBody.range(of: "        isRecording = false", options: .backwards),
              let dispose = stopBody.range(of: "discardStoppedVoiceProcessingGraph(ownedBy: stopOwner)") else {
            assertTrue(false, "normal stop must handle a native VPIO disable failure")
            return
        }
        assertTrue(idle.lowerBound < dispose.lowerBound, "normal stop must finish recording state before graph replacement changes ownership")
        let idleCleanup = sharingSourceBlock(engine, from: "    private func releaseIdleAudioHardware(", to: "    private func cancelAudioWatchdogForRecordingStart()")
        assertTrue(idleCleanup.contains("return discardStoppedVoiceProcessingGraph(ownedBy: idleCleanupOwner)"), "cancelled and idle cleanup must drop a failed VPIO graph under its captured owner")
        let rebuild = sharingSourceBlock(engine, from: "    func rebuildAudioEngine(", to: "    func abandonBlockedAudioEngine(")
        assertTrue(rebuild.contains("if !releasedVoiceProcessing {\n            return discardStoppedVoiceProcessingGraph"), "recovery must discard a graph whose native disable failed")
        assertTrue(rebuild.contains("if requiresFreshGraph {\n                interruptRecordingPreservingRecoveredTimeline()\n                return nil"), "fresh-graph recovery must fail closed at the retirement limit")
        assertTrue(recovery.contains("let graphStrategy = forceForMicrophoneSharing ? .rebuildGraph"), "Zoom downgrade must rebuild even when route endpoints stay the same")
        assertTrue(recovery.contains("requiresFreshGraph: forceForMicrophoneSharing || !releasedVoiceProcessing"), "failed disarm must never fall back to reusing the same graph")
    }
}

private func sharingSourceBlock(_ source: String, from start: String, to end: String) -> String {
    guard let beginning = source.range(of: start) else { return "" }
    let ending = source.range(of: end, range: beginning.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
    return String(source[beginning.lowerBound..<ending])
}

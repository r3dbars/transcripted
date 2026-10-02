import Foundation

// AVAudioEngine capture lives in the app target. These contracts pin its
// ownership and ordering seams; live Zoom speech still needs a remote listener.
// The decisions (when VPIO is asked for, when a call app downgrade may run,
// and how it skips suppression and rebuilds) are behavior-tested in
// ParakeetMicrophoneSharingTests.swift. What is left here is wiring and
// AVAudioEngine call order inside ParakeetEngine, which the fast tests can't
// construct.
func testParakeetMicrophoneSharingSourceContract() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let engine = readParakeetEngineSource()
    let recovery = (try? String(contentsOf: root.appendingPathComponent("Sources/Speech/ParakeetDeviceRecovery.swift"), encoding: .utf8)) ?? ""

    runSuite("Dictation rechecks call apps around every start") {
        assertTrue(engine.contains("CallAppMicrophoneSharingMonitor.shared.refresh()\n            let voiceProcessingDecision"), "explicit start must refresh process presence before choosing VPIO")
        assertTrue(engine.contains("CallAppMicrophoneSharingMonitor.shared.$isCallAppRunning"), "a call app launching must be observed during dictation")
        let committedStart = sharingSourceBlock(engine, from: "        isRecording = true\n        markFormatReadyAndPublish()", to: "        // Watchdog:")
        assertTrue(
            committedStart.contains("Task { @MainActor [weak self] in\n            await self?.shareMicrophoneWithCallAppIfNeeded()"),
            "a call app launching during suspended engine start must be rechecked after start commits"
        )
    }

    runSuite("Call app launch recovery only downgrades an owned active VPIO graph") {
        let handler = sharingSourceBlock(engine, from: "    func shareMicrophoneWithCallAppIfNeeded()", to: "    private func microphoneSharingDowngradeIsAllowed()")
        assertTrue(handler.contains("let usesVoiceProcessing = await runAudioEngineWork"), "VPIO state must be read on the graph queue")
        assertTrue(handler.contains("Self.existingInputNode(on: audioEngine)?.isVoiceProcessingEnabled == true"), "probe must not create an idle input node")
        assertEqual(handler.components(separatedBy: "microphoneSharingDowngradeIsAllowed()").count - 1, 2, "the downgrade gate must run on both sides of the queue suspension")
        let afterProbe = sharingSourceBlock(handler, from: "        guard usesVoiceProcessing,", to: "        // Reuse the owned recovery path")
        assertTrue(afterProbe.contains("ownsAudioEngineQueue(owner)"), "a stale graph probe must not restart the successor")
        assertTrue(handler.contains("await recoverForMicrophoneSharing()"), "downgrade must use the recording-preserving recovery path")
        let forcedRecovery = sharingSourceBlock(recovery, from: "    func recoverForMicrophoneSharing()", to: "    private func handleAudioConfigChange(")
        assertTrue(forcedRecovery.contains("forceForMicrophoneSharing: true"), "sharing downgrade must bypass local continuity success")
        let config = sharingSourceBlock(recovery, from: "    private func handleAudioConfigChange(", to: "    private func invalidateAudioGraphForIdleRouteChange()")
        assertTrue(config.contains("observedAt: configChangeObservedAt,"), "notification suppression must classify callback arrival, not delayed handler time")
        assertTrue(config.contains("ignoreWindowUntil: ignoreInputSelectionConfigChangesUntil,"), "notification suppression must retain the bounded restore window")
        assertTrue(config.contains("preserveCurrentRecordingBuffersForRecovery()"), "speech already captured must survive the downgrade")
        assertTrue(config.contains("if audioStopInProgress"), "sharing must retain the explicit-stop guard")
    }

    runSuite("Stopped and cancelled dictation graphs disarm VPIO without opening an idle microphone") {
        let teardown = sharingSourceBlock(engine, from: "    nonisolated static func safelyRemoveInputTap(", to: "    func runAudioEngineWork")
        assertFalse(teardown.contains("audioEngine.inputNode"), "teardown must not lazily create an input node")
        assertTrue(teardown.contains("audioEngine.attachedNodes.compactMap { $0 as? AVAudioInputNode }.first"), "teardown must inspect only existing nodes")
        let tapRemoval = sharingSourceBlock(teardown, from: "    nonisolated static func safelyRemoveInputTap(", to: "    nonisolated static func existingInputNode(")
        guard let stop = tapRemoval.range(of: "audioEngine.stop()"),
              let remove = tapRemoval.range(of: "inputNode?.removeTap(onBus: 0)"),
              let release = tapRemoval.range(of: "releaseStoppedVoiceProcessing(on: audioEngine)") else {
            assertTrue(false, "tap teardown must stop, remove, then disarm VPIO")
            return
        }
        assertTrue(stop.lowerBound < remove.lowerBound && remove.lowerBound < release.lowerBound, "VPIO must be disarmed after stopped input callbacks and tap removal")
        assertTrue(teardown.contains("guard !audioEngine.isRunning else { return false }"), "disarm must reject a running graph")
        assertTrue(teardown.contains("guard let inputNode = existingInputNode(on: audioEngine) else { return true }"), "an untouched graph is already released and must stay untouched")
        let lateStart = sharingSourceBlock(teardown, from: "    nonisolated static func cleanUpLateAudioStart(", to: "    func runAudioEngineWork")
        assertTrue(lateStart.contains("safelyRemoveInputTap(on: audioEngine)"), "cancelled and late starts must share VPIO cleanup")
        let idleStop = sharingSourceBlock(engine, from: "    func stopAudioEngine() async", to: "    func discardStoppedVoiceProcessingGraph(")
        assertTrue(idleStop.contains("Self.releaseStoppedVoiceProcessing(on: audioEngine)"), "normal stop, cancel, and idle cleanup must release stopped VPIO")
    }

    runSuite("A failed VPIO disable never becomes shared capture or a retained idle graph") {
        // "A failed VPIO disable throws before the tap" is now a behavior test:
        // BluetoothRouteContractTests, "a failed voice-processing release stops the start before any tap".
        let disposal = sharingSourceBlock(engine, from: "    func discardStoppedVoiceProcessingGraph(", to: "    func trackAudioEngineRebuildChurn(")
        assertTrue(disposal.contains("guard ownsAudioEngineQueue(owner), !isRecording else { return nil }"), "failure disposal must own the exact stopped graph")
        assertTrue(disposal.contains("audioEngine = AVAudioEngine()"), "failure disposal must drop the VPIO graph")
        assertFalse(disposal.contains("reserveRetiredAudioEngine"), "failed VPIO must not be retained for delayed graph retirement")
        let stop = sharingSourceBlock(engine, from: "    private func performStopRecording()", to: "    private func cancelPendingRecordingRecovery()")
        // The lifecycle helper name is part of the stop ownership contract.
        let stopBody = stop.isEmpty ? sharingSourceBlock(engine, from: "    func stopRecording() async", to: "    private func cancelPendingRecordingRecovery()") : stop
        guard let idle = stopBody.range(of: "        isRecording = false", options: .backwards),
              let dispose = stopBody.range(of: "discardStoppedVoiceProcessingGraph(ownedBy: stopOwner)") else {
            assertTrue(false, "normal stop must handle a native VPIO disable failure")
            return
        }
        assertTrue(idle.lowerBound < dispose.lowerBound, "normal stop must finish recording state before graph replacement changes ownership")
        let idleCleanup = sharingSourceBlock(engine, from: "    func releaseIdleAudioHardware(", to: "\n}\n")
        assertTrue(idleCleanup.contains("return discardStoppedVoiceProcessingGraph(ownedBy: idleCleanupOwner)"), "cancelled and idle cleanup must drop a failed VPIO graph under its captured owner")
        let rebuild = sharingSourceBlock(engine, from: "    func rebuildAudioEngine(", to: "    func abandonBlockedAudioEngine(")
        assertTrue(rebuild.contains("if !releasedVoiceProcessing {\n            return discardStoppedVoiceProcessingGraph"), "recovery must discard a graph whose native disable failed")
        assertTrue(rebuild.contains("if requiresFreshGraph {\n                interruptRecordingPreservingRecoveredTimeline()\n                return nil"), "fresh-graph recovery must fail closed at the retirement limit")
        // "A call app downgrade always rebuilds" and "a failed disarm never
        // reuses the graph" are behavior tests now: ParakeetMicrophoneSharingTests
        // and BluetoothRouteContractTests ("a stable route echo keeps the current graph").
    }
}

private func sharingSourceBlock(_ source: String, from start: String, to end: String) -> String {
    guard let beginning = source.range(of: start) else { return "" }
    let ending = source.range(of: end, range: beginning.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
    return String(source[beginning.lowerBound..<ending])
}

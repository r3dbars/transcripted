import Foundation

// AVAudioEngine capture lives in the app target. These contracts pin the
// start wiring, the route-change arguments, and the native AVAudioEngine call
// order that the fast tests can't construct; live Zoom speech still needs a
// remote listener. The decisions (when VPIO is asked for, when a call app
// downgrade may run, and how it skips suppression and rebuilds) are
// behavior-tested in ParakeetMicrophoneSharingTests.swift. The owned-graph
// downgrade probe, the stop-in-progress guard, buffer preservation, and
// failed-VPIO graph disposal are behavior tests in ParakeetAudioGraphTests.swift.
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

    runSuite("Call app launch recovery forces the recording-preserving route recovery") {
        let handler = sharingSourceBlock(engine, from: "    func shareMicrophoneWithCallAppIfNeeded()", to: "    private func microphoneSharingDowngradeIsAllowed()")
        assertTrue(handler.contains("await recoverForMicrophoneSharing()"), "downgrade must use the recording-preserving recovery path")
        let forcedRecovery = sharingSourceBlock(recovery, from: "    func recoverForMicrophoneSharing()", to: "    private func handleAudioConfigChange(")
        assertTrue(forcedRecovery.contains("forceForMicrophoneSharing: true"), "sharing downgrade must bypass local continuity success")
        let config = sharingSourceBlock(recovery, from: "    private func handleAudioConfigChange(", to: "    private func invalidateAudioGraphForIdleRouteChange()")
        assertTrue(config.contains("observedAt: configChangeObservedAt,"), "notification suppression must classify callback arrival, not delayed handler time")
        assertTrue(config.contains("ignoreWindowUntil: ignoreInputSelectionConfigChangesUntil,"), "notification suppression must retain the bounded restore window")
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
        let driverStop = sharingSourceBlock(engine, from: "    func stop(_ engine: AVAudioEngine) -> Bool", to: "    func reset(_ engine: AVAudioEngine)")
        assertTrue(driverStop.contains("ParakeetEngine.releaseStoppedVoiceProcessing(on: engine)"), "normal stop, cancel, and idle cleanup must release stopped VPIO")
        let driverProbe = sharingSourceBlock(engine, from: "    func usesVoiceProcessing(_ engine: AVAudioEngine) -> Bool", to: "    func retire(")
        assertTrue(driverProbe.contains("ParakeetEngine.existingInputNode(on: engine)?.isVoiceProcessingEnabled == true"), "the call-app probe must not create an idle input node")
    }
}

private func sharingSourceBlock(_ source: String, from start: String, to end: String) -> String {
    guard let beginning = source.range(of: start) else { return "" }
    let ending = source.range(of: end, range: beginning.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
    return String(source[beginning.lowerBound..<ending])
}

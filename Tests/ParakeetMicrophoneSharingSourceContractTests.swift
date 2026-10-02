import Foundation

// AVAudioEngine capture lives in the app target. These contracts pin the
// route-change arguments the fast tests can't construct; live Zoom speech
// still needs a remote listener. The decisions (when VPIO is asked for, when
// a call app downgrade may run, and how it skips suppression and rebuilds)
// are behavior-tested in ParakeetMicrophoneSharingTests.swift. The owned-graph
// downgrade probe, the stop-in-progress guard, buffer preservation,
// failed-VPIO graph disposal, the call-app recheck around every start, and
// the VPIO-disarming teardown order are behavior tests in
// ParakeetAudioGraphTests.swift.
func testParakeetMicrophoneSharingSourceContract() {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let engine = readParakeetEngineSource()
    let recovery = (try? String(contentsOf: root.appendingPathComponent("Sources/Speech/ParakeetDeviceRecovery.swift"), encoding: .utf8)) ?? ""

    runSuite("Call app launch recovery forces the recording-preserving route recovery") {
        let handler = sharingSourceBlock(engine, from: "    func shareMicrophoneWithCallAppIfNeeded()", to: "    private func microphoneSharingDowngradeIsAllowed()")
        assertTrue(handler.contains("await recoverForMicrophoneSharing()"), "downgrade must use the recording-preserving recovery path")
        let forcedRecovery = sharingSourceBlock(recovery, from: "    func recoverForMicrophoneSharing()", to: "    private func handleAudioConfigChange(")
        assertTrue(forcedRecovery.contains("forceForMicrophoneSharing: true"), "sharing downgrade must bypass local continuity success")
        let config = sharingSourceBlock(recovery, from: "    private func handleAudioConfigChange(", to: "    private func invalidateAudioGraphForIdleRouteChange()")
        assertTrue(config.contains("observedAt: configChangeObservedAt,"), "notification suppression must classify callback arrival, not delayed handler time")
        assertTrue(config.contains("ignoreWindowUntil: ignoreInputSelectionConfigChangesUntil,"), "notification suppression must retain the bounded restore window")
    }
}

private func sharingSourceBlock(_ source: String, from start: String, to end: String) -> String {
    guard let beginning = source.range(of: start) else { return "" }
    let ending = source.range(of: end, range: beginning.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
    return String(source[beginning.lowerBound..<ending])
}

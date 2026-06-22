// CameraActivityMonitorTests.swift
// Tests for the pure decision helper of CameraActivityMonitor. The live CMIO
// listener itself is not unit-testable (mirrors MicActivityMonitor); attribution
// from the camera boolean to a provider is tested in MeetingPromptHeuristicsTests
// (cameraCallProvider) and SyntheticMeetingPromptTests (end-to-end de-dupe).

import Foundation

func testCameraActivityMonitor() {
    guard #available(macOS 14.0, *) else { return }

    runSuite("CameraActivityMonitor.isCameraInUse — any running camera device counts as in use") {
        assertTrue(
            CameraActivityMonitor.isCameraInUse(deviceRunningStates: [false, true, false]),
            "one running camera among several devices should report the camera as in use"
        )
    }

    runSuite("CameraActivityMonitor.isCameraInUse — no running device is the inactive edge") {
        assertFalse(
            CameraActivityMonitor.isCameraInUse(deviceRunningStates: [false, false]),
            "no running camera device should report not-in-use"
        )
        assertFalse(
            CameraActivityMonitor.isCameraInUse(deviceRunningStates: []),
            "a machine with no camera devices should report not-in-use"
        )
    }
}

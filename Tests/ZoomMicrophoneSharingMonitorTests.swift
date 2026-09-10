import AppKit
import Combine
import Foundation

@MainActor
func testZoomMicrophoneSharingMonitor() {
    runSuite("Zoom microphone sharing observes both launch orders without opening audio") {
        let center = NotificationCenter()
        var applications = ["us.zoom.xos"]
        let monitor = ZoomMicrophoneSharingMonitor(
            notificationCenter: center,
            runningApplicationBundleIDs: { applications }
        )
        assertTrue(monitor.isZoomRunning, "Zoom already open must suppress VPIO")

        var changes: [Bool] = []
        let subscription = monitor.$isZoomRunning.sink { changes.append($0) }
        applications = []
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        assertFalse(monitor.isZoomRunning, "Next capture can use the saved preference after Zoom quits")
        applications = ["com.apple.Safari"]
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        assertFalse(monitor.isZoomRunning, "Do not remove the WebRTC recovery option")
        applications.append("us.zoom.xos")
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        assertTrue(monitor.isZoomRunning, "Zoom launched during capture must notify owners")
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        assertEqual(changes, [true, false, true], "Unrelated notifications must not restart capture")
        withExtendedLifetime(subscription) {}
    }

    runSuite("Zoom sharing refreshes before capture and does not match lookalike apps") {
        var applications = ["example.us.zoom.xos", "us.zoom.xos.example"]
        let monitor = ZoomMicrophoneSharingMonitor(
            notificationCenter: NotificationCenter(),
            runningApplicationBundleIDs: { applications }
        )
        assertFalse(monitor.isZoomRunning, "Only the Zoom desktop app activates this guard")
        applications = ["us.zoom.xos"]
        monitor.refresh()
        assertTrue(monitor.isZoomRunning, "Pre-start refresh closes a delayed notification window")
    }
}

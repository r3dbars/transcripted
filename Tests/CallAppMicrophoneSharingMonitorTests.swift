import AppKit
import Combine
import Foundation

@MainActor
func testCallAppMicrophoneSharingMonitor() {
    runSuite("Call app microphone sharing observes both launch orders without opening audio") {
        let center = NotificationCenter()
        var applications = ["us.zoom.xos"]
        let monitor = CallAppMicrophoneSharingMonitor(
            notificationCenter: center,
            runningApplicationBundleIDs: { applications }
        )
        assertTrue(monitor.isCallAppRunning, "Zoom already open must suppress VPIO")

        var changes: [Bool] = []
        let subscription = monitor.$isCallAppRunning.sink { changes.append($0) }
        applications = []
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        assertFalse(monitor.isCallAppRunning, "Next capture can use the saved preference after Zoom quits")
        applications = ["com.apple.Safari"]
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        assertFalse(monitor.isCallAppRunning, "Do not remove the WebRTC recovery option")
        applications.append("us.zoom.xos")
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        assertTrue(monitor.isCallAppRunning, "Zoom launched during capture must notify owners")
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        assertEqual(changes, [true, false, true], "Unrelated notifications must not restart capture")
        withExtendedLifetime(subscription) {}
    }

    runSuite("Call app sharing refreshes before capture and does not match lookalike apps") {
        var applications = ["example.us.zoom.xos", "us.zoom.xos.example"]
        let monitor = CallAppMicrophoneSharingMonitor(
            notificationCenter: NotificationCenter(),
            runningApplicationBundleIDs: { applications }
        )
        assertFalse(monitor.isCallAppRunning, "Lookalike bundle ids must not activate this guard")
        applications = ["us.zoom.xos"]
        monitor.refresh()
        assertTrue(monitor.isCallAppRunning, "Pre-start refresh closes a delayed notification window")
    }

    runSuite("Every desktop call app with its own voice processing keeps the mic shared") {
        for bundleID in [
            "us.zoom.xos",
            "com.microsoft.teams",
            "com.microsoft.teams2",
            "com.cisco.webexmeetingsapp",
            "com.webex.meetingmanager",
            "Cisco-Systems.Spark",
            "com.apple.FaceTime",
        ] {
            assertTrue(
                MicrophoneSharingPolicy.requiresSharedMicrophone(runningApplicationBundleIDs: ["com.apple.finder", bundleID]),
                "\(bundleID) must suppress Apple voice processing"
            )
        }
    }

    runSuite("Browsers and chat apps keep Boost Mic available") {
        for bundleID in [
            "com.apple.Safari",
            "org.mozilla.firefox",
            "com.google.Chrome",
            "com.tinyspeck.slackmacgap",
            "com.hnc.Discord",
            "com.microsoft.teams.helper",
            "com.apple.FaceTimeExtra",
        ] {
            assertFalse(
                MicrophoneSharingPolicy.requiresSharedMicrophone(runningApplicationBundleIDs: [bundleID]),
                "\(bundleID) must not suppress the WebRTC recovery option"
            )
        }
    }
}

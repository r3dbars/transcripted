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

    runSuite("A second call app launching is visible while the first is open") {
        let center = NotificationCenter()
        var applications = ["com.microsoft.teams2"]
        let monitor = CallAppMicrophoneSharingMonitor(
            notificationCenter: center,
            runningApplicationBundleIDs: { applications }
        )
        assertEqual(monitor.runningCallAppBundleIDs, ["com.microsoft.teams2"])
        applications.append("us.zoom.xos")
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        assertTrue(monitor.isCallAppRunning)
        assertEqual(
            monitor.runningCallAppBundleIDs,
            ["com.microsoft.teams2", "us.zoom.xos"],
            "Zoom joining an open Teams must still reach a boosted meeting"
        )
    }

    runSuite("Only a call app holding the mic takes Boost away mid-meeting") {
        for bundleID in [
            "us.zoom.xos",
            "us.zoom.CptHost",
            "com.microsoft.teams2",
            "com.microsoft.teams2.helper",
            "com.apple.avconferenced",
            "com.cisco.webexmeetingsapp",
        ] {
            assertTrue(
                MicrophoneSharingPolicy.isCallAppUsingMicrophone(micInputBundleIDs: ["com.google.Chrome.helper", bundleID]),
                "\(bundleID) holding the mic must keep it shared"
            )
        }
        for bundleID in [
            "com.google.Chrome.helper",
            "com.apple.WebKit.GPU",
            "org.mozilla.firefox",
            "com.tinyspeck.slackmacgap.helper",
            "example.us.zoom.xos",
            "com.apple.FaceTimeExtra",
        ] {
            assertFalse(
                MicrophoneSharingPolicy.isCallAppUsingMicrophone(micInputBundleIDs: [bundleID]),
                "\(bundleID) on the mic is a browser or other app, so Boost stays available"
            )
        }
        assertFalse(
            MicrophoneSharingPolicy.isCallAppUsingMicrophone(micInputBundleIDs: []),
            "Teams open but idle must not block Boost"
        )
    }

    runSuite("Every native call app the meeting prompt knows also keeps the mic shared") {
        for provider in MeetingPromptProvider.allCases {
            for bundleID in provider.activeBundleIdentifiers {
                assertTrue(
                    MicrophoneSharingPolicy.callAppBundleIDs.contains(bundleID),
                    "\(bundleID) is a native call app for meeting prompts, so it must also be in the mic sharing list"
                )
            }
        }
    }

    runSuite("Old Zoom names still work for branches written before the rename") {
        let monitor: ZoomMicrophoneSharingMonitor = CallAppMicrophoneSharingMonitor(
            notificationCenter: NotificationCenter(),
            runningApplicationBundleIDs: { ["com.microsoft.teams2"] }
        )
        assertTrue(monitor.isZoomRunning, "The old name reports any call app, same as isCallAppRunning")
    }
}

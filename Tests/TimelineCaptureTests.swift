import AppKit
import CoreGraphics
import Foundation

func testTimelineCapture() {
    runSuite("Timeline capture cadence constants match Dayflow parity") {
        assertEqual(TimelineCaptureCadence.screenshotInterval, 10, "screenshots should tick every 10 seconds")
        assertEqual(TimelineCaptureCadence.permissionProbeInterval, 60, "permission revocation should probe once per minute")
        assertEqual(TimelineCaptureCadence.wakeResumeDelay, 5, "wake resumes should wait 5 seconds")
        assertEqual(TimelineCaptureCadence.unlockResumeDelay, 0.5, "unlock/screensaver resumes should wait 0.5 seconds")
        assertEqual(TimelineCaptureCadence.targetHeightPixels, 1080, "capture target height should stay at 1080 px")
    }

    runSuite("Timeline capture scaling keeps even dimensions and aspect fit") {
        let display = TimelineDisplay(id: 1, pixelWidth: 3024, pixelHeight: 1964)
        let size = TimelineCaptureScaling.targetPixelSize(for: display)

        assertEqual(Int(size.height), 1080, "height should cap at 1080 px")
        assertTrue(Int(size.width).isMultiple(of: 2), "width should be even for JPEG/video-friendly dimensions")
        assertTrue(Int(size.height).isMultiple(of: 2), "height should be even")
        assertEqual(Int(size.width), 1662, "width should preserve display aspect ratio and round to an even value")
    }

    runSuite("Timeline capture scaling does not upscale small displays") {
        let display = TimelineDisplay(id: 2, pixelWidth: 1280, pixelHeight: 720)
        let size = TimelineCaptureScaling.targetPixelSize(for: display)

        assertEqual(Int(size.width), 1280, "small displays should keep native width")
        assertEqual(Int(size.height), 720, "small displays should not upscale to 1080")
    }

    runSuite("ActiveDisplayTracker prefers requested, then active, then first display") {
        let displays = [
            TimelineDisplay(id: 10, pixelWidth: 1000, pixelHeight: 800),
            TimelineDisplay(id: 20, pixelWidth: 1200, pixelHeight: 900),
            TimelineDisplay(id: 30, pixelWidth: 1400, pixelHeight: 1000)
        ]

        assertEqual(
            ActiveDisplayTracker.selectDisplay(from: displays, requestedDisplayID: 30, activeDisplayID: 20)?.id,
            30,
            "requested display should win"
        )
        assertEqual(
            ActiveDisplayTracker.selectDisplay(from: displays, requestedDisplayID: 99, activeDisplayID: 20)?.id,
            20,
            "active display should be used when requested display is unavailable"
        )
        assertEqual(
            ActiveDisplayTracker.selectDisplay(from: displays, requestedDisplayID: nil, activeDisplayID: 99)?.id,
            10,
            "first display should be the fallback"
        )
    }

    runSuite("Timeline capture blocklist trims empty bundle identifiers") {
        let normalized = TimelineCaptureBlocklist.normalizedBundleIdentifiers([
            " com.example.Secret ",
            "",
            "   ",
            "com.example.Visible"
        ])

        assertEqual(normalized, ["com.example.Secret", "com.example.Visible"], "blocklist should be stable and trimmed")
    }

    runSuite("Timeline capture state machine handles permission and resume states") {
        var machine = TimelineCaptureStateMachine()

        assertEqual(machine.state, .idle, "engine should start idle")
        machine.start(permissionGranted: false)
        assertEqual(machine.state, .paused(.permissionDenied), "denied screen recording should pause instead of crash")
        machine.resume(permissionGranted: true)
        assertEqual(machine.state, .starting, "permission recovery should move back through starting")
        machine.markCapturing()
        assertEqual(machine.state, .capturing, "starting should become capturing after timer setup")
        machine.pause(.permissionRevoked)
        assertEqual(machine.state, .paused(.permissionRevoked), "runtime TCC revocation should be represented as a pause reason")
    }

    runSuite("Timeline capture resume delay policy is explicit") {
        assertEqual(
            TimelineCaptureStateMachine.resumeDelay(after: .sleep),
            5,
            "sleep should use the wake resume delay"
        )
        assertEqual(
            TimelineCaptureStateMachine.resumeDelay(after: .screenLock),
            0.5,
            "screen unlock should use the short resume delay"
        )
        assertEqual(
            TimelineCaptureStateMachine.resumeDelay(after: .screensaver),
            0.5,
            "screensaver end should use the short resume delay"
        )
        assertEqual(
            TimelineCaptureStateMachine.resumeDelay(after: .permissionRevoked),
            nil,
            "permission revocation should use the slower probe cadence, not an immediate resume"
        )
        assertEqual(
            TimelineCaptureStateMachine.resumeDelay(after: .userPause),
            nil,
            "user pause should never auto-resume"
        )
    }

    runSuite("Foreground app sampler title selection ignores non-window layers") {
        let app = NSRunningApplication.current
        let pid = app.processIdentifier
        let title = ForegroundAppSampler.windowTitle(for: app, windows: [
            [
                kCGWindowOwnerPID as String: pid,
                kCGWindowLayer as String: 1,
                kCGWindowName as String: "Menu"
            ],
            [
                kCGWindowOwnerPID as String: pid,
                kCGWindowLayer as String: 0,
                kCGWindowName as String: "Editor"
            ]
        ])

        assertEqual(title, "Editor", "sampler should pick the foreground app's normal window title when available")
    }
}

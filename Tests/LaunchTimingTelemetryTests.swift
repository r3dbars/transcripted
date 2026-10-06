import Foundation

func testLaunchTimingTelemetry() {
    let machineClass = ["mac_chip": "m2_pro", "memory_gb_bucket": "16gb"]

    runSuite("Launch timings become rounded PostHog properties") {
        let properties = LaunchTimingTelemetry.properties(
            marks: LaunchTimingTelemetry.Marks(
                statusItemShownMs: 412,
                hotkeysRegisteredMs: 1_236,
                warmupStartedMs: 1_301,
                launchedAtLogin: true
            ),
            dictationWarmupMs: 7_048,
            meetingWarmupMs: 3_994,
            speechModel: "parakeet-tdt-v3",
            machineClass: machineClass
        )
        assertEqual(properties["status_item_ms"], "410", "menu bar icon time rounds to 10 ms")
        assertEqual(properties["hotkeys_ready_ms"], "1240", "shortcut time rounds to 10 ms")
        assertEqual(properties["warmup_start_ms"], "1300", "warmup start rounds to 10 ms")
        assertEqual(properties["dictation_warmup_ms"], "7050", "dictation model time rounds to 10 ms")
        assertEqual(properties["meeting_warmup_ms"], "3990", "meeting model time rounds to 10 ms")
        assertEqual(properties["login_launch"], "true", "a login start is marked")
        assertEqual(properties["stt_model"], "parakeet-tdt-v3", "the warmed model is named")
        assertEqual(properties["mac_chip"], "m2_pro", "machine class rides along")
        assertEqual(properties["memory_gb_bucket"], "16gb", "memory bucket rides along")
    }

    runSuite("Launch timings leave out marks that never happened") {
        let properties = LaunchTimingTelemetry.properties(
            marks: LaunchTimingTelemetry.Marks(),
            dictationWarmupMs: 900,
            meetingWarmupMs: nil,
            speechModel: "parakeet-tdt-v3",
            machineClass: machineClass
        )
        assertEqual(
            Set(properties.keys),
            ["dictation_warmup_ms", "stt_model", "mac_chip", "memory_gb_bucket"],
            "no status item, hotkey, warmup start, meeting or login keys without a value"
        )
    }

    runSuite("Elapsed launch time drops gaps that can't be a real launch") {
        let start = Date(timeIntervalSince1970: 1_000_000)
        assertEqual(
            LaunchTimingTelemetry.elapsedMilliseconds(from: start, to: start.addingTimeInterval(2.5004)),
            2_500,
            "a normal gap is whole milliseconds"
        )
        assertEqual(LaunchTimingTelemetry.elapsedMilliseconds(from: start, to: start), 0, "zero gap is kept")
        assertEqual(
            LaunchTimingTelemetry.elapsedMilliseconds(from: start, to: start.addingTimeInterval(-1)),
            nil,
            "a clock that moved backwards is dropped"
        )
        assertEqual(
            LaunchTimingTelemetry.elapsedMilliseconds(from: start, to: start.addingTimeInterval(601)),
            nil,
            "over ten minutes is not a launch timing"
        )
        assertEqual(
            LaunchTimingTelemetry.elapsedMilliseconds(from: nil, to: start),
            nil,
            "no process start time means no value"
        )
    }
}

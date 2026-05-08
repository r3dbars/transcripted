import Foundation

func testRuntimeDiagnosticsStore() {
    runSuite("RuntimeDiagnosticsStore builds unclean shutdown context without raw dates") {
        let marker = RuntimeDiagnosticsMarker(
            launchID: "launch-1",
            appVersion: "1.2.3",
            buildVersion: "456",
            osMajor: 26,
            cleanShutdown: false,
            startedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_100),
            lastEvent: "dictation_recording",
            sessionKind: "dictation",
            sessionStage: "recording",
            sessionActive: true
        )

        let context = RuntimeDiagnosticsStore.contextForUncleanShutdown(
            previous: marker,
            now: Date(timeIntervalSince1970: 1_220)
        )

        assertEqual(context["app_version"], "1.2.3", "context should keep app version")
        assertEqual(context["build_version"], "456", "context should keep build version")
        assertEqual(context["heartbeat_age_bucket"], "1_4m", "context should bucket heartbeat age")
        assertEqual(context["last_event"], "dictation_recording", "context should keep last runtime event")
        assertEqual(context["session_active"], "true", "context should keep whether a session was active")
        assertEqual(context["session_duration_bucket"], "1_4m", "context should bucket previous session duration")
        assertEqual(context["session_kind"], "dictation", "context should keep coarse session kind")
        assertEqual(context["session_stage"], "recording", "context should keep coarse session stage")
    }

    runSuite("RuntimeDiagnosticsStore builds current Sentry runtime context") {
        let marker = RuntimeDiagnosticsMarker(
            launchID: "launch-2",
            appVersion: "1.2.4",
            buildVersion: "457",
            osMajor: 26,
            cleanShutdown: false,
            startedAt: Date(timeIntervalSince1970: 2_000),
            updatedAt: Date(timeIntervalSince1970: 2_010),
            lastEvent: "meeting_transcribing",
            sessionKind: "meeting",
            sessionStage: "transcribing",
            sessionActive: true
        )

        let context = RuntimeDiagnosticsStore.contextForCurrentSession(
            marker: marker,
            now: Date(timeIntervalSince1970: 2_040)
        )

        assertEqual(context["app_version"], "1.2.4", "context should keep app version")
        assertEqual(context["build_version"], "457", "context should keep build version")
        assertEqual(context["heartbeat_age_bucket"], "15_59s", "context should bucket heartbeat age")
        assertEqual(context["last_event"], "meeting_transcribing", "context should keep last runtime event")
        assertEqual(context["previous_clean_shutdown"], "false", "context should keep current marker clean flag")
        assertEqual(context["session_active"], "true", "context should keep whether a session is active")
        assertEqual(context["session_duration_bucket"], "lt_1m", "context should bucket current session duration")
        assertEqual(context["session_kind"], "meeting", "context should keep coarse session kind")
        assertEqual(context["session_stage"], "transcribing", "context should keep coarse session stage")
    }

    runSuite("RuntimeDiagnosticsStore current Sentry context stays privacy-safe and stable") {
        let marker = RuntimeDiagnosticsMarker(
            launchID: "launch-secret",
            appVersion: "1.2.5",
            buildVersion: "458",
            osMajor: 26,
            cleanShutdown: true,
            startedAt: Date(timeIntervalSince1970: 3_000),
            updatedAt: Date(timeIntervalSince1970: 3_015),
            lastEvent: "clean_shutdown",
            sessionKind: "none",
            sessionStage: "idle",
            sessionActive: false
        )

        let context = RuntimeDiagnosticsStore.contextForCurrentSession(
            marker: marker,
            now: Date(timeIntervalSince1970: 3_020)
        )

        assertEqual(
            Set(context.keys),
            [
                "app_version",
                "build_version",
                "heartbeat_age_bucket",
                "last_event",
                "os_major",
                "previous_clean_shutdown",
                "session_active",
                "session_duration_bucket",
                "session_kind",
                "session_stage",
            ],
            "current Sentry context should stay limited to coarse runtime keys"
        )
        assertEqual(context["previous_clean_shutdown"], "true", "clean shutdown state should survive as a coarse boolean")
        assertEqual(context["session_duration_bucket"], "lt_1m", "session duration should stay coarse")
        assertNil(context["launch_id"], "launch IDs should not leak into crash context")
        assertNil(context["started_at"], "raw start timestamps should not leak into crash context")
        assertNil(context["updated_at"], "raw heartbeat timestamps should not leak into crash context")
    }

    runSuite("RuntimeDiagnosticsStore buckets session duration without raw timestamps") {
        let now = Date(timeIntervalSince1970: 100_000)

        assertEqual(
            RuntimeDiagnosticsStore.sessionDurationBucket(startedAt: now.addingTimeInterval(-30), now: now),
            "lt_1m",
            "sub-minute sessions should stay coarse"
        )
        assertEqual(
            RuntimeDiagnosticsStore.sessionDurationBucket(startedAt: now.addingTimeInterval(-600), now: now),
            "5_14m",
            "middle durations should use stable buckets"
        )
        assertEqual(
            RuntimeDiagnosticsStore.sessionDurationBucket(startedAt: now.addingTimeInterval(-30_000), now: now),
            "8h_plus",
            "long-running sessions should be bucketed"
        )
    }

    runSuite("RuntimeDiagnosticsStore round-trips marker files") {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RuntimeDiagnosticsStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(RuntimeDiagnosticsStore.markerFileName)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let marker = RuntimeDiagnosticsStore.makeLaunchMarker(
            launchID: "roundtrip",
            appVersion: "1.0",
            buildVersion: "7",
            osMajor: 26,
            now: Date(timeIntervalSince1970: 100)
        )

        RuntimeDiagnosticsStore.save(marker, to: url)
        let loaded = RuntimeDiagnosticsStore.load(from: url)

        assertEqual(loaded, marker, "runtime diagnostics marker should round-trip through JSON")
    }

    runSuite("RuntimeDiagnosticsStore suppresses idle launch-only shutdown markers") {
        let marker = RuntimeDiagnosticsMarker(
            launchID: "launch-only",
            appVersion: "1.2.3",
            buildVersion: "456",
            osMajor: 26,
            cleanShutdown: false,
            startedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_001),
            lastEvent: "app_launched",
            sessionKind: "none",
            sessionStage: "idle",
            sessionActive: false
        )

        let shouldReport = RuntimeDiagnosticsStore.shouldReportUncleanShutdown(
            previous: marker,
            now: Date(timeIntervalSince1970: 1_002)
        )

        assertEqual(shouldReport, false, "idle launch-only markers should not pollute shutdown health")
    }

    runSuite("RuntimeDiagnosticsStore reports unclean shutdowns during active work") {
        let marker = RuntimeDiagnosticsMarker(
            launchID: "active-session",
            appVersion: "1.2.3",
            buildVersion: "456",
            osMajor: 26,
            cleanShutdown: false,
            startedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_100),
            lastEvent: "meeting_recording",
            sessionKind: "meeting",
            sessionStage: "recording",
            sessionActive: true
        )

        let shouldReport = RuntimeDiagnosticsStore.shouldReportUncleanShutdown(
            previous: marker,
            now: Date(timeIntervalSince1970: 1_120)
        )

        assertEqual(shouldReport, true, "active meeting shutdowns should stay visible")
    }
}

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
        assertEqual(context["session_kind"], "dictation", "context should keep coarse session kind")
        assertEqual(context["session_stage"], "recording", "context should keep coarse session stage")
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

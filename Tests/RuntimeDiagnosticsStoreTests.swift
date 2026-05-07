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
        assertEqual(context["session_kind"], "meeting", "context should keep coarse session kind")
        assertEqual(context["session_stage"], "transcribing", "context should keep coarse session stage")
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
}

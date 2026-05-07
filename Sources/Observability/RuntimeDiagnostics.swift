import Foundation

@MainActor
final class RuntimeDiagnostics {
    private let markerURL: URL
    private var marker: RuntimeDiagnosticsMarker?
    private var heartbeatTimer: Timer?

    init(markerURL: URL = RuntimeDiagnosticsStore.defaultMarkerURL()) {
        self.markerURL = markerURL
    }

    func start() {
        guard marker == nil else { return }

        if let previous = RuntimeDiagnosticsStore.load(from: markerURL),
           !previous.cleanShutdown {
            let context = RuntimeDiagnosticsStore.contextForUncleanShutdown(previous: previous)
            EventReporter.shared.capture(
                level: .error,
                engine: "app",
                event: "unclean_shutdown_detected",
                message: "Previous app session did not shut down cleanly",
                context: context
            )
            AnalyticsReporter.track("app_unclean_shutdown_detected", properties: context)
        }

        marker = RuntimeDiagnosticsStore.makeLaunchMarker(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        )
        persist(event: "app_launched")
        startHeartbeatTimer()
    }

    func markCleanShutdown() {
        guard var marker else { return }
        marker.cleanShutdown = true
        marker.updatedAt = Date()
        marker.lastEvent = "clean_shutdown"
        self.marker = marker
        RuntimeDiagnosticsStore.save(marker, to: markerURL)
        CrashReporter.setRuntimeDiagnosticsContext(
            RuntimeDiagnosticsStore.contextForCurrentSession(marker: marker)
        )
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    func recordSession(kind: String, stage: String, active: Bool = true) {
        if marker == nil {
            start()
        }
        guard marker != nil else { return }
        updateMarker { marker in
            marker.sessionKind = kind
            marker.sessionStage = stage
            marker.sessionActive = active
            marker.lastEvent = "\(kind)_\(stage)"
        }
    }

    func clearSession(kind: String, outcome: String) {
        if marker == nil {
            start()
        }
        guard marker != nil else { return }
        updateMarker { marker in
            marker.sessionKind = kind
            marker.sessionStage = outcome
            marker.sessionActive = false
            marker.lastEvent = "\(kind)_\(outcome)"
        }
    }

    func recordStall(
        kind: String,
        stage: String,
        durationSeconds: Double,
        extra: [String: String] = [:]
    ) {
        recordSession(kind: kind, stage: stage, active: true)
        var context = currentAnalyticsContext()
        context["duration_bucket"] = AnalyticsReporter.durationBucket(seconds: durationSeconds)
        context["stall_kind"] = kind
        context["stall_stage"] = stage
        for (key, value) in extra {
            context[key] = value
        }

        EventReporter.shared.capture(
            level: .error,
            engine: "app",
            event: "session_stall_detected",
            message: "Runtime session appears stalled",
            context: context
        )
        AnalyticsReporter.track("app_session_stall_detected", properties: context)
    }

    func currentAnalyticsContext(now: Date = Date()) -> [String: String] {
        guard let marker else {
            return [
                "last_event": "unknown",
                "session_active": "false",
                "session_kind": "none",
                "session_stage": "idle",
            ]
        }

        return [
            "heartbeat_age_bucket": RuntimeDiagnosticsStore.heartbeatAgeBucket(previousUpdate: marker.updatedAt, now: now),
            "last_event": marker.lastEvent,
            "previous_clean_shutdown": "\(marker.cleanShutdown)",
            "session_active": "\(marker.sessionActive)",
            "session_kind": marker.sessionKind,
            "session_stage": marker.sessionStage,
        ]
    }

    private func startHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.persist(event: "heartbeat")
            }
        }
    }

    private func persist(event: String) {
        updateMarker { marker in
            marker.lastEvent = event
        }
    }

    private func updateMarker(_ update: (inout RuntimeDiagnosticsMarker) -> Void) {
        guard var marker else { return }
        update(&marker)
        marker.cleanShutdown = false
        marker.updatedAt = Date()
        self.marker = marker
        RuntimeDiagnosticsStore.save(marker, to: markerURL)
        CrashReporter.setRuntimeDiagnosticsContext(
            RuntimeDiagnosticsStore.contextForCurrentSession(marker: marker)
        )
    }
}

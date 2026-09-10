import Foundation

func testUsageHealthStore() {
    runSuite("Usage health counts lifecycle outcomes and deduplicates paired failures") {
        let name = "UsageHealthTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UsageHealthStore(userDefaults: defaults)
        let now = Date()
        let id = UUID().uuidString
        var properties = ["correlation_id": id, "failure_kind": "mic_unavailable", "failure_stage": "microphone", "app_version": "1.1.59"]
        store.record(event: "meeting_recording_started", properties: properties, now: now)
        store.record(event: "meeting_recording_stopped", properties: properties, durationSeconds: 20 * 60, now: now)
        store.record(event: "meeting_transcript_saved", properties: properties, now: now)
        properties["duration_bucket"] = "10_29s"
        store.record(event: "dictation_completed", properties: properties, now: now)
        store.record(event: "reliability_failure_observed", properties: properties, now: now)
        store.record(event: "meeting_recording_start_failed", properties: properties, now: now)
        store.record(event: "product_friction_observed", properties: properties, now: now)
        properties["capture_quality"] = "fair"
        properties["capture_outcome"] = "complete"
        store.record(event: "meeting_capture_health_snapshot", properties: properties, now: now)
        let summary = store.snapshot(now: now)
        assertEqual(summary.meetings, 1, "saved meetings count once")
        assertEqual(summary.dictations, 1, "completed dictations count once")
        assertEqual(summary.meetingMinutesBucket, "15_59m", "meeting minutes stay bucketed in summary")
        assertEqual(summary.failures.count, 1, "paired analytics and Sentry failure count once")
        assertEqual(summary.qualityCounts["degraded"], 1, "fair capture quality is degraded, not an unknown or hard failure")
        assertEqual(UsageHealthStore(userDefaults: defaults).snapshot(now: now), summary, "metadata survives restart")
    }
    runSuite("Usage health excludes cancellations and ignores content fields") {
        let name = "UsageHealthTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UsageHealthStore(userDefaults: defaults)
        store.record(event: "meeting_capture_health_snapshot", properties: ["capture_outcome": "cancelled", "capture_quality": "excellent", "transcript": "Private content"])
        for i in 0..<5 {
            store.record(event: "dictation_start_failed", properties: ["failure_kind": "failure_\(i)", "transcript": "Private content"])
        }
        assertEqual(store.snapshot().failures.count, 3, "only the last three failures are retained")
        assertEqual(store.snapshot().qualityCounts.count, 0, "discard is not a quality completion")
        let persisted = String(decoding: defaults.data(forKey: UsageHealthStore.storageKey)!, as: UTF8.self)
        assertFalse(persisted.contains("Private content"), "content fields cannot enter the local ledger")
        AnalyticsPreferences.setEnabled(false, userDefaults: defaults)
        store.clear()
        store.record(event: "dictation_completed", properties: [:])
        assertNil(defaults.data(forKey: UsageHealthStore.storageKey), "opt-out erases the ledger and blocks new collection")
    }
}

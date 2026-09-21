import Foundation

func testUsageHealthStore() {
    runSuite("Unverified system capture is not counted as good or denied") {
        let name = "UsageUnverifiedTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UsageHealthStore(userDefaults: defaults)
        store.record(event: "meeting_capture_health_snapshot", properties: [
            "capture_outcome": "system_audio_unverified", "capture_quality": "excellent"
        ])
        assertEqual(store.snapshot().qualityCounts["unknown"], 1, "transport success does not prove audio content")
        assertNil(store.snapshot().qualityCounts["good"], "must not present the recording as fully healthy")
        assertEqual(store.snapshot().failures.count, 0, "unverified is not proof of permission denial or failure")
        store.record(event: "meeting_capture_health_snapshot", properties: [
            "capture_outcome": "system_audio_unverified", "capture_quality": "degraded"
        ])
        assertEqual(store.snapshot().qualityCounts["degraded"], 1, "known transport damage keeps its stronger classification")
    }
    runSuite("Daily rollups handle local midnight, DST, and partial quit snapshots") {
        let name = "UsageDaysTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UsageHealthStore(userDefaults: defaults)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = ISO8601DateFormatter().date(from: "2026-03-08T07:30:00Z")!
        let nextDay = calendar.date(byAdding: .day, value: 1, to: now)!
        store.record(event: "dictation_completed", properties: ["duration_bucket": "10_29s"], now: now, calendar: calendar)
        assertEqual(store.pendingDigests(includeCurrentDay: false, now: now, calendar: calendar).count, 0, "do not send an empty launch-day rollup")
        let complete = store.pendingDigests(includeCurrentDay: false, now: nextDay, calendar: calendar)
        assertEqual(complete.count, 1, "a closed local day rolls over across DST")
        assertEqual(complete.first?.day, "2026-03-08", "report the activity's local day")
        assertEqual(complete.first?.properties["digest_is_partial"], "false", "closed day is complete")
        let partial = store.pendingDigests(includeCurrentDay: true, now: now, calendar: calendar).first!
        assertEqual(partial.properties["digest_is_partial"], "true", "quit snapshots disclose partial coverage")
        assertEqual(partial.id, complete.first?.id, "quit and rollover share a stable insert ID")
        store.markDigestEnqueued(id: partial.id)
        assertEqual(store.pendingDigests(includeCurrentDay: true, now: nextDay, calendar: calendar).count, 0, "at most one digest per reported local day")
        AnalyticsPreferences.setEnabled(false, userDefaults: defaults)
        store.clear()
        AnalyticsPreferences.setEnabled(true, userDefaults: defaults)
        store.record(event: "dictation_completed", properties: [:], now: now, calendar: calendar)
        assertEqual(store.pendingDigests(includeCurrentDay: true, now: now, calendar: calendar).count, 0, "date-only receipt prevents duplicate digest after same-day re-opt-in")
        assertEqual(UsageHealthStore.medianDurationBucket(["lt_10s": 1, "10_29s": 3, "30m_plus": 1]), "10_29s", "median uses ordered duration bins")
    }
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
    runSuite("Unexpected no-audio stop records one failure and a failed quality outcome") {
        let name = "UsageUnexpectedStopTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UsageHealthStore(userDefaults: defaults)
        let properties = ["correlation_id": UUID().uuidString, "failure_kind": "no_audio", "failure_stage": "capture_stop", "capture_outcome": "no_audio"]
        store.record(event: "meeting_capture_stopped_under_controller", properties: properties)
        store.record(event: "reliability_failure_observed", properties: properties)
        store.record(event: "meeting_capture_health_snapshot", properties: properties)
        assertEqual(store.snapshot().failures.map(\.kind), ["no_audio"], "terminal and canonical failure are deduplicated")
        assertEqual(store.snapshot().qualityCounts["failed"], 1, "health records the failed capture once")
        let digest = store.pendingDigests(includeCurrentDay: true).first!
        assertEqual(digest.aggregates["failures_by_kind"]?["no_audio"], "1", "digest includes the terminal failure")
        assertNotNil(SentryEventPolicy.policy(forEngine: "meeting", event: "meeting_capture_stopped_under_controller"), "unexpected stop remains a hard Sentry failure")
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

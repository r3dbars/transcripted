import Foundation

func testRetentionTelemetry() {
    let suite = "RetentionTelemetryTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let start = Date(timeIntervalSince1970: 1_000_000)
    func reset() { defaults.removePersistentDomain(forName: suite) }

    runSuite("Observed onboarding times the first successful value separately for each workflow") {
        reset()
        RetentionTelemetry.observeOnboarding(previouslyCompleted: false, now: start, userDefaults: defaults, isAutomatedLaunch: false)
        RetentionTelemetry.observeOnboarding(previouslyCompleted: false, now: start.addingTimeInterval(90), userDefaults: defaults, isAutomatedLaunch: false)
        RetentionTelemetry.completeOnboarding(now: start.addingTimeInterval(90), userDefaults: defaults, isAutomatedLaunch: false)
        let first = RetentionTelemetry.firstValueProperties(artifactKind: .dictation, now: start.addingTimeInterval(120), userDefaults: defaults, isAutomatedLaunch: false)
        assertEqual(first?["measurement_basis"], "observed_onboarding", "only observed onboarding supplies timing")
        assertEqual(first?["onboarding_to_value_bucket"], "1_5m", "reopening onboarding must not reset the start")
        assertEqual(first?["setup_to_value_bucket"], "lt_1m", "completion is a separate baseline")
        assertNil(RetentionTelemetry.firstValueProperties(artifactKind: .dictation, now: start, userDefaults: defaults, isAutomatedLaunch: false), "repeated saves do not create another first value")
        let meeting = RetentionTelemetry.firstValueProperties(artifactKind: .meeting, now: start.addingTimeInterval(7 * 86_400), userDefaults: defaults, isAutomatedLaunch: false)
        assertEqual(meeting?["onboarding_to_value_bucket"], "7d_plus", "first meeting is independent of first dictation")
    }

    runSuite("Existing installs and onboarding replay never invent original installation timing") {
        reset()
        RetentionTelemetry.observeOnboarding(previouslyCompleted: true, now: start, userDefaults: defaults, isAutomatedLaunch: false)
        let value = RetentionTelemetry.firstValueProperties(artifactKind: .meeting, now: start, userDefaults: defaults, isAutomatedLaunch: false)
        assertEqual(value?["measurement_basis"], "existing_or_unobserved", "replayed setup is not a fresh cohort")
        assertEqual(value?["onboarding_to_value_bucket"], "unknown", "legacy timing is unknown")
        reset()
        defaults.set(true, forKey: ActivationTelemetry.firstArtifactSavedTrackedKey)
        RetentionTelemetry.observeOnboarding(previouslyCompleted: false, now: start, userDefaults: defaults, isAutomatedLaunch: false)
        assertNil(defaults.object(forKey: RetentionTelemetry.onboardingStartedKey), "prior saved value disqualifies first-value timing")
        assertEqual(RetentionTelemetry.elapsedBucket(since: start.addingTimeInterval(1), now: start), "unknown", "clock reversal is not instant activation")
    }

    runSuite("Opt-out and automated launches retain no new retention observations") {
        reset()
        AnalyticsPreferences.setEnabled(false, userDefaults: defaults)
        RetentionTelemetry.observeOnboarding(previouslyCompleted: false, now: start, userDefaults: defaults, isAutomatedLaunch: false)
        RetentionTelemetry.completeOnboarding(now: start, userDefaults: defaults, isAutomatedLaunch: false)
        assertNil(RetentionTelemetry.firstValueProperties(artifactKind: .dictation, now: start, userDefaults: defaults, isAutomatedLaunch: false), "disabled analytics collect no milestone")
        assertNil(defaults.object(forKey: RetentionTelemetry.onboardingStartedKey), "disabled analytics collect no date")
        AnalyticsPreferences.setEnabled(true, userDefaults: defaults)
        RetentionTelemetry.observeOnboarding(previouslyCompleted: false, now: start, userDefaults: defaults, isAutomatedLaunch: true)
        assertNil(defaults.object(forKey: RetentionTelemetry.onboardingStartedKey), "smokes cannot alter the real onboarding baseline")
        RetentionTelemetry.observeOnboarding(previouslyCompleted: false, now: start, userDefaults: defaults, isAutomatedLaunch: false)
        RetentionTelemetry.setAnalyticsEnabled(false, userDefaults: defaults)
        RetentionTelemetry.setAnalyticsEnabled(true, userDefaults: defaults)
        let first = RetentionTelemetry.firstValueProperties(artifactKind: .dictation, now: start, userDefaults: defaults, isAutomatedLaunch: false)
        assertEqual(first?["onboarding_to_value_bucket"], "unknown", "opt-in must not time across an opt-out gap")
        RetentionTelemetry.clearObservation(userDefaults: defaults)
        assertNil(RetentionTelemetry.firstValueProperties(artifactKind: .dictation, now: start, userDefaults: defaults, isAutomatedLaunch: false), "toggle does not regenerate a first value")
    }

    runSuite("Repeated opt-out clearing stops mutating preferences once the baselines are gone") {
        let name = "RetentionClearingTests-\(UUID().uuidString)"
        let recordingDefaults = RetentionRecordingDefaults(suiteName: name)!
        defer { recordingDefaults.removePersistentDomain(forName: name) }
        recordingDefaults.set(start, forKey: RetentionTelemetry.onboardingStartedKey)
        recordingDefaults.set(start, forKey: RetentionTelemetry.onboardingCompletedKey)
        RetentionTelemetry.clearObservation(userDefaults: recordingDefaults)
        assertEqual(recordingDefaults.removals, 2, "both observed baselines are removed")
        RetentionTelemetry.clearObservation(userDefaults: recordingDefaults)
        assertEqual(recordingDefaults.removals, 2, "observer reentry must not produce more defaults notifications")
    }

    runSuite("Duplicate capture completion cannot count as the second saved artifact") {
        reset()
        let capture = UUID().uuidString
        let first = ActivationTelemetry.recordArtifactSave(artifactKind: .meeting, correlationID: capture, savedAt: start, userDefaults: defaults)
        assertTrue(first.firstArtifact, "first save counts")
        let retry = ActivationTelemetry.recordArtifactSave(artifactKind: .meeting, correlationID: capture.lowercased(), savedAt: start.addingTimeInterval(5), userDefaults: defaults)
        assertNil(retry.secondArtifact, "same UUID casing and retry do not create another artifact")
        let next = ActivationTelemetry.recordArtifactSave(artifactKind: .dictation, correlationID: UUID().uuidString, savedAt: start.addingTimeInterval(100), userDefaults: defaults)
        assertNotNil(next.secondArtifact, "a different capture counts as second")
    }

    runSuite("Save identifiers survive only the reviewed UUID property allowlist") {
        let id = UUID().uuidString
        for event in ["dictation_artifact_saved", "meeting_transcript_saved", "activation_first_value_saved"] {
            let policy = AnalyticsEventPolicy.policy(forEvent: event)!
            let safe = AnalyticsPayloadSanitizer.sanitizeProperties([
                "save_id": id, "title": "Private title", "transcript_text": "Private words", "path": "/Users/private/meeting.md"
            ], allowedKeys: policy.allowedProperties)
            assertEqual(safe, ["save_id": id], "only random correlation leaves the sanitizer")
            assertNil(AnalyticsPayloadSanitizer.sanitizeProperties(["save_id": "private-contents"], allowedKeys: policy.allowedProperties)["save_id"], "free-form save IDs are dropped")
        }
    }
}

private final class RetentionRecordingDefaults: UserDefaults {
    var removals = 0
    override func removeObject(forKey defaultName: String) {
        removals += 1
        super.removeObject(forKey: defaultName)
    }
}

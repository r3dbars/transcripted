import Foundation
import EventKit
import ScreenCaptureKit

@MainActor
private final class PermissionRequestBox {
    var callCount = 0
}

@MainActor
private final class SystemAudioPermissionAttemptDriver {
    typealias ProbeResult = TranscriptedPermissionAccess.SystemAudioPermissionProbeResult

    var completion: ((ProbeResult) -> Void)?
    var timeoutAction: (() -> Void)?
    var cleanupCount = 0
    var timeoutCancellationCount = 0

    func start(_ completion: @escaping (ProbeResult) -> Void) {
        self.completion = completion
    }

    func scheduleTimeout(_ action: @escaping () -> Void) -> () -> Void {
        timeoutAction = action
        return { [weak self] in
            self?.timeoutCancellationCount += 1
        }
    }

    func fireTimeout() {
        timeoutAction?()
    }
}

@MainActor
private func waitForSystemAudioPermissionAttemptStart(
    _ driver: SystemAudioPermissionAttemptDriver
) async -> Bool {
    for _ in 0..<20 {
        if driver.completion != nil { return true }
        await Task.yield()
    }
    return driver.completion != nil
}

@MainActor
func testTranscriptedPermissionAccess() async {
    let knownKey = "systemAudioRecordingPermissionKnown"
    let grantedKey = "systemAudioRecordingPermissionGranted"
    let onboardingKey = "permissionsOnboardingCompleted"

    func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    await runSuite("SystemAudioPermissionRequestAttempt — stalled requester times out as indeterminate") {
        let driver = SystemAudioPermissionAttemptDriver()
        var timeoutCount = 0
        var resolved: [TranscriptedPermissionAccess.SystemAudioPermissionProbeResult] = []
        let attempt = SystemAudioPermissionRequestAttempt(
            scheduleTimeout: driver.scheduleTimeout,
            onTimeout: { timeoutCount += 1 },
            onResolved: { resolved.append($0) }
        )
        let resultTask = Task { @MainActor in
            await attempt.awaitResult(
                start: driver.start,
                cleanup: { driver.cleanupCount += 1 }
            )
        }

        assertTrue(
            await waitForSystemAudioPermissionAttemptStart(driver),
            "the deterministic requester should start before its timeout is fired"
        )
        driver.fireTimeout()
        let result = await resultTask.value

        assertEqual(result, .indeterminate(.timedOut), "a stalled permission requester must not manufacture a denial")
        assertEqual(timeoutCount, 1, "the timeout diagnostic hook should fire once")
        assertEqual(resolved, [.indeterminate(.timedOut)], "timeout should resolve the request exactly once")
        assertEqual(driver.cleanupCount, 1, "timeout should clean up the in-flight requester")
        assertEqual(driver.timeoutCancellationCount, 1, "timeout should cancel its pending timer once")
    }

    await runSuite("SystemAudioPermissionRequestAttempt — ignores a late success after timeout") {
        let driver = SystemAudioPermissionAttemptDriver()
        var resolved: [TranscriptedPermissionAccess.SystemAudioPermissionProbeResult] = []
        let attempt = SystemAudioPermissionRequestAttempt(
            scheduleTimeout: driver.scheduleTimeout,
            onResolved: { resolved.append($0) }
        )
        let resultTask = Task { @MainActor in
            await attempt.awaitResult(
                start: driver.start,
                cleanup: { driver.cleanupCount += 1 }
            )
        }

        assertTrue(await waitForSystemAudioPermissionAttemptStart(driver), "the requester should start")
        driver.fireTimeout()
        let result = await resultTask.value
        driver.completion?(.granted)
        await Task.yield()

        assertEqual(result, .indeterminate(.timedOut), "a timeout must not be upgraded to a late success")
        assertEqual(resolved, [.indeterminate(.timedOut)], "a late ScreenCaptureKit callback must be harmless")
        assertEqual(driver.cleanupCount, 1, "late callbacks must not repeat cleanup")
    }

    await runSuite("SystemAudioPermissionRequestAttempt — returns real success and explicit denial") {
        let successDriver = SystemAudioPermissionAttemptDriver()
        let successAttempt = SystemAudioPermissionRequestAttempt(scheduleTimeout: successDriver.scheduleTimeout)
        let successTask = Task { @MainActor in
            await successAttempt.awaitResult(
                start: successDriver.start,
                cleanup: { successDriver.cleanupCount += 1 }
            )
        }
        assertTrue(await waitForSystemAudioPermissionAttemptStart(successDriver), "the success requester should start")
        successDriver.completion?(.granted)
        assertEqual(await successTask.value, .granted, "a successful ScreenCaptureKit probe should be granted")

        let failureDriver = SystemAudioPermissionAttemptDriver()
        let failureAttempt = SystemAudioPermissionRequestAttempt(scheduleTimeout: failureDriver.scheduleTimeout)
        let failureTask = Task { @MainActor in
            await failureAttempt.awaitResult(
                start: failureDriver.start,
                cleanup: { failureDriver.cleanupCount += 1 }
            )
        }
        assertTrue(await waitForSystemAudioPermissionAttemptStart(failureDriver), "the failure requester should start")
        failureDriver.completion?(.explicitlyDenied)
        assertEqual(await failureTask.value, .explicitlyDenied, "an explicit ScreenCaptureKit denial should stay denied")
        assertEqual(successDriver.cleanupCount, 1, "success should clean up the probe stream")
        assertEqual(failureDriver.cleanupCount, 1, "failure should clean up the probe stream")
    }

    await runSuite("SystemAudioPermissionRequestAttempt — duplicate callbacks and cancellation resolve once") {
        let duplicateDriver = SystemAudioPermissionAttemptDriver()
        var duplicateResolved: [TranscriptedPermissionAccess.SystemAudioPermissionProbeResult] = []
        let duplicateAttempt = SystemAudioPermissionRequestAttempt(
            scheduleTimeout: duplicateDriver.scheduleTimeout,
            onResolved: { duplicateResolved.append($0) }
        )
        let duplicateTask = Task { @MainActor in
            await duplicateAttempt.awaitResult(
                start: duplicateDriver.start,
                cleanup: { duplicateDriver.cleanupCount += 1 }
            )
        }
        assertTrue(await waitForSystemAudioPermissionAttemptStart(duplicateDriver), "the duplicate-callback requester should start")
        duplicateDriver.completion?(.granted)
        assertEqual(await duplicateTask.value, .granted, "the first callback should win")
        duplicateDriver.completion?(.explicitlyDenied)
        await Task.yield()
        assertEqual(duplicateResolved, [.granted], "duplicate callbacks must not resume twice")
        assertEqual(duplicateDriver.cleanupCount, 1, "duplicate callbacks must not repeat cleanup")

        let cancellationDriver = SystemAudioPermissionAttemptDriver()
        var cancellationResolved: [TranscriptedPermissionAccess.SystemAudioPermissionProbeResult] = []
        let cancellationAttempt = SystemAudioPermissionRequestAttempt(
            scheduleTimeout: cancellationDriver.scheduleTimeout,
            onResolved: { cancellationResolved.append($0) }
        )
        let cancellationTask = Task { @MainActor in
            await cancellationAttempt.awaitResult(
                start: cancellationDriver.start,
                cleanup: { cancellationDriver.cleanupCount += 1 }
            )
        }
        assertTrue(await waitForSystemAudioPermissionAttemptStart(cancellationDriver), "the cancellable requester should start")
        cancellationTask.cancel()
        assertEqual(
            await cancellationTask.value,
            .indeterminate(.cancelled),
            "cancelling a request should not be persisted as a permission denial"
        )
        assertEqual(cancellationResolved, [.indeterminate(.cancelled)], "cancellation must resolve exactly once")
        assertEqual(cancellationDriver.cleanupCount, 1, "cancellation should clean up the probe stream")
    }

    runSuite("TranscriptedPermissionAccess.systemAudioRecordingGranted — old onboarding completion no longer implies a real grant") {
        let originalKnown = UserDefaults.standard.object(forKey: knownKey)
        let originalGranted = UserDefaults.standard.object(forKey: grantedKey)
        let originalOnboarding = UserDefaults.standard.object(forKey: onboardingKey)
        defer {
            restore(originalKnown, forKey: knownKey)
            restore(originalGranted, forKey: grantedKey)
            restore(originalOnboarding, forKey: onboardingKey)
        }

        UserDefaults.standard.removeObject(forKey: knownKey)
        UserDefaults.standard.removeObject(forKey: grantedKey)
        UserDefaults.standard.set(true, forKey: onboardingKey)

        assertFalse(
            TranscriptedPermissionAccess.systemAudioRecordingGranted(),
            "upgraded installs should not treat completed onboarding as proof that system audio is granted"
        )
        assertFalse(
            TranscriptedPermissionAccess.isGranted(.systemAudioRecording),
            "permission checks should stay false until system audio is actually verified"
        )
    }

    await runSuite("TranscriptedPermissionAccess.requestSystemAudioRecordingAccessIfNeeded — rechecks upgraded installs instead of short-circuiting") {
        let originalKnown = UserDefaults.standard.object(forKey: knownKey)
        let originalGranted = UserDefaults.standard.object(forKey: grantedKey)
        let originalOnboarding = UserDefaults.standard.object(forKey: onboardingKey)
        defer {
            restore(originalKnown, forKey: knownKey)
            restore(originalGranted, forKey: grantedKey)
            restore(originalOnboarding, forKey: onboardingKey)
        }

        UserDefaults.standard.removeObject(forKey: knownKey)
        UserDefaults.standard.removeObject(forKey: grantedKey)
        UserDefaults.standard.set(true, forKey: onboardingKey)

        let requestBox = PermissionRequestBox()
        let granted = await TranscriptedPermissionAccess.requestSystemAudioRecordingAccessIfNeeded {
            requestBox.callCount += 1
            return false
        }

        assertFalse(granted, "a denied recheck should return false")
        assertEqual(requestBox.callCount, 1, "upgraded installs should perform a real system audio recheck")
        assertTrue(
            UserDefaults.standard.bool(forKey: knownKey),
            "recheck results should mark the system audio permission state as known"
        )
        assertFalse(
            UserDefaults.standard.bool(forKey: grantedKey),
            "a denied recheck should persist the missing permission state"
        )
    }

    await runSuite("TranscriptedPermissionAccess.requestSystemAudioRecordingAccessIfNeeded — skips the requester once a real grant is already known") {
        let originalKnown = UserDefaults.standard.object(forKey: knownKey)
        let originalGranted = UserDefaults.standard.object(forKey: grantedKey)
        let originalOnboarding = UserDefaults.standard.object(forKey: onboardingKey)
        defer {
            restore(originalKnown, forKey: knownKey)
            restore(originalGranted, forKey: grantedKey)
            restore(originalOnboarding, forKey: onboardingKey)
        }

        UserDefaults.standard.set(true, forKey: knownKey)
        UserDefaults.standard.set(true, forKey: grantedKey)
        UserDefaults.standard.set(true, forKey: onboardingKey)

        let requestBox = PermissionRequestBox()
        let granted = await TranscriptedPermissionAccess.requestSystemAudioRecordingAccessIfNeeded {
            requestBox.callCount += 1
            return false
        }

        assertTrue(granted, "known granted permission should stay ready")
        assertEqual(requestBox.callCount, 0, "known granted permission should not trigger another request")
    }

    await runSuite("TranscriptedPermissionAccess.requestSystemAudioRecordingAccessIfNeeded(forceRefresh:) — rechecks cached grants before meeting start") {
        let originalKnown = UserDefaults.standard.object(forKey: knownKey)
        let originalGranted = UserDefaults.standard.object(forKey: grantedKey)
        let originalOnboarding = UserDefaults.standard.object(forKey: onboardingKey)
        defer {
            restore(originalKnown, forKey: knownKey)
            restore(originalGranted, forKey: grantedKey)
            restore(originalOnboarding, forKey: onboardingKey)
        }

        UserDefaults.standard.set(true, forKey: knownKey)
        UserDefaults.standard.set(true, forKey: grantedKey)
        UserDefaults.standard.set(true, forKey: onboardingKey)

        let requestBox = PermissionRequestBox()
        let granted = await TranscriptedPermissionAccess.requestSystemAudioRecordingAccessIfNeeded(forceRefresh: true) {
            requestBox.callCount += 1
            return false
        }

        assertFalse(granted, "a forced recheck should surface revoked system audio permission")
        assertEqual(requestBox.callCount, 1, "meeting start should bypass the cached grant and perform a real recheck")
        assertTrue(
            UserDefaults.standard.bool(forKey: knownKey),
            "forced rechecks should keep the permission state marked as known"
        )
        assertFalse(
            UserDefaults.standard.bool(forKey: grantedKey),
            "a failed forced recheck should clear the cached granted state"
        )
    }

    await runSuite("TranscriptedPermissionAccess.systemAudioRecordingAccessDecision — preserves cached grants across every indeterminate probe stage") {
        let originalKnown = UserDefaults.standard.object(forKey: knownKey)
        let originalGranted = UserDefaults.standard.object(forKey: grantedKey)
        defer {
            restore(originalKnown, forKey: knownKey)
            restore(originalGranted, forKey: grantedKey)
        }

        for stage in TranscriptedPermissionAccess.SystemAudioPermissionProbeStage.allCases
            where stage != .cancelled {
            UserDefaults.standard.set(true, forKey: knownKey)
            UserDefaults.standard.set(true, forKey: grantedKey)

            let decision = await TranscriptedPermissionAccess.systemAudioRecordingAccessDecision(
                forceRefresh: true,
                probeRequester: { .indeterminate(stage) }
            )

            assertTrue(decision.canProceed, "cached grant should survive an indeterminate \(stage.rawValue) probe")
            assertEqual(decision.state, .granted, "indeterminate \(stage.rawValue) should not rewrite cached state")
            assertEqual(
                decision.probeResult,
                .indeterminate(stage),
                "the decision should retain the privacy-safe probe stage"
            )
            assertTrue(
                UserDefaults.standard.bool(forKey: grantedKey),
                "indeterminate \(stage.rawValue) should leave the persisted grant intact"
            )
        }
    }

    await runSuite("TranscriptedPermissionAccess.systemAudioRecordingAccessDecision — cancellation preserves cached grant but blocks this start") {
        let originalKnown = UserDefaults.standard.object(forKey: knownKey)
        let originalGranted = UserDefaults.standard.object(forKey: grantedKey)
        defer {
            restore(originalKnown, forKey: knownKey)
            restore(originalGranted, forKey: grantedKey)
        }

        UserDefaults.standard.set(true, forKey: knownKey)
        UserDefaults.standard.set(true, forKey: grantedKey)

        let decision = await TranscriptedPermissionAccess.systemAudioRecordingAccessDecision(
            forceRefresh: true,
            probeRequester: { .indeterminate(.cancelled) }
        )

        assertFalse(decision.canProceed, "a cancelled caller must not continue into meeting capture")
        assertEqual(decision.state, .granted, "cancellation must not rewrite the persisted TCC grant")
        assertEqual(decision.probeResult, .indeterminate(.cancelled), "the decision should retain cancellation as its terminal stage")
        assertTrue(UserDefaults.standard.bool(forKey: grantedKey), "cancellation must preserve the cached grant for a future attempt")
    }

    await runSuite("TranscriptedPermissionAccess.systemAudioRecordingAccessDecision — explicit denial clears a cached grant") {
        let originalKnown = UserDefaults.standard.object(forKey: knownKey)
        let originalGranted = UserDefaults.standard.object(forKey: grantedKey)
        defer {
            restore(originalKnown, forKey: knownKey)
            restore(originalGranted, forKey: grantedKey)
        }

        UserDefaults.standard.set(true, forKey: knownKey)
        UserDefaults.standard.set(true, forKey: grantedKey)

        let decision = await TranscriptedPermissionAccess.systemAudioRecordingAccessDecision(
            forceRefresh: true,
            probeRequester: { .explicitlyDenied }
        )

        assertFalse(decision.canProceed, "an explicit TCC denial should still block meeting start")
        assertEqual(decision.state, .denied, "an explicit denial should replace the stale grant")
        assertFalse(UserDefaults.standard.bool(forKey: grantedKey), "explicit denial should clear the cached grant")
    }

    await runSuite("TranscriptedPermissionAccess.systemAudioRecordingAccessDecision — first-run indeterminate stays unknown") {
        let originalKnown = UserDefaults.standard.object(forKey: knownKey)
        let originalGranted = UserDefaults.standard.object(forKey: grantedKey)
        defer {
            restore(originalKnown, forKey: knownKey)
            restore(originalGranted, forKey: grantedKey)
        }

        UserDefaults.standard.removeObject(forKey: knownKey)
        UserDefaults.standard.removeObject(forKey: grantedKey)

        let decision = await TranscriptedPermissionAccess.systemAudioRecordingAccessDecision(
            probeRequester: { .indeterminate(.shareableContent) }
        )

        assertFalse(decision.canProceed, "an unverified first-run state should not claim capture is ready")
        assertEqual(decision.state, .unknown, "a transient first-run failure should remain unknown, not denied")
        assertFalse(UserDefaults.standard.bool(forKey: knownKey), "an indeterminate probe should not persist a known denial")
    }

    runSuite("SystemAudioPermissionProbeClassifier — only user-declined errors become permission denials") {
        let explicitDenial = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userDeclined.rawValue
        )
        let transientStartFailure = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.failedToStart.rawValue
        )
        let unrelatedFailure = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)

        assertEqual(
            SystemAudioPermissionProbeClassifier.result(for: explicitDenial, stage: .startCapture),
            .explicitlyDenied,
            "the explicit ScreenCaptureKit user-declined code should clear a cached grant"
        )
        assertEqual(
            SystemAudioPermissionProbeClassifier.result(for: transientStartFailure, stage: .startCapture),
            .indeterminate(.startCapture),
            "a ScreenCaptureKit transport/start failure should not impersonate TCC denial"
        )
        assertEqual(
            SystemAudioPermissionProbeClassifier.result(for: unrelatedFailure, stage: .shareableContent),
            .indeterminate(.shareableContent),
            "unrelated service failures should remain indeterminate"
        )
        assertEqual(
            SystemAudioPermissionProbeClassifier.resultAfterSuccessfulStart(),
            .granted,
            "a cleanup failure after startCapture succeeds must not downgrade a proven grant"
        )
    }

    runSuite("TranscriptedPermissionKind action titles — name the real recovery path for blocked permissions") {
        assertEqual(
            TranscriptedPermissionKind.microphoneActionTitle(for: .notDetermined),
            "Allow microphone",
            "microphone action should stay prompt-like before the first decision"
        )
        assertEqual(
            TranscriptedPermissionKind.microphoneActionTitle(for: .denied),
            "Open Microphone Settings",
            "microphone action should point to System Settings after denial"
        )
        assertEqual(
            TranscriptedPermissionKind.accessibilityActionTitle(isTrusted: false),
            "Open Accessibility Settings",
            "accessibility action should name the settings destination instead of a vague fix label"
        )
        assertEqual(
            TranscriptedPermissionKind.systemAudioRecordingActionTitle(for: .unknown),
            "Check System Audio Recording",
            "unknown system audio state should ask the app to verify access instead of treating it as a denial"
        )
        assertEqual(
            TranscriptedPermissionKind.systemAudioRecordingActionTitle(for: .denied),
            "Open Audio Recording Settings",
            "system audio action should explain the destination when the permission is still missing"
        )
        assertEqual(
            TranscriptedPermissionKind.calendarActionTitle(for: .notDetermined),
            "Allow Calendar Access",
            "calendar action should stay prompt-like before the first decision"
        )
    }

    runSuite("TranscriptedPermissionKind.requiredForCurrentUse — meetings-first setup requires system audio, not Accessibility") {
        assertEqual(
            TranscriptedPermissionKind.requiredForCurrentUse(dictationShortcutsEnabled: true),
            [.microphone, .accessibility],
            "dictation shortcut users should still need Accessibility for paste-back"
        )
        assertEqual(
            TranscriptedPermissionKind.requiredForCurrentUse(dictationShortcutsEnabled: false),
            [.microphone, .systemAudioRecording],
            "meetings-first users with dictation shortcuts off should need system audio instead of Accessibility"
        )
    }

    await runSuite("TranscriptedPermissionAccess.revalidateSystemAudioRecordingStatus — updates stale cached grants") {
        let originalKnown = UserDefaults.standard.object(forKey: knownKey)
        let originalGranted = UserDefaults.standard.object(forKey: grantedKey)
        defer {
            restore(originalKnown, forKey: knownKey)
            restore(originalGranted, forKey: grantedKey)
        }

        UserDefaults.standard.set(true, forKey: knownKey)
        UserDefaults.standard.set(true, forKey: grantedKey)

        let requestBox = PermissionRequestBox()
        let granted = await TranscriptedPermissionAccess.revalidateSystemAudioRecordingStatus {
            requestBox.callCount += 1
            return false
        }

        assertFalse(granted, "a failed revalidation should return the live denied state")
        assertEqual(requestBox.callCount, 1, "status-surface revalidation should perform a real probe")
        assertTrue(
            UserDefaults.standard.bool(forKey: knownKey),
            "revalidation should keep the permission state marked as known"
        )
        assertFalse(
            UserDefaults.standard.bool(forKey: grantedKey),
            "revalidation should clear stale cached grants after revocation"
        )
    }

    await runSuite("TranscriptedPermissionAccess.revalidateSystemAudioRecordingStatus — smoke mode preserves cached granted state without a live probe") {
        let originalKnown = UserDefaults.standard.object(forKey: knownKey)
        let originalGranted = UserDefaults.standard.object(forKey: grantedKey)
        defer {
            restore(originalKnown, forKey: knownKey)
            restore(originalGranted, forKey: grantedKey)
        }

        UserDefaults.standard.set(true, forKey: knownKey)
        UserDefaults.standard.set(true, forKey: grantedKey)

        let requestBox = PermissionRequestBox()
        let granted = await TranscriptedPermissionAccess.revalidateSystemAudioRecordingStatus(
            requester: {
                requestBox.callCount += 1
                return false
            },
            skipSmokeRevalidation: true
        )

        assertTrue(granted, "smoke-mode revalidation should keep the cached granted state")
        assertEqual(requestBox.callCount, 0, "smoke mode should not perform a live system-audio probe")
        assertTrue(
            UserDefaults.standard.bool(forKey: knownKey),
            "smoke mode should keep the cached system-audio state marked as known"
        )
        assertTrue(
            UserDefaults.standard.bool(forKey: grantedKey),
            "smoke mode should preserve the cached granted state"
        )
    }

    await runSuite("TranscriptedPermissionAccess.requestMicrophoneAccessIfNeeded — skips requester when microphone is already authorized") {
        let requestBox = PermissionRequestBox()
        let granted = await TranscriptedPermissionAccess.requestMicrophoneAccessIfNeeded(
            statusProvider: { .authorized },
            activateForPrompt: {},
            requester: { completion in
                requestBox.callCount += 1
                completion(false)
            }
        )

        assertTrue(granted, "authorized microphone status should return true")
        assertEqual(requestBox.callCount, 0, "authorized microphone status should not trigger another prompt")
    }

    await runSuite("TranscriptedPermissionAccess.requestMicrophoneAccessIfNeeded — prompts when microphone is not determined") {
        let requestBox = PermissionRequestBox()
        let granted = await TranscriptedPermissionAccess.requestMicrophoneAccessIfNeeded(
            statusProvider: { .notDetermined },
            activateForPrompt: {},
            requester: { completion in
                requestBox.callCount += 1
                completion(true)
            }
        )

        assertTrue(granted, "not-determined microphone access should return the requester result")
        assertEqual(requestBox.callCount, 1, "not-determined microphone access should ask macOS once")
    }

    await runSuite("TranscriptedPermissionAccess.requestMicrophoneAccessIfNeeded — does not prompt after denial") {
        let requestBox = PermissionRequestBox()
        let granted = await TranscriptedPermissionAccess.requestMicrophoneAccessIfNeeded(
            statusProvider: { .denied },
            activateForPrompt: {},
            requester: { completion in
                requestBox.callCount += 1
                completion(true)
            }
        )

        assertFalse(granted, "denied microphone access should stay blocked until Settings changes")
        assertEqual(requestBox.callCount, 0, "denied microphone access should not show a repeat system prompt")
    }

    await runSuite("TranscriptedPermissionAccess.requestCalendarAccessIfNeeded — skips requester when calendar is already authorized") {
        let requestBox = PermissionRequestBox()
        let granted = await TranscriptedPermissionAccess.requestCalendarAccessIfNeeded(
            statusProvider: { .fullAccess },
            requester: {
                requestBox.callCount += 1
                return false
            }
        )

        assertTrue(granted, "full calendar access should return true")
        assertEqual(requestBox.callCount, 0, "authorized calendar status should not trigger another prompt")
    }

    await runSuite("TranscriptedPermissionAccess.requestCalendarAccessIfNeeded — prompts when calendar is not determined") {
        let requestBox = PermissionRequestBox()
        let granted = await TranscriptedPermissionAccess.requestCalendarAccessIfNeeded(
            statusProvider: { .notDetermined },
            requester: {
                requestBox.callCount += 1
                return true
            }
        )

        assertTrue(granted, "not-determined calendar access should return the requester result")
        assertEqual(requestBox.callCount, 1, "not-determined calendar access should ask EventKit once")
    }

    await runSuite("TranscriptedPermissionAccess.requestCalendarAccessIfNeeded — does not prompt after denial") {
        let requestBox = PermissionRequestBox()
        let granted = await TranscriptedPermissionAccess.requestCalendarAccessIfNeeded(
            statusProvider: { .denied },
            requester: {
                requestBox.callCount += 1
                return true
            }
        )

        assertFalse(granted, "denied calendar access should stay blocked until Settings changes")
        assertEqual(requestBox.callCount, 0, "denied calendar access should not show a repeat system prompt")
    }

    runSuite("TranscriptedPermissionAccess.systemAudioRecordingStatus — separates unknown from denied state") {
        let originalKnown = UserDefaults.standard.object(forKey: knownKey)
        let originalGranted = UserDefaults.standard.object(forKey: grantedKey)
        defer {
            restore(originalKnown, forKey: knownKey)
            restore(originalGranted, forKey: grantedKey)
        }

        UserDefaults.standard.removeObject(forKey: knownKey)
        UserDefaults.standard.removeObject(forKey: grantedKey)
        assertEqual(
            TranscriptedPermissionAccess.systemAudioRecordingStatus(),
            .unknown,
            "missing local cache should stay unknown so upgraded installs are not treated like explicit denials"
        )

        UserDefaults.standard.set(true, forKey: knownKey)
        UserDefaults.standard.set(false, forKey: grantedKey)
        assertEqual(
            TranscriptedPermissionAccess.systemAudioRecordingStatus(),
            .denied,
            "known negative result should stay denied"
        )

        UserDefaults.standard.set(true, forKey: grantedKey)
        assertEqual(
            TranscriptedPermissionAccess.systemAudioRecordingStatus(),
            .granted,
            "cached positive result should stay granted"
        )
    }

    await runSuite("TranscriptedPermissionAccess.revalidateSystemAudioRecordingStatus — refreshes stale cache") {
        let originalKnown = UserDefaults.standard.object(forKey: knownKey)
        let originalGranted = UserDefaults.standard.object(forKey: grantedKey)
        defer {
            restore(originalKnown, forKey: knownKey)
            restore(originalGranted, forKey: grantedKey)
        }

        UserDefaults.standard.set(true, forKey: knownKey)
        UserDefaults.standard.set(false, forKey: grantedKey)
        let granted = await TranscriptedPermissionAccess.revalidateSystemAudioRecordingStatus {
            true
        }

        assertTrue(granted, "revalidation should return the fresh requester result")
        assertEqual(
            TranscriptedPermissionAccess.systemAudioRecordingStatus(),
            .granted,
            "revalidation should replace stale denied cache with the fresh grant"
        )

        let denied = await TranscriptedPermissionAccess.revalidateSystemAudioRecordingStatus {
            false
        }
        assertFalse(denied, "revalidation should also report revocations")
        assertEqual(
            TranscriptedPermissionAccess.systemAudioRecordingStatus(),
            .denied,
            "revalidation should replace stale granted cache after revocation"
        )
    }
}

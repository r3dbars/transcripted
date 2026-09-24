import Foundation
import AVFoundation
import EventKit
import CoreAudio

@MainActor
private final class PermissionRequestBox {
    var callCount = 0
}

private final class AudioPermissionCaptureFake: @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: ((SystemAudioPermissionSampleEvidence) -> Void)?
    private var starts = 0
    private var stops = 0
    private var prepares = 0
    var prepareGate: DispatchSemaphore?

    func prepare() {
        lock.lock(); prepares += 1; lock.unlock()
        prepareGate?.wait()
    }
    func start(_ receiver: @escaping (SystemAudioPermissionSampleEvidence) -> Void) {
        lock.lock(); self.receiver = receiver; starts += 1; lock.unlock()
    }
    func stop() {
        lock.lock(); stops += 1; lock.unlock()
    }
    func emit(_ evidence: SystemAudioPermissionSampleEvidence) {
        lock.lock(); let callback = receiver; lock.unlock()
        callback?(evidence)
    }
    var counts: (prepares: Int, starts: Int, stops: Int) {
        lock.lock(); defer { lock.unlock() }
        return (prepares, starts, stops)
    }
}

@MainActor
private func awaitAudioPermissionCondition(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
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
    runSuite("Core Audio permission signal — silent, empty, and nonfinite PCM are not proof") {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        let samples = buffer.floatChannelData![0]
        for index in 0..<4 { samples[index] = 0 }
        assertFalse(SystemAudioPermissionProbeClassifier.containsAudioSignal(buffer), "all-zero PCM is inconclusive even when frames arrive")
        samples[0] = .nan
        samples[1] = .infinity
        assertFalse(SystemAudioPermissionProbeClassifier.containsAudioSignal(buffer), "invalid samples do not prove audio access")
        samples[2] = -0.001
        assertTrue(SystemAudioPermissionProbeClassifier.containsAudioSignal(buffer), "finite nonzero PCM proves actual signal")
        buffer.frameLength = 0
        assertFalse(SystemAudioPermissionProbeClassifier.containsAudioSignal(buffer), "empty buffers ignore stale capacity")
    }

    runSuite("Cached system audio revalidation uses a short bounded budget") {
        assertEqual(TranscriptedPermissionAccess.systemAudioProbeTimeout(for: .granted), 3_000_000_000,
            "an existing grant must not wait through the first-install consent budget")
        for state: TranscriptedPermissionAccess.SystemAudioPermissionState in [.unknown, .denied] {
            assertEqual(TranscriptedPermissionAccess.systemAudioProbeTimeout(for: state), TranscriptedConstants.systemAudioPermissionRequestTimeout,
                "first-time and explicit permission requests retain their dialog budget")
        }
    }

    await runSuite("Permission attempt honors its per-request live timeout") {
        let driver = SystemAudioPermissionAttemptDriver()
        let attempt = SystemAudioPermissionRequestAttempt(timeoutNanoseconds: 1_000_000)
        let result = await attempt.awaitResult(start: { driver.completion = $0 }, cleanup: { driver.cleanupCount += 1 })
        assertEqual(result, .indeterminate(.timedOut), "a callback-free check resolves with its injected short budget")
        assertEqual(driver.cleanupCount, 1, "short timeouts still tear down once")
    }

    await runSuite("Core Audio permission probe — terminal backend errors finish inconclusive without waiting for PCM") {
        let fake = AudioPermissionCaptureFake()
        let requester = SystemAudioPermissionRequester(prepare: fake.prepare, start: fake.start, stop: fake.stop)
        var results: [TranscriptedPermissionAccess.SystemAudioPermissionProbeResult] = []
        requester.requestAccess { results.append($0) }
        assertTrue(await awaitAudioPermissionCondition { fake.counts.starts == 1 }, "capture should start")
        requester.handleBackendError(nil)
        requester.handleBackendError("System audio reconnecting after capture interruption.")
        assertTrue(results.isEmpty, "temporary recovery is not terminal failure")
        requester.handleBackendError("System audio failed - no audio buffers after reconnecting.")
        assertEqual(results, [.indeterminate(.startCapture)], "backend failure is unavailable verification, not denial")
        requester.cancel()
        fake.emit(.signal)
        requester.handleBackendError("System audio failed - could not reconnect.")
        await Task.yield()
        assertEqual(results.count, 1, "late failure and PCM cannot revive a finished request")
    }

    await runSuite("Core Audio permission probe — silence is inconclusive, signal proves capture") {
        let fake = AudioPermissionCaptureFake()
        let requester = SystemAudioPermissionRequester(prepare: fake.prepare, start: fake.start, stop: fake.stop)
        var results: [TranscriptedPermissionAccess.SystemAudioPermissionProbeResult] = []
        requester.requestAccess { results.append($0) }
        assertTrue(await awaitAudioPermissionCondition { fake.counts.starts == 1 }, "capture should start")
        assertTrue(results.isEmpty, "starting the device alone does not establish access")
        fake.emit(.silentFrames)
        await Task.yield()
        assertTrue(results.isEmpty, "silent frames must not manufacture a grant or denial")
        fake.emit(.signal)
        assertTrue(await awaitAudioPermissionCondition { results.count == 1 }, "nonzero audio proves working capture")
        assertEqual(results, [.granted], "actual signal establishes capture")
        fake.emit(.signal)
        await Task.yield()
        assertEqual(results.count, 1, "duplicate buffers cannot resolve twice")
        requester.cancel()
        assertTrue(await awaitAudioPermissionCondition { fake.counts.stops == 1 }, "capture must be cleaned up")
    }

    await runSuite("Core Audio permission probe — cancellation during prepare prevents late startup") {
        let fake = AudioPermissionCaptureFake()
        fake.prepareGate = DispatchSemaphore(value: 0)
        let requester = SystemAudioPermissionRequester(prepare: fake.prepare, start: fake.start, stop: fake.stop)
        var results: [TranscriptedPermissionAccess.SystemAudioPermissionProbeResult] = []
        requester.requestAccess { results.append($0) }
        assertTrue(await awaitAudioPermissionCondition { fake.counts.prepares == 1 }, "prepare should be in flight")
        requester.cancel()
        fake.prepareGate?.signal()
        assertTrue(await awaitAudioPermissionCondition { fake.counts.stops > 0 }, "cancelled setup must be torn down")
        assertEqual(fake.counts.starts, 0, "cancelled setup must not start capture later")
        assertTrue(results.isEmpty, "cancelled requester must not send late results")
    }

    await runSuite("Core Audio permission probe — valid silent frames finish promptly as inconclusive") {
        let fake = AudioPermissionCaptureFake()
        let requester = SystemAudioPermissionRequester(
            prepare: fake.prepare, start: fake.start, stop: fake.stop,
            silenceObservationDelay: 0.01
        )
        var results: [TranscriptedPermissionAccess.SystemAudioPermissionProbeResult] = []
        requester.requestAccess { results.append($0) }
        assertTrue(await awaitAudioPermissionCondition { fake.counts.starts == 1 }, "capture should start")
        fake.emit(.noValidFrames)
        await Task.yield()
        assertTrue(results.isEmpty, "missing frames must not become silent-but-running")
        fake.emit(.silentFrames)
        assertTrue(await awaitAudioPermissionCondition { !results.isEmpty }, "valid silent capture should not wait for the TCC timeout")
        assertEqual(results, [.indeterminate(.silentAudio)], "silence neither grants nor denies permission")
        requester.cancel()
        assertTrue(await awaitAudioPermissionCondition { fake.counts.stops == 1 }, "silent probe must stop")
    }

    runSuite("Audio-only migration copy — names both macOS sections") {
        assertTrue(TranscriptedPermissionKind.systemAudioRecordingMigrationInstructions.contains("System Audio Recording Only"), "guide must name narrow grant")
        assertTrue(TranscriptedPermissionKind.systemAudioRecordingMigrationInstructions.contains("turn that broader permission off"), "guide must explain removing old access")
        assertTrue(TranscriptedPermissionKind.systemAudioRecordingSummary.contains("no screen access needed"), "new onboarding should explain narrow access")
    }
    // Exercise the actual Settings/onboarding action, including its external
    // handoff. Request-only helper tests cannot catch a dead Review button.
    let microphoneSettings = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
    let calendarSettings = "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"

    for status: AVAuthorizationStatus in [.authorized, .notDetermined, .denied, .restricted] {
        for promptResult in [true, false] {
            await runSuite("Microphone permission action — status \(status.rawValue), prompt \(promptResult)") {
                var opened: [String] = []
                var requests = 0
                let granted = await TranscriptedPermissionAccess.requestAccessOrOpenSettings(
                    for: .microphone,
                    microphoneStatus: { status },
                    requestMicrophone: {
                        requests += 1
                        return promptResult
                    },
                    openSystemSettings: { opened.append($0) }
                )
                let expectedGranted = status == .authorized || (status == .notDetermined && promptResult)
                assertEqual(granted, expectedGranted, "the action should preserve the authorization result")
                assertEqual(requests, status == .notDetermined ? 1 : 0, "only undetermined access should request permission")
                assertEqual(opened, status == .notDetermined ? [] : [microphoneSettings], "Review and blocked access should open Microphone Settings exactly once; a fresh answer to the macOS prompt, Allow or Don't Allow, should stay in-app")
            }
        }
    }

    for status: EKAuthorizationStatus in [.fullAccess, .authorized, .notDetermined, .denied, .restricted, .writeOnly] {
        for promptResult in [true, false] {
            await runSuite("Calendar permission action — status \(status.rawValue), prompt \(promptResult)") {
                var opened: [String] = []
                var requests = 0
                var activations = 0
                let granted = await TranscriptedPermissionAccess.requestAccessOrOpenSettings(
                    for: .calendar,
                    calendarStatus: { status },
                    requestCalendar: {
                        await TranscriptedPermissionAccess.requestCalendarAccessIfNeeded(
                            statusProvider: { status },
                            requester: {
                                requests += 1
                                return promptResult
                            }
                        )
                    },
                    activateForPrompt: { activations += 1 },
                    openSystemSettings: { opened.append($0) }
                )
                let alreadyGranted = status == .fullAccess || status == .authorized
                let freshlyGranted = status == .notDetermined && promptResult
                assertEqual(granted, alreadyGranted || freshlyGranted, "the action should preserve the authorization result")
                assertEqual(requests, status == .notDetermined ? 1 : 0, "only undetermined access should request permission")
                assertEqual(opened, status == .notDetermined ? [] : [calendarSettings], "Review and blocked access should open Calendar Settings exactly once; a fresh answer to the macOS prompt, Allow or Don't Allow, should stay in-app")
                if alreadyGranted {
                    assertEqual(activations, 0, "Review should go straight to Settings without activating an in-app prompt")
                }
            }
        }
    }

    let accessibilitySettings = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    for trusted in [true, false] {
        for promptShown in [true, false] {
            await runSuite("Accessibility permission action — trusted \(trusted), prompt shown before \(promptShown)") {
                var opened: [String] = []
                var prompts = 0
                let granted = await TranscriptedPermissionAccess.requestAccessOrOpenSettings(
                    for: .accessibility,
                    isAccessibilityTrusted: { trusted },
                    hasShownAccessibilityPrompt: { promptShown },
                    promptForAccessibility: { prompts += 1 },
                    openSystemSettings: { opened.append($0) }
                )
                assertEqual(granted, trusted, "the action should report the current trust state")
                assertEqual(prompts, trusted ? 0 : 1, "only an untrusted app should ask macOS to show its prompt")
                let firstAsk = !trusted && !promptShown
                assertEqual(
                    opened,
                    firstAsk ? [] : [accessibilitySettings],
                    "the first Grant shows only the macOS prompt; stacking System Settings on top of it opened two windows at once"
                )
            }
        }
    }

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

    await runSuite("Fresh meeting start — real quiet probe proceeds without caching a grant") {
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
        UserDefaults.standard.removeObject(forKey: onboardingKey)

        let fake = AudioPermissionCaptureFake()
        let requester = SystemAudioPermissionRequester(
            prepare: fake.prepare, start: fake.start, stop: fake.stop,
            silenceObservationDelay: 0.01
        )
        defer { requester.cancel() }
        let attempt = SystemAudioPermissionRequestAttempt(timeoutNanoseconds: 2_000_000_000)
        let decisionTask = Task { @MainActor in
            await TranscriptedPermissionAccess.systemAudioRecordingAccessDecision(
                forceRefresh: true,
                probeRequester: {
                    await attempt.awaitResult(
                        start: { requester.requestAccess(completion: $0) },
                        cleanup: { requester.cancel() }
                    )
                }
            )
        }
        assertTrue(await awaitAudioPermissionCondition { fake.counts.starts == 1 }, "fresh probe should start its injected capture")
        // Exercise the real requester's quiet-frame classification, not a
        // synthetic .silentAudio result supplied directly to the decision.
        fake.emit(.silentFrames)
        let decision = await decisionTask.value

        assertTrue(decision.canProceed, "a quiet new install can start without mandatory playback")
        assertEqual(decision.state, .unknown, "silent PCM must not persist a verified permission grant")
        assertEqual(decision.probeResult, .indeterminate(.silentAudio), "tentative startup retains its evidence limit")
        assertEqual(
            MeetingRecordingStartGate.evaluate(microphoneGranted: true, systemAudioRecordingGranted: decision.canProceed),
            .allowed,
            "meeting preflight must use canProceed, not mistake an unknown cached grant for a blocked quiet capture"
        )
        assertEqual(TranscriptedPermissionAccess.systemAudioRecordingStatus(), .unknown, "a provisional start must leave the persisted permission state unknown")
        assertNil(UserDefaults.standard.object(forKey: knownKey), "quiet frames must not create a known permission decision")
        assertNil(UserDefaults.standard.object(forKey: grantedKey), "quiet frames must not create a cached grant")
        assertNil(UserDefaults.standard.object(forKey: onboardingKey), "probing access must not complete onboarding")
        assertTrue(await awaitAudioPermissionCondition { fake.counts.stops == 1 }, "the permission probe must stop after the bounded observation")
    }

    await runSuite("Fresh meeting start — a callback-free backend failure remains blocked") {
        let originalKnown = UserDefaults.standard.object(forKey: knownKey)
        let originalGranted = UserDefaults.standard.object(forKey: grantedKey)
        defer {
            restore(originalKnown, forKey: knownKey)
            restore(originalGranted, forKey: grantedKey)
        }
        UserDefaults.standard.removeObject(forKey: knownKey)
        UserDefaults.standard.removeObject(forKey: grantedKey)

        let fake = AudioPermissionCaptureFake()
        let requester = SystemAudioPermissionRequester(
            prepare: fake.prepare, start: fake.start, stop: fake.stop,
            silenceObservationDelay: 0.01
        )
        defer { requester.cancel() }
        let attempt = SystemAudioPermissionRequestAttempt(timeoutNanoseconds: 2_000_000_000)
        let decisionTask = Task { @MainActor in
            await TranscriptedPermissionAccess.systemAudioRecordingAccessDecision(
                forceRefresh: true,
                probeRequester: {
                    await attempt.awaitResult(
                        start: { requester.requestAccess(completion: $0) },
                        cleanup: { requester.cancel() }
                    )
                }
            )
        }
        assertTrue(await awaitAudioPermissionCondition { fake.counts.starts == 1 }, "capture setup should complete before the backend watchdog fails")
        // No PCM callback is delivered: device startup alone is not the
        // silent-but-running evidence that permits provisional capture.
        requester.handleBackendError("System audio failed - no audio buffers after reconnecting.")
        let decision = await decisionTask.value

        assertEqual(decision.probeResult, .indeterminate(.startCapture), "missing buffers must remain a capture-service failure, not quiet-running evidence")
        assertFalse(decision.canProceed, "a fresh install with no working capture must remain blocked")
        assertEqual(decision.state, .unknown, "a backend failure is not proof of TCC denial")
        assertFalse(
            MeetingRecordingStartGate.evaluate(microphoneGranted: true, systemAudioRecordingGranted: decision.canProceed).canStart,
            "the quiet-capture allowance must not bypass the meeting health guard for missing buffers"
        )
        assertNil(UserDefaults.standard.object(forKey: knownKey), "transport failure must not persist a known permission decision")
        assertNil(UserDefaults.standard.object(forKey: grantedKey), "transport failure must not cache a grant")
        assertTrue(await awaitAudioPermissionCondition { fake.counts.stops == 1 }, "failed probes must clean up their injected capture")
    }

    for probeResult: TranscriptedPermissionAccess.SystemAudioPermissionProbeResult in [.explicitlyDenied, .indeterminate(.cancelled)] {
        await runSuite("Fresh meeting start — \(probeResult.diagnosticName) stays blocked") {
            let originalKnown = UserDefaults.standard.object(forKey: knownKey)
            let originalGranted = UserDefaults.standard.object(forKey: grantedKey)
            defer {
                restore(originalKnown, forKey: knownKey)
                restore(originalGranted, forKey: grantedKey)
            }
            UserDefaults.standard.removeObject(forKey: knownKey)
            UserDefaults.standard.removeObject(forKey: grantedKey)

            // Explicit denial is a typed policy control; generic Core Audio
            // errors must not be relabeled as definitive TCC denials.
            let decision = await TranscriptedPermissionAccess.systemAudioRecordingAccessDecision(
                forceRefresh: true, probeRequester: { probeResult }
            )
            assertEqual(decision.probeResult, probeResult, "the terminal decision must preserve its evidence")
            assertFalse(decision.canProceed, "denial or cancellation must block this fresh start")
            assertFalse(
                MeetingRecordingStartGate.evaluate(microphoneGranted: true, systemAudioRecordingGranted: decision.canProceed).canStart,
                "meeting preflight must not reinterpret a blocked permission decision as allowed"
            )
            assertEqual(decision.state, probeResult == .explicitlyDenied ? .denied : .unknown, "only explicit denial may make the fresh permission state known")
            assertFalse(UserDefaults.standard.bool(forKey: grantedKey), "blocked starts must not create a cached grant")
            assertEqual(UserDefaults.standard.bool(forKey: knownKey), probeResult == .explicitlyDenied, "cancellation must not persist a denial")
        }
    }

    runSuite("Core Audio cache migration — preserves existing users without forcing permission changes") {
        let keys = [knownKey, grantedKey]
        let originals = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, originals) { restore(value, forKey: key) }
        }
        UserDefaults.standard.set(true, forKey: "systemAudioRecordingPermissionKnown")
        UserDefaults.standard.set(true, forKey: "systemAudioRecordingPermissionGranted")
        assertEqual(TranscriptedPermissionAccess.systemAudioRecordingStatus(), .granted, "existing users keep their historical verified state, not a new permission proof")
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

    runSuite("SystemAudioPermissionProbeClassifier — device errors do not impersonate TCC denial") {
        let explicitDenial = NSError(
            domain: "CoreAudioSystemAudioCapture",
            code: Int(kAudioDevicePermissionsError)
        )
        let transientStartFailure = NSError(
            domain: "CoreAudioSystemAudioCapture",
            code: Int(kAudioHardwareUnspecifiedError)
        )
        let unrelatedFailure = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)

        assertEqual(
            SystemAudioPermissionProbeClassifier.result(for: explicitDenial, stage: .startCapture),
            .indeterminate(.startCapture),
            "device permission or hog-mode errors are not definitive TCC denial"
        )
        assertEqual(
            SystemAudioPermissionProbeClassifier.result(for: transientStartFailure, stage: .startCapture),
            .indeterminate(.startCapture),
            "a Core Audio transport/start failure should not impersonate TCC denial"
        )
        assertEqual(
            SystemAudioPermissionProbeClassifier.result(for: unrelatedFailure, stage: .shareableContent),
            .indeterminate(.shareableContent),
            "unrelated service failures should remain indeterminate"
        )
        assertEqual(
            SystemAudioPermissionProbeClassifier.result(
                for: NSError(domain: NSCocoaErrorDomain, code: Int(kAudioDevicePermissionsError)),
                stage: .startCapture
            ),
            .indeterminate(.startCapture),
            "a matching numeric error from another domain is not permission evidence"
        )
    }

    runSuite("System audio onboarding — distinguish approval checks from verified audio") {
        let initial = TranscriptedPermissionKind.systemAudioOnboardingPresentation(state: .unknown, result: nil, isChecking: false)
        assertEqual(initial.actionTitle, "Grant", "untouched setup offers the initial request")
        assertFalse(initial.isVerified, "unknown is not granted")
        let checking = TranscriptedPermissionKind.systemAudioOnboardingPresentation(state: .unknown, result: nil, isChecking: true)
        assertEqual(checking.actionTitle, "Checking…", "an in-flight request is visible")
        for stage in TranscriptedPermissionAccess.SystemAudioPermissionProbeStage.allCases {
            let unverified = TranscriptedPermissionKind.systemAudioOnboardingPresentation(state: .unknown, result: .indeterminate(stage), isChecking: false)
            assertEqual(unverified.actionTitle, "Check", "inconclusive checks must not loop back to Grant")
            assertFalse(unverified.isVerified, "silence and transport errors must not manufacture consent")
            assertTrue(unverified.summary.contains("Not yet verified"), "uncertainty must be visible")
            assertTrue(unverified.summary.contains("continue"), "optional verification must not block onboarding")
        }
        let granted = TranscriptedPermissionKind.systemAudioOnboardingPresentation(state: .granted, result: .indeterminate(.silentAudio), isChecking: false)
        assertTrue(granted.isVerified, "verified cache wins over older inconclusive evidence")
        assertEqual(granted.actionTitle, "Granted", "verified access renders success")
        let denied = TranscriptedPermissionKind.systemAudioOnboardingPresentation(state: .denied, result: .explicitlyDenied, isChecking: false)
        assertFalse(denied.isVerified, "denial remains unverified")
        assertTrue(denied.summary.contains("Settings"), "explicit denial explains recovery")
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

    // macOS's own recorded answer is the only signal that can tell Don't
    // Allow from a quiet Mac. It must correct the cache in both directions.
    let tccCases: [(SystemAudioCaptureTCCStatus, TranscriptedPermissionAccess.SystemAudioPermissionState, TranscriptedPermissionAccess.SystemAudioPermissionState)] = [
        (.denied, .granted, .denied),
        (.authorized, .denied, .granted),
        (.authorized, .unknown, .granted),
        (.notDetermined, .granted, .unknown),
        (.unavailable, .granted, .granted),
        (.unavailable, .unknown, .unknown),
    ]
    for (systemStatus, cached, expected) in tccCases {
        runSuite("System audio status from macOS — \(systemStatus.rawValue) over cached \(cached)") {
            let originalKnown = UserDefaults.standard.object(forKey: knownKey)
            let originalGranted = UserDefaults.standard.object(forKey: grantedKey)
            defer {
                restore(originalKnown, forKey: knownKey)
                restore(originalGranted, forKey: grantedKey)
            }
            switch cached {
            case .granted:
                UserDefaults.standard.set(true, forKey: knownKey)
                UserDefaults.standard.set(true, forKey: grantedKey)
            case .denied:
                UserDefaults.standard.set(true, forKey: knownKey)
                UserDefaults.standard.set(false, forKey: grantedKey)
            case .unknown:
                UserDefaults.standard.removeObject(forKey: knownKey)
                UserDefaults.standard.removeObject(forKey: grantedKey)
            }

            let returned = TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem(
                tcc: SystemAudioCaptureTCC(preflight: { systemStatus }, request: { nil })
            )
            assertEqual(returned, systemStatus, "the caller sees macOS's answer as read")
            assertEqual(TranscriptedPermissionAccess.systemAudioRecordingStatus(), expected,
                "a real macOS answer replaces the cache; an unavailable read leaves it alone")
        }
    }

    for macOSAnswer: Bool? in [true, false, nil] {
        await runSuite("System audio macOS box — answer \(String(describing: macOSAnswer)) is recorded") {
            let originalKnown = UserDefaults.standard.object(forKey: knownKey)
            let originalGranted = UserDefaults.standard.object(forKey: grantedKey)
            defer {
                restore(originalKnown, forKey: knownKey)
                restore(originalGranted, forKey: grantedKey)
            }
            UserDefaults.standard.removeObject(forKey: knownKey)
            UserDefaults.standard.removeObject(forKey: grantedKey)

            var activations = 0
            let granted = await TranscriptedPermissionAccess.requestSystemAudioCaptureAccess(
                tcc: SystemAudioCaptureTCC(preflight: { .notDetermined }, request: { macOSAnswer }),
                activateForPrompt: { activations += 1 }
            )
            assertEqual(granted, macOSAnswer, "the user's answer comes back unchanged")
            assertEqual(activations, 1, "Transcripted comes forward so the macOS box isn't hidden")
            let expected: TranscriptedPermissionAccess.SystemAudioPermissionState
            switch macOSAnswer {
            case .some(true): expected = .granted
            case .some(false): expected = .denied
            case .none: expected = .unknown
            }
            assertEqual(TranscriptedPermissionAccess.systemAudioRecordingStatus(), expected,
                "Allow and Don't Allow are both remembered; no answer changes nothing")
        }
    }
}

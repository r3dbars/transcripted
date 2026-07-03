import Foundation
import EventKit

@MainActor
private final class PermissionRequestBox {
    var callCount = 0
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
            TranscriptedPermissionKind.screenRecordingActionTitle(isGranted: false),
            "Open Screen Recording Settings",
            "screen recording action should point to the distinct Screen Recording TCC pane"
        )
        assertEqual(
            TranscriptedPermissionKind.calendarActionTitle(for: .notDetermined),
            "Allow Calendar Access",
            "calendar action should stay prompt-like before the first decision"
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

    await runSuite("TranscriptedPermissionAccess.requestScreenRecordingAccessIfNeeded — skips requester when already granted") {
        let requestBox = PermissionRequestBox()
        let granted = await TranscriptedPermissionAccess.requestScreenRecordingAccessIfNeeded(
            preflight: { true },
            activateForPrompt: {},
            requester: {
                requestBox.callCount += 1
                return false
            }
        )

        assertTrue(granted, "granted screen recording access should return true")
        assertEqual(requestBox.callCount, 0, "granted screen recording access should not prompt again")
    }

    await runSuite("TranscriptedPermissionAccess.requestScreenRecordingAccessIfNeeded — asks once when missing") {
        let requestBox = PermissionRequestBox()
        let granted = await TranscriptedPermissionAccess.requestScreenRecordingAccessIfNeeded(
            preflight: { false },
            activateForPrompt: {},
            requester: {
                requestBox.callCount += 1
                return true
            }
        )

        assertTrue(granted, "missing screen recording access should return the requester result")
        assertEqual(requestBox.callCount, 1, "missing screen recording access should ask macOS once")
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
}

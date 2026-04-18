import Foundation

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
            TranscriptedPermissionKind.calendarActionTitle(for: .notDetermined),
            "Allow Calendar Access",
            "calendar action should stay prompt-like before the first decision"
        )
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

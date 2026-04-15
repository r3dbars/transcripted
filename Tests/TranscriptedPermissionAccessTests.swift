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
            TranscriptedPermissionKind.systemAudioRecordingActionTitle(isGranted: false),
            "Open Audio Recording Settings",
            "system audio action should explain the destination when the permission is still missing"
        )
        assertEqual(
            TranscriptedPermissionKind.calendarActionTitle(for: .notDetermined),
            "Allow Calendar Access",
            "calendar action should stay prompt-like before the first decision"
        )
    }
}

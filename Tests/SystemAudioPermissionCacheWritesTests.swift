import Foundation

/// Re-reading macOS's System Audio Recording answer on every app activation
/// doesn't rewrite unchanged defaults (each write notifies the whole app),
/// and the cached answer stays the same.
func testSystemAudioPermissionCacheWrites() {
    let knownKey = "systemAudioRecordingPermissionKnown"
    let grantedKey = "systemAudioRecordingPermissionGranted"

    func countingDefaultsChanges(_ body: () -> Void) -> Int {
        var count = 0
        let observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: nil
        ) { _ in count += 1 }
        body()
        NotificationCenter.default.removeObserver(observer)
        return count
    }
    func tcc(_ status: SystemAudioCaptureTCCStatus) -> SystemAudioCaptureTCC {
        SystemAudioCaptureTCC(preflight: { status }, request: { nil })
    }

    runSuite("System audio cache - a repeated macOS answer writes nothing") {
        let originals = [knownKey, grantedKey].map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip([knownKey, grantedKey], originals) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        UserDefaults.standard.removeObject(forKey: knownKey)
        UserDefaults.standard.removeObject(forKey: grantedKey)

        let first = countingDefaultsChanges {
            TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem(tcc: tcc(.authorized))
        }
        assertTrue(first > 0, "the first grant is recorded")
        assertEqual(TranscriptedPermissionAccess.systemAudioRecordingStatus(), .granted, "granted after the first read")

        let repeated = countingDefaultsChanges {
            TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem(tcc: tcc(.authorized))
        }
        assertEqual(repeated, 0, "the same answer again writes nothing")
        assertEqual(TranscriptedPermissionAccess.systemAudioRecordingStatus(), .granted, "still granted")

        let denied = countingDefaultsChanges {
            TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem(tcc: tcc(.denied))
        }
        assertTrue(denied > 0, "a changed answer is recorded")
        assertEqual(TranscriptedPermissionAccess.systemAudioRecordingStatus(), .denied, "denied replaces the grant")

        let reset = countingDefaultsChanges {
            TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem(tcc: tcc(.notDetermined))
        }
        assertTrue(reset > 0, "a reset clears the cache")
        assertNil(UserDefaults.standard.object(forKey: knownKey), "known cleared")
        assertNil(UserDefaults.standard.object(forKey: grantedKey), "grant cleared")
        assertEqual(TranscriptedPermissionAccess.systemAudioRecordingStatus(), .unknown, "nothing known after a reset")

        let resetAgain = countingDefaultsChanges {
            TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem(tcc: tcc(.notDetermined))
        }
        assertEqual(resetAgain, 0, "clearing an empty cache writes nothing")
    }
}

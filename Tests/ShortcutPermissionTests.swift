import Foundation

func testShortcutPermission() {
    runSuite("Shortcut registration — denied access never touches the protected event tap") {
        var attempts = 0
        for _ in 0..<3 {
            let error = PhysicalShortcutTriggerStatus.installIfGranted(accessibilityGranted: false) {
                attempts += 1
                return nil
            }
            assertEqual(error, PhysicalShortcutTriggerStatus.accessibilityPermissionErrorMessage,
                "launch, wake and re-registration keep a passive permission status")
        }
        assertEqual(attempts, 0, "denial must prevent the OS call, not merely report its failure")

        let error = PhysicalShortcutTriggerStatus.installIfGranted(accessibilityGranted: true) {
            attempts += 1
            return nil
        }
        assertNil(error, "granting access later enables shortcuts without resetting preferences")
        assertEqual(attempts, 1, "the granted registration installs once")
    }

    runSuite("Shortcut registration — a revoked grant blocks subsequent tap installation") {
        var attempts = 0
        for granted in [true, false, false, true] {
            _ = PhysicalShortcutTriggerStatus.installIfGranted(accessibilityGranted: granted) {
                attempts += 1
                return nil
            }
        }
        assertEqual(attempts, 2, "only registrations while access is granted reach the OS")
        let error = PhysicalShortcutTriggerStatus.installIfGranted(accessibilityGranted: true) {
            PhysicalShortcutTriggerStatus.failedToStartMessage
        }
        assertEqual(error, PhysicalShortcutTriggerStatus.failedToStartMessage,
            "a real installation failure is preserved")
    }

}

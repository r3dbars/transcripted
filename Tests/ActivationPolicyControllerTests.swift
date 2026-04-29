import AppKit
import Foundation

@MainActor
func testActivationPolicyController() async {
    runSuite("ActivationPolicyDecision returns .regular when Dock visibility is on and both sessions are idle") {
        let policy = ActivationPolicyDecision.desiredPolicy(
            showInDock: true,
            isMeetingRecording: false,
            isDictationRecording: false
        )
        assertEqual(policy, .regular, "Dock visibility should keep the app regular while idle")
    }

    runSuite("ActivationPolicyDecision returns .accessory when Dock visibility is off and both sessions are idle") {
        let policy = ActivationPolicyDecision.desiredPolicy(
            showInDock: false,
            isMeetingRecording: false,
            isDictationRecording: false
        )
        assertEqual(policy, .accessory, "idle app should stay menu-bar-only when the Dock toggle is off")
    }

    runSuite("ActivationPolicyDecision returns .regular when a meeting is recording") {
        let policy = ActivationPolicyDecision.desiredPolicy(
            showInDock: false,
            isMeetingRecording: true,
            isDictationRecording: false
        )
        assertEqual(policy, .regular, "meeting recording should force a visible Dock presence")
    }

    runSuite("ActivationPolicyDecision returns .regular when a dictation is recording") {
        let policy = ActivationPolicyDecision.desiredPolicy(
            showInDock: false,
            isMeetingRecording: false,
            isDictationRecording: true
        )
        assertEqual(policy, .regular, "dictation recording should force a visible Dock presence")
    }

    runSuite("DockVisibilityPreferences defaults to visible") {
        let (defaults, suiteName) = makeDockVisibilityDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertTrue(
            DockVisibilityPreferences.isVisible(userDefaults: defaults),
            "new installs should keep the current Dock-visible behavior"
        )
    }

    runSuite("DockVisibilityPreferences persists explicit hidden state") {
        let (defaults, suiteName) = makeDockVisibilityDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DockVisibilityPreferences.setVisible(false, userDefaults: defaults)

        assertFalse(
            DockVisibilityPreferences.isVisible(userDefaults: defaults),
            "Dock preference should round-trip through injected defaults"
        )
    }

    runSuite("DockVisibilityPreferences uses a stable storage key") {
        assertEqual(
            DockVisibilityPreferences.showInDockKey,
            "show-transcripted-in-dock",
            "storage key must stay stable across releases"
        )
    }

    runSuite("ActivationPolicyController applies initial .regular policy when Dock visibility is on") {
        let recorder = PolicyRecorder()
        _ = ActivationPolicyController(showInDock: true) { policy in
            recorder.append(policy)
        }
        assertEqual(recorder.history, [.regular], "init applies the regular policy exactly once")
    }

    runSuite("ActivationPolicyController applies initial .accessory policy when Dock visibility is off") {
        let recorder = PolicyRecorder()
        _ = ActivationPolicyController(showInDock: false) { policy in
            recorder.append(policy)
        }
        assertEqual(recorder.history, [.accessory], "idle hidden-Dock mode should start as menu-bar-only")
    }

    runSuite("ActivationPolicyController promotes hidden-Dock mode to .regular while a meeting records") {
        let recorder = PolicyRecorder()
        let controller = ActivationPolicyController(showInDock: false) { policy in
            recorder.append(policy)
        }

        controller.setMeetingRecording(true)

        assertEqual(recorder.history, [.accessory, .regular], "meeting start should surface the app in the Dock")
        assertEqual(controller.currentPolicy, .regular, "controller should stay regular while recording")
    }

    runSuite("ActivationPolicyController demotes hidden-Dock mode after recording stops") {
        let recorder = PolicyRecorder()
        let controller = ActivationPolicyController(showInDock: false) { policy in
            recorder.append(policy)
        }

        controller.setMeetingRecording(true)
        controller.setMeetingRecording(false)

        assertEqual(
            recorder.history,
            [.accessory, .regular, .accessory],
            "hidden-Dock mode should return to menu-bar-only when recording ends"
        )
    }

    runSuite("ActivationPolicyController keeps hidden-Dock mode visible across overlapping sessions") {
        let recorder = PolicyRecorder()
        let controller = ActivationPolicyController(showInDock: false) { policy in
            recorder.append(policy)
        }

        controller.setMeetingRecording(true)
        controller.setDictationRecording(true)
        controller.setMeetingRecording(false)
        controller.setDictationRecording(false)

        assertEqual(
            recorder.history,
            [.accessory, .regular, .accessory],
            "overlapping recordings should only surface once and hide once"
        )
    }

    runSuite("ActivationPolicyController can toggle Dock visibility while idle") {
        let recorder = PolicyRecorder()
        let controller = ActivationPolicyController(showInDock: false) { policy in
            recorder.append(policy)
        }

        controller.setShowInDock(true)
        controller.setShowInDock(false)

        assertEqual(
            recorder.history,
            [.accessory, .regular, .accessory],
            "Dock toggle should promote and demote the app while idle"
        )
    }

    runSuite("ActivationPolicyController coalesces redundant flag updates") {
        let recorder = PolicyRecorder()
        let controller = ActivationPolicyController(showInDock: false) { policy in
            recorder.append(policy)
        }

        controller.setMeetingRecording(false)
        controller.setDictationRecording(false)
        controller.setShowInDock(false)
        controller.setMeetingRecording(true)
        controller.setMeetingRecording(true)

        assertEqual(recorder.history, [.accessory, .regular], "redundant updates should not re-apply policy")
    }
}

/// Captures the sequence of activation policies applied by a controller.
/// `@MainActor` because the controller is `@MainActor` and synchronously
/// invokes the `applyPolicy` closure during init/updates.
@MainActor
private final class PolicyRecorder {
    private(set) var history: [NSApplication.ActivationPolicy] = []

    func append(_ policy: NSApplication.ActivationPolicy) {
        history.append(policy)
    }
}

private func makeDockVisibilityDefaults() -> (UserDefaults, String) {
    let suiteName = "DockVisibilityPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

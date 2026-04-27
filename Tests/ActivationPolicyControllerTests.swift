import AppKit
import Foundation

@MainActor
func testActivationPolicyController() async {
    runSuite("ActivationPolicyDecision returns .accessory when both sessions are idle") {
        let policy = ActivationPolicyDecision.desiredPolicy(
            isMeetingRecording: false,
            isDictationRecording: false
        )
        assertEqual(policy, .accessory, "idle app stays a menubar agent")
    }

    runSuite("ActivationPolicyDecision returns .regular when a meeting is recording") {
        let policy = ActivationPolicyDecision.desiredPolicy(
            isMeetingRecording: true,
            isDictationRecording: false
        )
        assertEqual(policy, .regular, "meeting session promotes the app to .regular for force-quit visibility")
    }

    runSuite("ActivationPolicyDecision returns .regular when a dictation is recording") {
        let policy = ActivationPolicyDecision.desiredPolicy(
            isMeetingRecording: false,
            isDictationRecording: true
        )
        assertEqual(policy, .regular, "dictation session promotes the app the same way")
    }

    runSuite("ActivationPolicyDecision returns .regular when both sessions are recording") {
        let policy = ActivationPolicyDecision.desiredPolicy(
            isMeetingRecording: true,
            isDictationRecording: true
        )
        assertEqual(policy, .regular, "any active session keeps us in .regular")
    }

    await runSuite("ActivationPolicyController applies initial policy at init") {
        let recorder = PolicyRecorder()
        _ = ActivationPolicyController(
            initialPolicy: .accessory,
            applyPolicy: { policy in recorder.append(policy) }
        )
        assertEqual(recorder.history, [.accessory], "init applies initial policy exactly once")
    }

    await runSuite("ActivationPolicyController switches to .regular when a meeting starts") {
        let recorder = PolicyRecorder()
        let controller = ActivationPolicyController(
            initialPolicy: .accessory,
            applyPolicy: { policy in recorder.append(policy) }
        )

        controller.setMeetingRecording(true)

        assertEqual(recorder.history, [.accessory, .regular], "meeting on flips to .regular")
        assertEqual(controller.currentPolicy, .regular, "controller tracks current policy")
    }

    await runSuite("ActivationPolicyController returns to .accessory when meeting stops with no other session") {
        let recorder = PolicyRecorder()
        let controller = ActivationPolicyController(
            initialPolicy: .accessory,
            applyPolicy: { policy in recorder.append(policy) }
        )

        controller.setMeetingRecording(true)
        controller.setMeetingRecording(false)

        assertEqual(recorder.history, [.accessory, .regular, .accessory], "stop without overlapping session restores .accessory")
    }

    await runSuite("ActivationPolicyController stays .regular while either session is active") {
        let recorder = PolicyRecorder()
        let controller = ActivationPolicyController(
            initialPolicy: .accessory,
            applyPolicy: { policy in recorder.append(policy) }
        )

        controller.setMeetingRecording(true)        // accessory -> regular
        controller.setDictationRecording(true)      // already regular, no apply
        controller.setMeetingRecording(false)       // dictation still active, stays regular
        controller.setDictationRecording(false)     // both off, back to accessory

        assertEqual(
            recorder.history,
            [.accessory, .regular, .accessory],
            "policy only changes when the OR of sessions flips; intermediate flag changes do not bounce the Dock"
        )
    }

    await runSuite("ActivationPolicyController coalesces redundant flag updates") {
        let recorder = PolicyRecorder()
        let controller = ActivationPolicyController(
            initialPolicy: .accessory,
            applyPolicy: { policy in recorder.append(policy) }
        )

        controller.setMeetingRecording(false)    // already false; no apply
        controller.setDictationRecording(false)  // already false; no apply
        controller.setMeetingRecording(true)     // accessory -> regular
        controller.setMeetingRecording(true)     // already true; no apply

        assertEqual(recorder.history, [.accessory, .regular], "redundant updates do not re-apply policy")
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

import AppKit
import Foundation

@MainActor
func testActivationPolicyController() async {
    runSuite("ActivationPolicyDecision returns .regular when both sessions are idle") {
        let policy = ActivationPolicyDecision.desiredPolicy(
            isMeetingRecording: false,
            isDictationRecording: false
        )
        assertEqual(policy, .regular, "app keeps a permanent Dock presence even when idle")
    }

    runSuite("ActivationPolicyDecision returns .regular when a meeting is recording") {
        let policy = ActivationPolicyDecision.desiredPolicy(
            isMeetingRecording: true,
            isDictationRecording: false
        )
        assertEqual(policy, .regular, "meeting session keeps the app visible in force-quit / Dock")
    }

    runSuite("ActivationPolicyDecision returns .regular when a dictation is recording") {
        let policy = ActivationPolicyDecision.desiredPolicy(
            isMeetingRecording: false,
            isDictationRecording: true
        )
        assertEqual(policy, .regular, "dictation session keeps the app visible in force-quit / Dock")
    }

    runSuite("ActivationPolicyDecision returns .regular when both sessions are recording") {
        let policy = ActivationPolicyDecision.desiredPolicy(
            isMeetingRecording: true,
            isDictationRecording: true
        )
        assertEqual(policy, .regular, "any combination of session flags resolves to .regular")
    }

    await runSuite("ActivationPolicyController applies initial .regular policy at init") {
        let recorder = PolicyRecorder()
        _ = ActivationPolicyController(
            initialPolicy: .regular,
            applyPolicy: { policy in recorder.append(policy) }
        )
        assertEqual(recorder.history, [.regular], "init applies initial policy exactly once")
    }

    await runSuite("ActivationPolicyController stays .regular when a meeting starts") {
        let recorder = PolicyRecorder()
        let controller = ActivationPolicyController(
            initialPolicy: .regular,
            applyPolicy: { policy in recorder.append(policy) }
        )

        controller.setMeetingRecording(true)

        assertEqual(recorder.history, [.regular], "meeting on does not bounce the activation policy")
        assertEqual(controller.currentPolicy, .regular, "controller stays .regular")
    }

    await runSuite("ActivationPolicyController stays .regular when meeting stops") {
        let recorder = PolicyRecorder()
        let controller = ActivationPolicyController(
            initialPolicy: .regular,
            applyPolicy: { policy in recorder.append(policy) }
        )

        controller.setMeetingRecording(true)
        controller.setMeetingRecording(false)

        assertEqual(recorder.history, [.regular], "session lifecycle never demotes the app from .regular")
    }

    await runSuite("ActivationPolicyController stays .regular across overlapping sessions") {
        let recorder = PolicyRecorder()
        let controller = ActivationPolicyController(
            initialPolicy: .regular,
            applyPolicy: { policy in recorder.append(policy) }
        )

        controller.setMeetingRecording(true)
        controller.setDictationRecording(true)
        controller.setMeetingRecording(false)
        controller.setDictationRecording(false)

        assertEqual(
            recorder.history,
            [.regular],
            "no combination of overlapping session flags should demote the activation policy"
        )
    }

    await runSuite("ActivationPolicyController coalesces redundant flag updates") {
        let recorder = PolicyRecorder()
        let controller = ActivationPolicyController(
            initialPolicy: .regular,
            applyPolicy: { policy in recorder.append(policy) }
        )

        controller.setMeetingRecording(false)
        controller.setDictationRecording(false)
        controller.setMeetingRecording(true)
        controller.setMeetingRecording(true)

        assertEqual(recorder.history, [.regular], "redundant updates do not re-apply policy")
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

// DictationQueuedStartPolicyTests.swift
// A dictation press while the last take is still finishing waits for it
// (up to a short limit) instead of being refused.

import Foundation

func testDictationQueuedStartPolicy() {
    runSuite("A remembered press starts as soon as the last take finishes") {
        assertEqual(
            DictationQueuedStartPolicy.decision(previousStillFinishing: false, previousLeftMessage: false, secondsWaited: 0.2),
            .start,
            "finished quickly: start now"
        )
        assertEqual(
            DictationQueuedStartPolicy.decision(previousStillFinishing: false, previousLeftMessage: false, secondsWaited: 1.9),
            .start,
            "finished just inside the wait: start now"
        )
    }

    runSuite("A remembered press waits a short time, then gives up") {
        assertEqual(
            DictationQueuedStartPolicy.decision(previousStillFinishing: true, previousLeftMessage: false, secondsWaited: 1),
            .keepWaiting,
            "still finishing inside the wait"
        )
        assertEqual(
            DictationQueuedStartPolicy.decision(
                previousStillFinishing: true,
                previousLeftMessage: false,
                secondsWaited: DictationQueuedStartPolicy.waitSeconds
            ),
            .giveUp,
            "still finishing at the limit: fall back to the old message"
        )
        assertTrue(DictationQueuedStartPolicy.waitSeconds <= 3, "the wait stays short so a press never feels lost")
    }

    runSuite("A remembered press never starts over the last take's message") {
        assertEqual(
            DictationQueuedStartPolicy.decision(previousStillFinishing: false, previousLeftMessage: true, secondsWaited: 0.3),
            .dropForMessage,
            "a failed or copied-only take keeps its message and its button"
        )
    }

    runSuite("Only shortcut presses are remembered") {
        assertTrue(DictationQueuedStartPolicy.remembersPress(shortcutMode: .pushToTalk), "push-to-talk press")
        assertTrue(DictationQueuedStartPolicy.remembersPress(shortcutMode: .handsFree), "hands-free press")
        assertFalse(DictationQueuedStartPolicy.remembersPress(shortcutMode: nil), "menu clicks keep the old message")
    }

    runSuite("The controller routes presses during a finishing take through the queue") {
        let controller = readSourceFixture("Sources/UI/Overlay/DictationSessionController.swift")
        let engine = readSourceFixture("Sources/Capture/ContextCaptureEngine.swift")
        assertTrue(
            engine.contains("session.rememberStartPressIfFinishing(")
                && engine.contains("if session.dropQueuedPushToTalkStart() { return }"),
            "push-to-talk press and release both go through the queue"
        )
        assertTrue(
            controller.contains("shortcutMode == .handsFree,\n           rememberStartPressIfFinishing("),
            "a hands-free press after the take stopped asks for the next take instead of another stop"
        )
        assertTrue(
            controller.contains("dropQueuedDictationStart(showMessage: false)\n"),
            "Esc and quit drop a waiting start"
        )
        assertTrue(
            controller.contains("guard !isTerminatingDictation,"),
            "a press while Quit waits must not queue a new recording"
        )
        assertTrue(
            controller.contains("overlayController?.onEscapeKeyDuringSession = { [weak self] in\n                self?.dropQueuedDictationStart(showMessage: false)"),
            "the first Esc of a confirm already takes back a waiting start"
        )
        assertTrue(
            controller.contains("!$0.errorMessage.isEmpty && !$0.messageCanGiveWayToNextStart"),
            "a passing note (no speech heard, press Return to send) doesn't hold back the next take"
        )
        let overlay = readSourceFixture("Sources/UI/Overlay/FloatingOverlayController.swift")
        assertTrue(
            overlay.contains("messageTone = tone\n        messageCanGiveWayToNextStart = false"),
            "every other message keeps the next take from starting over it"
        )
        let termination = controller.components(separatedBy: "func finishDictationForTermination() async -> Bool").last ?? ""
        let terminationBody = termination.components(separatedBy: "// MARK: - Private").first ?? ""
        assertFalse(
            terminationBody.contains("defer { isTerminatingDictation = false }"),
            "an admitted Quit keeps blocking new takes until the app is gone"
        )
        assertTrue(
            controller.contains("if !canTerminate {\n            isTerminatingDictation = false"),
            "a refused Quit lets presses queue again"
        )
        assertTrue(
            controller.contains("if showMessage, !isDictating {"),
            "a dropped press never puts an error over a take that is still transcribing"
        )
    }
}

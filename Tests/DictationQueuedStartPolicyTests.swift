// DictationQueuedStartPolicyTests.swift
// A dictation press while the last take is still finishing waits for it
// (up to a short limit) instead of being refused.

import Foundation

func testDictationQueuedStartPolicy() {
    runSuite("A remembered press starts as soon as the last take finishes") {
        assertEqual(
            DictationQueuedStartPolicy.decision(previousStillFinishing: false, secondsWaited: 0.2),
            .start,
            "finished quickly: start now"
        )
        assertEqual(
            DictationQueuedStartPolicy.decision(previousStillFinishing: false, secondsWaited: 1.9),
            .start,
            "finished just inside the wait: start now"
        )
    }

    runSuite("A remembered press waits a short time, then gives up") {
        assertEqual(
            DictationQueuedStartPolicy.decision(previousStillFinishing: true, secondsWaited: 1),
            .keepWaiting,
            "still finishing inside the wait"
        )
        assertEqual(
            DictationQueuedStartPolicy.decision(
                previousStillFinishing: true,
                secondsWaited: DictationQueuedStartPolicy.waitSeconds
            ),
            .giveUp,
            "still finishing at the limit: fall back to the old message"
        )
        assertTrue(DictationQueuedStartPolicy.waitSeconds <= 3, "the wait stays short so a press never feels lost")
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
    }
}

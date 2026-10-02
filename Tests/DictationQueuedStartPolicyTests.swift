// DictationQueuedStartPolicyTests.swift
// A dictation press while the last take is still finishing waits for it
// (up to a short limit) instead of being refused.

import Foundation

@MainActor
func testDictationQueuedStartPolicy() async {
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

    runSuite("A Push to Talk press while the last take finishes is remembered, not started") {
        let session = HotkeySessionFake()
        session.remembers = true
        session.router.pushToTalkPressed()
        assertEqual(session.events, ["remember physical_key push_to_talk"], "the press waits for the take instead of being dropped")
    }

    runSuite("A Push to Talk release takes back a press that never started") {
        let session = HotkeySessionFake()
        session.hasQueuedPushToTalk = true
        session.isDictating = true
        session.router.pushToTalkReleased()
        assertEqual(session.events, ["drop queued push_to_talk"], "the release drops the waiting start and doesn't stop the take still finishing")
    }

    await runSuite("Quit drops a waiting start and stops new ones from queueing") {
        var gate = DictationQueuedStartGate()
        var events: [String] = []
        var pressAdmittedDuringQuit = true
        let admitted = await DictationTerminationFinisher.run(quitSteps(
            gate: { gate.setTerminating($0) },
            record: { events.append($0) },
            admitInactiveQuit: {
                pressAdmittedDuringQuit = gate.admitsPress(shortcutMode: .pushToTalk, previousIsFinishing: { true })
                return true
            }
        ))
        assertTrue(admitted, "Quit was admitted")
        assertEqual(events, ["drop queued"], "the waiting start is dropped as Quit begins")
        assertFalse(pressAdmittedDuringQuit, "a press while Quit waits must not queue a new recording")
        assertFalse(
            gate.admitsPress(shortcutMode: .handsFree, previousIsFinishing: { true }),
            "an admitted Quit keeps blocking new takes until the app is gone"
        )
    }

    await runSuite("A refused Quit lets presses queue again") {
        var gate = DictationQueuedStartGate()
        var steps = quitSteps(gate: { gate.setTerminating($0) }, record: { _ in }, admitInactiveQuit: { true })
        var dictating = true
        steps.isDictating = { dictating }
        steps.stop = { dictating = true }
        steps.waitForCheckpoint = { false }
        let admitted = await DictationTerminationFinisher.run(steps)
        assertFalse(admitted, "Quit was refused: the take's audio isn't saved yet")
        assertTrue(
            gate.admitsPress(shortcutMode: .pushToTalk, previousIsFinishing: { true }),
            "the user stays in the app, so the next press can wait for the take again"
        )
    }

    runSuite("Only a shortcut press during a finishing take is remembered") {
        let gate = DictationQueuedStartGate()
        assertTrue(gate.admitsPress(shortcutMode: .pushToTalk, previousIsFinishing: { true }), "shortcut press, take finishing")
        assertFalse(gate.admitsPress(shortcutMode: nil, previousIsFinishing: { true }), "a menu click keeps the old message")
        assertFalse(gate.admitsPress(shortcutMode: .handsFree, previousIsFinishing: { false }), "nothing finishing, nothing to wait for")
    }

    runSuite("A passing note doesn't hold back the next take; a real message does") {
        assertFalse(
            DictationQueuedStartPolicy.previousLeftMessage(isDrafting: true, errorMessage: "No speech heard", messageCanGiveWayToNextStart: true),
            "no speech heard, or press Return to send, gives way"
        )
        assertTrue(
            DictationQueuedStartPolicy.previousLeftMessage(isDrafting: true, errorMessage: "Copied. Press ⌘V to paste.", messageCanGiveWayToNextStart: false),
            "a copied-only or failed take keeps its message and its button"
        )
        assertFalse(
            DictationQueuedStartPolicy.previousLeftMessage(isDrafting: true, errorMessage: "", messageCanGiveWayToNextStart: false),
            "no message, nothing to protect"
        )
        assertFalse(
            DictationQueuedStartPolicy.previousLeftMessage(isDrafting: false, errorMessage: "Old error", messageCanGiveWayToNextStart: false),
            "a message only counts while the last take is still showing it"
        )
    }

    runSuite("A dropped press is still counted as a refused start") {
        var events: [String] = []
        DictationQueuedStartPolicy.drop(
            showMessage: false,
            isDictating: false,
            DictationQueuedStartPolicy.DropSteps(
                countRequest: { events.append("requested") },
                countRefusal: { events.append("refused \($0)") },
                showStillFinishing: { events.append("message") }
            )
        )
        assertEqual(
            events,
            ["requested", "refused previous_dictation_transcribing"],
            "a remembered press that never starts counts the way the old refusal did"
        )
    }

    runSuite("A dropped press never puts an error over a take that is still transcribing") {
        var shown: [Bool] = []
        for isDictating in [true, false] {
            var showed = false
            DictationQueuedStartPolicy.drop(
                showMessage: true,
                isDictating: isDictating,
                DictationQueuedStartPolicy.DropSteps(countRequest: {}, countRefusal: { _ in }, showStillFinishing: { showed = true })
            )
            shown.append(showed)
        }
        assertEqual(shown, [false, true], "quiet while the take is on screen, the old message once it's gone")
        assertFalse(DictationQueuedStartPolicy.showsDropMessage(requested: false, isDictating: false), "Esc and Quit drop quietly")
    }

    // Still source-text, deliberately. Both live where a fake can't reach yet:
    // the overlay's own message flag (FloatingOverlayController, which open
    // PR #1946 is rewriting) and the controller's Esc callback wiring. Convert
    // them once #1946 lands and the overlay has a testable message model.
    runSuite("Esc takes back a waiting start, and other messages hold back the next take") {
        let controller = readSourceFixture("Sources/UI/Overlay/DictationSessionController.swift")
        assertTrue(
            controller.contains("overlayController?.onEscapeKeyDuringSession = { [weak self] in\n                self?.dropQueuedDictationStart(showMessage: false)"),
            "the first Esc of a confirm already takes back a waiting start"
        )
        let overlay = readSourceFixture("Sources/UI/Overlay/FloatingOverlayController.swift")
        assertTrue(
            overlay.contains("messageTone = tone\n        messageCanGiveWayToNextStart = false"),
            "every other message keeps the next take from starting over it"
        )
    }
}

@MainActor
private func quitSteps(
    gate: @escaping @MainActor (Bool) -> Void,
    record: @escaping @MainActor (String) -> Void,
    admitInactiveQuit: @escaping @MainActor () -> Bool
) -> DictationTerminationFinisher.Steps {
    DictationTerminationFinisher.Steps(
        setTerminating: gate,
        dropQueuedStart: { record("drop queued") },
        isDictating: { false },
        admitInactiveQuit: admitInactiveQuit,
        stop: {},
        gracePolls: 1,
        sleepOnePoll: { true },
        preserveStoppedAudio: {},
        waitForCheckpoint: { true },
        canTerminateActive: { true },
        showError: { _ in },
        cancelPreservingStoppedAudio: {}
    )
}

/// A dictation session as the hotkey router sees it, recording the commands.
@MainActor
private final class HotkeySessionFake {
    var isDictating = false
    var remembers = false
    var hasQueuedPushToTalk = false
    private(set) var events: [String] = []

    var router: DictationHotkeyRouter {
        DictationHotkeyRouter(
            isDictating: { self.isDictating },
            rememberStartPressIfFinishing: { trigger, mode in
                guard self.remembers else { return false }
                self.events.append("remember \(trigger.rawValue) \(mode.rawValue)")
                return true
            },
            dropQueuedPushToTalkStart: {
                guard self.hasQueuedPushToTalk else { return false }
                self.events.append("drop queued push_to_talk")
                return true
            },
            start: { trigger, mode in self.events.append("start \(trigger.rawValue) \(mode.rawValue)") },
            stop: { trigger, mode in self.events.append("stop \(trigger.rawValue) \(mode.rawValue)") }
        )
    }
}

// DictationSessionCapWarningPolicyTests.swift
// The last-30-seconds warning before the 5-minute dictation cap: a live
// countdown, worded for the shortcut that started the take.

import Foundation

func testDictationSessionCapWarningPolicy() {
    runSuite("The cap warning only shows in the last 30 seconds") {
        assertFalse(DictationSessionCapWarningPolicy.shouldWarn(remainingSeconds: 45), "no warning with 45s left")
        assertTrue(DictationSessionCapWarningPolicy.shouldWarn(remainingSeconds: 30), "warn at exactly 30s")
        assertTrue(DictationSessionCapWarningPolicy.shouldWarn(remainingSeconds: 0.4), "still warning near the end")
    }

    runSuite("The cap countdown counts down and never reads 0s while recording") {
        assertEqual(
            DictationSessionCapWarningPolicy.notice(remainingSeconds: 30, shortcutMode: nil),
            "30s left",
            "starts at 30"
        )
        assertEqual(
            DictationSessionCapWarningPolicy.notice(remainingSeconds: 12.2, shortcutMode: nil),
            "13s left",
            "rounds up so the number drops as time passes"
        )
        assertEqual(
            DictationSessionCapWarningPolicy.notice(remainingSeconds: 0.1, shortcutMode: nil),
            "1s left",
            "never shows 0s"
        )
    }

    runSuite("The cap warning is worded for the shortcut in use") {
        let pushToTalk = DictationSessionCapWarningPolicy.notice(remainingSeconds: 20, shortcutMode: .pushToTalk)
        let handsFree = DictationSessionCapWarningPolicy.notice(remainingSeconds: 20, shortcutMode: .handsFree)
        assertEqual(pushToTalk, "20s left · let go to finish", "push-to-talk people hold a key")
        assertEqual(handsFree, "20s left · press to finish", "hands-free people press the shortcut again")
        for notice in [pushToTalk, handsFree] {
            assertFalse(notice.lowercased().contains("release the key"), "no key-release copy for hands-free")
            // Fits the cursor mini pill beside "Press Esc again to discard".
            assertTrue(notice.count <= DictationEscapeCancelPolicy.confirmNotice.count + 2, "\(notice) is too long for the mini pill")
        }
        assertFalse(
            DictationSessionCapWarningPolicy.announcement(shortcutMode: .handsFree).contains("Let go"),
            "VoiceOver copy follows the shortcut too"
        )
    }

    runSuite("Clearing the cap countdown leaves the Esc prompt alone") {
        assertTrue(
            DictationSessionCapWarningPolicy.isCapNotice(
                DictationSessionCapWarningPolicy.notice(remainingSeconds: 5, shortcutMode: .handsFree)
            ),
            "cap notices are recognized"
        )
        assertFalse(
            DictationSessionCapWarningPolicy.isCapNotice(DictationEscapeCancelPolicy.confirmNotice),
            "the Esc confirm prompt is not a cap notice"
        )
        assertFalse(
            DictationSessionCapWarningPolicy.isCapNotice(DictationQueuedStartPolicy.waitingNotice),
            "the queued-start notice is not a cap notice"
        )
    }
}

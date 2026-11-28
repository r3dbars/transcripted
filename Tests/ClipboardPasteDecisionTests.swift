// ClipboardPasteDecisionTests.swift
// Decision promises for clipboard snapshot/restore and unconfirmed-paste
// recovery. Inputs are plain snapshot facts; outputs are the plan the
// paster must follow.

import Foundation

func testClipboardPasteDecision() {
    runSuite("An unreadable exotic clipboard still pastes") {
        assertEqual(
            ClipboardPasteDecision.snapshotPastePlan(
                isComplete: false,
                cause: .unreadable,
                privacyPayloadMissing: false,
                hasCapturedRestorableData: false,
                changeCountMatches: true
            ),
            .paste,
            "file promises and other unreadable types must not block Cmd+V"
        )
    }

    runSuite("A timed-out lazy clipboard still pastes") {
        assertEqual(
            ClipboardPasteDecision.snapshotPastePlan(
                isComplete: false,
                cause: .timeout,
                privacyPayloadMissing: false,
                hasCapturedRestorableData: false,
                changeCountMatches: true
            ),
            .paste,
            "a stalled promised item must not skip paste-back"
        )
    }

    runSuite("A complete snapshot pastes") {
        assertEqual(
            ClipboardPasteDecision.snapshotPastePlan(
                isComplete: true,
                cause: nil,
                privacyPayloadMissing: false,
                hasCapturedRestorableData: false,
                changeCountMatches: true
            ),
            .paste,
            "a fully captured clipboard is borrowed as before"
        )
    }

    runSuite("A concealed password that could not be read still refuses paste") {
        assertEqual(
            ClipboardPasteDecision.snapshotPastePlan(
                isComplete: false,
                cause: .unreadable,
                privacyPayloadMissing: true,
                hasCapturedRestorableData: false,
                changeCountMatches: true
            ),
            .refuse(.unreadable),
            "a password-manager copy whose payload was not captured must stay put"
        )
    }

    runSuite("A clipboard that changed during the snapshot still refuses paste") {
        assertEqual(
            ClipboardPasteDecision.snapshotPastePlan(
                isComplete: true,
                cause: nil,
                privacyPayloadMissing: false,
                hasCapturedRestorableData: true,
                changeCountMatches: false
            ),
            .refuse(.changed),
            "a newer copy must not be overwritten even if the old snapshot looked complete"
        )
        assertEqual(
            ClipboardPasteDecision.snapshotPastePlan(
                isComplete: false,
                cause: .changed,
                privacyPayloadMissing: false,
                hasCapturedRestorableData: false,
                changeCountMatches: true
            ),
            .refuse(.changed),
            "a re-entrant or superseded snapshot must not borrow the clipboard"
        )
    }

    runSuite("A clipboard too large to set aside still refuses paste") {
        assertEqual(
            ClipboardPasteDecision.snapshotPastePlan(
                isComplete: false,
                cause: .tooLarge,
                privacyPayloadMissing: false,
                hasCapturedRestorableData: false,
                changeCountMatches: true
            ),
            .refuse(.tooLarge),
            "an oversized item with nothing restorable still blocks overwrite"
        )
        assertEqual(
            ClipboardPasteDecision.snapshotPastePlan(
                isComplete: false,
                cause: .tooLarge,
                privacyPayloadMissing: false,
                hasCapturedRestorableData: true,
                changeCountMatches: true
            ),
            .paste,
            "text captured next to an oversized item still pastes"
        )
    }

    runSuite("Captured representations are restored when possible") {
        assertTrue(
            ClipboardPasteDecision.shouldRestoreCapturedItems(
                isComplete: true,
                hasCapturedRestorableData: false
            ),
            "an empty complete clipboard is restored by clearing"
        )
        assertTrue(
            ClipboardPasteDecision.shouldRestoreCapturedItems(
                isComplete: false,
                hasCapturedRestorableData: true
            ),
            "text or PNG captured next to an exotic type comes back after paste"
        )
        assertFalse(
            ClipboardPasteDecision.shouldRestoreCapturedItems(
                isComplete: false,
                hasCapturedRestorableData: false
            ),
            "a snapshot that captured nothing must leave the dictation on the clipboard"
        )
    }

    runSuite("Unconfirmed paste keeps the dictation unless a different string replaced it") {
        assertEqual(
            ClipboardPasteDecision.fallbackRecovery(
                currentString: "the dictation",
                dictation: "the dictation",
                generationChanged: false
            ),
            .keepExistingDictation,
            "the recovery copy is already there"
        )
        assertEqual(
            ClipboardPasteDecision.fallbackRecovery(
                currentString: nil,
                dictation: "the dictation",
                generationChanged: false
            ),
            .recopyDictation,
            "an empty or rich-only rewrite must not drop the transcript"
        )
        assertEqual(
            ClipboardPasteDecision.fallbackRecovery(
                currentString: "something the user copied",
                dictation: "the dictation",
                generationChanged: false
            ),
            .leaveChangedClipboard,
            "a different string is the user's copy and stays"
        )
        assertEqual(
            ClipboardPasteDecision.fallbackRecovery(
                currentString: "the dictation",
                dictation: "the dictation",
                generationChanged: true
            ),
            .leaveChangedClipboard,
            "text from a superseded generation does not count as verified recovery"
        )
    }
}

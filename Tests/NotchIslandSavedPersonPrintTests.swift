import Foundation

/// Promise: naming an unrecognized voice as someone already saved counts as a
/// yes for that person, so their voice print shows their color with the rings
/// they had plus the one this meeting earns, plays the match animation, and
/// says what's left, exactly like ✓ on "Is this …?".
func testNotchIslandSavedPersonPrint() {
    typealias Policy = NotchIslandSpeakerReviewPolicy
    let picked = Policy.RowState.named(.savedPerson)

    runSuite("A repeated recording cannot complete an asked or picked person's print") {
        let repeated = Policy.Progress(confirmed: 4, required: 5, earnsConfirmation: false)
        let fresh = Policy.Progress(confirmed: 4, required: 5)
        for state in [Policy.RowState.confirmed, picked] {
            assertEqual(Policy.litRings(state, progress: repeated), 4)
            assertFalse(Policy.namedAutomatically(state, progress: repeated))
            assertEqual(Policy.rowHint(state, progress: repeated)?.text, "1 more to go")
            assertEqual(Policy.litRings(state, progress: fresh), 5)
            assertTrue(Policy.namedAutomatically(state, progress: fresh))
        }
        assertEqual(Policy.rowHint(.asking, progress: repeated), nil, "no one-more-yes promise for already-counted audio")
        assertEqual(repeated.afterYes.confirmed, 4)
        assertEqual(fresh.afterYes.confirmed, 5)
    }

    runSuite("Picking a saved person lights their rings and the one this meeting earns") {
        assertEqual(Policy.litRings(picked, progress: Policy.Progress(confirmed: 2, required: 5)), 3, "2 before, 3 after")
        assertEqual(Policy.litRings(picked, progress: Policy.Progress(confirmed: 4, required: 5)), 5, "the fifth completes the print")
        assertEqual(Policy.litRings(picked, progress: nil), 0, "no saved progress, no rings")
        assertTrue(Policy.celebrates(picked), "it plays the match animation")
        assertEqual(Policy.litRings(.named(.owner), progress: Policy.Progress(confirmed: 4, required: 5)), 0, "You is not a print")
    }

    runSuite("Picking a saved person says what's left, like a yes") {
        assertEqual(Policy.rowHint(picked, progress: Policy.Progress(confirmed: 2, required: 5)),
                    SpeakerNamingTierPresentation.ReviewHint(text: "2 more to go", usesPersonColor: false))
        assertEqual(Policy.rowHint(picked, progress: Policy.Progress(confirmed: 4, required: 5)),
                    SpeakerNamingTierPresentation.ReviewHint(text: "Named automatically from now on", usesPersonColor: true))
        assertTrue(Policy.namedAutomatically(picked, progress: Policy.Progress(confirmed: 4, required: 5)), "joins the footer")
        assertFalse(Policy.namedAutomatically(picked, progress: Policy.Progress(confirmed: 2, required: 5)))
        assertEqual(Policy.rowHint(picked, progress: Policy.Progress(confirmed: 7, required: 5, isTrusted: false)), nil,
                    "no auto-naming promise while on probation")
    }
}

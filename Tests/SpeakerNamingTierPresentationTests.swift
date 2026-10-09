import Foundation

func testSpeakerNamingTierPresentation() {
    runSuite("The dial's tier words are New, Learning and Auto") {
        assertEqual(SpeakerNamingTierPresentation.word(.new), "New")
        assertEqual(SpeakerNamingTierPresentation.word(.learning), "Learning")
        assertEqual(SpeakerNamingTierPresentation.word(.auto), "Auto")
        assertEqual(SpeakerNamingTierPresentation.segmentCount, 5, "one segment per meeting on the standard bar")
    }

    runSuite("The dial fills by progress toward the bar and is only full at Auto") {
        typealias P = SpeakerNamingTierPresentation
        assertEqual(P.filledSegments(confirmed: 0, required: 5, tier: .new), 0)
        assertEqual(P.filledSegments(confirmed: 2, required: 5, tier: .learning), 2)
        assertEqual(P.filledSegments(confirmed: 5, required: 5, tier: .auto), 5)
        assertEqual(P.filledSegments(confirmed: 9, required: 5, tier: .learning), 4, "probation past the bar is never a full ring")
        assertEqual(P.filledSegments(confirmed: 1, required: 2, tier: .new), 2, "a lineup bar of 2 scales: half the ring, rounded down")
        assertEqual(P.filledSegments(confirmed: -1, required: 5, tier: .new), 0, "a bad count never draws negative segments")
        assertEqual(P.filledSegments(confirmed: 0, required: 0, tier: .new), 0, "a zero bar doesn't divide by zero")
    }

    runSuite("The dial explains, in a first name, how far someone is from being named on their own") {
        typealias P = SpeakerNamingTierPresentation
        assertEqual(
            P.explanation(name: "Maya Patel", confirmed: 0, required: 5, tier: .new, isTrusted: true),
            "Not confirmed yet. After 5 meetings, Transcripted names Maya on its own."
        )
        assertEqual(
            P.explanation(name: "Maya Patel", confirmed: 1, required: 2, tier: .new, isTrusted: true),
            "Confirmed in 1 meeting. One more and Transcripted names Maya on its own with matching meeting context.",
            "one meeting is singular, and one left says One more"
        )
        assertEqual(
            P.explanation(name: "Maya Patel", confirmed: 2, required: 5, tier: .learning, isTrusted: true),
            "Confirmed in 2 of 5 meetings. 3 more and Transcripted names Maya on its own."
        )
        assertEqual(
            P.explanation(name: "  Maya  ", confirmed: 5, required: 5, tier: .auto, isTrusted: true),
            "Confirmed in 5 meetings. Transcripted names Maya on its own when the voice is a clear match."
        )
        assertEqual(
            P.explanation(name: "Maya Patel", confirmed: 6, required: 5, tier: .learning, isTrusted: false),
            "A recent correction paused auto-naming for Maya. Keep confirming Maya until the voice is a clear match again."
        )
    }

    runSuite("Every contextual hover and VoiceOver promise keeps its meeting scope") {
        typealias P = SpeakerNamingTierPresentation
        assertEqual(P.explanation(name: "Maya Patel", confirmed: 0, required: 2, tier: .new, isTrusted: true),
                    "Not confirmed yet. After 2 meetings, Transcripted names Maya on its own with matching meeting context.")
        assertEqual(P.explanation(name: "Maya Patel", confirmed: 1, required: 2, tier: .learning, isTrusted: true),
                    "Confirmed in 1 meeting. One more and Transcripted names Maya on its own with matching meeting context.")
        assertEqual(P.explanation(name: "Maya Patel", confirmed: 2, required: 4, tier: .learning, isTrusted: true),
                    "Confirmed in 2 of 4 meetings. 2 more and Transcripted names Maya on its own with matching meeting context.")
        assertEqual(P.explanation(name: "Maya Patel", confirmed: 2, required: 2, tier: .auto, isTrusted: true),
                    "Confirmed in 2 meetings. Transcripted names Maya on its own when the voice is a clear match and meeting context supports it.")
        assertEqual(P.accessibilityLabel(confirmed: 2, required: 2, tier: .auto),
                    "Auto, names on its own with matching meeting context")
        assertEqual(P.accessibilityLabel(confirmed: 5, required: 5, tier: .auto), "Auto, names on its own")
        assertEqual(P.reviewHint(moment: .savedNew, confirmedBefore: 0, required: 2, isTrusted: true),
                    P.ReviewHint(text: "Saved · 1 more to auto-name with meeting context", usesPersonColor: false))
        assertEqual(P.reviewHint(moment: .savedNew, confirmedBefore: 0, required: 5, isTrusted: true),
                    P.ReviewHint(text: "Saved · 4 more to auto-name", usesPersonColor: false))
        assertEqual(P.explanation(name: "Maya Patel", confirmed: 2, required: 2, tier: .learning, isTrusted: false),
                    "A recent correction paused auto-naming for Maya. Keep confirming Maya until the voice is a clear match again.", "context never makes probation promise auto-naming")
    }

    runSuite("VoiceOver hears the tier word with the count") {
        typealias P = SpeakerNamingTierPresentation
        assertEqual(P.accessibilityLabel(confirmed: 1, required: 5, tier: .new), "New, 1 of 5 meetings confirmed")
        assertEqual(P.accessibilityLabel(confirmed: 3, required: 5, tier: .learning), "Learning, 3 of 5 meetings confirmed")
        assertEqual(P.accessibilityLabel(confirmed: 8, required: 5, tier: .auto), "Auto, names on its own")
    }

    runSuite("The review line under a name: one more yes, the payoff, and what's left") {
        typealias P = SpeakerNamingTierPresentation
        assertEqual(P.reviewHint(moment: .asking, confirmedBefore: 4, required: 5, isTrusted: true),
                    P.ReviewHint(text: "One more yes to auto-name", usesPersonColor: true))
        assertEqual(P.reviewHint(moment: .asking, confirmedBefore: 2, required: 5, isTrusted: true), nil, "only the last yes is called out")
        assertEqual(P.reviewHint(moment: .asking, confirmedBefore: 4, required: 5, isTrusted: false), nil, "no promise on probation")
        assertEqual(P.reviewHint(moment: .asking, confirmedBefore: 1, required: 2, isTrusted: true),
                    P.ReviewHint(text: "One more yes to auto-name with meeting context", usesPersonColor: true), "lineup bar of 2 is contextual, not generic readiness")
        assertEqual(P.reviewHint(moment: .confirmed, confirmedBefore: 4, required: 5, isTrusted: true),
                    P.ReviewHint(text: "Named automatically from now on", usesPersonColor: true))
        assertEqual(P.reviewHint(moment: .confirmed, confirmedBefore: 1, required: 5, isTrusted: true),
                    P.ReviewHint(text: "3 more to go", usesPersonColor: false))
        assertEqual(P.reviewHint(moment: .confirmed, confirmedBefore: 3, required: 5, isTrusted: true),
                    P.ReviewHint(text: "1 more to go", usesPersonColor: false))
        assertEqual(P.reviewHint(moment: .confirmed, confirmedBefore: 7, required: 5, isTrusted: false), nil,
                    "a corrected person past the bar isn't promised auto-naming")
        assertEqual(P.reviewHint(moment: .savedNew, confirmedBefore: 0, required: 5, isTrusted: true),
                    P.ReviewHint(text: "Saved · 4 more to auto-name", usesPersonColor: false))
    }

    runSuite("Contextual review progress does not promise automatic naming in every meeting") {
        typealias P = SpeakerNamingTierPresentation
        assertEqual(P.reviewHint(moment: .confirmed, confirmedBefore: 1, required: 2, isTrusted: true),
                    P.ReviewHint(text: "Auto-named with matching meeting context", usesPersonColor: true))
        assertEqual(P.reviewHint(moment: .confirmed, confirmedBefore: 2, required: 5, isTrusted: true),
                    P.ReviewHint(text: "2 more to go", usesPersonColor: false), "the same saved person is still learning outside a lineup")
        assertEqual(P.reviewHint(moment: .confirmed, confirmedBefore: 1, required: 2, isTrusted: false), nil,
                    "context never overrides a recent correction")
    }

    runSuite("The review footer counts people named automatically") {
        typealias P = SpeakerNamingTierPresentation
        assertEqual(P.autoNamedFooter(count: 0), nil)
        assertEqual(P.autoNamedFooter(count: 1), "1 person named automatically")
        assertEqual(P.autoNamedFooter(count: 3), "3 people named automatically")
    }
}

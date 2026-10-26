// Home row controls: what a row's ⋯ menu offers (HomeRowMenuPolicy) and how
// big a Home control's hit shape is (HomeHitTarget). These replaced
// source-text pins in UIAutomationSurfaceContractTests.swift.

import CoreGraphics
import Foundation

func testHomeRowControls() {
    func meetingTitles(
        review: Bool = false,
        boost: Bool = false,
        audio: Bool = false,
        retranscribable: Bool = false
    ) -> [String?] {
        HomeRowMenuPolicy.meetingEntries(
            hasPendingSpeakerReview: review,
            offersMicBoost: boost,
            hasAudioRevealTarget: audio,
            hasRetranscriptionInput: retranscribable
        ).map(\.fixedTitle)
    }

    runSuite("A dictation row's menu opens or reveals the Markdown, and offers no report or delete") {
        let titles = HomeRowMenuPolicy.dictationEntries.compactMap(\.fixedTitle)
        assertEqual(titles, ["Open Markdown", "Reveal in Finder"], "a dictation row should offer Open Markdown, then Reveal in Finder")
        assertFalse(
            HomeRowMenuPolicy.dictationEntries.contains { $0.isDestructive },
            "dictation rows delete through the Dictations page's inline undo, not this menu"
        )
    }

    runSuite("Every meeting row can be renamed, reported, revealed and deleted") {
        assertEqual(
            meetingTitles(),
            [HomeMeetingRenameAffordance.title, "Report issue", "Show transcript in Finder", "Delete meeting"],
            "a plain meeting row should offer rename, Report issue, the transcript in Finder, and Delete meeting last"
        )
        let entries = HomeRowMenuPolicy.meetingEntries(
            hasPendingSpeakerReview: true,
            offersMicBoost: true,
            hasAudioRevealTarget: true,
            hasRetranscriptionInput: true
        )
        assertEqual(entries.last, .deleteMeeting, "Delete meeting should stay the last item, whatever else the row offers")
        assertEqual(entries.filter(\.isDestructive), [.deleteMeeting], "only Delete meeting should be destructive")
    }

    runSuite("A meeting with voices to name offers Who spoke? from its row menu") {
        assertTrue(meetingTitles(review: true).contains("Who spoke?"), "pending speaker review should add Who spoke?")
        assertFalse(meetingTitles(review: false).contains("Who spoke?"), "a meeting with nothing to review should not offer it")
    }

    runSuite("Re-transcribe and Show audio need retained audio with a Finder target") {
        let withAudio = HomeRowMenuPolicy.meetingEntries(
            hasPendingSpeakerReview: false,
            offersMicBoost: false,
            hasAudioRevealTarget: true,
            hasRetranscriptionInput: true
        )
        assertTrue(withAudio.contains(.retranscribe), "retained audio that can be fed back should offer re-transcribe")
        assertTrue(meetingTitles(audio: true).contains("Show audio in Finder"), "retained audio with a Finder target should offer Show audio in Finder")

        let notRetranscribable = HomeRowMenuPolicy.meetingEntries(
            hasPendingSpeakerReview: false,
            offersMicBoost: false,
            hasAudioRevealTarget: true,
            hasRetranscriptionInput: false
        )
        assertFalse(notRetranscribable.contains(.retranscribe), "audio with no re-transcription input should not offer re-transcribe")
        assertTrue(notRetranscribable.contains(.showAudio), "it should still offer Show audio in Finder")

        let noFinderTarget = HomeRowMenuPolicy.meetingEntries(
            hasPendingSpeakerReview: false,
            offersMicBoost: false,
            hasAudioRevealTarget: false,
            hasRetranscriptionInput: true
        )
        assertFalse(
            noFinderTarget.contains(.retranscribe) || noFinderTarget.contains(.showAudio),
            "without a Finder target neither audio action should show"
        )
    }

    runSuite("Boost mic shows only when the mic-boost hint offers it") {
        assertTrue(meetingTitles(boost: true).contains("Boost mic next meeting"), "an offered hint should add Boost mic next meeting")
        assertFalse(meetingTitles(boost: false).contains("Boost mic next meeting"), "no hint, no Boost mic item")
    }

    runSuite("Home controls never get a hit shape under 40pt, or smaller than what's drawn") {
        assertEqual(HomeHitTarget.hitSize(forVisibleSize: 28), HomeHitTarget.minimum, "a small retained-audio button should still get the 40pt floor")
        assertEqual(HomeHitTarget.hitSize(forVisibleSize: 0), 40, "even a zero-size glyph gets a 40pt hit shape")
        assertEqual(HomeHitTarget.hitSize(forVisibleSize: 48), 48, "a big play button keeps its own size")
    }
}

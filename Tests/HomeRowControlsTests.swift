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
        retranscribable: Bool = false,
        starred: Bool = false
    ) -> [String?] {
        HomeRowMenuPolicy.meetingEntries(
            hasPendingSpeakerReview: review,
            offersMicBoost: boost,
            hasAudioRevealTarget: audio,
            hasRetranscriptionInput: retranscribable,
            isStarred: starred
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

    func visibleTitles(
        review: Bool = false,
        boost: Bool = false,
        audio: Bool = false,
        retranscribable: Bool = false,
        starred: Bool = false
    ) -> [String?] {
        HomeRowMenuPolicy.visibleMenuEntries(HomeRowMenuPolicy.meetingEntries(
            hasPendingSpeakerReview: review,
            offersMicBoost: boost,
            hasAudioRevealTarget: audio,
            hasRetranscriptionInput: retranscribable,
            isStarred: starred
        )).map(\.fixedTitle)
    }

    runSuite("A meeting's menu is the short list: Rename, Who spoke?, Transcribe again, Keep audio, Show in Finder, Delete") {
        assertEqual(
            visibleTitles(review: true, boost: true, audio: true, retranscribable: true),
            [HomeMeetingRenameAffordance.title, "Who spoke?", nil, "Keep audio", "Show in Finder", "Delete"],
            "everything a meeting can do fits in six lines (Transcribe again's title is built by the shell)"
        )
        assertEqual(
            visibleTitles(),
            [HomeMeetingRenameAffordance.title, "Show in Finder", "Delete"],
            "a meeting with no audio and nothing to review offers rename, Finder and delete"
        )
        let entries = HomeRowMenuPolicy.meetingEntries(
            hasPendingSpeakerReview: true,
            offersMicBoost: true,
            hasAudioRevealTarget: true,
            hasRetranscriptionInput: true
        )
        assertEqual(entries.last, .deleteMeeting, "Delete should stay the last item, whatever else the row offers")
        assertEqual(entries.filter(\.isDestructive), [.deleteMeeting], "only Delete should be destructive")
        assertFalse(entries.contains(.reportIssue), "Report issue lives in the sidebar's Feedback now")
    }

    runSuite("Keep audio sets the same starred flag that keeps a meeting's audio") {
        let off = HomeRowMenuPolicy.meetingEntries(
            hasPendingSpeakerReview: false,
            offersMicBoost: false,
            hasAudioRevealTarget: true,
            hasRetranscriptionInput: false,
            isStarred: false
        )
        assertTrue(off.contains(.starMeeting), "a meeting with audio offers Keep audio, which stars it")
        assertFalse(HomeRowMenuEntry.starMeeting.isChecked, "Keep audio is unchecked on an unstarred meeting")

        let on = HomeRowMenuPolicy.meetingEntries(
            hasPendingSpeakerReview: false,
            offersMicBoost: false,
            hasAudioRevealTarget: true,
            hasRetranscriptionInput: false,
            isStarred: true
        )
        assertTrue(on.contains(.unstarMeeting), "a starred meeting shows Keep audio, checked, which unstars it")
        assertFalse(on.contains(.starMeeting), "a starred meeting doesn't offer to star it again")
        assertTrue(HomeRowMenuEntry.unstarMeeting.isChecked, "Keep audio is checked on a starred meeting")
        assertEqual(HomeRowMenuEntry.starMeeting.fixedTitle, "Keep audio")
        assertEqual(HomeRowMenuEntry.unstarMeeting.fixedTitle, "Keep audio")

        let starredWithoutAudio = HomeRowMenuPolicy.meetingEntries(
            hasPendingSpeakerReview: false,
            offersMicBoost: false,
            hasAudioRevealTarget: false,
            hasRetranscriptionInput: false,
            isStarred: true
        )
        assertTrue(starredWithoutAudio.contains(.unstarMeeting), "a starred meeting can always turn Keep audio off")
        assertFalse(meetingTitles().contains("Keep audio"), "no audio and not starred: nothing to keep")
    }

    runSuite("A meeting with voices to name offers Who spoke? from its row menu") {
        assertTrue(meetingTitles(review: true).contains("Who spoke?"), "pending speaker review should add Who spoke?")
        assertFalse(meetingTitles(review: false).contains("Who spoke?"), "a meeting with nothing to review should not offer it")
    }

    runSuite("Transcribe again and Show audio need retained audio with a Finder target") {
        let withAudio = HomeRowMenuPolicy.meetingEntries(
            hasPendingSpeakerReview: false,
            offersMicBoost: false,
            hasAudioRevealTarget: true,
            hasRetranscriptionInput: true
        )
        assertTrue(withAudio.contains(.retranscribe), "retained audio that can be fed back should offer Transcribe again")
        assertTrue(meetingTitles(audio: true).contains("Show audio in Finder"), "retained audio with a Finder target can still be shown in Finder")
        assertEqual(HomeRowMenuEntry.showAudio.placement, .optionAlternate, "Show audio in Finder is Show in Finder with Option held")
        if let finder = withAudio.firstIndex(of: .showTranscript) {
            assertEqual(withAudio[finder + 1], .showAudio, "an Option alternate must sit right after the line it replaces")
        } else {
            assertTrue(false, "Show in Finder should always be offered")
        }

        let notRetranscribable = HomeRowMenuPolicy.meetingEntries(
            hasPendingSpeakerReview: false,
            offersMicBoost: false,
            hasAudioRevealTarget: true,
            hasRetranscriptionInput: false
        )
        assertFalse(notRetranscribable.contains(.retranscribe), "audio with no re-transcription input should not offer Transcribe again")
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

    runSuite("Boost mic rides on the card's Mic was muffled line, only when the hint offers it") {
        assertTrue(meetingTitles(boost: true).contains("Boost mic next meeting"), "an offered hint keeps Boost mic next meeting reachable")
        assertFalse(meetingTitles(boost: false).contains("Boost mic next meeting"), "no hint, no Boost mic")
        assertEqual(HomeRowMenuEntry.boostMic.placement, .issueLine, "Boost mic is on the amber line, not a menu line")
        assertFalse(visibleTitles(boost: true).contains("Boost mic next meeting"), "it doesn't add a menu line")
    }

    runSuite("Home controls never get a hit shape under 40pt, or smaller than what's drawn") {
        assertEqual(HomeHitTarget.hitSize(forVisibleSize: 28), HomeHitTarget.minimum, "a small retained-audio button should still get the 40pt floor")
        assertEqual(HomeHitTarget.hitSize(forVisibleSize: 0), 40, "even a zero-size glyph gets a 40pt hit shape")
        assertEqual(HomeHitTarget.hitSize(forVisibleSize: 48), 48, "a big play button keeps its own size")
    }
}

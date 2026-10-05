// DictationCardPresentationTests.swift
// The Dictations card's metadata line and the Transcribe again rules.

import Foundation

func testDictationCardPresentation() {
    runSuite("Card length reads as plain words: seconds, minutes and seconds, then whole minutes") {
        assertEqual(DictationCardFormatting.lengthText(seconds: 16), "16 sec", "short takes are seconds")
        assertEqual(DictationCardFormatting.lengthText(seconds: 0.3), "1 sec", "a blip still reads as a length")
        assertEqual(DictationCardFormatting.lengthText(seconds: 59.4), "59 sec", "rounds to the nearest second")
        assertEqual(DictationCardFormatting.lengthText(seconds: 60), "1 min", "an even minute drops the seconds")
        assertEqual(DictationCardFormatting.lengthText(seconds: 84), "1 min 24 sec", "under five minutes shows both")
        assertEqual(DictationCardFormatting.lengthText(seconds: 1_930), "32 min", "long takes are whole minutes")
        assertEqual(DictationCardFormatting.lengthText(seconds: 3_900), "1 hr 5 min", "an hour and more shows hours")
        assertEqual(DictationCardFormatting.lengthText(seconds: 7_200), "2 hr", "even hours drop the minutes")
    }

    runSuite("Player clock is m:ss, with hours only when needed") {
        assertEqual(DictationCardFormatting.clockText(seconds: 7.9), "0:07", "the clock counts whole seconds played")
        assertEqual(DictationCardFormatting.clockText(seconds: 84), "1:24", "minutes and padded seconds")
        assertEqual(DictationCardFormatting.clockText(seconds: 3_723), "1:02:03", "hours when the take is that long")
        assertEqual(DictationCardFormatting.clockText(seconds: -3), "0:00", "never negative")
        assertEqual(DictationCardFormatting.clockText(seconds: .nan), "0:00", "a bad duration reads as zero")
    }

    runSuite("Card metadata reads time, length, words, app, then any delivery problem") {
        let items = DictationCardFormatting.metadata(
            time: "5:30 AM", length: 16, wordCount: 46, appName: "Claude", delivery: .pasted
        )
        assertEqual(items.map(\.text), ["5:30 AM", "16 sec", "46 words", "Claude"], "a pasted take has no problem note")
        assertEqual(items.map(\.kind), [.time, .length, .words, .app], "kinds follow the same order")
        assertEqual(
            DictationCardFormatting.accessibilitySummary(items),
            "5:30 AM, 16 sec, 46 words, Claude",
            "VoiceOver reads the whole bar"
        )
        assertEqual(
            items.filter(\.collapsesWhilePlaying).map(\.kind),
            [.length, .app],
            "length and app step aside while the player is open"
        )
    }

    runSuite("Card metadata leaves out what it doesn't know") {
        let items = DictationCardFormatting.metadata(
            time: "9:41 PM", length: nil, wordCount: 1, appName: "Unknown", delivery: .pasted
        )
        assertEqual(items.map(\.text), ["9:41 PM", "1 word"], "no length until it's read, no made-up app")
        let blankApp = DictationCardFormatting.metadata(
            time: "9:41 PM", length: 0, wordCount: 2, appName: "  ", delivery: .pasted
        )
        assertEqual(blankApp.map(\.text), ["9:41 PM", "2 words"], "a zero length and a blank app are left out")
    }

    runSuite("Delivery problems show in the bar without claiming a destination") {
        assertNil(DictationCardFormatting.deliveryProblem(.pasted), "pasted takes have no problem")
        assertEqual(DictationCardFormatting.deliveryProblem(.copied), "copied, not pasted", "copied takes say so")
        assertEqual(DictationCardFormatting.deliveryProblem(.failed), "saved only", "failed paste-back still says the Markdown was saved")
        assertEqual(DictationCardFormatting.deliveryProblem(.savedWithoutPaste), "saved only", "capped takes were only saved")
        let items = DictationCardFormatting.metadata(
            time: "4:41 AM", length: 41, wordCount: 94, appName: "Mail", delivery: .copied
        )
        assertEqual(items.last, DictationCardFormatting.MetadataItem(kind: .problem, text: "copied, not pasted"),
                    "the problem note comes last")
        assertFalse(items.last?.collapsesWhilePlaying ?? true, "the problem note stays visible while playing")
    }

    runSuite("Transcribe again shows only with kept audio and follows the saved-audio busy rules") {
        typealias Policy = DictationTranscribeAgainPolicy
        let hidden = Policy.availability(entryID: "a", hasAudio: false, runningEntryID: nil, globalUnavailableReason: nil)
        assertEqual(hidden, .hidden, "no kept audio hides the item")
        assertNil(Policy.menuTitle(for: hidden), "a hidden item has no title")

        let ready = Policy.availability(entryID: "a", hasAudio: true, runningEntryID: nil, globalUnavailableReason: nil)
        assertEqual(ready, .available, "kept audio and nothing busy means available")
        assertEqual(Policy.menuTitle(for: ready), "Transcribe again", "plain title when it can run")
        assertTrue(Policy.isEnabled(ready), "available is enabled")

        let dictating = Policy.availability(
            entryID: "a", hasAudio: true, runningEntryID: nil,
            globalUnavailableReason: SavedMeetingRetranscriptionAvailabilityPolicy.dictationActiveReason
        )
        assertFalse(Policy.isEnabled(dictating), "a live dictation blocks it")
        assertEqual(Policy.menuTitle(for: dictating), "Transcribe again (after this dictation)", "the title says when it'll work")

        let loading = Policy.availability(
            entryID: "a", hasAudio: true, runningEntryID: nil,
            globalUnavailableReason: SavedMeetingRetranscriptionAvailabilityPolicy.preparingModelsReason
        )
        assertEqual(Policy.menuTitle(for: loading), "Transcribe again (once models load)", "loading models blocks it")

        let recording = Policy.availability(
            entryID: "a", hasAudio: true, runningEntryID: nil,
            globalUnavailableReason: SavedMeetingRetranscriptionAvailabilityPolicy.meetingRecordingReason
        )
        assertEqual(Policy.menuTitle(for: recording), "Transcribe again (after this recording)", "a recording meeting blocks it")
    }

    runSuite("Transcribe again runs one dictation at a time") {
        typealias Policy = DictationTranscribeAgainPolicy
        let this = Policy.availability(entryID: "a", hasAudio: true, runningEntryID: "a", globalUnavailableReason: nil)
        assertEqual(this, .running, "the running entry says it's running")
        assertFalse(Policy.isEnabled(this), "it can't be started twice")
        assertEqual(Policy.menuTitle(for: this), "Transcribing again\u{2026}", "running title")

        let other = Policy.availability(entryID: "b", hasAudio: true, runningEntryID: "a", globalUnavailableReason: nil)
        assertFalse(Policy.isEnabled(other), "another entry waits")
        assertEqual(Policy.menuTitle(for: other), "Transcribe again (after the current one)", "and says why")
    }
}

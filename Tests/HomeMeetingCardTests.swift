// The Meetings card (QuietMeetingCard): what a closed card shows from the
// transcript, what its bar says, and when Show more appears
// (HomeMeetingCardPresentation). Fictional names only.

import Foundation

func testHomeMeetingCard() {
    func meetingMarkdown(turns: [(String, String, String)]) -> String {
        var body = """
        ---
        capture_type: meeting
        ---

        # Launch sync

        ## Transcript

        """
        for (time, label, text) in turns {
            body += "\n**\(time)** [\(label)]\n\(text)\n"
        }
        return body
    }

    runSuite("A closed meeting card shows its first four lines and who spoke") {
        let markdown = meetingMarkdown(turns: [
            ("00:04", "Mic/You", "Okay, let's get started with the launch."),
            ("00:11", "System/Speaker 2", "Sounds good. First item is the date."),
            ("00:19", "System/Priya", "I can take the design review."),
            ("00:25", "Mic/You", "Great. So the launch moves to Tuesday."),
            ("00:31", "System/Priya", "Works for me."),
        ])
        let snippet = HomeMeetingCardPresentation.snippet(from: HomeMeetingPreviewContent.make(from: markdown))

        assertEqual(snippet.lines.map(\.text), [
            "Okay, let's get started with the launch.",
            "Sounds good. First item is the date.",
            "I can take the design review.",
            "Great. So the launch moves to Tuesday.",
        ], "a closed card shows the opening four lines, in order")
        assertEqual(snippet.totalLineCount, 5, "the card knows how many lines the transcript has")
        assertEqual(snippet.participants, ["You", "Priya"], "named voices in order of first appearance; Speaker 2 is left out")
        assertTrue(HomeMeetingCardPresentation.hasMore(snippet), "a fifth line means Show more")
        assertEqual(snippet.lines[2].startSeconds, 19, "each line keeps its time so hovering it can play from there")
    }

    runSuite("A short transcript has no Show more") {
        let markdown = meetingMarkdown(turns: [
            ("00:02", "System/Marcus", "The header still jumps when the page loads."),
            ("00:06", "System/Priya", "I'll fix that today."),
        ])
        let snippet = HomeMeetingCardPresentation.snippet(from: HomeMeetingPreviewContent.make(from: markdown))
        assertFalse(HomeMeetingCardPresentation.hasMore(snippet), "two short lines already show everything")
        assertEqual(snippet.fallbackText, nil, "a transcript with speaker lines uses them, not plain text")
    }

    runSuite("Unnamed voices are spotted so the bar doesn't list them as people") {
        for name in ["Speaker", "Speaker 2", "speaker 12", "Unknown"] {
            assertTrue(HomeMeetingCardPresentation.isUnnamedVoice(name), "\(name) is a voice nobody named yet")
        }
        for name in ["You", "Priya", "Speaker Lee", "Speakerphone"] {
            assertFalse(HomeMeetingCardPresentation.isUnnamedVoice(name), "\(name) is a name")
        }
    }

    runSuite("The bar says time, length and people, with no date or model") {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        assertEqual(
            HomeMeetingCardPresentation.metaItems(
                time: "9:00 AM",
                start: start,
                end: start.addingTimeInterval(32 * 60),
                participants: ["You", "Priya"]
            ),
            ["9:00 AM", "32 min", "You, Priya"]
        )
        assertEqual(
            HomeMeetingCardPresentation.metaItems(time: "9:00 AM", start: nil, end: nil, participants: []),
            ["9:00 AM"],
            "unknown length and no names leave just the time"
        )
        assertEqual(
            HomeMeetingCardPresentation.participantsText(["You", "Priya", "Leo", "Sam", "Ana"]),
            "You, Priya, Leo +2",
            "more than three people collapse into +N"
        )
    }

    runSuite("Meeting lengths read the way people say them") {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func length(_ minutes: Double) -> String? {
            HomeMeetingCardPresentation.durationText(start: start, end: start.addingTimeInterval(minutes * 60))
        }
        assertEqual(length(0.2), "<1 min")
        assertEqual(length(32), "32 min")
        assertEqual(length(60), "1 hr")
        assertEqual(length(65), "1 hr 5 min")
        assertEqual(HomeMeetingCardPresentation.durationText(start: start, end: start), nil, "no length without a real span")
    }

    runSuite("Line times show as a plain clock") {
        assertEqual(MeetingAudioPlayback.clockText(19), "0:19")
        assertEqual(MeetingAudioPlayback.clockText(32 * 60 + 10), "32:10")
        assertEqual(MeetingAudioPlayback.clockText(3723), "1:02:03")
    }

    runSuite("An opened card holds back very long transcripts behind Show all") {
        assertEqual(HomeMeetingCardPresentation.showAllTitle(totalLineCount: 214), "Show all 214 lines")
        assertEqual(
            HomeMeetingCardPresentation.showAllTitle(totalLineCount: HomeMeetingCardPresentation.openedLineLimit),
            nil,
            "a transcript that fits shows whole"
        )
    }

    runSuite("The audio source picker says you and others, not devices") {
        assertEqual(MeetingAudioSourceTitle.title(sourceStem: "microphone", fallback: "Mic"), "You")
        assertEqual(MeetingAudioSourceTitle.title(sourceStem: "system_audio", fallback: "System"), "Others")
        assertEqual(MeetingAudioSourceTitle.title(sourceStem: "playback", fallback: "Mix"), "Mix")
    }
}

import Foundation

func testHomeTranscriptionActivityCopy() {
    runSuite("HomeTranscriptionActivityCopy.resolvedTranscriptName prefers the last saved title") {
        assertEqual(
            HomeTranscriptionActivityCopy.resolvedTranscriptName(
                lastSavedTitle: "Weekly Sync",
                transcriptURL: URL(fileURLWithPath: "/tmp/2026-07-04 Weekly Sync.md")
            ),
            "Weekly Sync",
            "a non-empty saved title should win over the transcript file name"
        )
    }

    runSuite("HomeTranscriptionActivityCopy.resolvedTranscriptName falls back to the transcript file stem") {
        assertEqual(
            HomeTranscriptionActivityCopy.resolvedTranscriptName(
                lastSavedTitle: nil,
                transcriptURL: URL(fileURLWithPath: "/tmp/2026-07-04 Weekly Sync.md")
            ),
            "2026-07-04 Weekly Sync",
            "an empty title should fall back to the transcript URL's file stem"
        )
        assertEqual(
            HomeTranscriptionActivityCopy.resolvedTranscriptName(
                lastSavedTitle: "",
                transcriptURL: URL(fileURLWithPath: "/tmp/2026-07-04 Weekly Sync.md")
            ),
            "2026-07-04 Weekly Sync",
            "an empty-string title should also fall back to the transcript URL's file stem"
        )
    }

    runSuite("HomeTranscriptionActivityCopy.resolvedTranscriptName returns nil with nothing to show") {
        assertNil(
            HomeTranscriptionActivityCopy.resolvedTranscriptName(lastSavedTitle: nil, transcriptURL: nil),
            "no title and no transcript URL should resolve to no name"
        )
    }

    runSuite("HomeTranscriptionActivityCopy.failedTranscriptionDetail adds a convert hint for audio-file failures") {
        let detail = HomeTranscriptionActivityCopy.failedTranscriptionDetail(
            for: "That audio file could not be processed."
        )

        assertEqual(
            detail,
            "That audio file could not be processed. Choose another file, or convert it to WAV or M4A and import it again.",
            "generic audio-file failures should append the convert hint"
        )
    }

    runSuite("HomeTranscriptionActivityCopy.failedTranscriptionDetail does not double up existing choose/try copy") {
        let chooseMessage = "That audio file couldn't be used. Choose a different one."
        assertEqual(
            HomeTranscriptionActivityCopy.failedTranscriptionDetail(for: chooseMessage),
            chooseMessage,
            "audio-file failures that already say Choose should be returned unmodified"
        )

        let tryMessage = "That audio file didn't work. Try picking a different one."
        assertEqual(
            HomeTranscriptionActivityCopy.failedTranscriptionDetail(for: tryMessage),
            tryMessage,
            "audio-file failures that already say Try should be returned unmodified"
        )
    }

    runSuite("HomeTranscriptionActivityCopy.failedTranscriptionDetail adds the retry hint for other failures") {
        let detail = HomeTranscriptionActivityCopy.failedTranscriptionDetail(for: "Model was not ready.")

        assertEqual(
            detail,
            "Model was not ready. If audio was saved, the meeting row below will show Try again.",
            "non-audio-file failures should append the retry-row hint"
        )
    }
}

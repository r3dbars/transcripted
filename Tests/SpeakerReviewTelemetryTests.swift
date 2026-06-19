import Foundation

func testSpeakerReviewTelemetry() {
    runSuite("SpeakerReviewTelemetry builds bucketed prompt properties") {
        let request = makeSpeakerReviewRequest(speakers: [
            makeSpeakerEntry(needsNaming: true, needsConfirmation: false),
            makeSpeakerEntry(needsNaming: false, needsConfirmation: true),
            makeSpeakerEntry(needsNaming: true, needsConfirmation: false),
            makeSpeakerEntry(needsNaming: true, needsConfirmation: false),
        ])

        let properties = SpeakerReviewTelemetry.properties(
            request: request,
            result: .shown,
            surface: .postMeetingSheet
        )

        assertEqual(properties["participant_count_bucket"], "4_9", "speaker review should bucket participant counts")
        assertEqual(properties["review_reason"], "mixed", "mixed naming and confirmation work should stay enum-only")
        assertEqual(properties["result"], "shown", "prompt event should use a result enum")
        assertEqual(properties["surface"], "post_meeting_sheet", "surface should stay a stable enum")
    }

    runSuite("SpeakerReviewTelemetry maps completion results without private data") {
        let saved = SpeakerReviewTelemetry.result(for: [
            makeSpeakerUpdate(action: .named),
            makeSpeakerUpdate(action: .confirmed),
        ])
        let collapsed = SpeakerReviewTelemetry.result(for: [
            makeSpeakerUpdate(action: .collapsedToMe),
            makeSpeakerUpdate(action: .collapsedToMe),
        ])
        let discarded = SpeakerReviewTelemetry.result(for: [
            makeSpeakerUpdate(action: .discardedFromDatabase),
        ])
        let later = SpeakerReviewTelemetry.result(for: [])

        assertEqual(saved.rawValue, "saved", "name or confirmation updates should count as saved")
        assertEqual(collapsed.rawValue, "collapsed_to_me", "Keep as You should get its own enum")
        assertEqual(discarded.rawValue, "discarded", "discard-only completion should get its own enum")
        assertEqual(later.rawValue, "review_later", "empty updates should mean review later")
    }
}

private func makeSpeakerReviewRequest(speakers: [SpeakerNamingEntry]) -> SpeakerNamingRequest {
    SpeakerNamingRequest(
        speakers: speakers,
        transcriptURL: URL(fileURLWithPath: "/tmp/meeting.md"),
        transcriptId: UUID(),
        systemAudioURL: URL(fileURLWithPath: "/tmp/system.wav"),
        micAudioURL: URL(fileURLWithPath: "/tmp/mic.wav"),
        onComplete: { _ in }
    )
}

private func makeSpeakerEntry(
    needsNaming: Bool,
    needsConfirmation: Bool,
    channel: UtteranceChannel = .system
) -> SpeakerNamingEntry {
    SpeakerNamingEntry(
        id: UUID(),
        diarizerSpeakerId: "0",
        channel: channel,
        clipURL: URL(fileURLWithPath: "/tmp/clip.wav"),
        sampleText: "sample",
        currentName: needsConfirmation ? "Suggested" : nil,
        matchSimilarity: needsConfirmation ? 0.72 : nil,
        needsNaming: needsNaming,
        needsConfirmation: needsConfirmation
    )
}

private func makeSpeakerUpdate(action: SpeakerNameUpdate.NamingAction) -> SpeakerNameUpdate {
    SpeakerNameUpdate(
        persistentSpeakerId: UUID(),
        diarizerSpeakerId: "0",
        newName: "Person",
        action: action
    )
}

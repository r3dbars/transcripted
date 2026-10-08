import Foundation

func testSpeakerReviewBridge() {
    runSuite("Speaker review submission preserves both channels, every verdict, and identity metadata") {
        let speakerID = UUID()
        let targetID = UUID()
        let resolvedID = UUID()
        let actions: [SpeakerReviewUpdate.NamingAction] = [
            .named, .confirmed, .corrected, .merged(targetProfileId: targetID),
            .collapsedToMe, .discardedFromDatabase
        ]
        for channel in [SpeakerReviewUpdate.Channel.mic, .system] {
            for (index, action) in actions.enumerated() {
                let original = SpeakerReviewUpdate(
                    persistentSpeakerId: speakerID, diarizerSpeakerId: "7", channel: channel,
                    newName: "Taylor", previousName: "Alex", action: action,
                    resolvedPersistentSpeakerId: resolvedID
                )
                let saved = SpeakerReviewBridge.coreUpdate(original)
                let restored = SpeakerReviewBridge.reviewUpdate(saved)
                assertEqual(restored.persistentSpeakerId, speakerID, "speaker identity survives submission")
                assertEqual(restored.diarizerSpeakerId, "7", "local diarizer identity survives submission")
                assertEqual(restored.channel.rawValue, channel.rawValue, "mic and system stay distinct")
                assertEqual(restored.newName, "Taylor", "typed name survives submission")
                assertEqual(restored.previousName, "Alex", "prior name survives correction")
                assertEqual(restored.resolvedPersistentSpeakerId, resolvedID, "resolved identity survives submission")
                let expected: [String?] = ["named", "confirmed", "corrected", "merged", nil, nil]
                assertEqual(SpeakerReviewBridge.matchOutcome(for: restored), expected[index], "bookkeeping is excluded from match telemetry")
                if case .merged(let target) = action {
                    if case .merged(let restoredTarget) = restored.action {
                        assertEqual(restoredTarget, target, "merge target survives submission")
                    } else { assertTrue(false, "merged answer stays a merge") }
                }
                if case .collapsedToMe = action {
                    if case .collapsedToMe = restored.action {} else { assertTrue(false, "All me stays All me") }
                }
                if case .discardedFromDatabase = action {
                    if case .discardedFromDatabase = restored.action {} else { assertTrue(false, "Not a person stays discarded") }
                }
            }
        }
    }
}

import Foundation

func testSpeakerSilentNameCorrectionTelemetry() {
    let alice = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    let bob = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    let carol = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    func identity(_ profile: UUID?, _ channel: HomeMeetingSpeakerChannel?) -> HomeMeetingSpeakerIdentity {
        HomeMeetingSpeakerIdentity(displayName: "Alice", rawLabel: "System/Alice", channel: channel,
                                   diarizerSpeakerID: "1", persistentSpeakerID: profile)
    }

    runSuite("Only voices Transcripted named on its own (source: db) count as silent names") {
        let markdown = """
        ---
        transcript_id: "297F08B7-62AE-4291-9EA3-41EB0B17A64A"
        speakers:
          - id: "1"
            channel: system
            db_id: "\(alice.uuidString)"
            name: "Alice"
            source: db
          - id: "2"
            channel: system
            db_id: "\(carol.uuidString)"
            name: "Carol"
            source: db_pending
          - id: "0"
            channel: mic
            db_id: "\(bob.uuidString)"
            name: "Bob"
            source: user_manual
        ---
        """
        assertEqual(
            HomeMeetingPreviewContent.autoRecognizedVoices(in: markdown),
            [HomeMeetingAutoRecognizedVoice(profileID: alice, channel: .system)]
        )
    }

    runSuite("Moving a silently named voice to another saved person is a wrong silent name; renames are not") {
        let silent = [HomeMeetingAutoRecognizedVoice(profileID: alice, channel: .system)]
        let movedToBob = HomeMeetingSpeakerAssignment(identity: identity(alice, .system), newName: "Bob", targetProfileID: bob)
        let renamed = HomeMeetingSpeakerAssignment(identity: identity(alice, .system), newName: "Alicia", targetProfileID: nil)
        let otherChannel = HomeMeetingSpeakerAssignment(identity: identity(alice, .mic), newName: "Bob", targetProfileID: bob)
        let notSilent = HomeMeetingSpeakerAssignment(identity: identity(carol, .system), newName: "Bob", targetProfileID: bob)
        let corrections = HomeMeetingSpeakerNamingPolicy.silentNameCorrections(
            [movedToBob, renamed, otherChannel, notSilent], autoRecognized: silent)
        assertEqual(corrections, [movedToBob], "a typed rename may be a spelling fix, and other voices weren't silent")
        let legacy = HomeMeetingSpeakerAssignment(identity: identity(alice, nil), newName: "Bob", targetProfileID: bob)
        assertEqual(HomeMeetingSpeakerNamingPolicy.silentNameCorrections([legacy], autoRecognized: silent), [legacy],
                    "an older transcript row without a channel still matches its profile")
    }

    runSuite("A wrong silent name reports a corrected, auto-recognized review with the match's buckets") {
        let voice = SpeakerSilentNameCorrectionTelemetry.Voice(profileID: alice, channel: "system")
        let outcomes = [
            SpeakerMatchOutcome(profileId: alice, kind: .confirmed, similarity: 0.5, channel: "system"),
            SpeakerMatchOutcome(profileId: bob, kind: .autoAccepted, similarity: 0.99, channel: "system"),
            SpeakerMatchOutcome(profileId: alice, kind: .autoAccepted, similarity: 0.95, secondSimilarity: 0.6,
                                callCountAtMatch: 7, channel: "system"),
        ]
        let outcome = SpeakerSilentNameCorrectionTelemetry.autoAcceptedOutcome(for: voice, in: outcomes)
        assertEqual(outcome?.similarity, 0.95, "the auto-accept row for this voice, not a verdict or another person")
        assertEqual(SpeakerSilentNameCorrectionTelemetry.properties(for: voice, outcome: outcome), [
            "review_action": "corrected",
            "auto_recognized": "true",
            "had_suggestion": "true",
            "channel": "system",
            "surface": "settings",
            "similarity_bucket": "0_92_plus",
            "margin_bucket": "0_25_plus",
            "call_count_bucket": "4_9",
        ])
    }

    runSuite("Without the auto-accept row the match buckets say unknown, never a guess") {
        let voice = SpeakerSilentNameCorrectionTelemetry.Voice(profileID: alice, channel: nil)
        let properties = SpeakerSilentNameCorrectionTelemetry.properties(for: voice, outcome: nil)
        assertEqual(properties["similarity_bucket"], "unknown")
        assertEqual(properties["margin_bucket"], "unknown")
        assertEqual(properties["call_count_bucket"], "unknown")
        assertEqual(properties["channel"], "unknown")
        assertEqual(properties["auto_recognized"], "true")
        assertEqual(Set(properties.keys), [
            "review_action", "auto_recognized", "had_suggestion", "channel", "surface",
            "similarity_bucket", "margin_bucket", "call_count_bucket",
        ], "only the registered bucket keys; no names, ids, titles or text")
    }
}

import Foundation

func testSpeakerNamingPolicy() {
    runSuite("SpeakerNamingPolicy.initialMapping keeps tentative matches generic") {
        let profile = SpeakerProfile(
            id: UUID(),
            displayName: "Alex",
            nameSource: NameSource.userManual,
            embedding: [0.1, 0.2, 0.3],
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: 4,
            confidence: 0.8,
            disputeCount: 0
        )

        let mapping = SpeakerNamingPolicy.initialMapping(
            speakerId: "0",
            profile: profile,
            similarity: 0.97
        )

        assertNil(mapping.identifiedName, "tentative matches should stay generic until the user confirms them")
        assertEqual(mapping.displayName, "Speaker 0", "tentative matches should not rewrite the transcript label")
    }

    runSuite("SpeakerNamingPolicy.initialMapping auto-applies mature high-confidence matches") {
        let profile = SpeakerProfile(
            id: UUID(),
            displayName: "Alex",
            nameSource: NameSource.userManual,
            embedding: [0.1, 0.2, 0.3],
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: 6,
            confidence: 0.9,
            disputeCount: 0
        )

        let mapping = SpeakerNamingPolicy.initialMapping(
            speakerId: "0",
            profile: profile,
            similarity: 0.91
        )

        assertEqual(mapping.identifiedName, "Alex", "strong repeated matches should still auto-apply")
        assertEqual(mapping.displayName, "Alex", "auto-applied names should render without a tentative suffix")
        assertEqual(mapping.confidence, .high, "strong repeated matches should be marked high confidence")
    }

    runSuite("SpeakerNamingPolicy.initialMapping keeps disputed profiles generic") {
        let profile = SpeakerProfile(
            id: UUID(),
            displayName: "Alex",
            nameSource: NameSource.userManual,
            embedding: [0.1, 0.2, 0.3],
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: 8,
            confidence: 0.9,
            disputeCount: 1
        )

        let mapping = SpeakerNamingPolicy.initialMapping(
            speakerId: "0",
            profile: profile,
            similarity: 0.95
        )

        assertNil(mapping.identifiedName, "disputed profiles should not auto-apply")
        assertEqual(mapping.displayName, "Speaker 0", "disputed profiles should stay generic until repaired")
    }

    runSuite("SpeakerNamingPolicy keeps row-level You edits as normal mic renames") {
        let entry = SpeakerNamingEntry(
            id: UUID(),
            diarizerSpeakerId: "1",
            channel: .mic,
            clipURL: URL(fileURLWithPath: "/tmp/speaker-row.wav"),
            sampleText: "I am in the room.",
            currentName: "Speaker 1",
            matchSimilarity: nil,
            needsNaming: true,
            needsConfirmation: false
        )

        let update = SpeakerNamingPolicy.typedNameUpdate(
            entry: entry,
            typedName: "You",
            optionsByLabel: [:]
        )

        assertEqual(update?.newName, "You", "row-level owner labels should still save the typed name")
        assertEqual(update?.previousName, "Speaker 1", "row-level owner labels should preserve the previous mic name")
        if case .corrected? = update?.action {
            assertTrue(true, "manually typing You should stay a row-level correction")
        } else {
            assertTrue(false, "manually typing You should not collapse the whole local speaker set")
        }
    }

    runSuite("SpeakerNamingPolicy.rowUpdate keeps typed correction after confirmation") {
        let entry = SpeakerNamingEntry(
            id: UUID(),
            diarizerSpeakerId: "2",
            channel: .system,
            clipURL: URL(fileURLWithPath: "/tmp/speaker-confirmed-row.wav"),
            sampleText: "Thanks for joining.",
            currentName: "Matt Vlasach",
            matchSimilarity: 0.86,
            needsNaming: false,
            needsConfirmation: true
        )

        let update = SpeakerNamingPolicy.rowUpdate(
            entry: entry,
            typedName: "Sarah Graham",
            isConfirmed: true,
            isDiscarded: false,
            optionsByLabel: [:]
        )

        assertEqual(update?.newName, "Sarah Graham", "typed corrections after Confirm should not be replaced by the original suggestion")
        assertEqual(update?.previousName, "Matt Vlasach", "corrections should preserve the rejected suggestion")
        if case .corrected? = update?.action {
            assertTrue(true, "typed correction after Confirm should still be a correction")
        } else {
            assertTrue(false, "typed correction after Confirm should not be saved as the original confirmed match")
        }
    }

    runSuite("SpeakerNamingPolicy.rowUpdate still confirms unchanged suggestions") {
        let entry = SpeakerNamingEntry(
            id: UUID(),
            diarizerSpeakerId: "3",
            channel: .system,
            clipURL: URL(fileURLWithPath: "/tmp/speaker-confirmed-row.wav"),
            sampleText: "Let's ship it.",
            currentName: "Alex Kim",
            matchSimilarity: 0.9,
            needsNaming: false,
            needsConfirmation: true
        )

        let update = SpeakerNamingPolicy.rowUpdate(
            entry: entry,
            typedName: "Alex Kim",
            isConfirmed: true,
            isDiscarded: false,
            optionsByLabel: [:]
        )

        assertEqual(update?.newName, "Alex Kim", "unchanged confirmed rows should keep the suggested name")
        if case .confirmed? = update?.action {
            assertTrue(true, "unchanged confirmed rows should stay confirmations")
        } else {
            assertTrue(false, "unchanged confirmed rows should not become corrections")
        }
    }
}

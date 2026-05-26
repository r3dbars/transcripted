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
        let entry = makeSpeakerNamingPolicyEntry(
            channel: .mic,
            currentName: "Speaker 1",
            needsNaming: true
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

    runSuite("SpeakerNamingPolicy skips blank row edits") {
        let update = SpeakerNamingPolicy.typedNameUpdate(
            entry: makeSpeakerNamingPolicyEntry(currentName: nil, needsNaming: true),
            typedName: "   ",
            optionsByLabel: [:]
        )

        assertNil(update, "blank speaker rows should stay unresolved instead of writing empty names")
    }

    runSuite("SpeakerNamingPolicy turns an explicit saved-person label into a merge") {
        let target = SpeakerIdentityOption(id: UUID(), displayName: "Jordan Lee", callCount: 5)
        let update = SpeakerNamingPolicy.typedNameUpdate(
            entry: makeSpeakerNamingPolicyEntry(currentName: nil, needsNaming: true),
            typedName: "Jordan Lee",
            optionsByLabel: ["Jordan Lee": target]
        )

        assertEqual(update?.newName, "Jordan Lee", "selected saved-person labels should keep the saved display name")
        if case .merged(let targetProfileId)? = update?.action {
            assertEqual(targetProfileId, target.id, "selected saved-person labels should merge into that profile")
        } else {
            assertTrue(false, "selected saved-person labels should emit a merge action")
        }
    }

    runSuite("SpeakerNamingPolicy separates new names from corrected suggestions") {
        let named = SpeakerNamingPolicy.typedNameUpdate(
            entry: makeSpeakerNamingPolicyEntry(currentName: nil, needsNaming: true),
            typedName: "Riley",
            optionsByLabel: [:]
        )
        if case .named? = named?.action {
            assertTrue(true, "unknown voices should become named rows")
        } else {
            assertTrue(false, "unknown voices should emit .named")
        }

        let corrected = SpeakerNamingPolicy.typedNameUpdate(
            entry: makeSpeakerNamingPolicyEntry(currentName: "Alex", needsConfirmation: true),
            typedName: "Morgan",
            optionsByLabel: [:]
        )
        if case .corrected? = corrected?.action {
            assertTrue(true, "changing a suggested match should become a correction")
        } else {
            assertTrue(false, "changing a suggested match should emit .corrected")
        }
    }
}

private func makeSpeakerNamingPolicyEntry(
    channel: UtteranceChannel = .system,
    currentName: String?,
    needsNaming: Bool = false,
    needsConfirmation: Bool = false
) -> SpeakerNamingEntry {
    SpeakerNamingEntry(
        id: UUID(),
        diarizerSpeakerId: "1",
        channel: channel,
        clipURL: URL(fileURLWithPath: "/tmp/speaker-row.wav"),
        sampleText: "Sample speaker audio.",
        currentName: currentName,
        matchSimilarity: nil,
        needsNaming: needsNaming,
        needsConfirmation: needsConfirmation
    )
}

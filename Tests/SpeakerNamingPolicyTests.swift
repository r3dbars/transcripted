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
            similarity: 0.97,
            secondBestSimilarity: -1
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
            similarity: 0.95,            // above the raised 0.92 auto-accept bar
            secondBestSimilarity: -1     // no confusable runner-up -> margin satisfied
        )

        assertEqual(mapping.identifiedName, "Alex", "strong repeated matches should still auto-apply")
        assertEqual(mapping.displayName, "Alex", "auto-applied names should render without a tentative suffix")
        assertEqual(mapping.confidence, .high, "strong repeated matches should be marked high confidence")
    }

    runSuite("SpeakerNamingPolicy.initialMapping confirms (does not auto-apply) when a runner-up is close") {
        let profile = SpeakerProfile(
            id: UUID(),
            displayName: "Alex",
            nameSource: NameSource.userManual,
            embedding: [0.1, 0.2, 0.3],
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: 8,
            confidence: 0.9,
            disputeCount: 0
        )

        // sim 0.94 clears the 0.92 bar, but the runner-up at 0.90 is only 0.04 away
        // (< 0.12 margin) — ambiguous, so route to confirm rather than silently name.
        let ambiguous = SpeakerNamingPolicy.initialMapping(
            speakerId: "0", profile: profile, similarity: 0.94, secondBestSimilarity: 0.90
        )
        assertNil(ambiguous.identifiedName, "a close runner-up should block silent auto-naming (confirm instead)")

        // same match with a clear gap (runner-up 0.78) auto-applies.
        let clear = SpeakerNamingPolicy.initialMapping(
            speakerId: "0", profile: profile, similarity: 0.94, secondBestSimilarity: 0.78
        )
        assertEqual(clear.identifiedName, "Alex", "a clear-winner match should still auto-apply")
    }

    runSuite("SpeakerNamingPolicy.initialMapping no longer auto-applies between 0.88 and 0.92") {
        let profile = SpeakerProfile(
            id: UUID(),
            displayName: "Alex",
            nameSource: NameSource.userManual,
            embedding: [0.1, 0.2, 0.3],
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: 8,
            confidence: 0.9,
            disputeCount: 0
        )

        // 0.90 would have auto-applied under the old 0.88 bar; with the raised 0.92 bar it
        // must drop to a confirm.
        let mapping = SpeakerNamingPolicy.initialMapping(
            speakerId: "0", profile: profile, similarity: 0.90, secondBestSimilarity: -1
        )
        assertNil(mapping.identifiedName, "matches between the old and new bar should confirm, not auto-apply")
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
            similarity: 0.95,
            secondBestSimilarity: -1
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

    runSuite("SpeakerReviewAnalytics derives only privacy-safe review lifecycle properties") {
        let localEntry = makeSpeakerNamingPolicyEntry(
            channel: .mic,
            currentName: nil,
            needsNaming: true
        )
        let remoteEntry = makeSpeakerNamingPolicyEntry(
            channel: .system,
            currentName: "Alex",
            needsConfirmation: true
        )
        let request = SpeakerNamingRequest(
            speakers: [localEntry, remoteEntry],
            transcriptURL: URL(fileURLWithPath: "/tmp/private-meeting.md"),
            transcriptId: UUID(),
            systemAudioURL: URL(fileURLWithPath: "/tmp/system.wav"),
            micAudioURL: URL(fileURLWithPath: "/tmp/mic.wav"),
            onComplete: { _ in }
        )
        let updates = [
            SpeakerNameUpdate(
                persistentSpeakerId: localEntry.id,
                diarizerSpeakerId: localEntry.diarizerSpeakerId,
                channel: .mic,
                newName: "You",
                previousName: localEntry.currentName,
                action: .collapsedToMe
            ),
            SpeakerNameUpdate(
                persistentSpeakerId: remoteEntry.id,
                diarizerSpeakerId: remoteEntry.diarizerSpeakerId,
                channel: .system,
                newName: "Alex",
                previousName: remoteEntry.currentName,
                action: .confirmed
            ),
            SpeakerNameUpdate(
                persistentSpeakerId: UUID(),
                diarizerSpeakerId: "discarded",
                channel: .system,
                newName: "",
                previousName: nil,
                action: .discardedFromDatabase
            ),
        ]

        let properties = SpeakerReviewAnalytics.lifecycleProperties(
            request: request,
            surface: .sheet,
            result: .saved,
            updates: updates
        )

        assertEqual(properties["participant_count_bucket"], "2_3", "review lifecycle should bucket total participants")
        assertEqual(properties["local_count_bucket"], "1", "review lifecycle should bucket local voices")
        assertEqual(properties["remote_count_bucket"], "1", "review lifecycle should bucket remote voices")
        assertEqual(properties["suggestion_count_bucket"], "1", "review lifecycle should bucket suggestions")
        assertEqual(properties["unknown_count_bucket"], "1", "review lifecycle should bucket unknown labels")
        assertEqual(properties["has_local"], "true", "local inventory should be boolean")
        assertEqual(properties["has_remote"], "true", "remote inventory should be boolean")
        assertEqual(properties["has_suggestions"], "true", "suggestion inventory should be boolean")
        assertEqual(properties["collapsed_local_to_you"], "true", "local collapse should be boolean")
        assertEqual(properties["confirmed_count_bucket"], "1", "confirmed rows should be bucketed")
        assertEqual(properties["discarded_count_bucket"], "1", "discarded rows should be bucketed")
        assertEqual(properties["typed_count_bucket"], "0", "typed rows should be bucketed")
        assertEqual(properties["review_reason"], "mixed", "mixed review work should stay enum-only")
        assertEqual(properties["result"], "saved", "review outcome should stay enum-only")
        assertEqual(properties["surface"], "review_sheet", "review surface should stay enum-only")
        assertFalse(properties.keys.contains { $0.contains("speaker") }, "property keys should avoid sanitizer-drop speaker fragments")
        assertFalse(properties.keys.contains { $0.contains("name") }, "property keys should avoid sanitizer-drop name fragments")
        assertFalse(properties.keys.contains { $0.contains("title") }, "property keys should avoid sanitizer-drop title fragments")
        assertFalse(properties.keys.contains { $0.contains("transcript") }, "property keys should avoid sanitizer-drop transcript fragments")
        assertFalse(properties.keys.contains { $0.contains("path") }, "property keys should avoid sanitizer-drop path fragments")
    }

    runSuite("SpeakerReviewAnalytics keeps settings actions separate from review lifecycle") {
        let properties = SpeakerReviewAnalytics.settingsActionProperties(
            action: .rowMenu,
            surface: .home,
            pendingCount: 4
        )

        assertEqual(properties["action"], "row_menu", "settings action should stay enum-only")
        assertEqual(properties["pending_count_bucket"], "4_9", "pending count should be bucketed")
        assertEqual(properties["result"], "opened", "settings action result should stay enum-only")
        assertEqual(properties["review_reason"], "settings_queue", "settings action reason should stay enum-only")
        assertEqual(properties["surface"], "home", "settings action surface should stay enum-only")
        assertFalse(properties.keys.contains { $0.contains("speaker") }, "settings action keys should avoid sanitizer-drop speaker fragments")
        assertFalse(properties.keys.contains { $0.contains("name") }, "settings action keys should avoid sanitizer-drop name fragments")
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

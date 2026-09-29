import Foundation

func testSpeakerNameSelectionPolicy() {
    runSuite("SpeakerNameSelectionPolicy finds the one saved person a queued voice is named after") {
        struct Person { let id: UUID; let name: String? }
        let voice = Person(id: UUID(), name: nil)
        let alice = Person(id: UUID(), name: "Alice Park")
        let sam = Person(id: UUID(), name: "Sam")
        let otherSam = Person(id: UUID(), name: "sam")
        let people = [voice, alice, sam, otherSam]
        func find(_ name: String, excluding: UUID = voice.id) -> UUID? {
            SpeakerNameSelectionPolicy.uniqueSavedPerson(
                named: name, among: people, excluding: excluding, id: { $0.id }, displayName: { $0.name }
            )?.id
        }
        assertEqual(find("  alice PARK "), alice.id, "an invitee chip or typed name joins the saved Alice")
        assertNil(find("Alice"), "a first name alone is a different name, so it stays a new person")
        assertNil(find("Sam"), "two saved Sams: can't tell which, so the voice is named as typed")
        assertNil(find("Alice Park", excluding: alice.id), "a voice is never merged into itself")
        assertNil(find("   "), "an empty name matches nobody")
    }

    runSuite("SpeakerNameSelectionPolicy suggests the only prefix match") {
        let people = [
            makeSpeakerIdentityOption(name: "Taylor Wolfe", calls: 9),
            makeSpeakerIdentityOption(name: "Matt Bentley", calls: 4),
        ]
        let labels = SpeakerNameSelectionPolicy.makeIdentityLabels(for: people, id: { $0.id }, displayName: { $0.displayName }, callCount: { $0.callCount })

        let completion = SpeakerNameSelectionPolicy.completedLabel(
            for: "tay",
            labels: labels.labels,
            optionsByLabel: labels.lookup,
            displayName: { $0.displayName },
            callCount: { $0.callCount }
        )

        assertEqual(completion, "Taylor Wolfe", "typing a unique prefix should auto-complete the matching speaker")
    }

    runSuite("SpeakerNameSelectionPolicy does not auto-complete ambiguous prefixes") {
        let people = [
            makeSpeakerIdentityOption(name: "Taylor Wolfe", calls: 9),
            makeSpeakerIdentityOption(name: "Tanya Smith", calls: 7),
        ]
        let labels = SpeakerNameSelectionPolicy.makeIdentityLabels(for: people, id: { $0.id }, displayName: { $0.displayName }, callCount: { $0.callCount })

        let completion = SpeakerNameSelectionPolicy.completedLabel(
            for: "ta",
            labels: labels.labels,
            optionsByLabel: labels.lookup,
            displayName: { $0.displayName },
            callCount: { $0.callCount }
        )

        assertNil(completion, "ambiguous prefixes should leave the user's typed text alone")
    }

    runSuite("SpeakerNameSelectionPolicy resolves typed display names without forcing dropdown labels") {
        let id = UUID()
        let people = [
            SpeakerIdentityOption(id: id, displayName: "Taylor Wolfe", callCount: 3),
            SpeakerIdentityOption(id: UUID(), displayName: "Taylor Wolfe", callCount: 1),
        ]
        let labels = SpeakerNameSelectionPolicy.makeIdentityLabels(for: people, id: { $0.id }, displayName: { $0.displayName }, callCount: { $0.callCount })

        let option = SpeakerNameSelectionPolicy.option(
            matching: "Taylor Wolfe • 3 calls • \(id.uuidString.prefix(8))",
            optionsByLabel: labels.lookup,
            displayName: { $0.displayName }
        )

        assertEqual(option?.id, id, "duplicate-name labels should still map to their exact selected person")
    }

    runSuite("SpeakerNameSelectionPolicy recognizes the owner label") {
        assertTrue(SpeakerNameSelectionPolicy.isOwnerLabel("You"), "exact owner label should match")
        assertTrue(SpeakerNameSelectionPolicy.isOwnerLabel("  you  "), "owner label should ignore case and surrounding whitespace")
        assertFalse(SpeakerNameSelectionPolicy.isOwnerLabel("Young"), "nearby names should not collapse to the owner speaker")
    }
}

private func makeSpeakerIdentityOption(name: String, calls: Int) -> SpeakerIdentityOption {
    SpeakerIdentityOption(id: UUID(), displayName: name, callCount: calls)
}

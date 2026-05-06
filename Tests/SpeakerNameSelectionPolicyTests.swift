import Foundation

func testSpeakerNameSelectionPolicy() {
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
}

private func makeSpeakerIdentityOption(name: String, calls: Int) -> SpeakerIdentityOption {
    SpeakerIdentityOption(id: UUID(), displayName: name, callCount: calls)
}

import Foundation

func testSpeakerVoiceRowPresentation() {
    runSuite("Play/pause toggle shows a pause glyph only while a clip plays") {
        assertEqual(
            SpeakerClipPlaybackPresentation.symbolName(isPlaying: false),
            "play.fill",
            "idle rows should show the play glyph"
        )
        assertEqual(
            SpeakerClipPlaybackPresentation.symbolName(isPlaying: true),
            "pause.fill",
            "a playing row should flip to the pause glyph"
        )
    }

    runSuite("Only a row that is actually playing a clip lights up as active") {
        assertTrue(
            SpeakerClipPlaybackPresentation.isActiveHighlight(hasClip: true, isPlaying: true),
            "a clip that is playing should highlight"
        )
        assertFalse(
            SpeakerClipPlaybackPresentation.isActiveHighlight(hasClip: true, isPlaying: false),
            "a clip that is not playing should not highlight"
        )
        assertFalse(
            SpeakerClipPlaybackPresentation.isActiveHighlight(hasClip: false, isPlaying: true),
            "a row with no clip can never be the active playing row"
        )
    }

    runSuite("Play/pause accessibility + help copy track playing state") {
        assertEqual(SpeakerClipPlaybackPresentation.accessibilityLabel(isPlaying: false), "Play voice sample")
        assertEqual(SpeakerClipPlaybackPresentation.accessibilityLabel(isPlaying: true), "Pause voice sample")
        assertEqual(
            SpeakerClipPlaybackPresentation.helpText(hasClip: false, isPlaying: false),
            "No voice clip was saved for this speaker",
            "a clipless row should explain why playback is unavailable"
        )
        assertEqual(SpeakerClipPlaybackPresentation.helpText(hasClip: true, isPlaying: true), "Pause this voice sample")
        assertEqual(SpeakerClipPlaybackPresentation.helpText(hasClip: true, isPlaying: false), "Play a short clip of this voice")
    }

    runSuite("Overflow menu exposes Show transcript then a destructive Delete voice") {
        let actions = SpeakerVoiceRowMenuPolicy.actions
        assertEqual(actions.count, 2, "the menu should expose exactly two actions")
        assertEqual(actions.first, .showTranscript, "Show transcript should come first")
        assertEqual(actions.last, .deleteVoice, "Delete voice should come last")
        assertEqual(SpeakerVoiceRowMenuAction.showTranscript.title, "Show transcript")
        assertEqual(SpeakerVoiceRowMenuAction.deleteVoice.title, "Delete voice")
        assertFalse(SpeakerVoiceRowMenuAction.showTranscript.isDestructive, "showing a transcript is non-destructive")
        assertTrue(SpeakerVoiceRowMenuAction.deleteVoice.isDestructive, "deleting a voice is destructive")
    }

    runSuite("Delete never silently no-ops: a failed delete yields a surfaced error") {
        assertNil(
            SpeakerVoiceRowMenuPolicy.deleteErrorMessage(didDelete: true),
            "a confirmed delete should produce no error copy"
        )
        let failure = SpeakerVoiceRowMenuPolicy.deleteErrorMessage(didDelete: false)
        assertNotNil(failure, "a delete that did not remove the speaker must surface an error")
        assertFalse(failure?.isEmpty ?? true, "the surfaced error must not be empty")
    }

    runSuite("Name autocomplete suggests only named profiles and never the voice itself") {
        let current = UUID()
        let other = UUID()
        let profiles = [
            makeVoiceRowProfile(id: current, name: "Sasha Kim", calls: 6),
            makeVoiceRowProfile(id: other, name: "Devon Park", calls: 3),
            makeVoiceRowProfile(id: UUID(), name: nil, calls: 2),
            makeVoiceRowProfile(id: UUID(), name: "   ", calls: 1),
        ]

        let options = SpeakerNameSuggestionSource.options(from: profiles, excluding: current)
        assertEqual(options.count, 1, "the unnamed, the blank, and the voice itself should all be excluded")
        assertEqual(options.first?.id, other, "only the other named profile should be suggested")
        assertEqual(options.first?.displayName, "Devon Park")
        assertEqual(options.first?.callCount, 3, "call count should carry through for ranking")
    }

    runSuite("Name autocomplete reuses SpeakerNameSelectionPolicy for inline completion") {
        let profiles = [
            makeVoiceRowProfile(id: UUID(), name: "Taylor Wolfe", calls: 9),
            makeVoiceRowProfile(id: UUID(), name: "Matt Bentley", calls: 4),
        ]
        let options = SpeakerNameSuggestionSource.options(from: profiles, excluding: nil)
        let labels = SpeakerNameSelectionPolicy.makeIdentityLabels(
            for: options,
            id: { $0.id },
            displayName: { $0.displayName },
            callCount: { $0.callCount }
        )

        let completion = SpeakerNameSelectionPolicy.completedLabel(
            for: "tay",
            labels: labels.labels,
            optionsByLabel: labels.lookup,
            displayName: { $0.displayName },
            callCount: { $0.callCount }
        )
        assertEqual(
            completion,
            "Taylor Wolfe",
            "the Speakers field should auto-complete a unique prefix exactly like the naming sheet"
        )
    }
}

private func makeVoiceRowProfile(id: UUID, name: String?, calls: Int) -> SpeakerProfile {
    SpeakerProfile(
        id: id,
        displayName: name,
        nameSource: name == nil ? nil : NameSource.userManual,
        embedding: [],
        firstSeen: Date(timeIntervalSince1970: 0),
        lastSeen: Date(timeIntervalSince1970: 0),
        callCount: calls,
        confidence: 1.0,
        disputeCount: 0
    )
}

import Foundation

func testHomePresentation() {
    runSuite("HomeMeetingSpeakerPalette.colorIndex — one color per person everywhere") {
        func colorIndex(_ identity: HomeMeetingSpeakerIdentity) -> Int {
            HomeMeetingSpeakerPalette.colorIndex(
                persistentSpeakerID: identity.persistentSpeakerID,
                stableID: identity.stableID
            )
        }
        let profileID = UUID(uuidString: "6F1C2D3E-4A5B-4C6D-8E9F-0A1B2C3D4E5F")!
        let saved = HomeMeetingSpeakerIdentity(
            displayName: "Avery Stone",
            rawLabel: "Avery Stone",
            channel: .system,
            diarizerSpeakerID: "2",
            persistentSpeakerID: profileID
        )
        assertEqual(
            colorIndex(saved),
            VoicePrintStyle(id: profileID).preferredColorIndex,
            "A saved person's transcript color is their voice-print color (Speakers page, island)"
        )

        let renamed = HomeMeetingSpeakerIdentity(
            displayName: "Avery S.",
            rawLabel: "Avery S.",
            channel: .mic,
            diarizerSpeakerID: "7",
            persistentSpeakerID: profileID
        )
        assertEqual(
            colorIndex(renamed),
            colorIndex(saved),
            "Renaming or a new meeting doesn't change a saved person's color"
        )

        let unsaved = HomeMeetingSpeakerIdentity(
            displayName: "Speaker 2",
            rawLabel: "Speaker 2",
            channel: .system,
            diarizerSpeakerID: "2",
            persistentSpeakerID: nil
        )
        assertEqual(unsaved.stableID, "voice:system:2", "an unsaved voice keys by its channel and diarizer id")
        assertEqual(
            colorIndex(unsaved),
            VoicePrintStyle(seedString: "voice:system:2").preferredColorIndex,
            "An unsaved voice keeps one color: the one its transcript key seeds, so it stays put across launches"
        )

        let names = (1...12).map { index in
            HomeMeetingSpeakerIdentity(
                displayName: "Speaker \(index)",
                rawLabel: "Speaker \(index)",
                channel: .system,
                diarizerSpeakerID: "\(index)",
                persistentSpeakerID: nil
            )
        }
        for identity in names {
            let index = colorIndex(identity)
            assertTrue(index >= 0 && index < HomeMeetingSpeakerPalette.slotCount, "Index stays inside the voice-print palette")
        }
        assertTrue(
            Set(names.map(colorIndex)).count >= 4,
            "Different voices spread across the palette"
        )
    }

    runSuite("HomeDaySectionLabel.label — Today / Yesterday / formatted date") {
        let calendar = Calendar.current
        let now = Date()

        assertEqual(
            HomeDaySectionLabel.label(for: calendar.startOfDay(for: now)),
            "Today",
            "The current day should label as Today"
        )

        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        assertEqual(
            HomeDaySectionLabel.label(for: calendar.startOfDay(for: yesterday)),
            "Yesterday",
            "The prior day should label as Yesterday"
        )

        // A fixed instant safely in the past so it never collides with Today/Yesterday:
        // 2026-04-25 12:00:00 UTC (a Saturday). Format with the same formatter the
        // label uses so the assertion stays locale/timezone agnostic.
        let pastDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_777_723_200))
        assertEqual(
            HomeDaySectionLabel.label(for: pastDay),
            HomeDaySectionLabel.formatter.string(from: pastDay),
            "Older days should fall through to the EEEE, MMM d formatter"
        )
        assertFalse(HomeDaySectionLabel.label(for: pastDay) == "Today")
        assertFalse(HomeDaySectionLabel.label(for: pastDay) == "Yesterday")
    }

    runSuite("HomeCaptureListCopy — pinned empty-state strings") {
        assertEqual(
            HomeCaptureListCopy.emptyMeetings,
            "No recent meetings. Record one or transcribe an existing audio file."
        )
        assertEqual(HomeCaptureListCopy.emptyDictations, "No recent dictations.")
    }

    runSuite("HomeMeetingRenameAffordance — pinned discoverable edit control") {
        assertEqual(HomeMeetingRenameAffordance.title, "Rename")
        assertEqual(HomeMeetingRenameAffordance.help, "Rename meeting")
        assertEqual(HomeMeetingRenameAffordance.symbolName, "pencil")
        assertEqual(
            HomeMeetingRenameAffordance.automationIdentifier,
            "transcripted.home.meeting-preview.rename"
        )
    }

    runSuite("HomeMeetingTitleEditPolicy commits only a meaningful changed title") {
        assertEqual(
            HomeMeetingTitleEditPolicy.titleToCommit(draft: "  New title  ", currentTitle: "Old title"),
            "New title",
            "rename should trim the submitted title"
        )
        assertNil(
            HomeMeetingTitleEditPolicy.titleToCommit(draft: "   ", currentTitle: "Old title"),
            "blank rename should stay a cancel"
        )
        assertNil(
            HomeMeetingTitleEditPolicy.titleToCommit(draft: "Old title", currentTitle: "Old title"),
            "unchanged rename should not rewrite artifacts"
        )
    }
}

import Foundation

func testHomePresentation() {
    runSuite("HomeMeetingSpeakerPalette.slotIndex — stable, in-range, spread") {
        let slotCount = HomeMeetingSpeakerPalette.slotCount

        // Fixed mapping vectors catch a changed assignment between launches.
        for (name, expectedSlot) in [("Linus", 3), ("Alex", 2), ("You", 5)] {
            assertEqual(
                HomeMeetingSpeakerPalette.slotIndex(for: name),
                expectedSlot,
                "Existing speaker palette assignments should remain stable"
            )
        }

        // Normalization: case and surrounding whitespace do not change the slot.
        assertEqual(
            HomeMeetingSpeakerPalette.slotIndex(for: "Linus"),
            HomeMeetingSpeakerPalette.slotIndex(for: "  linus  "),
            "Slot selection should normalize case and whitespace"
        )

        // Every slot stays inside the palette range.
        let names = ["You", "Alex", "Linus", "Speaker 1", "Speaker 2", "Sam", "Jordan", "Riley", "Casey", "Morgan"]
        for name in names {
            let index = HomeMeetingSpeakerPalette.slotIndex(for: name)
            assertTrue(index >= 0 && index < slotCount, "Slot for \(name) should be within 0..<\(slotCount)")
        }

        // Distinct names spread across multiple slots (not all collapsed to one).
        let distinctSlots = Set(names.map { HomeMeetingSpeakerPalette.slotIndex(for: $0) })
        assertTrue(distinctSlots.count >= 4, "Distinct speaker names should spread across several palette slots")

        // Custom slot count is honored (mirrors the app palette of 8).
        let small = HomeMeetingSpeakerPalette.slotIndex(for: "Linus", slotCount: 3)
        assertTrue(small >= 0 && small < 3, "Custom slot count should be respected")
    }

    runSuite("HomeStableReferenceID.id — deterministic FNV-1a derivation") {
        // A representative capture id retains its published byte-stable output.
        assertEqual(
            HomeStableReferenceID.id(for: "297F08B7-62AE-4291-9EA3-41EB0B17A64A"),
            "72634aa329e052b2",
            "Existing capture ids should retain their stable reference ids"
        )

        // Distinct inputs -> distinct ids.
        let a = HomeStableReferenceID.id(for: "meeting-1")
        let b = HomeStableReferenceID.id(for: "meeting-2")
        assertTrue(a != b, "Distinct capture ids should derive distinct stable reference ids")

        // Pinned outputs so the on-disk/telemetry shape stays byte-stable
        // (offset basis matches the literal used in HomeView, not canonical FNV).
        assertEqual(HomeStableReferenceID.id(for: ""), "14650fb0739d0383", "Empty input returns the offset basis in hex")
        assertEqual(HomeStableReferenceID.id(for: "a"), "44bd8ad473cd9906", "Single-byte hash is pinned")
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

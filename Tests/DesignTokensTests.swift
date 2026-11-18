import AppKit
import Foundation

func testDesignTokens() {
    runSuite("DesignTokens — six text roles at the agreed sizes") {
        let sizes = TextRole.allCases.map(\.size)
        assertEqual(sizes, [28, 15, 13, 12, 11, 10.5], "display, heading, body, meta, small, label")
        assertTrue(TextRole.label.isUppercased && TextRole.label.tracking > 0, "the label role is uppercase and tracked")
        assertTrue(
            TextRole.allCases.filter { $0 != .label }.allSatisfy { !$0.isUppercased && $0.tracking == 0 },
            "only the label role changes case or tracking"
        )
    }

    // Runs before anything registers the bundled fonts: tests and smokes have
    // no app bundle, so the roles must fall back to system faces.
    runSuite("DesignTokens — display and label fall back without the bundled fonts") {
        let registered = BundledFonts.registerForProcess()
        guard registered.isEmpty else {
            assertTrue(true, "fonts were already registered in this process; fallback not observable here")
            return
        }
        let display = TextRole.display.nsFont()
        assertEqual(display.pointSize, 28, "display keeps its size on the fallback")
        assertTrue(
            display.familyName != NSFont.systemFont(ofSize: 28).familyName,
            "display falls back to the system serif, not the sans system font"
        )
        let label = TextRole.label.nsFont()
        assertEqual(label.pointSize, 10.5, "label keeps its size on the fallback")
        assertTrue(label.isFixedPitch, "label falls back to the system monospaced face")
    }

    runSuite("DesignTokens — bundled fonts register for the process and drive the roles") {
        let fonts = repoRoot().appendingPathComponent("Resources/Fonts", isDirectory: true)
        let available = BundledFonts.register(directory: fonts)
        assertEqual(Set(available), Set(BundledFonts.Face.allCases), "all four bundled faces register")
        assertEqual(TextRole.display.nsFont().fontName, "InstrumentSerif-Regular", "display uses Instrument Serif")
        assertEqual(TextRole.label.nsFont().fontName, "JetBrainsMono-Medium", "label uses JetBrains Mono Medium")
        assertEqual(
            Set(BundledFonts.register(directory: fonts)),
            Set(BundledFonts.Face.allCases),
            "registering again is harmless"
        )
    }

    runSuite("DesignTokens — the popover and main window read the shared colors") {
        assertTrue(MenuTokens.textPrimaryNS === DesignTokens.NS.ink, "popover ink is the shared ink")
        assertTrue(MenuTokens.buttonBackgroundNS === DesignTokens.NS.ink, "popover filled buttons are ink")
        assertTrue(MenuTokens.statusReadyNS !== DesignTokens.NS.live, "ready is not green")
        assertEqual(MenuTokens.cardCornerRadius, DesignTokens.Radius.control, "popover cards use the control radius")
        assertEqual(LibraryTokens.radiusRaised, DesignTokens.Radius.surface, "raised cards use the surface radius")
    }

    runSuite("DesignTokens — island prompt buttons take their style from what they do") {
        let note = MeetingAutoRecordNoteCopy.prompt
        assertEqual(note.primaryTitle, "Stop", "auto-record note primary is Stop")
        assertEqual(note.primaryRole, .primary, "Stop keeps the recording, so it is the safe primary, not red")
        assertEqual(note.secondaryTitle, "Discard", "auto-record note secondary is Discard")
        assertEqual(note.secondaryRole, .standard, "the first Discard only asks, so it stays grey; red is the confirm")

        let warning = NotchIslandMeetingContent.Prompt(
            title: "No sound",
            detail: "Nothing heard for 2 minutes.",
            countdown: "",
            primaryTitle: "Stop",
            secondaryTitle: "Dismiss",
            tertiaryTitle: nil
        )
        assertEqual(warning.primaryRole, .primary, "a warning's Stop and transcribe defaults to the primary, not red")
        assertEqual(warning.secondaryRole, .standard, "Dismiss stays the quiet pill")
    }
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

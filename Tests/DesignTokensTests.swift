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

    runSuite("DesignTokens — page titles are the system font, semibold") {
        let display = TextRole.display.nsFont()
        let system = NSFont.systemFont(ofSize: 28, weight: .semibold)
        assertEqual(display.pointSize, 28)
        assertEqual(display.fontName, system.fontName, "display is the system sans, not a serif")
    }

    // Runs before anything registers the bundled fonts: tests and smokes have
    // no app bundle, so the label role must fall back to a system face.
    runSuite("DesignTokens — label is a 10.5 pt fixed-pitch face, bundled or fallback") {
        // When JetBrains Mono is already available (installed on this Mac,
        // or registered earlier in the process) the fallback can't be seen,
        // so check what holds either way: the size, fixed pitch, and which
        // face it is.
        let registered = BundledFonts.registerForProcess()
        let label = TextRole.label.nsFont()
        assertEqual(label.pointSize, 10.5, "label keeps its size")
        assertTrue(label.isFixedPitch, "label is always a monospaced face")
        if registered.isEmpty {
            assertTrue(label.fontName != BundledFonts.Face.jetBrainsMonoMedium.postScriptName,
                       "without the bundled font, label falls back to the system monospaced face")
        } else {
            assertEqual(label.fontName, BundledFonts.Face.jetBrainsMonoMedium.postScriptName,
                        "with the font available, label uses it")
        }
    }

    runSuite("DesignTokens — bundled fonts register for the process and drive the roles") {
        let fonts = repoRoot().appendingPathComponent("Resources/Fonts", isDirectory: true)
        let available = BundledFonts.register(directory: fonts)
        assertEqual(Set(available), Set(BundledFonts.Face.allCases), "the bundled face registers")
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

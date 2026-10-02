// Focus / Tab order contract suite.
//
// The visual layout of a surface does not prove anything about the order the
// focus ring travels through its controls. These checks pin the keyboard Tab
// order so a UI sweep can't silently reshuffle it: FocusOrderContract must be
// a well-formed loop, the real menu bar rows must take focus and activate from
// the keyboard, the real section views must hand their rows over in the
// declared order, and the settings sidebar's primary rows must match the
// identifiers and ⌘ shortcuts the real TranscriptedSettingsPage cases produce.

import AppKit
import Foundation

@MainActor
func testFocusOrderContract() async {
    runSuite("Focus order contract - declared orders form well-formed Tab loops") {
        for surface in FocusOrderContract.Surface.allCases {
            let order = FocusOrderContract.order(for: surface)
            assertFalse(order.isEmpty, "\(surface.rawValue) should declare a focus order")
            assertTrue(
                FocusOrderContract.duplicateIdentifiers(in: order).isEmpty,
                "\(surface.rawValue) focus order must not repeat a control (a duplicate traps or skips Tab focus)"
            )
            assertTrue(
                order.allSatisfy { !$0.isEmpty },
                "\(surface.rawValue) focus order must not contain empty identifiers"
            )
        }

        // The popover loop is exactly the primary section followed by the
        // utility section, matching the top-to-bottom layout of MenuBarContentView.
        assertEqual(
            FocusOrderContract.menuBarPopoverOrder,
            FocusOrderContract.menuBarPrimaryOrder + FocusOrderContract.menuBarUtilityOrder,
            "popover Tab order should be primary actions then utility actions"
        )

        // Every major action stays reachable in the loop. (Slim menu:
        // Settings lives inside Open Transcripted, so it has no row.)
        assertTrue(
            FocusOrderContract.isReachable(
                [
                    "transcripted.menubar.primary.start-dictation",
                    "transcripted.menubar.primary.start-meeting",
                    "transcripted.menubar.utility.open-transcripted",
                    "transcripted.menubar.utility.check-updates",
                    "transcripted.menubar.utility.quit",
                ],
                in: FocusOrderContract.menuBarPopoverOrder
            ),
            "core popover actions must all be reachable by keyboard"
        )

        assertTrue(
            FocusOrderContract.isReachable(
                [
                    "transcripted.settings.sidebar.today",
                    "transcripted.settings.sidebar.home",
                    "transcripted.settings.sidebar.dictations",
                    "transcripted.settings.sidebar.writing",
                    "transcripted.settings.sidebar.people",
                    "transcripted.settings.sidebar.connect-agent",
                ],
                in: FocusOrderContract.settingsSidebarOrder
            ),
            "primary settings sidebar pages must all be reachable by keyboard"
        )

        // A focus order that lost a control should be detectable, not silent.
        assertFalse(
            FocusOrderContract.isReachable(
                ["transcripted.menubar.utility.quit"],
                in: FocusOrderContract.menuBarPrimaryOrder
            ),
            "reachability check should fail when a control is outside the given loop"
        )
    }

    runSuite("Focus order contract - menu bar rows take focus and activate from the keyboard") {
        _ = NSApplication.shared
        let row = MenuBarActionRowView(frame: NSRect(x: 0, y: 0, width: 200, height: 28))
        row.update(symbolName: "power", title: "Quit", detail: "")
        var presses = 0
        row.onPress = { presses += 1 }

        assertTrue(row.acceptsFirstResponder, "an enabled, visible row should accept keyboard focus")
        assertTrue(row.canBecomeKeyView, "an enabled, visible row should join the key-view loop")
        assertEqual(row.focusRingMaskBounds, row.bounds, "the focus ring should outline the whole row")

        // Space (49), Return (36), and keypad Enter (76) activate, like AppKit buttons.
        for (keyCode, characters) in [(UInt16(49), " "), (UInt16(36), "\r"), (UInt16(76), "\u{3}")] {
            guard let event = focusOrderKeyDown(keyCode: keyCode, characters: characters) else {
                assertTrue(false, "expected to build a key event for key code \(keyCode)")
                continue
            }
            row.keyDown(with: event)
        }
        assertEqual(presses, 3, "Space, Return, and keypad Enter should each press the focused row")

        row.isEnabled = false
        assertFalse(row.acceptsFirstResponder, "a disabled row should drop out of the Tab loop")
        assertFalse(row.canBecomeKeyView, "a disabled row should not be a key view")

        row.isEnabled = true
        row.isHidden = true
        assertFalse(row.acceptsFirstResponder, "a hidden row should drop out of the Tab loop")
    }

    runSuite("Focus order contract - menu bar sections hand over their rows in the declared order") {
        _ = NSApplication.shared
        let primary = MenuBarPrimaryActionsView(frame: .zero)
        let utility = MenuBarUtilityActionsView(frame: .zero)
        utility.update(
            updateSymbolName: "arrow.down.circle",
            updateTitle: "Check for Updates",
            updateDetail: "",
            updateVersion: nil,
            updateTone: .standard,
            updateEnabled: true
        )

        assertEqual(
            primary.keyboardFocusableRows.map { $0.identifier?.rawValue ?? "" },
            FocusOrderContract.menuBarPrimaryOrder,
            "the primary buttons should reach Tab in FocusOrderContract.menuBarPrimaryOrder order"
        )
        assertEqual(
            utility.keyboardFocusableRows.map { $0.identifier?.rawValue ?? "" },
            FocusOrderContract.menuBarUtilityOrder,
            "the utility rows should reach Tab in FocusOrderContract.menuBarUtilityOrder order"
        )

        // A hidden update row leaves the loop instead of trapping focus.
        utility.update(
            updateSymbolName: "arrow.down.circle",
            updateTitle: "Check for Updates",
            updateDetail: "",
            updateVersion: nil,
            updateTone: .standard,
            updateEnabled: true,
            showUpdateRow: false
        )
        assertEqual(
            utility.keyboardFocusableRows.map { $0.identifier?.rawValue ?? "" },
            FocusOrderContract.menuBarUtilityOrder.filter { $0 != "transcripted.menubar.utility.check-updates" },
            "a hidden update row should be skipped by Tab"
        )
    }

    runSuite("Focus order contract - the popover chains its rows into one explicit loop") {
        _ = NSApplication.shared
        let callout = MenuBarActionRowView(frame: .zero)
        callout.isHidden = true
        let primary = MenuBarPrimaryActionsView(frame: .zero)
        let utility = MenuBarUtilityActionsView(frame: .zero)
        utility.update(
            updateSymbolName: "arrow.down.circle",
            updateTitle: "Check for Updates",
            updateDetail: "",
            updateVersion: nil,
            updateTone: .standard,
            updateEnabled: true
        )

        let chain = MenuBarKeyViewLoop.orderedRows(
            updateCallout: callout,
            primary: primary.keyboardFocusableRows,
            utility: utility.keyboardFocusableRows
        )
        assertEqual(
            chain.map { $0.identifier?.rawValue ?? "" },
            FocusOrderContract.menuBarPopoverOrder,
            "with no update callout, the popover loop should be exactly the declared popover order"
        )

        let first = MenuBarKeyViewLoop.link(chain)
        assertTrue(first === chain.first, "the first row in the loop should take initial focus")
        for (index, row) in chain.enumerated() {
            let expected = chain[(index + 1) % chain.count]
            assertTrue(row.nextKeyView === expected, "Tab from row \(index) should land on the next row, wrapping at the end")
        }

        callout.isHidden = false
        let withCallout = MenuBarKeyViewLoop.orderedRows(
            updateCallout: callout,
            primary: primary.keyboardFocusableRows,
            utility: utility.keyboardFocusableRows
        )
        assertTrue(withCallout.first === callout, "a visible update callout should lead the Tab loop")
        assertEqual(withCallout.count, chain.count + 1, "the callout should add exactly one stop")
    }

    runSuite("Focus order contract - settings sidebar nav matches the declared order") {
        // TranscriptedSettingsPage is compiled here, so check the identifiers
        // the real pages produce instead of the text that builds them.
        let producedIdentifiers = Set(TranscriptedSettingsPage.allCases.map(\.automationIdentifier))
        for identifier in FocusOrderContract.settingsSidebarOrder {
            assertTrue(
                producedIdentifiers.contains(identifier),
                "TranscriptedSettingsPage should keep producing the sidebar identifier \(identifier) the contract pins"
            )
        }

        // The primary navigation pages are the ones with a ⌘1–⌘6 "Go"
        // shortcut; in shortcut order they must be exactly the declared Tab order.
        let shortcutOrder = TranscriptedSettingsPage.allCases
            .compactMap { page in page.navigationShortcutKey.map { (key: $0, identifier: page.automationIdentifier) } }
            .sorted { $0.key < $1.key }
            .map(\.identifier)
        assertEqual(
            shortcutOrder,
            FocusOrderContract.settingsSidebarOrder,
            "the ⌘1–⌘6 navigation pages should stay in the settings navigation surface, in the declared focus order"
        )

        // The sidebar's primary rows come from this list, in this order.
        assertEqual(
            SettingsSidebarSection.primarySection.pages.map(\.automationIdentifier),
            FocusOrderContract.settingsSidebarOrder,
            "the sidebar's primary rows should list the pages in the focus order the contract pins"
        )
        // The primary pages are the ones with a ⌘ shortcut, in page order.
        assertEqual(
            FocusOrderContract.settingsSidebarOrder,
            TranscriptedSettingsPage.allCases
                .filter { $0.navigationShortcutKey != nil }
                .map(\.automationIdentifier),
            "settings sidebar focus order should cover the six primary navigation pages in ⌘1–⌘6 order"
        )
    }
}

private func focusOrderKeyDown(keyCode: UInt16, characters: String) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    )
}

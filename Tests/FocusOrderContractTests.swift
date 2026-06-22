// Focus / Tab order contract suite.
//
// The visual layout of a surface does not prove anything about the order the
// focus ring travels through its controls. These checks pin the keyboard Tab
// order so a UI sweep can't silently reshuffle it: a pure-logic half asserts the
// FocusOrderContract is a well-formed loop, and a source half asserts the real
// menu bar views join the key-view loop and attach their identifiers in that
// same order. The source half greps text — it runs no UI.

import Foundation

func testFocusOrderContract() {
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

        // Every major action stays reachable in the loop.
        assertTrue(
            FocusOrderContract.isReachable(
                [
                    "transcripted.menubar.primary.home",
                    "transcripted.menubar.primary.start-dictation",
                    "transcripted.menubar.primary.start-meeting",
                    "transcripted.menubar.utility.settings",
                    "transcripted.menubar.utility.quit",
                ],
                in: FocusOrderContract.menuBarPopoverOrder
            ),
            "core popover actions must all be reachable by keyboard"
        )

        assertTrue(
            FocusOrderContract.isReachable(
                [
                    "transcripted.settings.sidebar.home",
                    "transcripted.settings.sidebar.dictations",
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

    runSuite("Focus order contract - menu bar rows join the keyboard loop") {
        let rowSource = readFocusContractFile("Sources/UI/MenuBar/MenuBarActionRowView.swift")
        let primarySource = readFocusContractFile("Sources/UI/MenuBar/MenuBarPrimaryActionsView.swift")
        let utilitySource = readFocusContractFile("Sources/UI/MenuBar/MenuBarUtilityActionsView.swift")
        let contentSource = readFocusContractFile("Sources/UI/MenuBar/MenuBarContentView.swift")

        // Rows must be focusable controls that activate by keyboard and draw a
        // focus ring, otherwise Tab can never land on or trigger them.
        assertTrue(
            rowSource.contains("override var acceptsFirstResponder: Bool { isEnabled && !isHidden }")
                && rowSource.contains("override var canBecomeKeyView: Bool { acceptsFirstResponder }")
                && rowSource.contains("override func keyDown(with event: NSEvent)")
                && rowSource.contains("event.keyCode == 49 || event.keyCode == 36 || event.keyCode == 76")
                && rowSource.contains("override func drawFocusRingMask()")
                && rowSource.contains("override var focusRingMaskBounds: NSRect { bounds }"),
            "menu bar rows should accept first responder, activate on Space/Return, and draw a focus ring"
        )

        // The section views expose their visible rows in Tab order and the
        // content view chains them into one explicit key-view loop.
        assertTrue(
            primarySource.contains("var keyboardFocusableRows: [MenuBarActionRowView]")
                && utilitySource.contains("var keyboardFocusableRows: [MenuBarActionRowView]"),
            "primary and utility action views should expose keyboardFocusableRows in Tab order"
        )
        assertTrue(
            contentSource.contains("private func configureKeyViewLoop()")
                && contentSource.contains("row.nextKeyView =")
                && contentSource.contains("window?.initialFirstResponder = chain.first")
                && contentSource.contains("primaryActionsView.keyboardFocusableRows")
                && contentSource.contains("utilityActionsView.keyboardFocusableRows"),
            "MenuBarContentView should chain the rows into an explicit key-view loop with an initial first responder"
        )

        // The shipping views must attach identifiers in the same relative order
        // the contract declares, so the pinned Tab order matches the real views.
        assertTrue(
            sourceAttachesIdentifiersInOrder(primarySource, FocusOrderContract.menuBarPrimaryOrder),
            "MenuBarPrimaryActionsView should attach identifiers in FocusOrderContract.menuBarPrimaryOrder order"
        )
        assertTrue(
            sourceAttachesIdentifiersInOrder(utilitySource, FocusOrderContract.menuBarUtilityOrder),
            "MenuBarUtilityActionsView should attach identifiers in FocusOrderContract.menuBarUtilityOrder order"
        )
    }

    runSuite("Focus order contract - settings sidebar nav matches the declared order") {
        let pagesSource = readFocusContractFile("Sources/UI/Settings/TranscriptedSettingsPage.swift")
        let sidebarSource = readFocusContractFile("Sources/UI/Settings/TranscriptedSettingsSidebar.swift")

        // The contract pins the produced identifiers: most pages interpolate
        // `transcripted.settings.sidebar.<rawValue>`, connect-agent uses a
        // bespoke literal, and the sidebar attaches them as the AX identifier.
        assertTrue(
            pagesSource.contains("transcripted.settings.sidebar.\\(rawValue)")
                && pagesSource.contains("transcripted.settings.sidebar.connect-agent"),
            "TranscriptedSettingsPage should keep producing the sidebar identifiers the contract pins"
        )
        assertTrue(
            sidebarSource.contains(".accessibilityIdentifier(page.automationIdentifier)"),
            "the sidebar should attach page.automationIdentifier so the pinned focus order is scriptable"
        )

        // The four primary navigation pages the contract orders must still exist.
        for pageCase in ["case home", "case dictations", "case people", "case connectAgent"] {
            assertTrue(
                pagesSource.contains(pageCase),
                "\(pageCase) should stay in the settings navigation surface the focus order depends on"
            )
        }
        assertEqual(
            FocusOrderContract.settingsSidebarOrder.count,
            4,
            "settings sidebar focus order should cover the four primary navigation pages"
        )
    }
}

private func readFocusContractFile(_ relativePath: String) -> String {
    (try? String(contentsOf: repoFixtureURL(relativePath), encoding: .utf8)) ?? ""
}

/// True when each identifier's `setAutomationIdentifier("…")` attachment appears
/// in `source` strictly after the previous one — i.e. the source attaches them
/// in the given order.
private func sourceAttachesIdentifiersInOrder(_ source: String, _ identifiers: [String]) -> Bool {
    var searchStart = source.startIndex
    for identifier in identifiers {
        let needle = "setAutomationIdentifier(\"\(identifier)\")"
        guard let range = source.range(of: needle, range: searchStart..<source.endIndex) else {
            return false
        }
        searchStart = range.upperBound
    }
    return true
}

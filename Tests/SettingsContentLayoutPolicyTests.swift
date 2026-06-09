import CoreGraphics

func testSettingsContentLayoutPolicy() {
    runSuite("SettingsContentLayoutPolicy protects Home from titlebar clipping") {
        assertEqual(
            SettingsContentLayoutPolicy.topPadding(for: .home, sidebarPresentation: .visible),
            14,
            "Home should stay below the titlebar controls when the sidebar is visible"
        )
        assertEqual(
            SettingsContentLayoutPolicy.topPadding(for: .home, sidebarPresentation: .hidden),
            14,
            "Home should stay below the titlebar controls when the sidebar is hidden"
        )
        assertEqual(
            SettingsContentLayoutPolicy.topPadding(for: .general, sidebarPresentation: .visible),
            14,
            "Non-home pages should keep their normal top spacing"
        )
        assertEqual(
            SettingsContentLayoutPolicy.topPadding(for: .about, sidebarPresentation: .hidden),
            14,
            "Collapsed-sidebar spacing should not special-case other pages"
        )
    }
}

import CoreGraphics

func testSettingsContentLayoutPolicy() {
    runSuite("SettingsContentLayoutPolicy protects collapsed-sidebar chrome") {
        assertEqual(
            SettingsContentLayoutPolicy.topPadding(for: .home, sidebarPresentation: .visible),
            -34,
            "Home should keep the elevated header when the sidebar owns the window controls"
        )
        assertEqual(
            SettingsContentLayoutPolicy.topPadding(for: .home, sidebarPresentation: .hidden),
            14,
            "Home should drop below the titlebar controls when the sidebar is collapsed"
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

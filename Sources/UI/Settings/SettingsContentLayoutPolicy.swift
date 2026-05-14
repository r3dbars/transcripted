import CoreGraphics

enum SettingsSidebarPresentation {
    case visible
    case hidden
}

enum SettingsContentLayoutPolicy {
    static func topPadding(
        for page: TranscriptedSettingsPage,
        sidebarPresentation: SettingsSidebarPresentation
    ) -> CGFloat {
        guard page == .home else { return 14 }
        return sidebarPresentation == .hidden ? 14 : -34
    }
}

import Foundation

/// Which Transcripted screen is up, as one fixed word for crash and hang
/// reports (`open_screen`).
///
/// Main-thread hangs (Sentry APPLE-MACOS-3K) mostly land while the app is
/// idle, and their stacks are all AppKit, SwiftUI or system frames, so they
/// can't say which window was being drawn. This tag can. Values are a closed
/// vocabulary that matches the debug control surface's `open_screen`: no
/// titles, names or free text, and anything unexpected becomes `unknown`.
enum OpenScreenDiagnostics {
    static let key = "open_screen"

    static let none = "none"
    static let menuBar = "menubar"
    static let onboarding = "onboarding"
    static let unknown = "unknown"

    /// Settings window pages, by `TranscriptedSettingsPage.analyticsValue`.
    static let settingsPages: Set<String> = [
        "today",
        "home",
        "files",
        "dictations",
        "writing",
        "general",
        "people",
        "connect_agent",
    ]

    static let allowedValues: Set<String> = settingsPages.union([none, menuBar, onboarding, unknown])

    /// The front-most surface: onboarding, then the menu bar popover, then the
    /// Settings window's page. Same order as the debug control surface.
    static func resolve(onboardingVisible: Bool, menuBarShown: Bool, settingsPage: String?) -> String {
        if onboardingVisible { return onboarding }
        if menuBarShown { return menuBar }
        guard let settingsPage else { return none }
        return normalized(settingsPage)
    }

    /// Keeps only reviewed values; a missing value is `none`, anything else `unknown`.
    static func normalized(_ value: String?) -> String {
        guard let value else { return none }
        return allowedValues.contains(value) ? value : unknown
    }
}

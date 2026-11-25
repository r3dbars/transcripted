import Foundation

/// One set of words for update status, for the popover, the status item's
/// tooltip, the sidebar footer and About. Sentence case, versions as given.
/// `UpdateStatusWords+Sparkle.swift` maps the updater's state onto `Phase`.
enum UpdateStatusWords {
    enum Phase: Equatable {
        /// Nothing found yet, or up to date.
        case idle
        case checking
        case available(version: String)
        case downloading(version: String)
        case readyToInstall(version: String)
    }

    /// A row or button title.
    static func title(for phase: Phase, downloadsAutomatically: Bool) -> String {
        switch phase {
        case .idle:
            return checkForUpdates
        case .checking:
            return "Checking for updates…"
        case .available(let version):
            return downloadsAutomatically ? downloading : "Update to \(version)"
        case .downloading:
            return downloading
        case .readyToInstall(let version):
            return "\(version) is ready"
        }
    }

    /// The second line under the title, or nil.
    static func detail(for phase: Phase, downloadsAutomatically: Bool) -> String? {
        switch phase {
        case .available(let version) where downloadsAutomatically:
            return "Version \(version)"
        case .downloading(let version):
            return "Version \(version)"
        case .readyToInstall:
            return "Restart to finish updating"
        case .idle, .checking, .available:
            return nil
        }
    }

    /// The button word when the update needs a click, else nil.
    static func action(for phase: Phase, downloadsAutomatically: Bool) -> String? {
        switch phase {
        case .available where !downloadsAutomatically:
            return "Install"
        case .readyToInstall:
            return "Restart"
        case .idle, .checking, .available, .downloading:
            return nil
        }
    }

    /// What the status item's tooltip adds after "Transcripted —".
    static func statusItemNote(for phase: Phase) -> String? {
        switch phase {
        case .readyToInstall(let version):
            return "\(version) ready, restart to update"
        case .available(let version):
            return "update to \(version) available"
        case .idle, .checking, .downloading:
            return nil
        }
    }

    /// A short note after the version number (the sidebar footer, About), or
    /// nil to show the version alone. `checkedUpToDate` is the updater's own
    /// "no update" answer, which `Phase.idle` folds in with "never checked".
    static func versionNote(for phase: Phase, checkedUpToDate: Bool, downloadsAutomatically: Bool) -> String? {
        guard phase != .idle else { return checkedUpToDate ? upToDate : nil }
        return title(for: phase, downloadsAutomatically: downloadsAutomatically)
    }

    /// The update button's word in About: what the update needs, or what
    /// the updater is busy with, else the manual check.
    static func buttonTitle(for phase: Phase, downloadsAutomatically: Bool) -> String {
        if let action = action(for: phase, downloadsAutomatically: downloadsAutomatically) { return action }
        switch phase {
        case .idle: return checkForUpdates
        case .checking, .available, .downloading, .readyToInstall:
            return title(for: phase, downloadsAutomatically: downloadsAutomatically)
        }
    }

    static let checkForUpdates = "Check for updates"
    static let downloading = "Downloading update"
    static let upToDate = "Up to date"
}

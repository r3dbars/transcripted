import Foundation

/// Transcripted (docs/writing-plan.md, decision 4): the apps Writing works in,
/// "All apps" or "Only apps I pick". One rule for Save my writing, Screen
/// Memory context and suggestions. Password managers (`DefaultExcludedApps`)
/// and the user's exclusion list win over any scope. Not part of Tilde.
///
/// Stored in the keyboard's shared suite so the keyboard can read it. The
/// keyboard caches the parsed scope and re-reads it when `revisionKey` moves.
public struct WritingAppScope: Equatable, Sendable {
    public enum Mode: String, Sendable {
        case all
        case picked
    }

    public static let modeKey = "WritingAppScopeMode"
    public static let bundleIdentifiersKey = "WritingAppScopeBundleIdentifiers"
    public static let revisionKey = "WritingAppScopeRevision"
    public static let maximumBundleIdentifiers = 256

    public static let all = WritingAppScope(mode: .all, bundleIdentifiers: [])

    public let mode: Mode
    /// The picked apps, sorted and deduplicated; empty for `.all`.
    public let bundleIdentifiers: [String]
    private let lowercasedBundleIdentifiers: Set<String>

    private init(mode: Mode, bundleIdentifiers: [String]) {
        self.mode = mode
        self.bundleIdentifiers = bundleIdentifiers
        lowercasedBundleIdentifiers = Set(bundleIdentifiers.map { $0.lowercased() })
    }

    /// "Only apps I pick". An empty list allows nothing.
    public static func picked(_ bundleIdentifiers: some Sequence<String>) -> WritingAppScope {
        let valid = Set(bundleIdentifiers.filter(PersonalHistoryEvent.validBundleIdentifier))
        return WritingAppScope(
            mode: .picked,
            bundleIdentifiers: Array(valid.sorted().prefix(maximumBundleIdentifiers))
        )
    }

    /// The stored form. A missing mode is the default, all apps. A mode this
    /// build doesn't know allows nothing, so a newer setting fails closed.
    public init(storedMode: String?, storedBundleIdentifiers: [String]?) {
        guard let storedMode else {
            self = .all
            return
        }
        switch Mode(rawValue: storedMode) {
        case .all?: self = .all
        case .picked?: self = .picked(storedBundleIdentifiers ?? [])
        case nil: self = .picked([])
        }
    }

    /// Whether the scope covers this app. Case-insensitive, exact match.
    public func includes(_ bundleIdentifier: String) -> Bool {
        switch mode {
        case .all: return true
        case .picked: return lowercasedBundleIdentifiers.contains(bundleIdentifier.lowercased())
        }
    }

    /// The whole rule: in scope, and not a password manager or an app on the
    /// user's exclusion list. An unknown app is allowed only under all apps,
    /// which keeps Tilde's behavior for hosts that don't report a bundle.
    public func allows(_ bundleIdentifier: String?, excludedApps: Set<String>) -> Bool {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return mode == .all }
        return !DefaultExcludedApps.isExcluded(bundleIdentifier, configuredExcludedApps: excludedApps)
            && includes(bundleIdentifier)
    }
}

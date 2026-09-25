import Foundation

/// Apps that are excluded from BOTH Screen Memory capture and Personal
/// History, unconditionally — the owner's exclusion list
/// (`personalHistoryExcludedApps`) is additive on top of this set, never a
/// replacement for it. A user cannot un-exclude a password manager by
/// leaving it out of their own list, and a fresh install with an empty
/// settings store is still safe on first launch.
///
/// Scope is deliberately narrow: apps whose ENTIRE reason for existing is
/// displaying secrets on screen. General-purpose apps that sometimes show a
/// password field (a browser, Mail) stay off this list — that is what the
/// redaction layer itself and the user's own exclusion list are for.
public enum DefaultExcludedApps {
    /// Bundle identifiers, exact-match (no prefix matching —
    /// `com.1password.1password7` is a distinct app from
    /// `com.1password.1password` and both are listed explicitly rather than
    /// pattern-matched, so a typo'd pattern can never silently fail open).
    /// Entries preserve each vendor's real `CFBundleIdentifier` casing as
    /// Apple or the vendor actually ships it (e.g. `com.apple.Passwords`,
    /// `com.KeePass.mac`) rather than being force-lowercased — lowercasing
    /// the DATA would drift it out of sync with the literal string macOS
    /// reports and risk a silent non-match. Comparisons instead normalize
    /// case on BOTH sides at lookup time (`isAlwaysExcluded`, `isExcluded`
    /// below), so a caller can query with whatever casing it observed
    /// without needing to know which vendors are consistent about it.
    public static let bundleIdentifiers: Set<String> = [
        // Apple
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        // 1Password
        "com.1password.1password",
        "com.1password.1password7",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        // Bitwarden
        "com.bitwarden.desktop",
        // Dashlane
        "com.dashlane.dashlanephonefinal",
        // LastPass
        "com.lastpass.LastPass",
        // KeePass family
        "org.keepassxc.KeePassXC",
        "com.KeePass.mac",
        // NordPass
        "com.nordsec.nordpass",
        // Enpass
        "in.sinew.Enpass-Desktop",
    ]

    /// Every capture-eligibility check the app makes should union its
    /// caller-configurable exclusion set with this one — never check either
    /// list alone. Kept as a function rather than requiring every call site
    /// to remember the union so the "always" guarantee cannot be dropped by
    /// a future refactor that reads only the user's list. Case-insensitive
    /// (see the `bundleIdentifiers` doc comment for why): still exact-match
    /// after normalizing case, never prefix matching.
    public static func isAlwaysExcluded(_ bundleIdentifier: String) -> Bool {
        let normalized = bundleIdentifier.lowercased()
        return bundleIdentifiers.contains { $0.lowercased() == normalized }
    }

    public static func union(with excludedApps: Set<String>) -> Set<String> {
        excludedApps.union(bundleIdentifiers)
    }

    /// The one shared "is this app excluded" check every Personal History
    /// and Screen Memory call site should route through instead of
    /// hand-rolling its own `excludedApps.contains(...)` — the always-
    /// excluded set (password managers, Keychain Access) is checked via
    /// `isAlwaysExcluded` (case-insensitive) OR the caller's own configured
    /// list (matched case-insensitively too, so a caller-typed bundle id
    /// that differs only in case still excludes). This exists specifically
    /// so a call site can never bypass the always-excluded set by reading
    /// only `configuredExcludedApps` — every one of `isAlwaysExcluded`,
    /// `union(with:)`, and this function is backed by the same
    /// `bundleIdentifiers` set on purpose.
    public static func isExcluded(_ bundleIdentifier: String, configuredExcludedApps: Set<String>) -> Bool {
        if isAlwaysExcluded(bundleIdentifier) { return true }
        let normalized = bundleIdentifier.lowercased()
        return configuredExcludedApps.contains { $0.lowercased() == normalized }
    }
}

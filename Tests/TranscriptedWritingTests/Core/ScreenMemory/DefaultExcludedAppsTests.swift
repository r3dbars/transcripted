import Foundation
import Testing
@testable import TranscriptedWritingCore

@Suite("Default excluded apps")
struct DefaultExcludedAppsTests {
    @Test("Known password managers and Keychain Access are always excluded")
    func knownAppsAreExcluded() {
        for bundleIdentifier in [
            "com.apple.keychainaccess",
            "com.1password.1password",
            "com.1password.1password7",
            "com.agilebits.onepassword7",
            "com.agilebits.onepassword-osx",
            "com.bitwarden.desktop",
            "com.dashlane.dashlanephonefinal",
            "com.lastpass.LastPass",
            "org.keepassxc.KeePassXC",
            "com.KeePass.mac",
            "com.nordsec.nordpass",
            "in.sinew.Enpass-Desktop",
        ] {
            #expect(DefaultExcludedApps.isAlwaysExcluded(bundleIdentifier), "\(bundleIdentifier) should be always-excluded")
        }
    }

    @Test("Ordinary apps are not always-excluded")
    func ordinaryAppsAreNotExcluded() {
        #expect(!DefaultExcludedApps.isAlwaysExcluded("com.apple.TextEdit"))
        #expect(!DefaultExcludedApps.isAlwaysExcluded("com.apple.Safari"))
        #expect(!DefaultExcludedApps.isAlwaysExcluded(""))
    }

    @Test("union always adds the default set on top of the caller's set, never replacing it")
    func unionIsAdditive() {
        let userSet: Set<String> = ["com.example.CustomApp"]
        let merged = DefaultExcludedApps.union(with: userSet)
        #expect(merged.contains("com.example.CustomApp"))
        #expect(merged.contains("com.1password.1password"))
        #expect(merged.isSuperset(of: DefaultExcludedApps.bundleIdentifiers))
    }

    @Test("union of an empty caller set still contains every default")
    func unionOfEmptySetIsStillTheDefaults() {
        #expect(DefaultExcludedApps.union(with: []) == DefaultExcludedApps.bundleIdentifiers)
    }

    @Test("Bundle identifiers are exact-match only, no accidental prefix matching")
    func noPrefixMatching() {
        // A hypothetical app whose id happens to start with a listed one
        // must NOT be treated as excluded — Set.contains is exact-match,
        // this test guards against a future refactor to prefix matching.
        #expect(!DefaultExcludedApps.isAlwaysExcluded("com.1password.1password.helper"))
    }

    @Test("isAlwaysExcluded matches regardless of case, since bundle identifier casing is not force-normalized in the stored list")
    func isAlwaysExcludedIsCaseInsensitive() {
        #expect(DefaultExcludedApps.isAlwaysExcluded("com.1password.1password".uppercased()))
        #expect(DefaultExcludedApps.isAlwaysExcluded("COM.APPLE.KEYCHAINACCESS"))
        #expect(DefaultExcludedApps.isAlwaysExcluded("com.apple.passwords"))
    }

    @Test("isExcluded is true for an always-excluded app even when the caller's configured set is empty")
    func isExcludedCoversAlwaysExcludedWithEmptyConfiguredSet() {
        #expect(DefaultExcludedApps.isExcluded("com.1password.1password", configuredExcludedApps: []))
        #expect(!DefaultExcludedApps.isExcluded("com.example.Editor", configuredExcludedApps: []))
    }

    @Test("isExcluded is also true for the caller's own configured set")
    func isExcludedCoversConfiguredSet() {
        #expect(DefaultExcludedApps.isExcluded(
            "com.example.CustomApp",
            configuredExcludedApps: ["com.example.CustomApp"]
        ))
    }
}

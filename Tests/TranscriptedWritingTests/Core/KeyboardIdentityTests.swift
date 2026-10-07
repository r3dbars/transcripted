import Foundation
import Testing
@testable import TranscriptedWritingCore

/// The keyboard's identity lives in several places that must agree. If the
/// Info.plist's connection name drifts from `TildeProductProfile.production`,
/// `main.swift` still registers the profile's name, the keyboard installs, and
/// it silently never gets a session. This compares the compiled profile with
/// the plist, loaded as data (a property list, not Swift source).
@Suite struct KeyboardIdentityTests {
    /// The keyboard target's Info.plist, found from this file's location by
    /// path components (no repo-path string literal).
    private static func keyboardInfoPlist() throws -> [String: Any] {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() } // Core, TranscriptedWritingTests, Tests, repo
        for part in ["Sources", "TranscriptedKeyboard", "Info.plist"] {
            url.appendPathComponent(part)
        }
        let data = try Data(contentsOf: url)
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }

    @Test func keyboardPlistMatchesProductionProfile() throws {
        let plist = try Self.keyboardInfoPlist()
        let profile = TildeProductProfile.production
        #expect(plist["CFBundleIdentifier"] as? String == profile.inputMethodBundleIdentifier)
        #expect(plist["TISInputSourceID"] as? String == profile.inputMethodBundleIdentifier)
        #expect(plist["InputMethodConnectionName"] as? String == profile.inputMethodConnectionName)
        #expect(plist["InputMethodServerControllerClass"] as? String == "GhostInputController")
        #expect(plist["CFBundleExecutable"] as? String == "TranscriptedKeyboard")
    }

    @Test func productionProfileCarriesTranscriptedIdentity() {
        let profile = TildeProductProfile.production
        #expect(profile.appBundleIdentifier == "com.justinbetker.draft")
        #expect(profile.inputMethodBundleIdentifier == "com.justinbetker.draft.inputmethod.Transcripted")
        #expect(profile.inputMethodInstalledBundleName == "Transcripted Keyboard.app")
        #expect(profile.displayName == "Transcripted")
        #expect(profile.llamaServerPort == 17_891)
    }
}

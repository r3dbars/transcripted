import Foundation
import Testing
@testable import TranscriptedWritingCore

/// The keyboard's identity lives in four places that must agree: its
/// Info.plist, `TildeProductProfile.production`, the bundle script, and
/// PackagedAppSmoke. If the plist's connection name drifts, `main.swift`
/// still registers `profile.inputMethodConnectionName`, the keyboard installs,
/// and it silently never gets a session. This pins the plist to the profile.
@Suite struct KeyboardIdentityTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // TranscriptedWritingTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
    }

    private static func keyboardInfoPlist() throws -> [String: Any] {
        let url = repoRoot.appendingPathComponent("Sources/TranscriptedKeyboard/Info.plist")
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

import Testing
@testable import TranscriptedWritingCore

struct TildeProductProfileTests {
    @Test func resolvesProductionProfileForKnownAndUnknownBundles() {
        #expect(TildeProductProfile.resolve(
            bundleIdentifier: "com.justinbetker.draft",
            declaredProfile: nil
        ) == .production)
        #expect(TildeProductProfile.resolve(
            bundleIdentifier: "org.swift.swiftpm.xctest",
            declaredProfile: nil
        ) == .production)
    }

    @Test func productionIdentityMatchesInputMethodBundleContract() {
        let production = TildeProductProfile.production
        #expect(production.appBundleIdentifier == "com.justinbetker.draft")
        #expect(production.inputMethodBundleIdentifier == "com.justinbetker.draft.inputmethod.Transcripted")
        #expect(production.inputMethodConnectionName == "TranscriptedKeyboard_1_Connection")
        #expect(production.supportDirectoryName == "Transcripted/writing")
        #expect(production.inputMethodInstalledBundleName == "Transcripted Keyboard.app")
    }
}

import Foundation
import Testing
@testable import TranscriptedWritingCore

/// The production profile's identity values are pinned here. That the
/// keyboard's Info.plist agrees with them is checked by
/// `scripts/dev/check-keyboard-identity.py` (linux-checks and test-matrix), so
/// no test has to read `Sources/` as text.
@Suite struct KeyboardIdentityTests {
    @Test func productionProfileCarriesTranscriptedIdentity() {
        let profile = TildeProductProfile.production
        #expect(profile.appBundleIdentifier == "com.justinbetker.draft")
        #expect(profile.inputMethodBundleIdentifier == "com.justinbetker.draft.inputmethod.Transcripted")
        #expect(profile.inputMethodInstalledBundleName == "Transcripted Keyboard.app")
        #expect(profile.displayName == "Transcripted")
        #expect(profile.llamaServerPort == 17_891)
    }
}

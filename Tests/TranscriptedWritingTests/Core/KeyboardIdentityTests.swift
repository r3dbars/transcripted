import Foundation
import Testing
@testable import TranscriptedWritingCore

/// The keyboard's identity lives in four places that must agree: its
/// Info.plist, `TildeProductProfile.production`, the bundle script, and
/// PackagedAppSmoke. The plist-to-profile check is a consistency check across
/// files, so it lives in `scripts/dev/check-keyboard-identity.py`; this pins
/// the profile's own production identity.
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

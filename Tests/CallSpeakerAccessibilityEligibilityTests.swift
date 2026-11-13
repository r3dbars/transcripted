import Foundation

// Helium's recognized meeting windows need Chromium's tree-enablement policy.
// This checks eligibility only; it never talks to Accessibility or a browser.
func testCallSpeakerAccessibilityEligibility() {
    runSuite("Call-speaker accessibility: Helium windows are eligible, helpers and unrelated apps stay excluded") {
        for id in ["net.imput.helium", "net.imput.helium.app.meet"] {
            assertEqual(CallSpeakerApp.host(forBundleID: id), .browser, "Helium meeting window has a browser host")
            assertTrue(CallSpeakerApp.needsManualAccessibility(bundleID: id), "Helium meeting windows need Chromium tree enablement")
        }
        for id in ["net.imput.helium.helper", "net.imput.helium.helper.renderer"] {
            assertNil(CallSpeakerApp.host(forBundleID: id), "helpers own no meeting windows and cannot enter the reader")
        }
        for id in ["net.imput.heliumEvil", "net.imput.heliumapp", "com.apple.Safari", "org.mozilla.firefox", "us.zoom.xos"] {
            assertFalse(CallSpeakerApp.needsManualAccessibility(bundleID: id), "lookalikes and non-Chromium apps stay untouched")
        }
        assertTrue(CallSpeakerApp.needsManualAccessibility(bundleID: "com.google.Chrome"), "existing Chromium eligibility is retained")
    }
}

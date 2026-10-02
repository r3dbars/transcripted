import Foundation

func testSettingsActionFailureCopy() {
    runSuite("Settings action failures say what to try in plain words") {
        for message in [
            SettingsActionFailureCopy.modelCacheRemoval,
            SettingsActionFailureCopy.launchAtLogin,
            SettingsActionFailureCopy.launchAtLoginUnavailable,
        ] {
            assertTrue(message.hasPrefix("Transcripted couldn't") || message.hasPrefix("Launch at login"), "\(message) should open with what happened")
            assertTrue(message.hasSuffix("."), "\(message) should be a full sentence")
            assertFalse(message.contains("!"), "\(message) should stay calm")
            assertFalse(message.lowercased().contains("error"), "\(message) should not dump an error")
        }
        assertTrue(
            SettingsActionFailureCopy.modelCacheRemoval.contains("try again"),
            "model-file cleanup failure should say to try again"
        )
        assertTrue(
            SettingsActionFailureCopy.launchAtLogin.contains("Login Items"),
            "launch-at-login failure should point at Login Items"
        )
        assertEqual(SettingsActionFailureCopy.detailsTitle, "Copy Details", "the raw error sits behind Copy Details")
    }

    runSuite("A stopped library copy says the captures stayed put") {
        let message = SettingsActionFailureCopy.captureLibraryMigration(currentLibraryPath: "~/Transcripted")
        assertTrue(message.contains("~/Transcripted"), "the user is told where their captures still are")
        assertTrue(message.contains("was not switched"), "the user is told the library did not move")
        assertFalse(message.lowercased().contains("error"), "the copy should not dump an error")
    }
}

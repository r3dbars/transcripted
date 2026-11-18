// One set of update words for the popover, the status item and the window.

func testUpdateStatusWords() {
    typealias W = UpdateStatusWords

    runSuite("Update words say what the update needs, in sentence case") {
        assertEqual(W.title(for: .idle, downloadsAutomatically: true), "Check for updates", "nothing found reads as the manual check")
        assertEqual(W.title(for: .checking, downloadsAutomatically: true), "Checking for updates…", "a check in flight says so")
        assertEqual(W.title(for: .available(version: "1.2.3"), downloadsAutomatically: true), "Downloading update", "an auto-downloading update is downloading, not ready")
        assertEqual(W.detail(for: .available(version: "1.2.3"), downloadsAutomatically: true), "Version 1.2.3", "the version goes on the second line")
        assertNil(W.action(for: .available(version: "1.2.3"), downloadsAutomatically: true), "an auto download needs no click")
        assertEqual(W.title(for: .available(version: "1.2.3"), downloadsAutomatically: false), "Update to 1.2.3", "a manual update names its version")
        assertEqual(W.action(for: .available(version: "1.2.3"), downloadsAutomatically: false), "Install", "a manual update asks to install")
        assertEqual(W.title(for: .downloading(version: "1.2.3"), downloadsAutomatically: false), "Downloading update", "downloading reads the same everywhere")
        assertEqual(W.title(for: .readyToInstall(version: "1.2.3"), downloadsAutomatically: true), "1.2.3 is ready", "a downloaded update is ready")
        assertEqual(W.action(for: .readyToInstall(version: "1.2.3"), downloadsAutomatically: true), "Restart", "a ready update asks to restart")
    }

    runSuite("The version note and About's button use the same words") {
        assertNil(W.versionNote(for: .idle, checkedUpToDate: false, downloadsAutomatically: true), "never checked shows the version alone")
        assertEqual(W.versionNote(for: .idle, checkedUpToDate: true, downloadsAutomatically: true), "Up to date", "a check that found nothing says so")
        assertEqual(W.versionNote(for: .checking, checkedUpToDate: false, downloadsAutomatically: true), "Checking for updates…", "a check in flight")
        assertEqual(W.versionNote(for: .available(version: "1.2.3"), checkedUpToDate: false, downloadsAutomatically: true), "Downloading update", "an update that downloads itself reads as downloading")
        assertEqual(W.versionNote(for: .available(version: "1.2.3"), checkedUpToDate: false, downloadsAutomatically: false), "Update to 1.2.3", "a manual update names its version")
        assertEqual(W.versionNote(for: .readyToInstall(version: "1.2.3"), checkedUpToDate: false, downloadsAutomatically: true), "1.2.3 is ready", "a downloaded update")
        assertEqual(W.buttonTitle(for: .idle, downloadsAutomatically: true), "Check for updates", "idle offers the manual check")
        assertEqual(W.buttonTitle(for: .available(version: "1.2.3"), downloadsAutomatically: false), "Install", "a manual update asks to install")
        assertEqual(W.buttonTitle(for: .readyToInstall(version: "1.2.3"), downloadsAutomatically: true), "Restart", "a ready update asks to restart")
        assertEqual(W.buttonTitle(for: .downloading(version: "1.2.3"), downloadsAutomatically: true), "Downloading update", "a busy updater says what it's doing")
    }

    runSuite("The status item tooltip only mentions an update that needs a click") {
        assertEqual(W.statusItemNote(for: .readyToInstall(version: "1.2.3")), "1.2.3 ready, restart to update", "ready says restart")
        assertEqual(W.statusItemNote(for: .available(version: "1.2.3")), "update to 1.2.3 available", "available names the version")
        assertNil(W.statusItemNote(for: .downloading(version: "1.2.3")), "a download in progress needs no note")
        assertNil(W.statusItemNote(for: .idle), "no update, no note")
    }
}

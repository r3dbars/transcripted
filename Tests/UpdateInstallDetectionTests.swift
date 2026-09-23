import Foundation

func testUpdateInstallDetection() {
    runSuite("UpdateInstallDetection counts the in-app restart and the silent install on quit") {
        let restart = UpdateInstallDetection.detect(
            currentVersion: "1.1.63",
            lastLaunchedVersion: "1.1.62",
            pendingVersion: "1.1.63",
            pendingPreviousVersion: "1.1.62",
            pendingKind: "restart"
        )
        assertEqual(
            restart,
            UpdateInstallDetection.Outcome(
                record: UpdateInstallRecord(version: "1.1.63", previousVersion: "1.1.62", kind: .restart),
                clearPendingMarkers: true
            ),
            "Restart to Update should count once as a restart install"
        )

        let quit = UpdateInstallDetection.detect(
            currentVersion: "1.1.63",
            lastLaunchedVersion: "1.1.62",
            pendingVersion: "1.1.63",
            pendingPreviousVersion: "1.1.62",
            pendingKind: "quit"
        )
        assertEqual(quit.record?.kind, .quit, "an update Sparkle installed when the app quit should count too; it used to be missed")
        assertTrue(quit.clearPendingMarkers, "a landed install should clear its marker")
    }

    runSuite("UpdateInstallDetection counts installs that did not go through the app") {
        let manual = UpdateInstallDetection.detect(
            currentVersion: "1.1.63",
            lastLaunchedVersion: "1.1.61",
            pendingVersion: nil,
            pendingPreviousVersion: nil,
            pendingKind: nil
        )
        assertEqual(
            manual.record,
            UpdateInstallRecord(version: "1.1.63", previousVersion: "1.1.61", kind: .unattributed),
            "a new DMG or Homebrew install should still count, as unattributed"
        )

        let numeric = UpdateInstallDetection.detect(
            currentVersion: "1.1.10",
            lastLaunchedVersion: "1.1.9",
            pendingVersion: nil,
            pendingPreviousVersion: nil,
            pendingKind: nil
        )
        assertEqual(numeric.record?.version, "1.1.10", "versions should compare numerically, not as text")
    }

    runSuite("UpdateInstallDetection stays quiet when nothing was installed") {
        let sameVersion = UpdateInstallDetection.detect(
            currentVersion: "1.1.63",
            lastLaunchedVersion: "1.1.63",
            pendingVersion: nil,
            pendingPreviousVersion: nil,
            pendingKind: nil
        )
        assertNil(sameVersion.record, "a normal relaunch is not an install")

        let firstLaunch = UpdateInstallDetection.detect(
            currentVersion: "1.1.63",
            lastLaunchedVersion: nil,
            pendingVersion: nil,
            pendingPreviousVersion: nil,
            pendingKind: nil
        )
        assertNil(firstLaunch.record, "a brand-new install has no previous version and is not an update")

        let downgrade = UpdateInstallDetection.detect(
            currentVersion: "1.1.61",
            lastLaunchedVersion: "1.1.63",
            pendingVersion: nil,
            pendingPreviousVersion: nil,
            pendingKind: nil
        )
        assertNil(downgrade.record, "going back to an older copy is not an update install")

        let unknownVersion = UpdateInstallDetection.detect(
            currentVersion: "unknown",
            lastLaunchedVersion: "1.1.61",
            pendingVersion: "1.1.63",
            pendingPreviousVersion: nil,
            pendingKind: "quit"
        )
        assertNil(unknownVersion.record, "a missing bundle version should never produce an install event")
        assertFalse(unknownVersion.clearPendingMarkers, "a missing bundle version should leave markers alone")

        let alreadyCounted = UpdateInstallDetection.detect(
            currentVersion: "1.1.63",
            lastLaunchedVersion: "1.1.63",
            pendingVersion: "1.1.63",
            pendingPreviousVersion: "1.1.62",
            pendingKind: "restart"
        )
        assertNil(alreadyCounted.record, "a marker for a version already launched should not count twice")
        assertTrue(alreadyCounted.clearPendingMarkers, "and it should be cleared")
    }

    runSuite("UpdateInstallDetection keeps a staged update's marker until it lands") {
        let staged = UpdateInstallDetection.detect(
            currentVersion: "1.1.62",
            lastLaunchedVersion: "1.1.62",
            pendingVersion: "1.1.63",
            pendingPreviousVersion: "1.1.62",
            pendingKind: "quit"
        )
        assertNil(staged.record, "the staged update has not been installed yet")
        assertFalse(staged.clearPendingMarkers, "the marker must survive until the staged version launches")

        let stale = UpdateInstallDetection.detect(
            currentVersion: "1.1.64",
            lastLaunchedVersion: "1.1.64",
            pendingVersion: "1.1.63",
            pendingPreviousVersion: "1.1.62",
            pendingKind: "quit"
        )
        assertTrue(stale.clearPendingMarkers, "a marker older than the running version is stale")

        let skippedAhead = UpdateInstallDetection.detect(
            currentVersion: "1.1.63",
            lastLaunchedVersion: "1.1.62",
            pendingVersion: "1.1.64",
            pendingPreviousVersion: "1.1.62",
            pendingKind: "quit"
        )
        assertEqual(skippedAhead.record?.kind, .unattributed, "a different version than the staged one came from somewhere else")
        assertFalse(skippedAhead.clearPendingMarkers, "the newer staged update can still land later")
    }

    runSuite("UpdateInstallDetection reads markers written by older builds") {
        let legacy = UpdateInstallDetection.detect(
            currentVersion: "1.1.63",
            lastLaunchedVersion: nil,
            pendingVersion: "1.1.63",
            pendingPreviousVersion: "1.1.61",
            pendingKind: nil
        )
        assertEqual(
            legacy.record,
            UpdateInstallRecord(version: "1.1.63", previousVersion: "1.1.61", kind: .restart),
            "older builds only wrote markers on the restart path and never stored the last-launched version"
        )
    }
}

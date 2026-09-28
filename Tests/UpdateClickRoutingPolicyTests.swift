import Foundation

func testUpdateClickRoutingPolicy() {
    func route(
        _ state: UpdateActionSafetyState,
        hasConfiguredFeed: Bool = true,
        hasImmediateInstallHandler: Bool = false,
        sessionInProgress: Bool = false,
        isSparkleHoldingUpdate: Bool = false,
        canCheckForUpdates: Bool = true,
        allowsWaiting: Bool = true
    ) -> UpdateClickRoute {
        UpdateClickRoutingPolicy.route(
            state: state,
            hasConfiguredFeed: hasConfiguredFeed,
            hasImmediateInstallHandler: hasImmediateInstallHandler,
            sessionInProgress: sessionInProgress,
            isSparkleHoldingUpdate: isSparkleHoldingUpdate,
            canCheckForUpdates: canCheckForUpdates,
            allowsWaiting: allowsWaiting
        )
    }

    runSuite("UpdateClickRoutingPolicy brings a held quiet reminder forward (#1830)") {
        // The 1.1.61 report: a background check found 1.1.62, Sparkle held it
        // as a quiet reminder with its session open, and the Install click
        // went down a path Sparkle ignores mid-session.
        assertEqual(
            route(.updateAvailable, sessionInProgress: true, isSparkleHoldingUpdate: true),
            .showHeldUpdate,
            "Install during a held reminder must open Sparkle's window, not start a check Sparkle ignores"
        )
        assertEqual(
            route(.readyToInstall, sessionInProgress: true, isSparkleHoldingUpdate: true),
            .showHeldUpdate,
            "a held downloaded update should open Sparkle's window too"
        )
    }

    runSuite("UpdateClickRoutingPolicy refocuses an update window Sparkle already shows") {
        // Sparkle turns canCheckForUpdates back on mid-session only once its
        // driver has shown an update, e.g. an Install window the person opened
        // that went behind other apps. Before, the second click just waited.
        assertEqual(
            route(.updateAvailable, sessionInProgress: true, canCheckForUpdates: true),
            .showHeldUpdate,
            "a shown-but-hidden Sparkle window should come back to the front"
        )
    }

    runSuite("UpdateClickRoutingPolicy keeps the existing install and check paths") {
        assertEqual(
            route(.readyToInstall, hasImmediateInstallHandler: true, sessionInProgress: true),
            .installImmediately,
            "a staged automatic update should use Sparkle's immediate install callback"
        )
        assertEqual(
            route(.readyToInstall),
            .startUserCheck,
            "a resumable downloaded update with no open session should start Sparkle's own check"
        )
        for state in [UpdateActionSafetyState.updateAvailable, .readyToCheck, .noUpdateAvailable, .unknown] {
            assertEqual(
                route(state),
                .startUserCheck,
                "state \(state) with no session should open Sparkle's check window"
            )
        }
        assertEqual(
            route(.updateAvailable, sessionInProgress: true, canCheckForUpdates: false),
            .waitForFeedRead,
            "a click during a feed read should wait for it instead of being dropped"
        )
    }

    runSuite("UpdateClickRoutingPolicy answers a click that already waited instead of parking it again") {
        // A replayed click can find a new probe or background check already
        // running. Parking it again could leave it unanswered until Sparkle's
        // next scheduled check, hours later (#1830).
        assertEqual(
            route(.updateAvailable, sessionInProgress: true, canCheckForUpdates: false, allowsWaiting: false),
            .explain(.updaterBusy),
            "a click past its wait should explain, not park again"
        )
        assertEqual(
            route(.updateAvailable, sessionInProgress: true, isSparkleHoldingUpdate: true, allowsWaiting: false),
            .showHeldUpdate,
            "a click past its wait still opens an update Sparkle now holds"
        )
        assertEqual(
            route(.updateAvailable, allowsWaiting: false),
            .startUserCheck,
            "a click past its wait still starts Sparkle's check once the session ended"
        )
    }

    runSuite("UpdateClickRoutingPolicy explains every case Sparkle would ignore") {
        assertEqual(
            route(.updateAvailable, hasConfiguredFeed: false),
            .explain(.updaterNotConfigured),
            "a build without a valid feed should say it can't update itself"
        )
        assertEqual(
            route(.readyToInstall, hasConfiguredFeed: false, hasImmediateInstallHandler: true),
            .explain(.updaterNotConfigured),
            "no feed wins over everything"
        )
        assertEqual(
            route(.readyToInstall, sessionInProgress: true, canCheckForUpdates: false),
            .explain(.updaterBusy),
            "a downloaded update Sparkle is busy with (and not showing) should explain, not no-op"
        )
        assertEqual(
            route(.readyToCheck, sessionInProgress: true, canCheckForUpdates: false),
            .explain(.updaterBusy),
            "Check for Updates during a background check should explain, not no-op"
        )
        assertEqual(
            route(.updateAvailable, canCheckForUpdates: false),
            .explain(.updaterBusy),
            "an updater that isn't ready should explain, not no-op"
        )
    }

    runSuite("UpdateClickRoutingPolicy messages tell people how to update by hand") {
        for problem in [UpdateClickProblem.updaterNotConfigured, .updaterBusy] {
            let message = UpdateClickRoutingPolicy.message(for: problem)
            assertFalse(message.title.isEmpty, "\(problem) needs a title")
            assertTrue(
                message.detail.contains("brew upgrade --cask transcripted"),
                "\(problem) should give the Homebrew command"
            )
            assertTrue(message.detail.contains("download page"), "\(problem) should point at the download page")
        }
        assertEqual(
            UpdateClickRoutingPolicy.downloadPageURL.absoluteString,
            "https://github.com/r3dbars/transcripted/releases/latest",
            "the download button should open the latest release"
        )
    }
}

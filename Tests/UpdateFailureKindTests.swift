import Foundation

func testUpdateFailureKind() {
    runSuite("UpdateFailureKind preserves explicit fallback when no error exists") {
        assertEqual(
            UpdateFailureKind.classify(nil, fallback: .sparkleBusy),
            .sparkleBusy,
            "callers with known context should be able to keep a non-unknown fallback"
        )
    }

    runSuite("UpdateFailureKind classifies offline and unreachable network errors") {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let cellularBlocked = NSError(domain: NSURLErrorDomain, code: NSURLErrorDataNotAllowed)
        let lostConnection = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)

        assertEqual(UpdateFailureKind.classify(offline), .offline, "offline errors should be visible as offline")
        assertEqual(UpdateFailureKind.classify(timedOut), .feedUnreachable, "network timeouts should be visible as feed_unreachable")
        assertEqual(UpdateFailureKind.classify(cellularBlocked), .offline, "blocked data should still read like offline")
        assertEqual(UpdateFailureKind.classify(lostConnection), .feedUnreachable, "dropped feeds should stay grouped with unreachable feed errors")
    }

    runSuite("UpdateFailureKind classifies Sparkle-style text failures") {
        let badAppcast = NSError(
            domain: "SUSparkleErrorDomain",
            code: 1001,
            userInfo: [NSLocalizedDescriptionKey: "Could not parse appcast XML"]
        )
        let signature = NSError(
            domain: "SUSparkleErrorDomain",
            code: 1002,
            userInfo: [NSLocalizedDescriptionKey: "Update signature verification failed"]
        )
        let download = NSError(
            domain: "SUSparkleErrorDomain",
            code: 1003,
            userInfo: [NSLocalizedDescriptionKey: "Download failed before completion"]
        )

        assertEqual(UpdateFailureKind.classify(badAppcast), .badAppcast, "bad appcast errors should be normalized")
        assertEqual(UpdateFailureKind.classify(signature), .signatureFailed, "signature failures should be normalized")
        assertEqual(UpdateFailureKind.classify(download), .downloadFailed, "download failures should be normalized")
    }

    runSuite("UpdateFailureKind classifies install and busy Sparkle failures from localized text") {
        let install = NSError(
            domain: "SUSparkleErrorDomain",
            code: 2001,
            userInfo: [NSLocalizedRecoverySuggestionErrorKey: "Quit and restart to finish installing the update."]
        )
        let busy = NSError(
            domain: "SUSparkleErrorDomain",
            code: 2002,
            userInfo: [NSLocalizedFailureReasonErrorKey: "An update session is already in progress."]
        )
        let unknown = NSError(
            domain: "SUSparkleErrorDomain",
            code: 2003,
            userInfo: [NSLocalizedDescriptionKey: "Something strange happened."]
        )

        assertEqual(UpdateFailureKind.classify(install), .installFailed, "restart/relaunch copy should normalize to install_failed")
        assertEqual(UpdateFailureKind.classify(busy), .sparkleBusy, "session-in-progress errors should normalize to sparkle_busy")
        assertEqual(UpdateFailureKind.classify(unknown, fallback: .feedUnreachable), .feedUnreachable, "unrecognized text should keep the caller fallback")
    }
}

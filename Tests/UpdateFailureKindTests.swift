import Foundation

func testUpdateFailureKind() {
    runSuite("UpdateFailureKind recognizes Sparkle no-update callbacks") {
        let noUpdate = NSError(domain: "SUSparkleErrorDomain", code: 1001)
        let appcastParse = NSError(domain: "SUSparkleErrorDomain", code: 1000)
        let unrelated = NSError(domain: NSCocoaErrorDomain, code: 1001)

        assertEqual(UpdateFailureKind.isNoUpdate(noUpdate), true, "Sparkle no-update code should not be treated as an update failure")
        assertEqual(UpdateFailureKind.isNoUpdate(appcastParse), false, "other Sparkle appcast errors should stay failure candidates")
        assertEqual(UpdateFailureKind.isNoUpdate(unrelated), false, "code 1001 outside Sparkle should not be reclassified")
    }

    runSuite("UpdateFailureKind preserves explicit fallback when no error exists") {
        assertEqual(
            UpdateFailureKind.classify(nil, fallback: .sparkleBusy),
            .sparkleBusy,
            "callers with known context should be able to keep a non-unknown fallback"
        )
        assertEqual(
            UpdateFailureKind.classify(nil, fallback: .checkTimedOut),
            .checkTimedOut,
            "observed update-check timeouts should keep their concrete failure kind"
        )
    }

    runSuite("UpdateFailureKind detects Sparkle no-update results") {
        let noUpdate = NSError(domain: "SUSparkleErrorDomain", code: 1001)
        let parseFailure = NSError(domain: "SUSparkleErrorDomain", code: 1000)
        let urlFailure = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        assertEqual(UpdateFailureKind.isNoUpdate(noUpdate), true, "Sparkle no-update should not count as an update failure")
        assertEqual(UpdateFailureKind.isNoUpdate(parseFailure), false, "other Sparkle errors should stay actionable")
        assertEqual(UpdateFailureKind.isNoUpdate(urlFailure), false, "network errors should stay actionable")
        assertEqual(UpdateFailureKind.isNoUpdate(nil), false, "missing errors should not look like no-update results")
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
            code: 1000,
            userInfo: [NSLocalizedDescriptionKey: "Could not parse appcast XML"]
        )
        let signature = NSError(
            domain: "SUSparkleErrorDomain",
            code: 3001,
            userInfo: [NSLocalizedDescriptionKey: "Update signature verification failed"]
        )
        let download = NSError(
            domain: "SUSparkleErrorDomain",
            code: 2001,
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

    runSuite("UpdateFailureKind emits coarse diagnostic codes") {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let sparkle = NSError(domain: "SUSparkleErrorDomain", code: 2003)
        let cocoa = NSError(domain: NSCocoaErrorDomain, code: 260)
        let custom = NSError(domain: "SensitiveVendor.PrivateDomain", code: 42)

        assertEqual(UpdateFailureKind.diagnosticCode(nil), nil, "missing errors should not invent failure codes")
        assertEqual(UpdateFailureKind.diagnosticCode(offline), "url_-1009", "URL errors should keep only the coarse domain bucket and code")
        assertEqual(UpdateFailureKind.diagnosticCode(sparkle), "sparkle_2003", "Sparkle errors should be grouped without raw localized text")
        assertEqual(UpdateFailureKind.diagnosticCode(cocoa), "cocoa_260", "Cocoa errors should use a stable public domain bucket")
        assertEqual(UpdateFailureKind.diagnosticCode(custom), "other_42", "custom domains should not be sent off-device")
    }
}

import Foundation

func testUpdateFailureKind() {
    runSuite("UpdateFailureKind classifies offline and unreachable network errors") {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)

        assertEqual(UpdateFailureKind.classify(offline), .offline, "offline errors should be visible as offline")
        assertEqual(UpdateFailureKind.classify(timedOut), .feedUnreachable, "network timeouts should be visible as feed_unreachable")
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
}

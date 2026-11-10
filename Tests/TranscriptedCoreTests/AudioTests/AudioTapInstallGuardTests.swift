import XCTest
import Foundation
@testable import TranscriptedCore

/// Sentry APPLE-MACOS-2K: `installTap` raised "Failed to create tap due to
/// format mismatch" at meeting start and the uncatchable Objective-C
/// exception killed the app. The guard must turn that into a normal error.
final class AudioTapInstallGuardTests: XCTestCase {

    func testRunsTheInstallAndDoesNotThrowWhenNothingRaises() throws {
        var ran = false
        try AudioTapInstallGuard.run(operation: "test") {
            ran = true
        }
        XCTAssertTrue(ran)
    }

    func testFormatCheckErrorIsNotMistakenForACaughtRaise() {
        let formatCheck = NSError(domain: "Audio", code: 5)
        XCTAssertFalse(AudioTapInstallGuard.isTapInstallRaise(formatCheck))
    }

    func testRaisedFormatMismatchBecomesAFailedAttemptError() {
        XCTAssertThrowsError(
            try AudioTapInstallGuard.run(operation: "test") {
                NSException(
                    name: .invalidArgumentException,
                    reason: "Failed to create tap due to format mismatch, <AVAudioFormat: 1 ch, 48000 Hz, Float32>",
                    userInfo: nil
                ).raise()
            }
        ) { error in
            let nsError = error as NSError
            // Same domain and message as ensureMicTapFormatStillMatches, so
            // the caught crash takes the existing failed-attempt path. The
            // code differs so field logs can tell the two apart.
            XCTAssertEqual(nsError.domain, "Audio")
            XCTAssertEqual(nsError.code, 12)
            XCTAssertTrue(AudioTapInstallGuard.isTapInstallRaise(error))
            XCTAssertEqual(
                nsError.localizedDescription,
                "The microphone route did not become ready. Check your input device and try again."
            )
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertEqual(
                underlying?.localizedDescription,
                "Failed to create tap due to format mismatch, <AVAudioFormat: 1 ch, 48000 Hz, Float32>"
            )
        }
    }

}

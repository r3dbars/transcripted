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

    func testRaisedFormatMismatchBecomesTheFormatCheckError() {
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
            // Same domain and code as ensureMicTapFormatStillMatches, so the
            // caught crash takes the existing failed-attempt path.
            XCTAssertEqual(nsError.domain, "Audio")
            XCTAssertEqual(nsError.code, 5)
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            XCTAssertEqual(
                underlying?.localizedDescription,
                "Failed to create tap due to format mismatch, <AVAudioFormat: 1 ch, 48000 Hz, Float32>"
            )
        }
    }

    /// Every production `installTap` must go through the guard. A new call
    /// site without it brings the crash back.
    func testEveryProductionInstallTapIsGuarded() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AudioTests
            .deletingLastPathComponent() // TranscriptedCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
        let sources = repoRoot.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var callSites = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            var searchStart = source.startIndex
            while let call = source.range(of: ".installTap(onBus:", range: searchStart..<source.endIndex) {
                callSites += 1
                let lineStart = source[..<call.lowerBound].lastIndex(of: "\n") ?? source.startIndex
                let previousLineStart = source[..<lineStart].lastIndex(of: "\n") ?? source.startIndex
                let lead = source[previousLineStart..<call.lowerBound]
                XCTAssertTrue(
                    lead.contains("AudioTapInstallGuard.run("),
                    "\(url.lastPathComponent): installTap must be wrapped in AudioTapInstallGuard.run"
                )
                searchStart = call.upperBound
            }
        }
        XCTAssertGreaterThanOrEqual(callSites, 3, "expected the meeting start, mic recovery, and dictation taps")
    }
}

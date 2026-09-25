import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// Tests must never append to the user's real
/// ~/Library/Application Support/Transcripted/logs/writing-diagnostics.log.
@Suite struct DiagnosticsLogTestIsolationTests {
    @Test func disabledUnderTestRunnersAndTheRepoFlag() {
        #expect(DiagnosticsLog.shouldDisableFileWrites(environment: ["TRANSCRIPTED_DISABLE_FILE_LOGGER": "1"], arguments: ["/Applications/Transcripted.app/Contents/MacOS/Transcripted"]))
        #expect(DiagnosticsLog.shouldDisableFileWrites(environment: ["XCTestConfigurationFilePath": "/tmp/x"], arguments: []))
        #expect(DiagnosticsLog.shouldDisableFileWrites(environment: [:], arguments: ["/usr/bin/swiftpm-testing-helper"]))
        #expect(DiagnosticsLog.shouldDisableFileWrites(environment: [:], arguments: ["/tmp/TranscriptedPackageTests.xctest/Contents/MacOS/x"]))
    }

    @Test func thisTestProcessNeverWritesTheRealLog() {
        #expect(DiagnosticsLog.shouldDisableFileWrites(
            environment: ProcessInfo.processInfo.environment,
            arguments: CommandLine.arguments
        ))
    }
}

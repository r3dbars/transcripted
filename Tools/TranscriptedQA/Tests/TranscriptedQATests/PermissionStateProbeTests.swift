import AVFoundation
import XCTest
@testable import transcripted_qa

final class PermissionStateProbeTests: XCTestCase {
    func testComputerUseModeReportsBlockedUIPermissionsAsIncompleteWarnings() {
        let probe = makeProbe(
            mode: .computerUse,
            accessibilityTrusted: false,
            eventPostingTrusted: false,
            eventListeningTrusted: false,
            screenCaptureTrusted: false,
            microphoneStatus: .notDetermined,
            automationStatus: .denied,
            defaults: StubPermissionDefaults(known: false, granted: false)
        )

        let results = probe.validate()

        XCTAssertWarning(results, check: "permissions/codex/accessibility")
        XCTAssertWarning(results, check: "permissions/codex/event-posting")
        XCTAssertWarning(results, check: "permissions/codex/event-listening")
        XCTAssertWarning(results, check: "permissions/codex/screen-recording")
        XCTAssertWarning(results, check: "permissions/codex/automation")
        XCTAssertPass(results, check: "permissions/app-bundle")
        XCTAssertPass(results, check: "permissions/codex/microphone")
        XCTAssertPass(results, check: "permissions/app/system-audio-cache")
    }

    func testLiveCaptureModeRequiresMicrophoneAndTranscriptedSystemAudioCache() {
        let probe = makeProbe(
            mode: .liveCapture,
            microphoneStatus: .denied,
            defaults: StubPermissionDefaults(known: true, granted: false)
        )

        let results = probe.validate()

        XCTAssertWarning(results, check: "permissions/codex/microphone")
        XCTAssertWarning(results, check: "permissions/app/system-audio-cache")
    }

    func testReadyComputerUseModeCanPassWithoutLiveCapturePermissions() {
        let probe = makeProbe(
            mode: .computerUse,
            microphoneStatus: .denied,
            defaults: StubPermissionDefaults(known: false, granted: false)
        )

        let results = probe.validate()
        let report = ValidationReport(results: results)

        XCTAssertEqual(report.summary.failed, 0)
        XCTAssertEqual(report.summary.warnings, 0)
        XCTAssertPass(results, check: "permissions/codex/microphone")
        XCTAssertPass(results, check: "permissions/app/system-audio-cache")
    }

    func testMissingAppBundleIsIncompleteInsteadOfGreen() {
        let probe = makeProbe(mode: .computerUse, appBundleIdentifier: nil)

        let results = probe.validate()

        XCTAssertWarning(results, check: "permissions/app-bundle")
    }

    func testMismatchedAppBundleIdentifierIsIncompleteInsteadOfGreen() {
        let probe = makeProbe(
            mode: .computerUse,
            transcriptedBundleID: "com.example.transcripted",
            appBundleIdentifier: "com.example.other"
        )

        let results = probe.validate()
        let result = results.first { $0.check == "permissions/app-bundle" }

        XCTAssertWarning(results, check: "permissions/app-bundle")
        XCTAssertTrue(result?.detail?.contains("com.example.other") == true)
        XCTAssertTrue(result?.detail?.contains("com.example.transcripted") == true)
    }

    func testAutomationStatusMappingNamesUndecidedAndDeniedStates() {
        let undecided = makeProbe(mode: .computerUse, automationStatus: .notDetermined).validate()
        XCTAssertWarning(undecided, check: "permissions/codex/automation")
        XCTAssertTrue(
            undecided.first { $0.check == "permissions/codex/automation" }?.detail?.contains("not decided") == true
        )

        let denied = makeProbe(mode: .computerUse, automationStatus: .denied).validate()
        XCTAssertWarning(denied, check: "permissions/codex/automation")
        XCTAssertTrue(
            denied.first { $0.check == "permissions/codex/automation" }?.detail?.contains("denied") == true
        )
    }

    func testAutomationUnavailableStatusStaysIncompleteWithDiagnosticCode() {
        let results = makeProbe(mode: .computerUse, automationStatus: .unavailable(-1743)).validate()
        let result = results.first { $0.check == "permissions/codex/automation" }

        XCTAssertWarning(results, check: "permissions/codex/automation")
        XCTAssertTrue(result?.detail?.contains("OSStatus -1743") == true)
    }

    func testAutomationStatusRetriesOnceWhenTargetIsNotRunning() {
        var statuses = [OSStatus(procNotFound), noErr]
        var warmedTargets: [String] = []

        let status = PermissionStateProbe.automationStatus(
            targetBundleID: "com.apple.systemevents",
            permissionStatusProvider: { statuses.removeFirst() },
            warmUpTargetProvider: {
                warmedTargets.append($0)
                return true
            }
        )

        XCTAssertEqual(status, .allowed)
        XCTAssertEqual(warmedTargets, ["com.apple.systemevents"])
        XCTAssertTrue(statuses.isEmpty, "the permission check should retry exactly once after warming the target")
    }

    func testAutomationStatusKeepsProcNotFoundWhenWarmupFails() {
        let status = PermissionStateProbe.automationStatus(
            targetBundleID: "com.apple.systemevents",
            permissionStatusProvider: { OSStatus(procNotFound) },
            warmUpTargetProvider: { _ in false }
        )

        XCTAssertEqual(status, .unavailable(OSStatus(procNotFound)))
    }

    func testLiveCaptureModeWarnsWhenTranscriptedDefaultsDomainCannotOpen() {
        let results = makeProbe(mode: .liveCapture, defaults: nil).validate()
        let result = results.first { $0.check == "permissions/app/system-audio-cache" }

        XCTAssertWarning(results, check: "permissions/app/system-audio-cache")
        XCTAssertTrue(result?.detail?.contains("Could not open") == true)
    }

    func testReadyLiveCaptureModeHasNoPermissionWarnings() {
        let probe = makeProbe(
            mode: .liveCapture,
            microphoneStatus: .authorized,
            defaults: StubPermissionDefaults(known: true, granted: true)
        )

        let report = ValidationReport(results: probe.validate())

        XCTAssertEqual(report.summary.failed, 0)
        XCTAssertEqual(report.summary.warnings, 0)
    }

    private func makeProbe(
        mode: PermissionStateMode,
        accessibilityTrusted: Bool = true,
        eventPostingTrusted: Bool = true,
        eventListeningTrusted: Bool = true,
        screenCaptureTrusted: Bool = true,
        microphoneStatus: AVAuthorizationStatus = .authorized,
        automationStatus: PermissionStateProbe.AutomationStatus = .allowed,
        transcriptedBundleID: String = "com.justinbetker.draft",
        appBundleIdentifier: String? = "com.justinbetker.draft",
        defaults: StubPermissionDefaults? = StubPermissionDefaults(known: true, granted: true)
    ) -> PermissionStateProbe {
        PermissionStateProbe(
            mode: mode,
            automationTargetBundleID: "com.apple.systemevents",
            transcriptedBundleID: transcriptedBundleID,
            appBundlePath: "build/Transcripted.app",
            transcriptedDefaultsDomain: "com.justinbetker.draft",
            processNameProvider: { "transcripted-qa-tests" },
            appBundleIdentifierProvider: { _ in appBundleIdentifier },
            accessibilityTrustedProvider: { accessibilityTrusted },
            eventPostingTrustedProvider: { eventPostingTrusted },
            eventListeningTrustedProvider: { eventListeningTrusted },
            screenCaptureTrustedProvider: { screenCaptureTrusted },
            microphoneStatusProvider: { microphoneStatus },
            automationStatusProvider: { _ in automationStatus },
            defaultsProvider: { _ in defaults },
            runningApplicationsProvider: { _ in [] }
        )
    }

    private func XCTAssertWarning(
        _ results: [ValidationResult],
        check: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(results.first { $0.check == check }?.status, .warn, file: file, line: line)
    }

    private func XCTAssertPass(
        _ results: [ValidationResult],
        check: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(results.first { $0.check == check }?.status, .pass, file: file, line: line)
    }
}

private final class StubPermissionDefaults: PermissionDefaultsReading {
    private let known: Bool
    private let granted: Bool

    init(known: Bool, granted: Bool) {
        self.known = known
        self.granted = granted
    }

    func bool(forKey defaultName: String) -> Bool {
        if defaultName == "systemAudioRecordingPermissionKnown" {
            return known
        }
        if defaultName == "systemAudioRecordingPermissionGranted" {
            return granted
        }
        return false
    }

    func object(forKey defaultName: String) -> Any? {
        if defaultName == "systemAudioRecordingPermissionKnown" {
            return known
        }
        if defaultName == "systemAudioRecordingPermissionGranted" {
            return granted
        }
        return nil
    }
}

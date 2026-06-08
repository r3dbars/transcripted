import AVFoundation
import XCTest
@testable import transcripted_qa

final class PermissionStateRuntimeGateTests: XCTestCase {
    func testExpectedManualGrantStateNamesComputerUseAndLiveCaptureRequirements() {
        let computerUse = makeProbe(mode: .computerUse).validate()
        let computerUseDetail = detail(from: computerUse, check: "permissions/expected-manual-grants")

        XCTAssertTrue(computerUseDetail.contains("Accessibility"))
        XCTAssertTrue(computerUseDetail.contains("Screen Recording"))
        XCTAssertTrue(computerUseDetail.contains("Automation/System Events"))
        XCTAssertTrue(computerUseDetail.contains("no duplicate or wrong Transcripted app instance"))
        XCTAssertTrue(computerUseDetail.contains("not required for click-only computer-use QA"))

        let liveCapture = makeProbe(mode: .liveCapture).validate()
        let liveCaptureDetail = detail(from: liveCapture, check: "permissions/expected-manual-grants")

        XCTAssertTrue(liveCaptureDetail.contains("Microphone"))
        XCTAssertTrue(liveCaptureDetail.contains("System Audio Recording"))
        XCTAssertTrue(liveCaptureDetail.contains("known/granted"))
    }

    func testNoRunningTranscriptedAppIsPassBeforeLaunch() {
        let results = makeProbe(mode: .computerUse, runningApplications: []).validate()

        XCTAssertEqual(results.first { $0.check == "permissions/app/running-instances" }?.status, .pass)
    }

    func testDuplicateRunningTranscriptedAppsAreIncompleteWarnings() {
        let results = makeProbe(
            mode: .computerUse,
            runningApplications: [
                PermissionRunningApplication(
                    processIdentifier: 1201,
                    localizedName: "Transcripted",
                    bundleIdentifier: "com.justinbetker.draft",
                    bundlePath: "/Applications/Transcripted.app"
                ),
                PermissionRunningApplication(
                    processIdentifier: 1202,
                    localizedName: "Transcripted",
                    bundleIdentifier: "com.justinbetker.draft",
                    bundlePath: "/tmp/Transcripted.app"
                )
            ]
        ).validate()
        let result = results.first { $0.check == "permissions/app/running-instances" }

        XCTAssertEqual(result?.status, .warn)
        XCTAssertTrue(result?.detail?.contains("Duplicate Transcripted apps") == true)
        XCTAssertTrue(result?.detail?.contains("Quit duplicates") == true)
    }

    func testWrongRunningTranscriptedAppIsIncompleteWarning() {
        let results = makeProbe(
            mode: .computerUse,
            appBundlePath: "/tmp/Expected/Transcripted.app",
            runningApplications: [
                PermissionRunningApplication(
                    processIdentifier: 1301,
                    localizedName: "Transcripted",
                    bundleIdentifier: "com.justinbetker.draft",
                    bundlePath: "/Applications/Transcripted.app"
                )
            ]
        ).validate()
        let result = results.first { $0.check == "permissions/app/running-instances" }

        XCTAssertEqual(result?.status, .warn)
        XCTAssertTrue(result?.detail?.contains("already running from") == true)
        XCTAssertTrue(result?.detail?.contains("pass --app-bundle") == true)
    }

    func testExpectedRunningTranscriptedAppIsPass() {
        let expected = "/tmp/Expected/Transcripted.app"
        let results = makeProbe(
            mode: .computerUse,
            appBundlePath: expected,
            runningApplications: [
                PermissionRunningApplication(
                    processIdentifier: 1401,
                    localizedName: "Transcripted",
                    bundleIdentifier: "com.justinbetker.draft",
                    bundlePath: expected
                )
            ]
        ).validate()

        XCTAssertEqual(results.first { $0.check == "permissions/app/running-instances" }?.status, .pass)
    }

    private func makeProbe(
        mode: PermissionStateMode,
        appBundlePath: String = "build/Transcripted.app",
        runningApplications: [PermissionRunningApplication] = []
    ) -> PermissionStateProbe {
        PermissionStateProbe(
            mode: mode,
            automationTargetBundleID: "com.apple.systemevents",
            transcriptedBundleID: "com.justinbetker.draft",
            appBundlePath: appBundlePath,
            transcriptedDefaultsDomain: "com.justinbetker.draft",
            processNameProvider: { "transcripted-qa-tests" },
            appBundleIdentifierProvider: { _ in "com.justinbetker.draft" },
            accessibilityTrustedProvider: { true },
            eventPostingTrustedProvider: { true },
            eventListeningTrustedProvider: { true },
            screenCaptureTrustedProvider: { true },
            microphoneStatusProvider: { .authorized },
            automationStatusProvider: { _ in .allowed },
            defaultsProvider: { _ in StubPermissionDefaults(known: true, granted: true) },
            runningApplicationsProvider: { _ in runningApplications }
        )
    }

    private func detail(from results: [ValidationResult], check: String) -> String {
        results.first { $0.check == check }?.detail ?? ""
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

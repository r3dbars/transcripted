import AVFoundation
import ArgumentParser
import Carbon
import CoreGraphics
import Foundation

enum PermissionStateMode: String, ExpressibleByArgument {
    case computerUse = "computer-use"
    case liveCapture = "live-capture"
}

struct PermissionState: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "permission-state",
        abstract: "Report local macOS permission blockers for Codex computer-use and live Transcripted QA."
    )

    @OptionGroup var formatOpts: FormatOptions

    @Option(name: .long, help: "Probe mode: computer-use or live-capture.")
    var mode: PermissionStateMode = .computerUse

    @Option(name: .long, help: "Apple Events target bundle id to check for Automation permission.")
    var automationTargetBundleID: String = "com.apple.systemevents"

    @Option(name: .long, help: "Transcripted app bundle id/defaults domain.")
    var transcriptedBundleID: String = "com.justinbetker.draft"

    @Option(name: .long, help: "Transcripted app bundle to identify before live/app UI QA.")
    var appBundle: String = "build/Transcripted.app"

    @Option(name: .long, help: "Override the Transcripted defaults domain used for the cached system-audio probe.")
    var transcriptedDefaultsDomain: String?

    func run() throws {
        let probe = PermissionStateProbe(
            mode: mode,
            automationTargetBundleID: automationTargetBundleID,
            transcriptedBundleID: transcriptedBundleID,
            appBundlePath: appBundle,
            transcriptedDefaultsDomain: transcriptedDefaultsDomain ?? transcriptedBundleID
        )
        try runPermissionState(results: probe.validate(), format: formatOpts.format)
    }
}

struct PermissionStateProbe {
    typealias DefaultsProvider = (String) -> PermissionDefaultsReading?

    enum AutomationStatus: Equatable {
        case allowed
        case notDetermined
        case denied
        case unavailable(OSStatus)
    }

    let mode: PermissionStateMode
    let automationTargetBundleID: String
    let transcriptedBundleID: String
    let appBundlePath: String
    let transcriptedDefaultsDomain: String
    var processNameProvider: () -> String = { ProcessInfo.processInfo.processName }
    var appBundleIdentifierProvider: (String) -> String? = { bundleIdentifier(atPath: $0) }
    var accessibilityTrustedProvider: () -> Bool = { AXIsProcessTrusted() }
    var eventPostingTrustedProvider: () -> Bool = { CGPreflightPostEventAccess() }
    var eventListeningTrustedProvider: () -> Bool = { CGPreflightListenEventAccess() }
    var screenCaptureTrustedProvider: () -> Bool = { CGPreflightScreenCaptureAccess() }
    var microphoneStatusProvider: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
    var automationStatusProvider: (String) -> AutomationStatus = { determineAutomationStatus(targetBundleID: $0) }
    var defaultsProvider: DefaultsProvider = { UserDefaults(suiteName: $0) }

    func validate() -> [ValidationResult] {
        var results: [ValidationResult] = []

        results.append(.permissionPass(
            "permissions/current-process",
            target: processNameProvider(),
            detail: "These checks apply to the process running this command. If Codex computer-use runs from a different app, grant that app too."
        ))
        results.append(appBundleIdentityResult())

        results.append(permissionResult(
            check: "permissions/codex/accessibility",
            target: "Accessibility",
            granted: accessibilityTrustedProvider(),
            blockedDetail: "Accessibility is off for the automation host. Enable System Settings > Privacy & Security > Accessibility for Codex or the terminal app running this command, then restart that host."
        ))

        results.append(permissionResult(
            check: "permissions/codex/event-posting",
            target: "Event Posting",
            granted: eventPostingTrustedProvider(),
            blockedDetail: "macOS is blocking synthetic clicks/keystrokes from this host. Enable Accessibility for Codex or the terminal app before counting UI click tests."
        ))

        results.append(permissionResult(
            check: "permissions/codex/event-listening",
            target: "Input Monitoring",
            granted: eventListeningTrustedProvider(),
            blockedDetail: "Input Monitoring is unavailable for this host. Global-key and physical-trigger QA cannot be counted until Privacy & Security > Input Monitoring allows the controlling app."
        ))

        results.append(permissionResult(
            check: "permissions/codex/screen-recording",
            target: "Screen Recording",
            granted: screenCaptureTrustedProvider(),
            blockedDetail: "Screen Recording is off for this host. Codex cannot prove screenshots or screen-state changes until Privacy & Security > Screen Recording allows the controlling app."
        ))

        results.append(automationResult(for: automationStatusProvider(automationTargetBundleID)))
        results.append(microphoneResult(for: microphoneStatusProvider()))
        results.append(transcriptedSystemAudioCacheResult())
        results.append(.permissionPass(
            "permissions/app/public-api-boundary",
            target: transcriptedBundleID,
            detail: "Public macOS APIs let this CLI query its own TCC state, not every Transcripted.app grant. Use Transcripted Settings or live smoke for app-owned permission proof."
        ))

        return results
    }

    private func permissionResult(
        check: String,
        target: String,
        granted: Bool,
        blockedDetail: String
    ) -> ValidationResult {
        if granted {
            return .permissionPass(check, target: target, detail: "Ready.")
        }
        return .warn(check, target: target, detail: blockedDetail)
    }

    private func appBundleIdentityResult() -> ValidationResult {
        guard let bundleIdentifier = appBundleIdentifierProvider(appBundlePath) else {
            return .warn(
                "permissions/app-bundle",
                target: appBundlePath,
                detail: "Transcripted app bundle was not found or has no CFBundleIdentifier. Run bash build.sh --no-open or pass --app-bundle before app UI/live QA."
            )
        }

        if bundleIdentifier == transcriptedBundleID {
            return .permissionPass(
                "permissions/app-bundle",
                target: appBundlePath,
                detail: "Bundle id \(bundleIdentifier) matches the expected Transcripted TCC identity."
            )
        }

        return .warn(
            "permissions/app-bundle",
            target: appBundlePath,
            detail: "Built app bundle id is \(bundleIdentifier), expected \(transcriptedBundleID). TCC grants may apply to a different app identity."
        )
    }

    private func automationResult(for status: AutomationStatus) -> ValidationResult {
        switch status {
        case .allowed:
            return .permissionPass(
                "permissions/codex/automation",
                target: automationTargetBundleID,
                detail: "Apple Events automation is allowed for this target."
            )
        case .notDetermined:
            return .warn(
                "permissions/codex/automation",
                target: automationTargetBundleID,
                detail: "Automation is not decided. A user-initiated Apple Events probe may prompt; do not count osascript/System Events UI steps as green yet."
            )
        case .denied:
            return .warn(
                "permissions/codex/automation",
                target: automationTargetBundleID,
                detail: "Automation is denied. Enable Privacy & Security > Automation for this host and target before Apple Events-based UI QA."
            )
        case .unavailable(let status):
            return .warn(
                "permissions/codex/automation",
                target: automationTargetBundleID,
                detail: "Automation probe returned OSStatus \(status). Treat Apple Events UI steps as unproven until this is resolved."
            )
        }
    }

    private func microphoneResult(for status: AVAuthorizationStatus) -> ValidationResult {
        let check = "permissions/codex/microphone"
        switch status {
        case .authorized:
            return .permissionPass(check, target: "Microphone", detail: "Current process can use microphone-backed QA probes.")
        case .notDetermined:
            return microphoneBlockedResult(
                check: check,
                status: "not determined",
                recovery: "A live capture run may prompt. Grant Microphone to the app that will run the capture, then rerun permission-state."
            )
        case .denied:
            return microphoneBlockedResult(
                check: check,
                status: "denied",
                recovery: "Enable Privacy & Security > Microphone for the app that runs the capture."
            )
        case .restricted:
            return microphoneBlockedResult(
                check: check,
                status: "restricted",
                recovery: "This Mac restricts microphone access, so live mic QA is not proven here."
            )
        @unknown default:
            return microphoneBlockedResult(
                check: check,
                status: "unknown",
                recovery: "macOS returned an unknown microphone status. Treat live mic QA as unproven."
            )
        }
    }

    private func microphoneBlockedResult(check: String, status: String, recovery: String) -> ValidationResult {
        let detail = "Microphone is \(status). \(recovery)"
        if mode == .liveCapture {
            return .warn(check, target: "Microphone", detail: detail)
        }
        return .permissionPass(
            check,
            target: "Microphone",
            detail: "\(detail) Not required for click-only computer-use QA."
        )
    }

    private func transcriptedSystemAudioCacheResult() -> ValidationResult {
        let check = "permissions/app/system-audio-cache"
        guard let defaults = defaultsProvider(transcriptedDefaultsDomain) else {
            return .warn(
                check,
                target: transcriptedDefaultsDomain,
                detail: "Could not open the Transcripted defaults domain, so cached system-audio permission state is unknown."
            )
        }

        let known = defaults.bool(forKey: "systemAudioRecordingPermissionKnown")
        let grantedObject = defaults.object(forKey: "systemAudioRecordingPermissionGranted")
        let granted = grantedObject as? Bool == true
        if known, granted {
            return .permissionPass(
                check,
                target: transcriptedDefaultsDomain,
                detail: "Transcripted has cached a successful system-audio recording probe."
            )
        }

        let detail: String
        if known {
            detail = "Transcripted has cached system audio as blocked. Open Transcripted Settings > Permissions and recheck System Audio Recording before live meeting QA."
        } else {
            detail = "Transcripted has not cached a successful system-audio probe. Run Transcripted's permission check or a live meeting start before treating system-audio capture as proven."
        }

        if mode == .liveCapture {
            return .warn(check, target: transcriptedDefaultsDomain, detail: detail)
        }
        return .permissionPass(
            check,
            target: transcriptedDefaultsDomain,
            detail: "\(detail) Not required for click-only computer-use QA."
        )
    }

    static func determineAutomationStatus(targetBundleID: String) -> AutomationStatus {
        var target = AEAddressDesc()
        let createStatus = OSStatus(targetBundleID.withCString { pointer in
            AECreateDesc(
                DescType(typeApplicationBundleID),
                pointer,
                targetBundleID.utf8.count,
                &target
            )
        })
        guard createStatus == noErr else {
            return .unavailable(createStatus)
        }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            typeWildCard,
            typeWildCard,
            false
        )
        if status == noErr {
            return .allowed
        }
        if status == OSStatus(errAEEventWouldRequireUserConsent) {
            return .notDetermined
        }
        if status == OSStatus(errAEEventNotPermitted) {
            return .denied
        }
        return .unavailable(status)
    }

    private static func bundleIdentifier(atPath path: String) -> String? {
        let infoPlist = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoPlist),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let plist = object as? [String: Any] else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }
}

protocol PermissionDefaultsReading {
    func bool(forKey defaultName: String) -> Bool
    func object(forKey defaultName: String) -> Any?
}

extension UserDefaults: PermissionDefaultsReading {}

private extension ValidationResult {
    static func permissionPass(_ check: String, target: String, detail: String) -> ValidationResult {
        ValidationResult(check: check, status: .pass, target: target, detail: detail)
    }
}

private func runPermissionState(results: [ValidationResult], format: OutputFormat) throws {
    let report = ValidationReport(results: results)
    switch format {
    case .text:
        report.printText()
    case .json:
        report.printJSON()
    }

    if report.summary.failed > 0 {
        throw ExitCode(1)
    }
    if report.summary.warnings > 0 {
        throw ExitCode(3)
    }
}

import ArgumentParser
import Darwin
import Foundation

struct PackagedAppSmoke: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "packaged-app-smoke",
        abstract: "Validate a built or packaged Transcripted.app before publishing a release."
    )

    @Option(name: .long, help: "Path to the built Transcripted.app bundle.")
    var app: String = "build/Transcripted.app"

    @Option(name: .long, help: "Path to the source Info.plist expected to match the built app.")
    var sourceInfoPlist: String = "Info.plist"

    @Option(name: .long, help: "Path to the release dSYM bundle.")
    var dsym: String = "build/Transcripted.app.dSYM"

    @Option(name: .long, help: "Path to the built DMG. Defaults to build/Transcripted-<CFBundleShortVersionString>.dmg.")
    var dmg: String?

    @Option(name: .long, help: "Path to the committed Sparkle appcast.")
    var appcast: String = "docs/appcast.xml"

    @Option(name: .long, parsing: .upToNextOption, help: "Local log files to scan for obvious privacy leaks.")
    var logPath: [String] = []

    @Option(name: .long, help: "Write a local JSON evidence report to this path.")
    var report: String?

    @Option(name: .long, help: "Write UI smoke JSON evidence to this path when --run-ui-smoke is set.")
    var uiReport: String?

    @Option(name: .long, help: "Write first-run reliability JSON evidence to this path when --run-first-run-reliability is set.")
    var firstRunReport: String?

    @Option(name: .long, help: "Seconds to wait for each UI smoke surface.")
    var uiTimeout: Double = 12

    @Option(name: .long, help: "Seconds to wait for each first-run reliability launch.")
    var firstRunTimeout: Double = 20

    @Flag(name: .long, help: "Warn instead of fail when the dSYM is missing or unverifiable.")
    var allowMissingDSYM = false

    @Flag(name: .long, help: "Warn instead of fail when the DMG is missing or unreadable.")
    var allowMissingDMG = false

    @Flag(name: .long, help: "Launch the built app and validate the menu bar through Accessibility.")
    var runUISmoke = false

    @Flag(name: .long, help: "Launch the packaged app inside isolated homes and containers to validate first-run reliability scenarios.")
    var runFirstRunReliability = false

    @Flag(name: .long, help: "Allow a pre-existing Transcripted process during --run-ui-smoke.")
    var allowExistingInstance = false

    @Flag(name: .long, help: "Ask macOS to show the Accessibility prompt during --run-ui-smoke if needed.")
    var promptForAccessibility = false

    @Flag(name: .long, help: "Skip codesign verification. This downgrades signing proof to INCOMPLETE.")
    var skipCodeSignatureCheck = false

    func run() throws {
        let runner = PackagedAppSmokeRunner(
            appBundlePath: app,
            sourceInfoPlistPath: sourceInfoPlist,
            dSYMPath: dsym,
            dmgPath: dmg,
            appcastPath: appcast,
            logPaths: logPath,
            reportPath: report,
            uiReportPath: uiReport,
            firstRunReportPath: firstRunReport,
            uiTimeout: uiTimeout,
            firstRunTimeout: firstRunTimeout,
            requireDSYM: !allowMissingDSYM,
            requireDMG: !allowMissingDMG,
            runUISmoke: runUISmoke,
            runFirstRunReliability: runFirstRunReliability,
            allowExistingInstance: allowExistingInstance,
            promptForAccessibility: promptForAccessibility,
            verifyCodeSignature: !skipCodeSignatureCheck
        )
        let smokeReport = runner.run()
        smokeReport.printText()
        try smokeReport.writeIfRequested()

        if smokeReport.exitCode != 0 {
            throw ExitCode(smokeReport.exitCode)
        }
    }
}

final class PackagedAppSmokeRunner {
    private let appBundleURL: URL
    private let sourceInfoPlistURL: URL
    private let dSYMURL: URL
    private let explicitDMGPath: String?
    private let appcastURL: URL
    private let initialLogPaths: [String]
    private let reportPath: String?
    private let uiReportPath: String?
    private let firstRunReportPath: String?
    private let uiTimeout: Double
    private let firstRunTimeout: Double
    private let requireDSYM: Bool
    private let requireDMG: Bool
    private let runUISmoke: Bool
    private let runFirstRunReliability: Bool
    private let allowExistingInstance: Bool
    private let promptForAccessibility: Bool
    private let verifyCodeSignature: Bool
    private let fileManager: FileManager
    private let commandRunner: PackagedAppSmokeCommandRunning
    private let runID = UUID().uuidString

    init(
        appBundlePath: String,
        sourceInfoPlistPath: String,
        dSYMPath: String,
        dmgPath: String?,
        appcastPath: String,
        logPaths: [String],
        reportPath: String?,
        uiReportPath: String?,
        firstRunReportPath: String?,
        uiTimeout: Double,
        firstRunTimeout: Double,
        requireDSYM: Bool,
        requireDMG: Bool,
        runUISmoke: Bool,
        runFirstRunReliability: Bool,
        allowExistingInstance: Bool,
        promptForAccessibility: Bool,
        verifyCodeSignature: Bool,
        fileManager: FileManager = .default,
        commandRunner: PackagedAppSmokeCommandRunning = ProcessPackagedAppSmokeCommandRunner()
    ) {
        self.appBundleURL = URL(fileURLWithPath: appBundlePath).standardizedFileURL
        self.sourceInfoPlistURL = URL(fileURLWithPath: sourceInfoPlistPath).standardizedFileURL
        self.dSYMURL = URL(fileURLWithPath: dSYMPath).standardizedFileURL
        self.explicitDMGPath = dmgPath
        self.appcastURL = URL(fileURLWithPath: appcastPath).standardizedFileURL
        self.initialLogPaths = logPaths
        self.reportPath = reportPath
        self.uiReportPath = uiReportPath
        self.firstRunReportPath = firstRunReportPath
        self.uiTimeout = uiTimeout
        self.firstRunTimeout = firstRunTimeout
        self.requireDSYM = requireDSYM
        self.requireDMG = requireDMG
        self.runUISmoke = runUISmoke
        self.runFirstRunReliability = runFirstRunReliability
        self.allowExistingInstance = allowExistingInstance
        self.promptForAccessibility = promptForAccessibility
        self.verifyCodeSignature = verifyCodeSignature
        self.fileManager = fileManager
        self.commandRunner = commandRunner
    }

    func run(generatedAt: Date = Date()) -> PackagedAppSmokeReport {
        var checks: [PackagedAppSmokeCheck] = []
        var scannedLogPaths = initialLogPaths
        var uiEvidencePath: String?
        var firstRunEvidencePath: String?

        guard fileManager.fileExists(atPath: appBundleURL.path) else {
            checks.append(.fail("app-bundle", target: appBundleURL.path, detail: "Run SKIP_NOTARIZATION=1 bash build-beta.sh '' <user-name> first, or pass --app."))
            return buildReport(
                checks: checks,
                dmgPath: nil,
                logPaths: scannedLogPaths,
                uiEvidencePath: uiEvidencePath,
                firstRunEvidencePath: firstRunEvidencePath,
                generatedAt: generatedAt
            )
        }
        checks.append(.pass("app-bundle", target: appBundleURL.path, detail: "Built app bundle exists."))

        let executableURL = appBundleURL.appendingPathComponent("Contents/MacOS/Transcripted", isDirectory: false)
        if fileManager.isExecutableFile(atPath: executableURL.path) {
            checks.append(.pass("app-executable", target: executableURL.path, detail: "Built app executable is present and executable."))
        } else {
            checks.append(.fail("app-executable", target: executableURL.path, detail: "Transcripted.app is missing Contents/MacOS/Transcripted or it is not executable."))
        }

        let builtInfoURL = appBundleURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let sourceInfo = loadPlist(sourceInfoPlistURL, check: "source-info-plist", checks: &checks)
        let builtInfo = loadPlist(builtInfoURL, check: "built-info-plist", checks: &checks)

        if let sourceInfo, let builtInfo {
            checks.append(contentsOf: validateInfoPlist(sourceInfo: sourceInfo, builtInfo: builtInfo))
            checks.append(contentsOf: validateSparkleConfig(sourceInfo: sourceInfo, builtInfo: builtInfo))
            checks.append(contentsOf: validateObservabilityConfig(builtInfo: builtInfo))

            let version = stringValue(builtInfo["CFBundleShortVersionString"]) ?? "unknown"
            let dmgURL = resolvedDMGURL(version: version)
            checks.append(validateDMG(at: dmgURL))
            return buildReport(
                checks: checksAfterTail(
                    checks,
                    scannedLogPaths: &scannedLogPaths,
                    uiEvidencePath: &uiEvidencePath,
                    firstRunEvidencePath: &firstRunEvidencePath,
                    executableURL: executableURL
                ),
                dmgPath: dmgURL.path,
                logPaths: scannedLogPaths,
                uiEvidencePath: uiEvidencePath,
                firstRunEvidencePath: firstRunEvidencePath,
                generatedAt: generatedAt
            )
        } else {
            checks.append(.fail("version-config", target: builtInfoURL.path, detail: "Cannot validate version/Sparkle config until both source and built Info.plist files are readable."))
            let dmgURL = resolvedDMGURL(version: "unknown")
            checks.append(validateDMG(at: dmgURL))
            return buildReport(
                checks: checksAfterTail(
                    checks,
                    scannedLogPaths: &scannedLogPaths,
                    uiEvidencePath: &uiEvidencePath,
                    firstRunEvidencePath: &firstRunEvidencePath,
                    executableURL: executableURL
                ),
                dmgPath: dmgURL.path,
                logPaths: scannedLogPaths,
                uiEvidencePath: uiEvidencePath,
                firstRunEvidencePath: firstRunEvidencePath,
                generatedAt: generatedAt
            )
        }
    }

    private func checksAfterTail(
        _ initialChecks: [PackagedAppSmokeCheck],
        scannedLogPaths: inout [String],
        uiEvidencePath: inout String?,
        firstRunEvidencePath: inout String?,
        executableURL: URL
    ) -> [PackagedAppSmokeCheck] {
        var checks = initialChecks
        checks.append(validateBundledFramework(relativePath: "Contents/Frameworks/Sparkle.framework", check: "sparkle-framework"))
        checks.append(validateBundledHelper(relativePath: "Contents/Helpers/transcripted-mcp", check: "mcp-helper"))
        checks.append(validateCodeSignature())
        checks.append(validateDSYM(binaryURL: executableURL))

        if runUISmoke {
            let defaultUIReport = reportPath.map { path in
                URL(fileURLWithPath: path)
                    .deletingLastPathComponent()
                    .appendingPathComponent("packaged-app-ui-smoke.json", isDirectory: false)
                    .path
            }
            let uiReportTarget = uiReportPath ?? defaultUIReport
            let uiRunner = UIAutomationSmokeRunner(
                appBundlePath: appBundleURL.path,
                reportPath: uiReportTarget,
                timeout: uiTimeout,
                allowExistingInstance: allowExistingInstance,
                promptForAccessibility: promptForAccessibility,
                keepRunning: false
            )
            let uiReport = uiRunner.run()
            try? uiReport.writeIfRequested()
            uiEvidencePath = uiReport.reportPath
            if let appLogPath = uiReport.appLogPath {
                scannedLogPaths.append(appLogPath)
            }
            checks.append(validateUISmoke(uiReport))
        } else {
            checks.append(.warn("ui-smoke", target: appBundleURL.path, detail: "Menu bar launch proof was not run. Rerun with --run-ui-smoke on a host with Accessibility permission."))
        }

        if runFirstRunReliability {
            let defaultFirstRunReport = reportPath.map { path in
                URL(fileURLWithPath: path)
                    .deletingLastPathComponent()
                    .appendingPathComponent("packaged-app-first-run-reliability.json", isDirectory: false)
                    .path
            }
            let firstRunReportTarget = firstRunReportPath ?? defaultFirstRunReport
            let firstRunRunner = FirstRunReliabilitySmokeRunner(
                appBundlePath: appBundleURL.path,
                reportPath: firstRunReportTarget,
                timeout: firstRunTimeout
            )
            let firstRunReport = firstRunRunner.run()
            try? firstRunReport.writeIfRequested()
            firstRunEvidencePath = firstRunReport.reportPath
            scannedLogPaths.append(contentsOf: firstRunReport.privacySweepPaths)
            checks.append(contentsOf: validateFirstRunReliability(firstRunReport))
        } else {
            checks.append(.warn(
                "first-run-reliability",
                target: appBundleURL.path,
                detail: "Packaged first-run reliability proof was not run. Rerun with --run-first-run-reliability for isolated clean-install coverage."
            ))
        }

        checks.append(contentsOf: validateLogPrivacy(
            paths: scannedLogPaths,
            allowedPathPrefixes: privacyAllowedPathPrefixes(firstRunReportPath: firstRunEvidencePath)
        ))
        checks.append(validateAppcastFile())

        return checks
    }

    private func buildReport(
        checks: [PackagedAppSmokeCheck],
        dmgPath: String?,
        logPaths: [String],
        uiEvidencePath: String?,
        firstRunEvidencePath: String?,
        generatedAt: Date
    ) -> PackagedAppSmokeReport {
        PackagedAppSmokeReport(
            runID: runID,
            generatedAt: ISO8601DateFormatter().string(from: generatedAt),
            appBundlePath: appBundleURL.path,
            sourceInfoPlistPath: sourceInfoPlistURL.path,
            dSYMPath: dSYMURL.path,
            dmgPath: dmgPath,
            appcastPath: appcastURL.path,
            logPaths: logPaths,
            uiReportPath: uiEvidencePath,
            firstRunReportPath: firstRunEvidencePath,
            reportPath: reportPath,
            checks: checks
        )
    }

    private func loadPlist(_ url: URL, check: String, checks: inout [PackagedAppSmokeCheck]) -> [String: Any]? {
        guard fileManager.fileExists(atPath: url.path) else {
            checks.append(.fail(check, target: url.path, detail: "Info.plist is missing."))
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                checks.append(.fail(check, target: url.path, detail: "Info.plist is not a dictionary."))
                return nil
            }
            checks.append(.pass(check, target: url.path, detail: "Info.plist is readable."))
            return plist
        } catch {
            checks.append(.fail(check, target: url.path, detail: error.localizedDescription))
            return nil
        }
    }

    private func validateInfoPlist(sourceInfo: [String: Any], builtInfo: [String: Any]) -> [PackagedAppSmokeCheck] {
        var checks: [PackagedAppSmokeCheck] = []
        let keys = [
            "CFBundleIdentifier",
            "CFBundleName",
            "CFBundleDisplayName",
            "CFBundleExecutable",
            "CFBundleShortVersionString",
            "CFBundleVersion",
            "LSMinimumSystemVersion",
        ]
        let drift = keys.compactMap { key -> String? in
            let source = stringValue(sourceInfo[key])
            let built = stringValue(builtInfo[key])
            return source == built ? nil : "\(key): source=\(source ?? "nil") built=\(built ?? "nil")"
        }
        if drift.isEmpty {
            checks.append(.pass("bundle-info-parity", target: appBundleURL.path, detail: "Built Info.plist matches source release identity keys."))
        } else {
            checks.append(.fail("bundle-info-parity", target: appBundleURL.path, detail: drift.joined(separator: "; ")))
        }

        if let version = stringValue(builtInfo["CFBundleShortVersionString"]), !version.isEmpty,
           let build = stringValue(builtInfo["CFBundleVersion"]), !build.isEmpty {
            checks.append(.pass("bundle-version", target: "Transcripted \(version) (\(build))", detail: "Version and dist are present."))
        } else {
            checks.append(.fail("bundle-version", target: appBundleURL.path, detail: "CFBundleShortVersionString or CFBundleVersion is empty."))
        }

        if stringValue(builtInfo["CFBundleIdentifier"]) == "com.justinbetker.draft" {
            checks.append(.pass("bundle-identifier", target: "com.justinbetker.draft", detail: "Bundle id preserves the current Transcripted TCC identity."))
        } else {
            checks.append(.fail("bundle-identifier", target: stringValue(builtInfo["CFBundleIdentifier"]) ?? "missing", detail: "Unexpected bundle id; changing it is a release migration."))
        }

        if stringValue(builtInfo["LSMinimumSystemVersion"]) == "26.0" {
            checks.append(.pass("minimum-system-version", target: "macOS 26.0", detail: "Packaged app matches the current release floor."))
        } else {
            checks.append(.fail("minimum-system-version", target: stringValue(builtInfo["LSMinimumSystemVersion"]) ?? "missing", detail: "Expected LSMinimumSystemVersion 26.0."))
        }

        return checks
    }

    private func validateSparkleConfig(sourceInfo: [String: Any], builtInfo: [String: Any]) -> [PackagedAppSmokeCheck] {
        var checks: [PackagedAppSmokeCheck] = []
        let keys = ["SUFeedURL", "SUPublicEDKey", "SUEnableAutomaticChecks", "SUAllowsAutomaticUpdates", "SUScheduledCheckInterval"]
        let drift = keys.compactMap { key -> String? in
            plistValuesEqual(sourceInfo[key], builtInfo[key]) ? nil : "\(key) drifted"
        }
        if drift.isEmpty {
            checks.append(.pass("sparkle-config-parity", target: "Info.plist", detail: "Built Sparkle settings match source Info.plist."))
        } else {
            checks.append(.fail("sparkle-config-parity", target: "Info.plist", detail: drift.joined(separator: "; ")))
        }

        let feedURL = stringValue(builtInfo["SUFeedURL"]) ?? ""
        if feedURL == "https://raw.githubusercontent.com/r3dbars/transcripted/main/docs/appcast.xml" {
            checks.append(.pass("sparkle-feed-url", target: feedURL, detail: "Updater points at the committed appcast feed."))
        } else {
            checks.append(.fail("sparkle-feed-url", target: feedURL.isEmpty ? "missing" : feedURL, detail: "Expected the canonical Transcripted appcast URL."))
        }

        let publicKey = stringValue(builtInfo["SUPublicEDKey"]) ?? ""
        if publicKey.count >= 32, Data(base64Encoded: publicKey) != nil {
            checks.append(.pass("sparkle-public-key", target: "SUPublicEDKey", detail: "Public EdDSA key is present and base64-decodable."))
        } else {
            checks.append(.fail("sparkle-public-key", target: "SUPublicEDKey", detail: "Missing or malformed Sparkle public key."))
        }

        if boolValue(builtInfo["SUEnableAutomaticChecks"]) == true {
            checks.append(.pass("sparkle-auto-checks", target: "SUEnableAutomaticChecks", detail: "Automatic update checks are enabled."))
        } else {
            checks.append(.fail("sparkle-auto-checks", target: "SUEnableAutomaticChecks", detail: "Automatic update checks are disabled or missing."))
        }

        if boolValue(builtInfo["SUAllowsAutomaticUpdates"]) == true {
            checks.append(.pass("sparkle-auto-downloads", target: "SUAllowsAutomaticUpdates", detail: "Automatic update downloads can be enabled by the user."))
        } else {
            checks.append(.fail("sparkle-auto-downloads", target: "SUAllowsAutomaticUpdates", detail: "Automatic update downloads are disabled or missing."))
        }

        if intValue(builtInfo["SUScheduledCheckInterval"]).map({ $0 > 0 }) == true {
            checks.append(.pass("sparkle-check-interval", target: "SUScheduledCheckInterval", detail: "Scheduled update interval is present."))
        } else {
            checks.append(.fail("sparkle-check-interval", target: "SUScheduledCheckInterval", detail: "Scheduled update interval is missing or invalid."))
        }

        return checks
    }

    private func validateObservabilityConfig(builtInfo: [String: Any]) -> [PackagedAppSmokeCheck] {
        var checks: [PackagedAppSmokeCheck] = []
        let sentryDSN = stringValue(builtInfo["TranscriptedSentryDSN"]) ?? ""
        if sentryDSN.hasPrefix("https://") {
            checks.append(.pass("sentry-dsn", target: "TranscriptedSentryDSN", detail: "Sentry DSN uses HTTPS."))
        } else {
            checks.append(.fail("sentry-dsn", target: "TranscriptedSentryDSN", detail: "Sentry DSN is missing or not HTTPS."))
        }

        let prefix = stringValue(builtInfo["TranscriptedSentryReleasePrefix"]) ?? ""
        let version = stringValue(builtInfo["CFBundleShortVersionString"]) ?? ""
        let dist = stringValue(builtInfo["CFBundleVersion"]) ?? ""
        if !prefix.isEmpty, !version.isEmpty, !dist.isEmpty {
            checks.append(.pass("sentry-release-metadata", target: "\(prefix)@\(version) dist \(dist)", detail: "Sentry release name and dist can be derived locally without registering a release."))
        } else {
            checks.append(.fail("sentry-release-metadata", target: "Info.plist", detail: "Missing release prefix, version, or dist."))
        }

        let postHogHost = stringValue(builtInfo["TranscriptedPostHogHost"]) ?? ""
        if postHogHost.hasPrefix("https://") {
            checks.append(.pass("posthog-host", target: "TranscriptedPostHogHost", detail: "PostHog host uses HTTPS."))
        } else {
            checks.append(.fail("posthog-host", target: "TranscriptedPostHogHost", detail: "PostHog host is missing or not HTTPS."))
        }
        return checks
    }

    private func validateBundledFramework(relativePath: String, check: String) -> PackagedAppSmokeCheck {
        let url = appBundleURL.appendingPathComponent(relativePath, isDirectory: true)
        if fileManager.fileExists(atPath: url.path) {
            return .pass(check, target: relativePath, detail: "Required bundled framework exists.")
        }
        return .fail(check, target: relativePath, detail: "Required bundled framework is missing.")
    }

    private func validateBundledHelper(relativePath: String, check: String) -> PackagedAppSmokeCheck {
        let url = appBundleURL.appendingPathComponent(relativePath, isDirectory: false)
        if fileManager.isExecutableFile(atPath: url.path) {
            return .pass(check, target: relativePath, detail: "Bundled helper exists and is executable.")
        }
        return .fail(check, target: relativePath, detail: "Bundled helper is missing or not executable.")
    }

    private func validateCodeSignature() -> PackagedAppSmokeCheck {
        guard verifyCodeSignature else {
            return .warn("code-signature", target: appBundleURL.path, detail: "Code signature verification was skipped by request.")
        }
        let result = commandRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", appBundleURL.path])
        if result.exitCode == 0 {
            return .pass("code-signature", target: appBundleURL.path, detail: "codesign --verify --deep --strict passed.")
        }
        return .fail("code-signature", target: appBundleURL.path, detail: result.combinedOutput.trimmedForReport)
    }

    private func validateDSYM(binaryURL: URL) -> PackagedAppSmokeCheck {
        guard fileManager.fileExists(atPath: dSYMURL.path) else {
            return requiredOrWarn("release-dsym", target: dSYMURL.path, detail: "Release dSYM is missing. build-beta.sh normally writes build/Transcripted.app.dSYM.", required: requireDSYM)
        }

        let dwarfURL = dSYMURL.appendingPathComponent("Contents/Resources/DWARF/Transcripted", isDirectory: false)
        guard fileManager.fileExists(atPath: dwarfURL.path) else {
            return requiredOrWarn("release-dsym", target: dSYMURL.path, detail: "dSYM exists but is missing Contents/Resources/DWARF/Transcripted.", required: requireDSYM)
        }

        let binaryUUIDs = uuidSet(for: binaryURL)
        let debugUUIDs = uuidSet(for: dSYMURL)
        if binaryUUIDs.uuids.isEmpty || debugUUIDs.uuids.isEmpty {
            return requiredOrWarn(
                "release-dsym-uuid",
                target: dSYMURL.path,
                detail: "Could not read UUIDs. binary=\(binaryUUIDs.error.trimmedForReport) dSYM=\(debugUUIDs.error.trimmedForReport)",
                required: requireDSYM
            )
        }
        if binaryUUIDs.uuids == debugUUIDs.uuids {
            return .pass("release-dsym-uuid", target: dSYMURL.path, detail: "dSYM UUID matches the app binary.")
        }
        return .fail(
            "release-dsym-uuid",
            target: dSYMURL.path,
            detail: "Binary UUIDs \(binaryUUIDs.uuids.sorted()) do not match dSYM UUIDs \(debugUUIDs.uuids.sorted())."
        )
    }

    private func uuidSet(for url: URL) -> (uuids: Set<String>, error: String) {
        let result = commandRunner.run("/usr/bin/dwarfdump", ["--uuid", url.path])
        guard result.exitCode == 0 else {
            return ([], result.combinedOutput)
        }
        var uuids = Set<String>()
        let pattern = #"UUID:\s+([A-Fa-f0-9-]+)\s"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return ([], "internal regex error")
        }
        let range = NSRange(result.stdout.startIndex..<result.stdout.endIndex, in: result.stdout)
        for match in regex.matches(in: result.stdout, range: range) {
            if let uuidRange = Range(match.range(at: 1), in: result.stdout) {
                uuids.insert(String(result.stdout[uuidRange]).uppercased())
            }
        }
        return (uuids, "")
    }

    private func validateDMG(at url: URL) -> PackagedAppSmokeCheck {
        guard fileManager.fileExists(atPath: url.path) else {
            return requiredOrWarn("release-dmg", target: url.path, detail: "DMG is missing. build-beta.sh normally writes build/Transcripted-<version>.dmg.", required: requireDMG)
        }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if (values.fileSize ?? 0) <= 0 {
                return requiredOrWarn("release-dmg", target: url.path, detail: "DMG exists but is empty.", required: requireDMG)
            }
        } catch {
            return requiredOrWarn("release-dmg", target: url.path, detail: error.localizedDescription, required: requireDMG)
        }

        let result = commandRunner.run("/usr/bin/hdiutil", ["imageinfo", url.path])
        if result.exitCode == 0 {
            return .pass("release-dmg", target: url.path, detail: "DMG exists, is non-empty, and hdiutil can read image metadata.")
        }
        return requiredOrWarn("release-dmg", target: url.path, detail: "DMG exists, but hdiutil imageinfo failed: \(result.combinedOutput.trimmedForReport)", required: requireDMG)
    }

    private func validateUISmoke(_ report: UIAutomationSmokeReport) -> PackagedAppSmokeCheck {
        switch report.status {
        case .pass:
            return .pass("ui-smoke", target: appBundleURL.path, detail: "App launched, menu bar appeared, audit rows 18/25/27/29/31 passed, and core menu/settings controls were visible.")
        case .incomplete:
            return .warn("ui-smoke", target: appBundleURL.path, detail: firstFlagDetail(in: report) ?? "UI smoke was incomplete.")
        case .fail:
            return .fail("ui-smoke", target: appBundleURL.path, detail: firstFlagDetail(in: report) ?? "UI smoke failed.")
        }
    }

    private func validateLogPrivacy(
        paths: [String],
        allowedPathPrefixes: [String] = []
    ) -> [PackagedAppSmokeCheck] {
        let uniquePaths = Array(Set(paths.filter { !$0.isEmpty })).sorted()
        guard !uniquePaths.isEmpty else {
            return [.warn("logs/privacy-scan", target: "local logs", detail: "No log path was provided and UI smoke did not produce an app log to scan.")]
        }

        return uniquePaths.map { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard fileManager.fileExists(atPath: url.path) else {
                return .warn("logs/privacy-scan", target: url.path, detail: "Log file does not exist.")
            }
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let findings = PrivacyLogScanner.findings(
                    in: content,
                    allowedPathPrefixes: allowedPathPrefixes
                )
                if findings.isEmpty {
                    return .pass("logs/privacy-scan", target: url.path, detail: "No obvious raw transcript/audio/title/path/email/token leak patterns found.")
                }
                return .fail("logs/privacy-scan", target: url.path, detail: findings.prefix(3).joined(separator: "; "))
            } catch {
                return .fail("logs/privacy-scan", target: url.path, detail: error.localizedDescription)
            }
        }
    }

    private func validateAppcastFile() -> PackagedAppSmokeCheck {
        guard fileManager.fileExists(atPath: appcastURL.path) else {
            return .warn("appcast-source", target: appcastURL.path, detail: "Committed appcast is missing. Existing installs will not discover unpublished builds until appcast is regenerated and pushed.")
        }
        guard let content = try? String(contentsOf: appcastURL, encoding: .utf8) else {
            return .fail("appcast-source", target: appcastURL.path, detail: "Committed appcast exists but is not readable.")
        }
        if content.contains("sparkle:edSignature"), content.contains("<enclosure") {
            return .pass("appcast-source", target: appcastURL.path, detail: "Committed appcast has signed enclosure metadata. This smoke does not publish or verify live GitHub assets.")
        }
        return .warn("appcast-source", target: appcastURL.path, detail: "Committed appcast is readable but latest signed enclosure metadata was not obvious.")
    }

    private func requiredOrWarn(_ check: String, target: String, detail: String, required: Bool) -> PackagedAppSmokeCheck {
        required ? .fail(check, target: target, detail: detail) : .warn(check, target: target, detail: detail)
    }

    private func resolvedDMGURL(version: String) -> URL {
        if let explicitDMGPath, !explicitDMGPath.isEmpty {
            return URL(fileURLWithPath: explicitDMGPath).standardizedFileURL
        }
        return URL(fileURLWithPath: "build/Transcripted-\(version).dmg").standardizedFileURL
    }

    private func firstFlagDetail(in report: UIAutomationSmokeReport) -> String? {
        report.checks.first { $0.status != .pass }.map { check in
            "\(check.id): \(check.detail ?? check.target)"
        }
    }

    private func privacyAllowedPathPrefixes(firstRunReportPath: String?) -> [String] {
        var prefixes = [
            appBundleURL.path,
            dSYMURL.path,
        ]

        guard let firstRunReportPath, !firstRunReportPath.isEmpty else {
            return Array(Set(prefixes)).sorted()
        }
        let reportURL = URL(fileURLWithPath: firstRunReportPath).standardizedFileURL
        guard let data = try? Data(contentsOf: reportURL),
              let report = try? JSONDecoder().decode(FirstRunReliabilitySmokeReport.self, from: data) else {
            return Array(Set(prefixes)).sorted()
        }

        prefixes.append(report.evidenceRootPath)
        prefixes.append(report.appBundlePath)
        prefixes.append(contentsOf: report.scenarios.flatMap { $0.isolatedHomePaths + $0.containerPaths })
        return Array(Set(prefixes.filter { !$0.isEmpty })).sorted()
    }

    private func validateFirstRunReliability(_ report: FirstRunReliabilitySmokeReport) -> [PackagedAppSmokeCheck] {
        let summaryDetail = report.status == .pass
            ? "Isolated first-run reliability matrix passed \(report.summary.passed)/\(report.scenarios.count) scenarios."
            : "Isolated first-run reliability matrix flagged \(report.summary.failed) failures and \(report.summary.warnings) warnings."
        var checks = [
            PackagedAppSmokeCheck(
                id: "first-run-reliability",
                status: report.status,
                target: appBundleURL.path,
                detail: summaryDetail
            )
        ]
        checks.append(contentsOf: report.scenarios.map { scenario in
            PackagedAppSmokeCheck(
                id: "first-run-\(scenario.id)",
                status: scenario.status,
                target: scenario.primaryEvidencePath ?? appBundleURL.path,
                detail: scenario.detail
            )
        })
        return checks
    }
}

struct PackagedAppSmokeCheck: Codable, Equatable {
    let id: String
    let status: ValidationStatus
    let target: String
    let detail: String

    static func pass(_ id: String, target: String, detail: String) -> PackagedAppSmokeCheck {
        PackagedAppSmokeCheck(id: id, status: .pass, target: target, detail: detail)
    }

    static func warn(_ id: String, target: String, detail: String) -> PackagedAppSmokeCheck {
        PackagedAppSmokeCheck(id: id, status: .warn, target: target, detail: detail)
    }

    static func fail(_ id: String, target: String, detail: String) -> PackagedAppSmokeCheck {
        PackagedAppSmokeCheck(id: id, status: .fail, target: target, detail: detail)
    }
}

struct PackagedAppSmokeReport: Codable, Equatable {
    struct Summary: Codable, Equatable {
        let passed: Int
        let failed: Int
        let warnings: Int
    }

    let runID: String
    let generatedAt: String
    let appBundlePath: String
    let sourceInfoPlistPath: String
    let dSYMPath: String
    let dmgPath: String?
    let appcastPath: String
    let logPaths: [String]
    let uiReportPath: String?
    let firstRunReportPath: String?
    let reportPath: String?
    let checks: [PackagedAppSmokeCheck]

    var summary: Summary {
        Summary(
            passed: checks.filter { $0.status == .pass }.count,
            failed: checks.filter { $0.status == .fail }.count,
            warnings: checks.filter { $0.status == .warn }.count
        )
    }

    var status: ValidationStatus {
        if summary.failed > 0 { return .fail }
        if summary.warnings > 0 { return .warn }
        return .pass
    }

    var exitCode: Int32 {
        switch status {
        case .pass: return 0
        case .fail: return 1
        case .warn: return 3
        }
    }

    func printText() {
        let passed = summary.passed
        let total = checks.count
        switch status {
        case .pass:
            print("PASS: tested \(passed)/\(total) packaged-app checks. App bundle, Sparkle config, signing, artifacts, and logs look coherent.")
        case .fail:
            print("FAIL: tested \(passed)/\(total) packaged-app checks. \(summary.failed + summary.warnings) flagged.")
        case .warn:
            print("INCOMPLETE: tested \(passed)/\(total) packaged-app checks. \(summary.warnings) warning(s).")
        }

        for check in checks where check.status != .pass {
            print("\(check.status.rawValue): \(check.id) - \(check.detail)")
        }
        if let uiReportPath {
            print("UI report: \(uiReportPath)")
        }
        if let firstRunReportPath {
            print("First-run report: \(firstRunReportPath)")
        }
        if let reportPath {
            print("Report: \(reportPath)")
        }
    }

    func writeIfRequested() throws {
        guard let reportPath, !reportPath.isEmpty else { return }
        let url = URL(fileURLWithPath: reportPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

final class FirstRunReliabilitySmokeRunner {
    private let appBundleURL: URL
    private let reportPath: String?
    private let timeout: TimeInterval
    private let fileManager: FileManager
    private let runID = UUID().uuidString

    init(
        appBundlePath: String,
        reportPath: String?,
        timeout: Double,
        fileManager: FileManager = .default
    ) {
        self.appBundleURL = URL(fileURLWithPath: appBundlePath).standardizedFileURL
        self.reportPath = reportPath
        self.timeout = max(5, timeout)
        self.fileManager = fileManager
    }

    func run(generatedAt: Date = Date()) -> FirstRunReliabilitySmokeReport {
        let evidenceRoot = resolvedEvidenceRoot()
        var scenarios: [FirstRunReliabilityScenario] = []
        let executableURL = appBundleURL.appendingPathComponent("Contents/MacOS/Transcripted", isDirectory: false)

        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            scenarios.append(
                FirstRunReliabilityScenario(
                    id: "harness-bootstrap",
                    status: .fail,
                    detail: "Packaged app executable is missing: \(executableURL.path)",
                    reportPaths: [],
                    logPaths: [],
                    isolatedHomePaths: [],
                    containerPaths: [],
                    launches: []
                )
            )
            return buildReport(
                scenarios: scenarios,
                evidenceRoot: evidenceRoot,
                generatedAt: generatedAt
            )
        }

        do {
            try fileManager.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
        } catch {
            scenarios.append(
                FirstRunReliabilityScenario(
                    id: "harness-bootstrap",
                    status: .fail,
                    detail: "Failed to prepare first-run evidence root: \(error.localizedDescription)",
                    reportPaths: [],
                    logPaths: [],
                    isolatedHomePaths: [],
                    containerPaths: [],
                    launches: []
                )
            )
            return buildReport(
                scenarios: scenarios,
                evidenceRoot: evidenceRoot,
                generatedAt: generatedAt
            )
        }

        let onboardingWorkspace = makeWorkspace(id: "zero-state", evidenceRoot: evidenceRoot)
        scenarios.append(runZeroStateAndRestartScenario(executableURL: executableURL, workspace: onboardingWorkspace))

        scenarios.append(runPermissionsMatrixScenario(executableURL: executableURL, evidenceRoot: evidenceRoot))

        let staleCacheWorkspace = makeWorkspace(id: "stale-model-cache", evidenceRoot: evidenceRoot)
        scenarios.append(runStaleModelCacheScenario(executableURL: executableURL, workspace: staleCacheWorkspace))

        let cachedModelWorkspace = makeWorkspace(id: "cached-model", evidenceRoot: evidenceRoot)
        scenarios.append(runCachedModelScenario(executableURL: executableURL, workspace: cachedModelWorkspace))

        let blockedDestinationWorkspace = makeWorkspace(id: "destination-unwritable", evidenceRoot: evidenceRoot)
        scenarios.append(runUnwritableDestinationScenario(executableURL: executableURL, workspace: blockedDestinationWorkspace))

        let helperWorkspace = makeWorkspace(id: "helper-install", evidenceRoot: evidenceRoot)
        scenarios.append(runHelperInstallScenario(executableURL: executableURL, workspace: helperWorkspace))

        let repairWorkspace = makeWorkspace(id: "helper-repair", evidenceRoot: evidenceRoot)
        scenarios.append(runHelperRepairScenario(executableURL: executableURL, workspace: repairWorkspace))

        scenarios.append(runHelperRefreshScenario(executableURL: executableURL, workspace: helperWorkspace))
        scenarios.append(runHelperReadySecondLaunchScenario(executableURL: executableURL, workspace: helperWorkspace))

        let syntheticWorkspace = makeWorkspace(id: "synthetic-models", evidenceRoot: evidenceRoot)
        scenarios.append(runSyntheticModelMatrixScenario(executableURL: executableURL, workspace: syntheticWorkspace))

        return buildReport(
            scenarios: scenarios,
            evidenceRoot: evidenceRoot,
            generatedAt: generatedAt
        )
    }

    private func buildReport(
        scenarios: [FirstRunReliabilityScenario],
        evidenceRoot: URL,
        generatedAt: Date
    ) -> FirstRunReliabilitySmokeReport {
        FirstRunReliabilitySmokeReport(
            runID: runID,
            generatedAt: ISO8601DateFormatter().string(from: generatedAt),
            appBundlePath: appBundleURL.path,
            evidenceRootPath: evidenceRoot.path,
            reportPath: reportPath,
            scenarios: scenarios
        )
    }

    private func runZeroStateAndRestartScenario(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace
    ) -> FirstRunReliabilityScenario {
        let first = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "zero-state-first",
            options: FirstRunLaunchOptions(onboardingCompleted: false, forceOnboarding: true)
        )
        let second = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "zero-state-restart",
            options: FirstRunLaunchOptions(onboardingCompleted: false, forceOnboarding: true)
        )
        return buildScenario(
            id: "zero-state-and-restart",
            launches: [first, second],
            successDetail: "Two launches from the same empty isolated profile kept onboarding incomplete, model state idle, and the same cached system-audio permission flags across restart."
        ) { reports in
            guard reports.count == 2 else {
                return ["expected two successful launch reports"]
            }
            var failures = isolationFailures(in: reports[0], workspace: workspace)
            failures.append(contentsOf: isolationFailures(in: reports[1], workspace: workspace))
            failures.append(contentsOf: expectedBooleanFailures(
                reports[0].permissionsOnboardingCompleted == false
                    && reports[1].permissionsOnboardingCompleted == false,
                message: "onboarding should stay incomplete across restart"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                reports[0].actualModelState == "not_loaded"
                    && reports[1].actualModelState == "not_loaded",
                message: "zero-state launches should keep actual model state at not_loaded"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                reports[0].helper.stateAfter == "notInstalled"
                    && reports[1].helper.stateAfter == "notInstalled",
                message: "helper should stay notInstalled in the empty profile"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                reports[0].runtime.systemAudioPermissionKnown == reports[1].runtime.systemAudioPermissionKnown
                    && reports[0].runtime.systemAudioPermissionGranted == reports[1].runtime.systemAudioPermissionGranted,
                message: "zero-state restart should preserve the same cached system-audio permission flags"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                reports[0].runtime.captureLibraryPath == reports[1].runtime.captureLibraryPath,
                message: "restart should keep the same isolated capture-library path"
            ))
            return failures
        }
    }

    private func runPermissionsMatrixScenario(
        executableURL: URL,
        evidenceRoot: URL
    ) -> FirstRunReliabilityScenario {
        let deniedWorkspace = makeWorkspace(id: "permissions-matrix-denied", evidenceRoot: evidenceRoot)
        let grantedWorkspace = makeWorkspace(id: "permissions-matrix-granted", evidenceRoot: evidenceRoot)
        let denied = launch(
            executableURL: executableURL,
            workspace: deniedWorkspace,
            tag: "permissions-denied",
            options: FirstRunLaunchOptions(
                onboardingCompleted: false,
                forceOnboarding: true,
                launchDefaultsOverrides: [
                    "systemAudioRecordingPermissionKnown": true,
                    "systemAudioRecordingPermissionGranted": false,
                ]
            )
        )
        let granted = launch(
            executableURL: executableURL,
            workspace: grantedWorkspace,
            tag: "permissions-granted",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                launchDefaultsOverrides: [
                    "systemAudioRecordingPermissionKnown": true,
                    "systemAudioRecordingPermissionGranted": true,
                ]
            )
        )
        return buildScenario(
            id: "permissions-state-matrix",
            launches: [denied, granted],
            successDetail: "The packaged app preserved incomplete and completed onboarding prefs while exercising cached denied and granted system-audio permission flags from separate isolated launch defaults."
        ) { reports in
            guard reports.count == 2 else {
                return ["expected denied and granted permission launch reports"]
            }
            let denied = reports[0]
            let granted = reports[1]
            var failures = isolationFailures(in: denied, workspace: deniedWorkspace)
            failures.append(contentsOf: isolationFailures(in: granted, workspace: grantedWorkspace))
            failures.append(contentsOf: expectedBooleanFailures(
                denied.runtime.systemAudioPermissionKnown && !denied.runtime.systemAudioPermissionGranted,
                message: "denied launch should report the cached known=true granted=false system-audio flags"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                granted.runtime.systemAudioPermissionKnown && granted.runtime.systemAudioPermissionGranted,
                message: "granted launch should report the cached known=true granted=true system-audio flags"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                denied.runtime.homePath != granted.runtime.homePath
                    && denied.runtime.containerPath != granted.runtime.containerPath,
                message: "cached permission-state coverage should launch denied and granted cases from separate isolated homes and containers"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                denied.permissionsOnboardingCompleted == false && granted.permissionsOnboardingCompleted,
                message: "permission matrix should preserve incomplete and completed onboarding states while covering cached permission-state restoration"
            ))
            return failures
        }
    }

    private func runStaleModelCacheScenario(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace
    ) -> FirstRunReliabilityScenario {
        seedStaleModelCache(in: workspace.homeURL)
        let outcome = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "stale-model-cache",
            options: FirstRunLaunchOptions(onboardingCompleted: true, forceOnboarding: false)
        )
        return buildScenario(
            id: "stale-model-cache",
            launches: [outcome],
            successDetail: "Stale local-model cache folders stayed isolated and did not trick first run into reporting a reusable active model."
        ) { reports in
            guard let report = reports.first else {
                return ["expected stale-cache launch report"]
            }
            var failures = isolationFailures(in: report, workspace: workspace)
            failures.append(contentsOf: expectedBooleanFailures(
                report.cachedModelDirectory == nil,
                message: "stale cache should not report an active cached model directory"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                report.actualModelState == "not_loaded",
                message: "stale cache should keep actual model state at not_loaded"
            ))
            return failures
        }
    }

    private func runCachedModelScenario(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace
    ) -> FirstRunReliabilityScenario {
        seedActiveModelCache(in: workspace.homeURL)
        let first = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "cached-model-first",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                environmentOverrides: [
                    "TRANSCRIPTED_FIRST_RUN_RELIABILITY_ACTIVATE_CACHED_MODEL": "1",
                ]
            )
        )
        let restart = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "cached-model-restart",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                environmentOverrides: [
                    "TRANSCRIPTED_FIRST_RUN_RELIABILITY_ACTIVATE_CACHED_MODEL": "1",
                ]
            )
        )
        return buildScenario(
            id: "cached-model-detected",
            launches: [first, restart],
            successDetail: "A complete synthetic Parakeet cache stayed cached across two packaged-app launches from the same isolated profile without entering the download state."
        ) { reports in
            guard reports.count == 2 else {
                return ["expected cached-model first-launch and restart reports"]
            }
            var failures = isolationFailures(in: reports[0], workspace: workspace)
            failures.append(contentsOf: isolationFailures(in: reports[1], workspace: workspace))
            failures.append(contentsOf: expectedBooleanFailures(
                reports.allSatisfy { $0.actualModelState == "cached" },
                message: "active model cache should remain cached on first launch and restart without entering the download state"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                reports.allSatisfy {
                    $0.cachedModelDirectory?.hasSuffix("parakeet-tdt-0.6b-v3") == true
                },
                message: "both cached-model launches should report the synthetic Parakeet directory"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                reports[0].runtime.homePath == reports[1].runtime.homePath
                    && reports[0].runtime.containerPath == reports[1].runtime.containerPath,
                message: "cached-model restart should reuse the same isolated home and container"
            ))
            return failures
        }
    }

    private func runUnwritableDestinationScenario(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace
    ) -> FirstRunReliabilityScenario {
        let blockedParent = workspace.rootURL.appendingPathComponent("blocked-parent", isDirectory: true)
        try? fileManager.createDirectory(at: blockedParent, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blockedParent.path)
        let blockedContainer = blockedParent.appendingPathComponent("Transcripted", isDirectory: true)
        let outcome = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "destination-unwritable",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                containerURL: blockedContainer
            )
        )
        return buildScenario(
            id: "destination-unwritable",
            launches: [outcome],
            successDetail: "The harness caught the safe stand-in for full or read-only destinations: app-owned paths stayed isolated and write probes failed loudly."
        ) { reports in
            guard let report = reports.first else {
                return ["expected destination failure launch report"]
            }
            var failures = isolationFailures(in: report, workspace: workspace, expectedContainerURL: blockedContainer)
            failures.append(contentsOf: expectedBooleanFailures(
                !report.runtime.appSupportWritable && !report.runtime.captureLibraryWritable && !report.runtime.cacheWritable,
                message: "blocked destination should report every app-owned store as unwritable"
            ))
            return failures
        }
    }

    private func runHelperInstallScenario(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace
    ) -> FirstRunReliabilityScenario {
        let outcome = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "helper-install",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                environmentOverrides: [
                    "TRANSCRIPTED_FIRST_RUN_RELIABILITY_ACTION": "install-helper",
                ]
            )
        )
        return buildScenario(
            id: "helper-install",
            launches: [outcome],
            successDetail: "The packaged app installed the bundled MCP helper into the isolated container, wrote an isolated Claude config, and passed the helper self-test."
        ) { reports in
            guard let report = reports.first else {
                return ["expected helper install launch report"]
            }
            var failures = isolationFailures(in: report, workspace: workspace)
            failures.append(contentsOf: helperInstalledFailures(report))
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.stateBefore == "notInstalled",
                message: "helper install should start from notInstalled"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.selfTestOK == true,
                message: "helper install should report a passing self-test"
            ))
            return failures
        }
    }

    private func runHelperRepairScenario(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace
    ) -> FirstRunReliabilityScenario {
        seedMalformedClaudeConfig(in: workspace.homeURL)
        seedInstalledHelperStub(at: workspace.containerURL.appendingPathComponent("mcp/transcripted-mcp", isDirectory: false))
        let outcome = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "helper-repair",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                environmentOverrides: [
                    "TRANSCRIPTED_FIRST_RUN_RELIABILITY_ACTION": "install-helper",
                ]
            )
        )
        return buildScenario(
            id: "helper-repair",
            launches: [outcome],
            successDetail: "Malformed helper config was backed up, repaired, and replaced with the bundled helper inside the isolated harness."
        ) { reports in
            guard let report = reports.first else {
                return ["expected helper repair launch report"]
            }
            var failures = isolationFailures(in: report, workspace: workspace)
            failures.append(contentsOf: helperInstalledFailures(report))
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.stateBefore == "needsRepair",
                message: "repair scenario should start from needsRepair"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.backupPath != nil,
                message: "repair scenario should back up the unreadable Claude config"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.configIsReadableBefore == false && report.helper.configIsReadableAfter == true,
                message: "repair scenario should rewrite the unreadable Claude config"
            ))
            return failures
        }
    }

    private func runHelperRefreshScenario(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace
    ) -> FirstRunReliabilityScenario {
        seedInstalledHelperStub(at: workspace.containerURL.appendingPathComponent("mcp/transcripted-mcp", isDirectory: false))
        let outcome = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "helper-refresh",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                environmentOverrides: [
                    "TRANSCRIPTED_FIRST_RUN_RELIABILITY_ACTION": "refresh-helper",
                ]
            )
        )
        return buildScenario(
            id: "helper-refresh-after-update",
            launches: [outcome],
            successDetail: "A stale installed MCP helper was refreshed in place to match the bundled helper, which approximates an app-update replacement path."
        ) { reports in
            guard let report = reports.first else {
                return ["expected helper refresh launch report"]
            }
            var failures = isolationFailures(in: report, workspace: workspace)
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.stateBefore == "needsRepair",
                message: "refresh scenario should detect a stale helper as needsRepair before refresh"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.refreshed == true,
                message: "refresh scenario should report refreshed=true"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.installedBinaryMatchesBundledAfter,
                message: "refresh scenario should leave the installed helper matching the bundled helper"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.stateAfter == "installed",
                message: "refresh scenario should end in installed state"
            ))
            return failures
        }
    }

    private func runHelperReadySecondLaunchScenario(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace
    ) -> FirstRunReliabilityScenario {
        let outcome = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "helper-ready-second-launch",
            options: FirstRunLaunchOptions(onboardingCompleted: true, forceOnboarding: false)
        )
        return buildScenario(
            id: "ready-second-launch",
            launches: [outcome],
            successDetail: "A second launch after helper install and refresh stayed ready: the isolated helper remained installed, configured, and matched to the packaged build."
        ) { reports in
            guard let report = reports.first else {
                return ["expected second-launch readiness report"]
            }
            var failures = isolationFailures(in: report, workspace: workspace)
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.stateBefore == "installed" && report.helper.stateAfter == "installed",
                message: "second launch should keep helper state installed before and after reporting"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                report.helper.installedBinaryMatchesBundledAfter,
                message: "second launch should keep the installed helper aligned with the bundled helper"
            ))
            return failures
        }
    }

    private func runSyntheticModelMatrixScenario(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace
    ) -> FirstRunReliabilityScenario {
        let failed = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "synthetic-failed",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                environmentOverrides: [
                    "TRANSCRIPTED_FIRST_RUN_RELIABILITY_SYNTHETIC_MODEL_STATE": "failed:Synthetic setup failed",
                ]
            )
        )
        let resumed = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "synthetic-resumed",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                environmentOverrides: [
                    "TRANSCRIPTED_FIRST_RUN_RELIABILITY_SYNTHETIC_MODEL_STATE": "downloading:0.73",
                ]
            )
        )
        let ready = launch(
            executableURL: executableURL,
            workspace: workspace,
            tag: "synthetic-ready",
            options: FirstRunLaunchOptions(
                onboardingCompleted: true,
                forceOnboarding: false,
                environmentOverrides: [
                    "TRANSCRIPTED_FIRST_RUN_RELIABILITY_SYNTHETIC_MODEL_STATE": "ready",
                ]
            )
        )
        return buildScenario(
            id: "synthetic-model-matrix",
            launches: [failed, resumed, ready],
            successDetail: "Synthetic model states covered failure, retry copy, resumed download progress, and ready-state copy without triggering a real model download."
        ) { reports in
            guard reports.count == 3 else {
                return ["expected three synthetic model launch reports"]
            }
            let failed = reports[0]
            let resumed = reports[1]
            let ready = reports[2]
            var failures = isolationFailures(in: failed, workspace: workspace)
            failures.append(contentsOf: isolationFailures(in: resumed, workspace: workspace))
            failures.append(contentsOf: isolationFailures(in: ready, workspace: workspace))
            failures.append(contentsOf: expectedBooleanFailures(
                failed.syntheticModel?.card.tone == "failed"
                    && failed.syntheticModel?.card.status == "Retry needed"
                    && failed.syntheticModel?.action.subtitle.contains("Try again") == true,
                message: "failed synthetic state should keep retry-focused first-run copy"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                resumed.syntheticModel?.card.tone == "working"
                    && resumed.syntheticModel?.card.status.contains("73%") == true
                    && resumed.syntheticModel?.card.progress.map { $0 > 0.5 } == true,
                message: "resumed synthetic state should show in-progress download copy and progress"
            ))
            failures.append(contentsOf: expectedBooleanFailures(
                ready.syntheticModel?.card.tone == "ready"
                    && ready.syntheticModel?.card.status == "Ready"
                    && ready.syntheticModel?.action.subtitle.isEmpty == true,
                message: "ready synthetic state should expose ready copy with no setup subtitle"
            ))
            return failures
        }
    }

    private func launch(
        executableURL: URL,
        workspace: FirstRunScenarioWorkspace,
        tag: String,
        options: FirstRunLaunchOptions
    ) -> FirstRunReliabilityLaunchOutcome {
        do {
            try fileManager.createDirectory(at: workspace.rootURL, withIntermediateDirectories: true)
            try writePreferences(
                home: workspace.homeURL,
                values: defaultPreferences(
                    onboardingCompleted: options.onboardingCompleted,
                    forceOnboarding: options.forceOnboarding,
                    overrides: options.preferenceOverrides
                )
            )
            try fileManager.createDirectory(at: workspace.reportsDirectoryURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: workspace.logsDirectoryURL, withIntermediateDirectories: true)
        } catch {
            return .failure(
                reportURL: workspace.reportsDirectoryURL.appendingPathComponent("\(tag).json", isDirectory: false),
                logURL: workspace.logsDirectoryURL.appendingPathComponent("\(tag).log", isDirectory: false),
                detail: "Failed to prepare isolated launch state: \(error.localizedDescription)",
                homeURL: workspace.homeURL,
                containerURL: options.containerURL ?? workspace.containerURL
            )
        }

        let reportURL = workspace.reportsDirectoryURL.appendingPathComponent("\(tag).json", isDirectory: false)
        let logURL = workspace.logsDirectoryURL.appendingPathComponent("\(tag).log", isDirectory: false)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-permissionsOnboardingCompleted", options.onboardingCompleted ? "YES" : "NO",
            "-forcePermissionsOnboarding", options.forceOnboarding ? "YES" : "NO",
            "-observability-anonymous-analytics-enabled", "NO",
            "-observability-crash-reporting-enabled", "NO",
        ]
        for key in options.launchDefaultsOverrides.keys.sorted() {
            guard let value = userDefaultsArgumentValue(options.launchDefaultsOverrides[key]) else { continue }
            process.arguments?.append(contentsOf: ["-\(key)", value])
        }

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = workspace.homeURL.path
        environment["CFFIXED_USER_HOME"] = workspace.homeURL.path
        environment["TRANSCRIPTED_CONTAINER_DIR"] = (options.containerURL ?? workspace.containerURL).path
        environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
        environment["TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS"] = "1"
        environment["TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD"] = "1"
        environment["TRANSCRIPTED_FIRST_RUN_RELIABILITY_REPORT"] = reportURL.path
        environment["TRANSCRIPTED_FIRST_RUN_RELIABILITY_TERMINATE_AFTER_REPORT"] = "1"
        environment["TRANSCRIPTED_FIRST_RUN_RELIABILITY_TERMINATE_DELAY_SECONDS"] = "0.1"
        environment.removeValue(forKey: "__CFBundleIdentifier")
        for (key, value) in options.environmentOverrides {
            environment[key] = value
        }
        process.environment = environment

        fileManager.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = handle
            process.standardError = handle
        }

        do {
            try process.run()
        } catch {
            return .failure(
                reportURL: reportURL,
                logURL: logURL,
                detail: "Failed to launch packaged app: \(error.localizedDescription)",
                homeURL: workspace.homeURL,
                containerURL: options.containerURL ?? workspace.containerURL
            )
        }

        defer {
            terminate(process: process)
        }

        guard waitForFile(at: reportURL, process: process) else {
            let detail = process.isRunning
                ? "Timed out waiting for the first-run reliability report."
                : "App exited before writing the first-run reliability report."
            return .failure(
                reportURL: reportURL,
                logURL: logURL,
                detail: detail,
                homeURL: workspace.homeURL,
                containerURL: options.containerURL ?? workspace.containerURL
            )
        }

        guard let data = try? Data(contentsOf: reportURL) else {
            return .failure(
                reportURL: reportURL,
                logURL: logURL,
                detail: "First-run reliability report was written but not readable.",
                homeURL: workspace.homeURL,
                containerURL: options.containerURL ?? workspace.containerURL
            )
        }

        do {
            let report = try JSONDecoder().decode(FirstRunReliabilityAppReport.self, from: data)
            waitForProcessExit(process)
            return .success(
                report: report,
                reportURL: reportURL,
                logURL: logURL,
                homeURL: workspace.homeURL,
                containerURL: options.containerURL ?? workspace.containerURL
            )
        } catch {
            return .failure(
                reportURL: reportURL,
                logURL: logURL,
                detail: "First-run reliability report could not be decoded: \(error.localizedDescription)",
                homeURL: workspace.homeURL,
                containerURL: options.containerURL ?? workspace.containerURL
            )
        }
    }

    private func buildScenario(
        id: String,
        launches: [FirstRunReliabilityLaunchOutcome],
        successDetail: String,
        evaluate: ([FirstRunReliabilityAppReport]) -> [String]
    ) -> FirstRunReliabilityScenario {
        let reports = launches.compactMap(\.report)
        let launchFailures = launches.compactMap(\.failureDetail)
        let evaluationFailures = launchFailures.isEmpty ? evaluate(reports) : []
        let failures = launchFailures + evaluationFailures
        let detail = failures.isEmpty ? successDetail : failures.joined(separator: "; ")

        return FirstRunReliabilityScenario(
            id: id,
            status: failures.isEmpty ? .pass : .fail,
            detail: detail,
            reportPaths: launches.map(\.reportURL.path),
            logPaths: launches.map(\.logURL.path),
            isolatedHomePaths: Array(Set(launches.map(\.homeURL.path))).sorted(),
            containerPaths: Array(Set(launches.map(\.containerURL.path))).sorted(),
            launches: reports
        )
    }

    private func isolationFailures(
        in report: FirstRunReliabilityAppReport,
        workspace: FirstRunScenarioWorkspace,
        expectedContainerURL: URL? = nil
    ) -> [String] {
        let expectedContainer = (expectedContainerURL ?? workspace.containerURL).standardizedFileURL
        var failures: [String] = []
        failures.append(contentsOf: expectedBooleanFailures(
            report.appLaunched && report.statusItemExists && report.popoverConfigured,
            message: "packaged app should launch far enough to configure the status item and popover"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.runtime.homePath == workspace.homeURL.path,
            message: "report home path should stay inside the isolated HOME"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.runtime.containerPath == expectedContainer.path,
            message: "report container path should match the isolated Transcripted container"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.runtime.appSupportPath == expectedContainer.path,
            message: "app support root should resolve to the isolated Transcripted container"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.runtime.captureLibraryPath.hasPrefix(expectedContainer.path + "/")
                && report.runtime.cachePath.hasPrefix(expectedContainer.path + "/")
                && report.runtime.logsPath.hasPrefix(expectedContainer.path + "/")
                && report.runtime.temporaryPath.hasPrefix(expectedContainer.path + "/")
                && report.runtime.mcpManifestPath.hasPrefix(expectedContainer.path + "/"),
            message: "capture, cache, logs, tmp, and MCP manifest paths should stay inside the isolated container"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.helper.configPath.hasPrefix(workspace.homeURL.path + "/"),
            message: "Claude helper config path should stay inside the isolated HOME"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.helper.installedBinaryPath.hasPrefix(expectedContainer.path + "/"),
            message: "installed helper path should stay inside the isolated Transcripted container"
        ))
        return failures
    }

    private func helperInstalledFailures(_ report: FirstRunReliabilityAppReport) -> [String] {
        var failures: [String] = []
        failures.append(contentsOf: expectedBooleanFailures(
            report.helper.error == nil,
            message: "helper action should finish without an error"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.helper.bundledBinaryExists,
            message: "packaged app should include the bundled MCP helper"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.helper.installedBinaryExistsAfter,
            message: "helper action should leave an installed helper binary"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.helper.installedBinaryMatchesBundledAfter,
            message: "installed helper should match the bundled helper after the action"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.helper.stateAfter == "installed",
            message: "helper action should leave the helper in installed state"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.helper.configuredCommandPathAfter == report.helper.installedBinaryPath,
            message: "Claude config should point at the installed helper path"
        ))
        failures.append(contentsOf: expectedBooleanFailures(
            report.helper.configIsReadableAfter,
            message: "Claude config should be readable after the helper action"
        ))
        return failures
    }

    private func expectedBooleanFailures(_ condition: Bool, message: String) -> [String] {
        condition ? [] : [message]
    }

    private func resolvedEvidenceRoot() -> URL {
        if let reportPath, !reportPath.isEmpty {
            return URL(fileURLWithPath: reportPath)
                .deletingLastPathComponent()
                .appendingPathComponent("packaged-app-first-run-reliability-\(runID)", isDirectory: true)
        }
        return fileManager.temporaryDirectory
            .appendingPathComponent("transcripted-first-run-reliability-\(runID)", isDirectory: true)
    }

    private func makeWorkspace(id: String, evidenceRoot: URL) -> FirstRunScenarioWorkspace {
        let rootURL = evidenceRoot.appendingPathComponent(id, isDirectory: true)
        return FirstRunScenarioWorkspace(
            rootURL: rootURL,
            homeURL: rootURL.appendingPathComponent("home", isDirectory: true),
            containerURL: rootURL.appendingPathComponent("container", isDirectory: true),
            reportsDirectoryURL: rootURL.appendingPathComponent("reports", isDirectory: true),
            logsDirectoryURL: rootURL.appendingPathComponent("logs", isDirectory: true)
        )
    }

    private func defaultPreferences(
        onboardingCompleted: Bool,
        forceOnboarding: Bool,
        overrides: [String: Any]
    ) -> [String: Any] {
        var values: [String: Any] = [
            "permissionsOnboardingCompleted": onboardingCompleted,
            "forcePermissionsOnboarding": forceOnboarding,
            "observability-anonymous-analytics-enabled": false,
            "observability-crash-reporting-enabled": false,
        ]
        for (key, value) in overrides {
            values[key] = value
        }
        return values
    }

    private func writePreferences(home: URL, values: [String: Any]) throws {
        let preferencesDirectory = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        try fileManager.createDirectory(at: preferencesDirectory, withIntermediateDirectories: true)
        let preferencesURL = preferencesDirectory.appendingPathComponent("com.justinbetker.draft.plist", isDirectory: false)
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try data.write(to: preferencesURL, options: .atomic)
    }

    private func seedStaleModelCache(in home: URL) {
        let stale = home
            .appendingPathComponent("Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml/Encoder.mlmodelc", isDirectory: true)
            .appendingPathComponent("coremldata.bin", isDirectory: false)
        try? writeFixtureFile(at: stale, contents: "stale")
    }

    private func seedActiveModelCache(in home: URL) {
        let activeRoot = home
            .appendingPathComponent("Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3", isDirectory: true)
        for directory in ["Encoder.mlmodelc", "JointDecisionv3.mlmodelc", "Decoder.mlmodelc", "Preprocessor.mlmodelc"] {
            let url = activeRoot.appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent("coremldata.bin", isDirectory: false)
            try? writeFixtureFile(at: url, contents: directory)
        }
        for filename in ["config.json", "parakeet_v3_vocab.json", "parakeet_vocab.json"] {
            try? writeFixtureFile(
                at: activeRoot.appendingPathComponent(filename, isDirectory: false),
                contents: filename
            )
        }
    }

    private func seedMalformedClaudeConfig(in home: URL) {
        let configURL = home
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json", isDirectory: false)
        try? writeFixtureFile(at: configURL, contents: "{ this is not valid json")
    }

    private func seedInstalledHelperStub(at url: URL) {
        try? writeFixtureFile(at: url, contents: "#!/bin/sh\necho stale helper\n", makeExecutable: true)
    }

    private func writeFixtureFile(
        at url: URL,
        contents: String,
        makeExecutable: Bool = false
    ) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if makeExecutable {
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    private func waitForFile(at url: URL, process: Process) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fileManager.fileExists(atPath: url.path) {
                return true
            }
            if !process.isRunning {
                return fileManager.fileExists(atPath: url.path)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return fileManager.fileExists(atPath: url.path)
    }

    private func waitForProcessExit(_ process: Process) {
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func terminate(process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        waitForProcessExit(process)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            waitForProcessExit(process)
        }
    }

    private func userDefaultsArgumentValue(_ value: Any?) -> String? {
        switch value {
        case let value as Bool:
            return value ? "YES" : "NO"
        case let value as Int:
            return String(value)
        case let value as Double:
            return String(value)
        case let value as String:
            return value
        default:
            return nil
        }
    }
}

private struct FirstRunScenarioWorkspace {
    let rootURL: URL
    let homeURL: URL
    let containerURL: URL
    let reportsDirectoryURL: URL
    let logsDirectoryURL: URL
}

private struct FirstRunLaunchOptions {
    let onboardingCompleted: Bool
    let forceOnboarding: Bool
    var preferenceOverrides: [String: Any] = [:]
    var launchDefaultsOverrides: [String: Any] = [:]
    var environmentOverrides: [String: String] = [:]
    var containerURL: URL? = nil
}

private struct FirstRunReliabilityLaunchOutcome {
    let report: FirstRunReliabilityAppReport?
    let reportURL: URL
    let logURL: URL
    let failureDetail: String?
    let homeURL: URL
    let containerURL: URL

    static func success(
        report: FirstRunReliabilityAppReport,
        reportURL: URL,
        logURL: URL,
        homeURL: URL,
        containerURL: URL
    ) -> Self {
        Self(
            report: report,
            reportURL: reportURL,
            logURL: logURL,
            failureDetail: nil,
            homeURL: homeURL,
            containerURL: containerURL
        )
    }

    static func failure(
        reportURL: URL,
        logURL: URL,
        detail: String,
        homeURL: URL,
        containerURL: URL
    ) -> Self {
        Self(
            report: nil,
            reportURL: reportURL,
            logURL: logURL,
            failureDetail: detail,
            homeURL: homeURL,
            containerURL: containerURL
        )
    }
}

struct FirstRunReliabilitySmokeReport: Codable, Equatable {
    struct Summary: Codable, Equatable {
        let passed: Int
        let failed: Int
        let warnings: Int
    }

    let runID: String
    let generatedAt: String
    let appBundlePath: String
    let evidenceRootPath: String
    let reportPath: String?
    let scenarios: [FirstRunReliabilityScenario]

    var summary: Summary {
        Summary(
            passed: scenarios.filter { $0.status == .pass }.count,
            failed: scenarios.filter { $0.status == .fail }.count,
            warnings: scenarios.filter { $0.status == .warn }.count
        )
    }

    var status: ValidationStatus {
        if summary.failed > 0 { return .fail }
        if summary.warnings > 0 { return .warn }
        return .pass
    }

    var privacySweepPaths: [String] {
        scenarios
            .flatMap { $0.reportPaths + $0.logPaths }
            .sorted()
    }

    func writeIfRequested() throws {
        guard let reportPath, !reportPath.isEmpty else { return }
        let url = URL(fileURLWithPath: reportPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

struct FirstRunReliabilityScenario: Codable, Equatable {
    let id: String
    let status: ValidationStatus
    let detail: String
    let reportPaths: [String]
    let logPaths: [String]
    let isolatedHomePaths: [String]
    let containerPaths: [String]
    let launches: [FirstRunReliabilityAppReport]

    var primaryEvidencePath: String? {
        reportPaths.first ?? logPaths.first
    }
}

struct FirstRunReliabilityAppReport: Codable, Equatable {
    let appLaunched: Bool
    let statusItemExists: Bool
    let popoverConfigured: Bool
    let permissionsOnboardingCompleted: Bool
    let selectedModel: String
    let actualModelState: String
    let cachedModelDirectory: String?
    let launchToInteractiveMs: Double?
    let menuContent: FirstRunReliabilityMenuContentSnapshot
    let runtime: FirstRunReliabilityRuntimeState
    let helper: FirstRunReliabilityHelperState
    let syntheticModel: FirstRunReliabilitySyntheticModelState?
}

struct FirstRunReliabilityMenuContentSnapshot: Codable, Equatable {
    let header: FirstRunReliabilityMenuHeaderSnapshot
    let updateCallout: FirstRunReliabilityActionRowSnapshot
    let primaryActions: [String: FirstRunReliabilityActionRowSnapshot]
    let utilityActions: [String: FirstRunReliabilityActionRowSnapshot]
}

struct FirstRunReliabilityMenuHeaderSnapshot: Codable, Equatable {
    let statusText: String
    let detailText: String
    let warningText: String
    let isReady: Bool
}

struct FirstRunReliabilityActionRowSnapshot: Codable, Equatable {
    let title: String
    let detail: String
    let trailingText: String
    let automationIdentifier: String
    let isVisible: Bool
    let isEnabled: Bool
}

struct FirstRunReliabilityRuntimeState: Codable, Equatable {
    let homePath: String
    let containerPath: String?
    let appSupportPath: String
    let captureLibraryPath: String
    let meetingsPath: String
    let dictationsPath: String
    let cachePath: String
    let logsPath: String
    let temporaryPath: String
    let mcpManifestPath: String
    let mcpManifestExists: Bool
    let systemAudioPermissionKnown: Bool
    let systemAudioPermissionGranted: Bool
    let appSupportWritable: Bool
    let captureLibraryWritable: Bool
    let cacheWritable: Bool
}

struct FirstRunReliabilityHelperState: Codable, Equatable {
    let action: String
    let backupPath: String?
    let bundledBinaryExists: Bool
    let bundledBinaryPath: String?
    let configuredCommandPathAfter: String?
    let configuredCommandPathBefore: String?
    let configIsReadableAfter: Bool
    let configIsReadableBefore: Bool
    let configPath: String
    let error: String?
    let installedBinaryExistsAfter: Bool
    let installedBinaryExistsBefore: Bool
    let installedBinaryMatchesBundledAfter: Bool
    let installedBinaryMatchesBundledBefore: Bool
    let installedBinaryPath: String
    let refreshed: Bool?
    let selfTestDictationFileCount: Int?
    let selfTestMeetingFileCount: Int?
    let selfTestOK: Bool?
    let stateAfter: String
    let stateBefore: String
}

struct FirstRunReliabilitySyntheticModelState: Codable, Equatable {
    let requestedState: String
    let action: FirstRunReliabilitySyntheticActionState
    let card: FirstRunReliabilitySyntheticCardState
}

struct FirstRunReliabilitySyntheticActionState: Codable, Equatable {
    let isEnabled: Bool
    let subtitle: String
    let symbolName: String
    let title: String
}

struct FirstRunReliabilitySyntheticCardState: Codable, Equatable {
    let detail: String
    let progress: Double?
    let status: String
    let title: String
    let tone: String
}

protocol PackagedAppSmokeCommandRunning {
    func run(_ executable: String, _ arguments: [String]) -> PackagedAppSmokeCommandResult
}

struct PackagedAppSmokeCommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var combinedOutput: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

struct ProcessPackagedAppSmokeCommandRunner: PackagedAppSmokeCommandRunning {
    func run(_ executable: String, _ arguments: [String]) -> PackagedAppSmokeCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return PackagedAppSmokeCommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
        } catch {
            return PackagedAppSmokeCommandResult(exitCode: 127, stdout: "", stderr: error.localizedDescription)
        }
    }
}

enum PrivacyLogScanner {
    private static let sensitiveKeys = Set([
        "transcript",
        "transcript_text",
        "raw_transcript",
        "audio_path",
        "audio_url",
        "meeting_title",
        "speaker_name",
        "speaker_names",
        "email",
        "token",
        "authorization",
        "password",
        "secret",
        "url",
        "file_path",
        "absolute_path",
        "device_name",
        "source_app",
    ])

    static func findings(in content: String, allowedPathPrefixes: [String] = []) -> [String] {
        var findings: [String] = []
        let normalizedAllowedPathPrefixes = normalizeAllowedPathPrefixes(allowedPathPrefixes)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        for (index, lineSlice) in lines.enumerated() {
            let line = String(lineSlice)
            if let jsonFinding = jsonFinding(
                in: line,
                lineNumber: index + 1,
                allowedPathPrefixes: normalizedAllowedPathPrefixes
            ) {
                findings.append(jsonFinding)
                continue
            }
            if containsEmail(line) {
                findings.append("line \(index + 1) contains an email-like value")
            }
            if containsTokenAssignment(line) {
                findings.append("line \(index + 1) contains a token/secret-looking assignment")
            }
            if containsDisallowedLocalPath(line, allowedPathPrefixes: normalizedAllowedPathPrefixes) {
                findings.append("line \(index + 1) contains an absolute local path")
            }
        }
        return findings
    }

    private static func jsonFinding(
        in line: String,
        lineNumber: Int,
        allowedPathPrefixes: [String]
    ) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if let key = firstSensitiveKey(in: object) {
            return "line \(lineNumber) contains sensitive key \(key)"
        }
        if containsSensitiveValue(in: object, allowedPathPrefixes: allowedPathPrefixes) {
            return "line \(lineNumber) contains an email, URL, or absolute local path"
        }
        return nil
    }

    private static func firstSensitiveKey(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if sensitiveKeys.contains(normalized(key)) {
                    return key
                }
                if let nested = firstSensitiveKey(in: value) {
                    return nested
                }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let nested = firstSensitiveKey(in: value) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func containsSensitiveValue(
        in object: Any,
        allowedPathPrefixes: [String]
    ) -> Bool {
        if let string = object as? String {
            return containsEmail(string) || containsDisallowedLocalPath(string, allowedPathPrefixes: allowedPathPrefixes)
        }
        if let dictionary = object as? [String: Any] {
            return dictionary.values.contains { containsSensitiveValue(in: $0, allowedPathPrefixes: allowedPathPrefixes) }
        }
        if let array = object as? [Any] {
            return array.contains { containsSensitiveValue(in: $0, allowedPathPrefixes: allowedPathPrefixes) }
        }
        return false
    }

    private static func normalizeAllowedPathPrefixes(_ prefixes: [String]) -> [String] {
        Array(
            Set(
                prefixes
                    .filter { !$0.isEmpty }
                    .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            )
        ).sorted()
    }

    private static func containsDisallowedLocalPath(
        _ value: String,
        allowedPathPrefixes: [String]
    ) -> Bool {
        let pattern = #"(file://[^\s`"']+|/(?:Users|Volumes|private|tmp)/[^\s`"']+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value.contains("/Users/") || value.contains("file://")
        }

        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        for match in regex.matches(in: value, range: fullRange) {
            guard let range = Range(match.range, in: value) else { continue }
            let normalized = normalizedLocalPath(String(value[range]))
            if isAllowedLocalPath(normalized, allowedPathPrefixes: allowedPathPrefixes) {
                continue
            }
            return true
        }
        return false
    }

    private static func normalizedLocalPath(_ candidate: String) -> String {
        let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ",;:.)]"))
        if trimmed.hasPrefix("file://"),
           let url = URL(string: trimmed),
           url.isFileURL {
            return url.standardizedFileURL.path
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private static func isAllowedLocalPath(
        _ path: String,
        allowedPathPrefixes: [String]
    ) -> Bool {
        allowedPathPrefixes.contains { prefix in
            path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }

    private static func containsEmail(_ value: String) -> Bool {
        value.range(of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func containsTokenAssignment(_ value: String) -> Bool {
        value.range(of: #"(?i)(token|api[_-]?key|authorization|bearer|secret|password)\s*[:=]"#, options: .regularExpression) != nil
    }
}

private func stringValue(_ value: Any?) -> String? {
    value as? String
}

private func boolValue(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    return nil
}

private func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
}

private func plistValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
    switch (lhs, rhs) {
    case let (left as String, right as String):
        return left == right
    case let (left as Bool, right as Bool):
        return left == right
    case let (left as NSNumber, right as NSNumber):
        return left == right
    case (nil, nil):
        return true
    default:
        return false
    }
}

private extension String {
    var trimmedForReport: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 240 {
            return trimmed.isEmpty ? "no output" : trimmed
        }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 240)
        return String(trimmed[..<end]) + "..."
    }
}

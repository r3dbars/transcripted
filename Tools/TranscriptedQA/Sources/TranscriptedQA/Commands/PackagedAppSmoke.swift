import ArgumentParser
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

    @Option(name: .long, help: "Seconds to wait for each UI smoke surface.")
    var uiTimeout: Double = 12

    @Flag(name: .long, help: "Warn instead of fail when the dSYM is missing or unverifiable.")
    var allowMissingDSYM = false

    @Flag(name: .long, help: "Warn instead of fail when the DMG is missing or unreadable.")
    var allowMissingDMG = false

    @Flag(name: .long, help: "Launch the built app and validate the menu bar through Accessibility.")
    var runUISmoke = false

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
            uiTimeout: uiTimeout,
            requireDSYM: !allowMissingDSYM,
            requireDMG: !allowMissingDMG,
            runUISmoke: runUISmoke,
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
    private let uiTimeout: Double
    private let requireDSYM: Bool
    private let requireDMG: Bool
    private let runUISmoke: Bool
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
        uiTimeout: Double,
        requireDSYM: Bool,
        requireDMG: Bool,
        runUISmoke: Bool,
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
        self.uiTimeout = uiTimeout
        self.requireDSYM = requireDSYM
        self.requireDMG = requireDMG
        self.runUISmoke = runUISmoke
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

        guard fileManager.fileExists(atPath: appBundleURL.path) else {
            checks.append(.fail("app-bundle", target: appBundleURL.path, detail: "Run SKIP_NOTARIZATION=1 bash build-beta.sh '' <user-name> first, or pass --app."))
            return buildReport(checks: checks, dmgPath: nil, logPaths: scannedLogPaths, uiEvidencePath: uiEvidencePath, generatedAt: generatedAt)
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
            return buildReport(checks: checksAfterTail(checks, scannedLogPaths: &scannedLogPaths, uiEvidencePath: &uiEvidencePath, executableURL: executableURL), dmgPath: dmgURL.path, logPaths: scannedLogPaths, uiEvidencePath: uiEvidencePath, generatedAt: generatedAt)
        } else {
            checks.append(.fail("version-config", target: builtInfoURL.path, detail: "Cannot validate version/Sparkle config until both source and built Info.plist files are readable."))
            let dmgURL = resolvedDMGURL(version: "unknown")
            checks.append(validateDMG(at: dmgURL))
            return buildReport(checks: checksAfterTail(checks, scannedLogPaths: &scannedLogPaths, uiEvidencePath: &uiEvidencePath, executableURL: executableURL), dmgPath: dmgURL.path, logPaths: scannedLogPaths, uiEvidencePath: uiEvidencePath, generatedAt: generatedAt)
        }
    }

    private func checksAfterTail(
        _ initialChecks: [PackagedAppSmokeCheck],
        scannedLogPaths: inout [String],
        uiEvidencePath: inout String?,
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

        checks.append(contentsOf: validateLogPrivacy(paths: scannedLogPaths))
        checks.append(validateAppcastFile())

        return checks
    }

    private func buildReport(
        checks: [PackagedAppSmokeCheck],
        dmgPath: String?,
        logPaths: [String],
        uiEvidencePath: String?,
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
            return .pass("ui-smoke", target: appBundleURL.path, detail: "App launched, menu bar appeared, and core menu/settings controls were visible.")
        case .incomplete:
            return .warn("ui-smoke", target: appBundleURL.path, detail: firstFlagDetail(in: report) ?? "UI smoke was incomplete.")
        case .fail:
            return .fail("ui-smoke", target: appBundleURL.path, detail: firstFlagDetail(in: report) ?? "UI smoke failed.")
        }
    }

    private func validateLogPrivacy(paths: [String]) -> [PackagedAppSmokeCheck] {
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
                let findings = PrivacyLogScanner.findings(in: content)
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

    static func findings(in content: String) -> [String] {
        var findings: [String] = []
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        for (index, lineSlice) in lines.enumerated() {
            let line = String(lineSlice)
            if let jsonFinding = jsonFinding(in: line, lineNumber: index + 1) {
                findings.append(jsonFinding)
                continue
            }
            if containsEmail(line) {
                findings.append("line \(index + 1) contains an email-like value")
            }
            if containsTokenAssignment(line) {
                findings.append("line \(index + 1) contains a token/secret-looking assignment")
            }
            if line.contains("/Users/") || line.contains("file://") {
                findings.append("line \(index + 1) contains an absolute local path")
            }
        }
        return findings
    }

    private static func jsonFinding(in line: String, lineNumber: Int) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if let key = firstSensitiveKey(in: object) {
            return "line \(lineNumber) contains sensitive key \(key)"
        }
        if containsSensitiveValue(in: object) {
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

    private static func containsSensitiveValue(in object: Any) -> Bool {
        if let string = object as? String {
            return containsEmail(string) || string.contains("/Users/") || string.contains("file://")
        }
        if let dictionary = object as? [String: Any] {
            return dictionary.values.contains(where: containsSensitiveValue)
        }
        if let array = object as? [Any] {
            return array.contains(where: containsSensitiveValue)
        }
        return false
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

import Foundation

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
        checks.append(contentsOf: validateBundledLlamaServer())
        checks.append(contentsOf: validateBundledKeyboard())
        checks.append(contentsOf: validateBundledCLI())
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

    /// Writing's inference helper, pinned by build-deps.sh from Tilde 0.1.0 beta 1
    /// and re-signed by the build. Never launched here: it would start a server.
    private func validateBundledLlamaServer() -> [PackagedAppSmokeCheck] {
        let relativePath = "Contents/Helpers/llama-server"
        let helperCheck = validateBundledHelper(relativePath: relativePath, check: "llama-server-helper")
        guard helperCheck.status == .pass else {
            return [helperCheck]
        }
        guard verifyCodeSignature else {
            return [helperCheck, .warn("llama-server-signature", target: relativePath, detail: "Code signature verification was skipped by request.")]
        }
        let url = appBundleURL.appendingPathComponent(relativePath, isDirectory: false)
        let result = commandRunner.run("/usr/bin/codesign", ["--verify", "--strict", url.path])
        if result.exitCode == 0 {
            return [helperCheck, .pass("llama-server-signature", target: relativePath, detail: "codesign --verify --strict passed for the bundled llama-server.")]
        }
        return [helperCheck, .fail("llama-server-signature", target: relativePath, detail: result.combinedOutput.trimmedForReport)]
    }

    /// Writing's IMKit keyboard, built by bundle-input-method.sh into
    /// Contents/Library/Input Methods. Never launched here: macOS starts input
    /// methods itself once they are installed and selected.
    private func validateBundledKeyboard() -> [PackagedAppSmokeCheck] {
        let relativePath = "Contents/Library/Input Methods/Transcripted Keyboard.app"
        let executablePath = relativePath + "/Contents/MacOS/TranscriptedKeyboard"
        let executable = appBundleURL.appendingPathComponent(executablePath, isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return [.fail("keyboard-bundle", target: relativePath, detail: "The Writing keyboard bundle or its executable is missing.")]
        }
        let bundleCheck = PackagedAppSmokeCheck.pass("keyboard-bundle", target: relativePath, detail: "Writing keyboard bundle exists and its executable is present.")
        guard verifyCodeSignature else {
            return [bundleCheck, .warn("keyboard-signature", target: relativePath, detail: "Code signature verification was skipped by request.")]
        }
        let url = appBundleURL.appendingPathComponent(relativePath, isDirectory: true)
        let result = commandRunner.run("/usr/bin/codesign", ["--verify", "--strict", url.path])
        if result.exitCode == 0 {
            return [bundleCheck, .pass("keyboard-signature", target: relativePath, detail: "codesign --verify --strict passed for the Writing keyboard.")]
        }
        return [bundleCheck, .fail("keyboard-signature", target: relativePath, detail: result.combinedOutput.trimmedForReport)]
    }

    /// The build scripts run `build-info` before signing. This is the only check
    /// that launches the CLI as it ships: signed, hardened, and loading its
    /// frameworks from this bundle under library validation.
    private func validateBundledCLI() -> [PackagedAppSmokeCheck] {
        let relativePath = "Contents/Helpers/transcripted-cli"
        let helperCheck = validateBundledHelper(relativePath: relativePath, check: "cli-helper")
        guard helperCheck.status == .pass else {
            return [helperCheck]
        }
        let url = appBundleURL.appendingPathComponent(relativePath, isDirectory: false)
        let result = commandRunner.run(url.path, ["build-info"])
        guard result.exitCode == 0 else {
            let output = result.combinedOutput.trimmedForReport
            return [helperCheck, .fail(
                "cli-launch",
                target: relativePath,
                detail: "transcripted-cli build-info exited \(result.exitCode)" + (output.isEmpty ? "." : ": \(output)")
            )]
        }
        // The runner merges stderr into stdout, so read the JSON line only.
        let jsonLine = result.combinedOutput
            .split(whereSeparator: \.isNewline)
            .last(where: { $0.hasPrefix("{") })
        guard let jsonLine,
              let info = try? JSONSerialization.jsonObject(with: Data(jsonLine.utf8)) as? [String: Any] else {
            return [helperCheck, .fail(
                "cli-launch",
                target: relativePath,
                detail: "transcripted-cli build-info did not print capabilities JSON: \(result.combinedOutput.trimmedForReport)"
            )]
        }
        let isFullPipeline = stringValue(info["mode"]) == "meeting"
            && boolValue(info["transcription"]) == true
            && boolValue(info["diarization"]) == true
            && boolValue(info["meetingImport"]) == true
        guard isFullPipeline else {
            return [helperCheck, .fail(
                "cli-launch",
                target: relativePath,
                detail: "transcripted-cli launched but lacks the full meeting pipeline: \(jsonLine)"
            )]
        }
        return [helperCheck, .pass("cli-launch", target: relativePath, detail: "Signed transcripted-cli launched and reported the full meeting pipeline.")]
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
            return .pass("ui-smoke", target: appBundleURL.path, detail: "App launched, menu bar appeared, audit rows 25/27/29/31 passed, and core menu/settings controls were visible.")
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

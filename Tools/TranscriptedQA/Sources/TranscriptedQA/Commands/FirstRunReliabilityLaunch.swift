import Foundation

extension FirstRunReliabilitySmokeRunner {
    func launch(
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

        // CFPreferences uses the real macOS account, not the temporary HOME.
        // The native-smoke guard above ensures this is a test account or hosted
        // runner. Seed typed values in that account's app domain, then restore
        // only the keys this scenario changed after the app exits.
        let appID = "com.justinbetker.draft"
        let accountDefaults = options.accountPreferenceOverrides.isEmpty
            ? nil : UserDefaults(suiteName: appID)
        if !options.accountPreferenceOverrides.isEmpty && accountDefaults == nil {
            return .failure(
                reportURL: reportURL,
                logURL: logURL,
                detail: "Could not open the test account's Transcripted preferences domain.",
                homeURL: workspace.homeURL,
                containerURL: options.containerURL ?? workspace.containerURL
            )
        }
        let previousAccountDomain = accountDefaults?.persistentDomain(forName: appID) ?? [:]
        if let accountDefaults {
            var current = previousAccountDomain
            for (key, value) in options.accountPreferenceOverrides {
                current[key] = value
            }
            accountDefaults.setPersistentDomain(current, forName: appID)
            accountDefaults.synchronize()
        }
        defer {
            if let accountDefaults {
                var current = accountDefaults.persistentDomain(forName: appID) ?? [:]
                for key in options.accountPreferenceOverrides.keys {
                    if let previous = previousAccountDomain[key] {
                        current[key] = previous
                    } else {
                        current.removeValue(forKey: key)
                    }
                }
                accountDefaults.setPersistentDomain(current, forName: appID)
                accountDefaults.synchronize()
            }
        }

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
        applyIsolatedLaunchEnvironment(&environment, isolatedHome: workspace.homeURL)
        environment["TRANSCRIPTED_CONTAINER_DIR"] = (options.containerURL ?? workspace.containerURL).path
        environment["TRANSCRIPTED_FIRST_RUN_RELIABILITY_REPORT"] = reportURL.path
        environment["TRANSCRIPTED_FIRST_RUN_RELIABILITY_TERMINATE_AFTER_REPORT"] = "1"
        environment["TRANSCRIPTED_FIRST_RUN_RELIABILITY_TERMINATE_DELAY_SECONDS"] = "0.1"
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
            terminateProcess(process, gracePeriod: 2, pollInterval: 0.05)
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

    func seedStaleModelCache(in home: URL) {
        let stale = home
            .appendingPathComponent("Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml/Encoder.mlmodelc", isDirectory: true)
            .appendingPathComponent("coremldata.bin", isDirectory: false)
        try? writeFixtureFile(at: stale, contents: "stale")
    }

    func seedActiveModelCache(in home: URL) {
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

    func seedMalformedClaudeConfig(in home: URL) {
        let configURL = home
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json", isDirectory: false)
        try? writeFixtureFile(at: configURL, contents: "{ this is not valid json")
    }

    func seedInstalledHelperStub(at url: URL) {
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

struct FirstRunScenarioWorkspace {
    let rootURL: URL
    let homeURL: URL
    let containerURL: URL
    let reportsDirectoryURL: URL
    let logsDirectoryURL: URL
}

struct FirstRunLaunchOptions {
    let onboardingCompleted: Bool
    let forceOnboarding: Bool
    var preferenceOverrides: [String: Any] = [:]
    var accountPreferenceOverrides: [String: Any] = [:]
    var launchDefaultsOverrides: [String: Any] = [:]
    var environmentOverrides: [String: String] = [:]
    var containerURL: URL? = nil
}

struct FirstRunReliabilityLaunchOutcome {
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

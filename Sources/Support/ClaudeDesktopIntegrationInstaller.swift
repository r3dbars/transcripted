import Foundation

struct ClaudeDesktopIntegrationStatus: Equatable {
    enum State: Equatable {
        case notInstalled
        case installed
        case needsRepair
    }

    let state: State
    let configURL: URL
    let installedBinaryURL: URL
    let bundledBinaryURL: URL?
    let configuredCommandPath: String?
    let installedBinaryExists: Bool
    let bundledBinaryExists: Bool
    let installedBinaryMatchesBundled: Bool
    let configExists: Bool
    let configIsReadable: Bool
    let claudeDesktopLikelyInstalled: Bool

    var isInstalled: Bool {
        state == .installed
    }

    var attentionMessage: String? {
        if !bundledBinaryExists {
            return "This app build does not include Transcripted direct tools yet."
        }

        if !configIsReadable {
            return "Claude Desktop config is not readable JSON. Install will back it up and write a clean config."
        }

        guard state == .needsRepair else {
            return nil
        }

        if !installedBinaryExists {
            return "Claude Desktop direct tools are missing. Install will copy a fresh helper."
        }

        if !installedBinaryMatchesBundled {
            return "Claude Desktop is using an older Transcripted helper. Update now to replace it."
        }

        return "Claude Desktop points at another Transcripted helper. Repair will update the config."
    }
}

struct ClaudeDesktopIntegrationInstallResult: Equatable {
    let configURL: URL
    let installedBinaryURL: URL
    let backupURL: URL?
    let selfTest: TranscriptedMCPSelfTest
}

struct TranscriptedMCPSelfTest: Codable, Equatable {
    let ok: Bool
    let meetingsDirectory: String
    let dictationsDirectory: String
    let indexDirectory: String
    let meetingFileCount: Int
    let dictationFileCount: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case meetingsDirectory = "meetings_directory"
        case dictationsDirectory = "dictations_directory"
        case indexDirectory = "index_directory"
        case meetingFileCount = "meeting_file_count"
        case dictationFileCount = "dictation_file_count"
    }
}

enum ClaudeDesktopIntegrationError: LocalizedError, Equatable {
    case bundledBinaryMissing(URL?)
    case installedBinaryNotExecutable(URL)
    case selfTestFailed(status: Int32, output: String)
    case selfTestReportedUnhealthy(output: String)
    case selfTestOutputUnreadable(String)
    case selfTestTimedOut

    var errorDescription: String? {
        switch self {
        case .bundledBinaryMissing(let url):
            if let url {
                return "Transcripted direct tools are missing from this app build at \(url.path)."
            }
            return "Transcripted direct tools are missing from this app build."
        case .installedBinaryNotExecutable(let url):
            return "Transcripted direct tools were installed, but the file is not executable at \(url.path)."
        case .selfTestFailed(_, let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "Transcripted direct tools did not pass the local check."
                : trimmed
        case .selfTestReportedUnhealthy:
            return "Transcripted direct tools did not pass the local check."
        case .selfTestOutputUnreadable:
            return "Transcripted direct tools ran, but the health check output could not be read."
        case .selfTestTimedOut:
            return "Transcripted direct tools did not respond to the local check. Try connecting again."
        }
    }
}

enum ClaudeDesktopIntegrationInstaller {
    static let serverName = "transcripted"
    static let helperBinaryName = "transcripted-mcp"
    static let mcpObservabilityConfigFileName = "mcp-observability.plist"
    static let appVersionInfoKey = "CFBundleShortVersionString"

    static var installedMCPBinaryURL: URL {
        FileManager.default.transcriptedAppSupportDir
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent(helperBinaryName, isDirectory: false)
    }

    static var mcpObservabilityConfigURL: URL {
        FileManager.default.transcriptedAppSupportDir
            .appendingPathComponent(mcpObservabilityConfigFileName, isDirectory: false)
    }

    static var claudeDesktopConfigURL: URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
    }

    static func bundledMCPBinaryURL(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        let helperURL = bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(helperBinaryName, isDirectory: false)

        if fileManager.isExecutableFile(atPath: helperURL.path) {
            return helperURL
        }

        return nil
    }

    static func currentStatus(
        configURL: URL = claudeDesktopConfigURL,
        installedBinaryURL: URL = installedMCPBinaryURL,
        bundledBinaryURL: URL? = bundledMCPBinaryURL(),
        fileManager: FileManager = .default
    ) -> ClaudeDesktopIntegrationStatus {
        let configExists = fileManager.fileExists(atPath: configURL.path)
        let installedBinaryExists = fileManager.isExecutableFile(atPath: installedBinaryURL.path)
        let bundledBinaryExists = bundledBinaryURL.map { fileManager.isExecutableFile(atPath: $0.path) } ?? false
        let configRead = readClaudeDesktopConfig(at: configURL, fileManager: fileManager)
        let configuredCommandPath = configRead.config.flatMap(transcriptedCommandPath(in:))
        let configIsReadable = !configExists || configRead.config != nil
        let isConfiguredForInstalledBinary = configuredCommandPath == installedBinaryURL.path
        let installedBinaryMatchesBundled = installedBinaryMatchesBundled(
            installedBinaryURL: installedBinaryURL,
            bundledBinaryURL: bundledBinaryURL,
            installedBinaryExists: installedBinaryExists,
            bundledBinaryExists: bundledBinaryExists,
            fileManager: fileManager
        )

        let state: ClaudeDesktopIntegrationStatus.State
        if installedBinaryExists && isConfiguredForInstalledBinary && installedBinaryMatchesBundled {
            state = .installed
        } else if !configExists && !installedBinaryExists {
            state = .notInstalled
        } else {
            state = .needsRepair
        }

        return ClaudeDesktopIntegrationStatus(
            state: state,
            configURL: configURL,
            installedBinaryURL: installedBinaryURL,
            bundledBinaryURL: bundledBinaryURL,
            configuredCommandPath: configuredCommandPath,
            installedBinaryExists: installedBinaryExists,
            bundledBinaryExists: bundledBinaryExists,
            installedBinaryMatchesBundled: installedBinaryMatchesBundled,
            configExists: configExists,
            configIsReadable: configIsReadable,
            claudeDesktopLikelyInstalled: claudeDesktopLikelyInstalled(fileManager: fileManager)
        )
    }

    static func installForClaudeDesktop(
        bundledBinaryURL: URL? = bundledMCPBinaryURL(),
        installedBinaryURL: URL = installedMCPBinaryURL,
        configURL: URL = claudeDesktopConfigURL,
        fileManager: FileManager = .default
    ) throws -> ClaudeDesktopIntegrationInstallResult {
        guard let bundledBinaryURL,
              fileManager.isExecutableFile(atPath: bundledBinaryURL.path) else {
            throw ClaudeDesktopIntegrationError.bundledBinaryMissing(bundledBinaryURL)
        }

        let stagedBinaryURL = try stageBundledBinary(
            from: bundledBinaryURL,
            in: installedBinaryURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
        defer {
            if fileManager.fileExists(atPath: stagedBinaryURL.path) {
                try? fileManager.removeItem(at: stagedBinaryURL)
            }
        }

        let selfTest = try runSelfTest(binaryURL: stagedBinaryURL, fileManager: fileManager)
        try replaceInstalledBinary(
            withStagedBinaryAt: stagedBinaryURL,
            at: installedBinaryURL,
            fileManager: fileManager
        )
        try writeMCPObservabilityConfigIfAvailable(fileManager: fileManager)

        let backupURL = try writeClaudeDesktopConfig(
            commandPath: installedBinaryURL.path,
            configURL: configURL,
            fileManager: fileManager
        )

        return ClaudeDesktopIntegrationInstallResult(
            configURL: configURL,
            installedBinaryURL: installedBinaryURL,
            backupURL: backupURL,
            selfTest: selfTest
        )
    }

    /// Silently restores or refreshes the bundled helper after app updates.
    /// An existing helper or an exact Claude Desktop config entry proves the
    /// user already opted into agent setup. Without either signal this never
    /// installs fresh.
    @discardableResult
    static func refreshInstalledHelperIfNeeded(
        bundledBinaryURL: URL? = bundledMCPBinaryURL(),
        installedBinaryURL: URL = installedMCPBinaryURL,
        configURL: URL = claudeDesktopConfigURL,
        observabilityConfigURL: URL = mcpObservabilityConfigURL,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let installedBinaryExists = fileManager.fileExists(atPath: installedBinaryURL.path)
        let configuredCommandPath = readClaudeDesktopConfig(at: configURL, fileManager: fileManager)
            .config
            .flatMap(transcriptedCommandPath(in:))
        let hasCanonicalClaudeConfig = configuredCommandPath == installedBinaryURL.path
        guard installedBinaryExists || hasCanonicalClaudeConfig else {
            return false
        }

        guard let bundledBinaryURL,
              fileManager.isExecutableFile(atPath: bundledBinaryURL.path),
              bundledBinaryURL.standardizedFileURL.path != installedBinaryURL.standardizedFileURL.path else {
            try writeMCPObservabilityConfigIfAvailable(
                configURL: observabilityConfigURL,
                infoDictionary: infoDictionary,
                fileManager: fileManager
            )
            return false
        }

        let installedBinaryIsCurrent = fileManager.isExecutableFile(atPath: installedBinaryURL.path)
            && fileManager.contentsEqual(atPath: installedBinaryURL.path, andPath: bundledBinaryURL.path)
        guard !installedBinaryIsCurrent else {
            try writeMCPObservabilityConfigIfAvailable(
                configURL: observabilityConfigURL,
                infoDictionary: infoDictionary,
                fileManager: fileManager
            )
            return false
        }

        let stagedBinaryURL = try stageBundledBinary(
            from: bundledBinaryURL,
            in: installedBinaryURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
        defer {
            if fileManager.fileExists(atPath: stagedBinaryURL.path) {
                try? fileManager.removeItem(at: stagedBinaryURL)
            }
        }

        // Validate the exact bytes we plan to install before replacing an
        // existing helper, so failed refreshes cannot strand Claude on a bad
        // update.
        _ = try runSelfTest(binaryURL: stagedBinaryURL, fileManager: fileManager)
        try replaceInstalledBinary(
            withStagedBinaryAt: stagedBinaryURL,
            at: installedBinaryURL,
            fileManager: fileManager
        )
        try writeMCPObservabilityConfigIfAvailable(
            configURL: observabilityConfigURL,
            infoDictionary: infoDictionary,
            fileManager: fileManager
        )
        return true
    }

    static func configSnippet(commandPath: String = installedMCPBinaryURL.path) -> String {
        let root: [String: Any] = [
            "mcpServers": [
                serverName: [
                    "command": commandPath
                ]
            ]
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ),
              let snippet = String(data: data, encoding: .utf8) else {
            return #"{"mcpServers":{"\#(serverName)":{"command":""}}}"#
        }

        return snippet
    }

    static func installBundledBinary(
        from bundledBinaryURL: URL,
        to installedBinaryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let stagedBinaryURL = try stageBundledBinary(
            from: bundledBinaryURL,
            in: installedBinaryURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
        defer {
            if fileManager.fileExists(atPath: stagedBinaryURL.path) {
                try? fileManager.removeItem(at: stagedBinaryURL)
            }
        }

        try replaceInstalledBinary(
            withStagedBinaryAt: stagedBinaryURL,
            at: installedBinaryURL,
            fileManager: fileManager
        )
    }

    static func stageBundledBinary(
        from bundledBinaryURL: URL,
        in installDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let stagedBinaryURL = installDirectory
            .appendingPathComponent(".\(helperBinaryName).install-\(UUID().uuidString)", isDirectory: false)
        try fileManager.copyItem(at: bundledBinaryURL, to: stagedBinaryURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: stagedBinaryURL.path
        )
        return stagedBinaryURL
    }

    static func replaceInstalledBinary(
        withStagedBinaryAt stagedBinaryURL: URL,
        at installedBinaryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        if fileManager.fileExists(atPath: installedBinaryURL.path) {
            _ = try fileManager.replaceItemAt(
                installedBinaryURL,
                withItemAt: stagedBinaryURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: stagedBinaryURL, to: installedBinaryURL)
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: installedBinaryURL.path
        )
    }

    static func writeMCPObservabilityConfigIfAvailable(
        configURL: URL = mcpObservabilityConfigURL,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        analyticsEnabled: Bool = AnalyticsPreferences.isEnabled(),
        fileManager: FileManager = .default
    ) throws {
        guard analyticsEnabled else {
            if fileManager.fileExists(atPath: configURL.path) {
                try fileManager.removeItem(at: configURL)
            }
            return
        }

        guard let apiKey = firstNonEmpty(infoDictionary?[AnalyticsRuntimeConfiguration.apiKeyInfoKey] as? String),
              let host = firstNonEmpty(infoDictionary?[AnalyticsRuntimeConfiguration.hostInfoKey] as? String),
              host.lowercased().hasPrefix("https://") else {
            if fileManager.fileExists(atPath: configURL.path) {
                try fileManager.removeItem(at: configURL)
            }
            return
        }

        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var configuration = [
            AnalyticsRuntimeConfiguration.apiKeyInfoKey: apiKey,
            AnalyticsRuntimeConfiguration.hostInfoKey: host,
        ]
        if let appVersion = safeAppVersion(infoDictionary?[appVersionInfoKey] as? String) {
            configuration[appVersionInfoKey] = appVersion
        }
        if let buildChannel = safeBuildChannel(
            infoDictionary?[AnalyticsRuntimeConfiguration.buildChannelInfoKey] as? String
        ) {
            configuration[AnalyticsRuntimeConfiguration.buildChannelInfoKey] = buildChannel
        }
        if let buildRevision = safeBuildRevision(
            infoDictionary?[AnalyticsRuntimeConfiguration.buildRevisionInfoKey] as? String
        ) {
            configuration[AnalyticsRuntimeConfiguration.buildRevisionInfoKey] = buildRevision
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: configuration,
            format: .xml,
            options: 0
        )
        try data.write(to: configURL, options: [.atomic])
        fileManager.restrictFileToOwnerOnly(at: configURL)
    }

    private static func firstNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func safeAppVersion(_ value: String?) -> String? {
        guard let value = firstNonEmpty(value),
              value.count <= 80,
              value.first?.isNumber == true,
              value.contains("."),
              value.allSatisfy(isSafeBuildCharacter) else {
            return nil
        }
        return value
    }

    private static func safeBuildChannel(_ value: String?) -> String? {
        guard let value = firstNonEmpty(value),
              ["beta", "debug", "dev", "local", "nightly", "release", "test"].contains(value) else {
            return nil
        }
        return value
    }

    private static func safeBuildRevision(_ value: String?) -> String? {
        guard let value = firstNonEmpty(value),
              (7...40).contains(value.count),
              value.allSatisfy({ $0.isHexDigit }) else {
            return nil
        }
        return value
    }

    private static func isSafeBuildCharacter(_ character: Character) -> Bool {
        character.isLetter
            || character.isNumber
            || character == "."
            || character == "_"
            || character == "-"
    }

    @discardableResult
    static func writeClaudeDesktopConfig(
        commandPath: String,
        configURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL? {
        try writeMCPServersConfig(
            commandPath: commandPath,
            configURL: configURL,
            fileManager: fileManager
        )
    }

    /// Merges the Transcripted server entry into any `mcpServers`-style JSON
    /// config (Claude Desktop, Cursor). Preserves other servers and top-level
    /// keys; backs up unreadable configs instead of overwriting them blindly.
    @discardableResult
    static func writeMCPServersConfig(
        commandPath: String,
        configURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL? {
        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let configRead = readClaudeDesktopConfig(at: configURL, fileManager: fileManager)
        var root = configRead.config ?? [:]
        let backupURL = configRead.needsBackup ? try backupConfig(at: configURL, fileManager: fileManager) : nil
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": commandPath]
        root["mcpServers"] = servers

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: configURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: configURL.path
        )
        return backupURL
    }

    static let selfTestTimeout: TimeInterval = 30

    static func runSelfTest(
        binaryURL: URL,
        fileManager: FileManager = .default,
        timeout: TimeInterval = selfTestTimeout,
        pipeDrainTimeout: TimeInterval = BoundedProcessRunner.defaultPipeDrainTimeout
    ) throws -> TranscriptedMCPSelfTest {
        guard fileManager.isExecutableFile(atPath: binaryURL.path) else {
            throw ClaudeDesktopIntegrationError.installedBinaryNotExecutable(binaryURL)
        }

        let result: BoundedProcessRunner.Output
        do {
            result = try BoundedProcessRunner.run(
                executable: binaryURL,
                arguments: ["--self-test"],
                timeout: timeout,
                pipeDrainTimeout: pipeDrainTimeout
            )
        } catch is BoundedProcessRunner.RunError {
            throw ClaudeDesktopIntegrationError.selfTestTimedOut
        }

        let output = String(decoding: result.stdoutData + result.stderrData, as: UTF8.self)

        guard result.status == 0 else {
            throw ClaudeDesktopIntegrationError.selfTestFailed(
                status: result.status,
                output: output
            )
        }

        do {
            let selfTest = try JSONDecoder().decode(TranscriptedMCPSelfTest.self, from: result.stdoutData)
            guard selfTest.ok else {
                throw ClaudeDesktopIntegrationError.selfTestReportedUnhealthy(output: output)
            }
            return selfTest
        } catch let error as ClaudeDesktopIntegrationError {
            throw error
        } catch {
            throw ClaudeDesktopIntegrationError.selfTestOutputUnreadable(output)
        }
    }

    static func claudeDesktopLikelyInstalled(fileManager: FileManager = .default) -> Bool {
        let homeApplications = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Claude.app", isDirectory: true)

        return fileManager.fileExists(atPath: "/Applications/Claude.app")
            || fileManager.fileExists(atPath: homeApplications.path)
    }

    private static func readClaudeDesktopConfig(
        at configURL: URL,
        fileManager: FileManager
    ) -> (config: [String: Any]?, needsBackup: Bool) {
        guard fileManager.fileExists(atPath: configURL.path) else {
            return ([:], false)
        }

        do {
            let data = try Data(contentsOf: configURL)
            let json = try JSONSerialization.jsonObject(with: data)
            guard let config = json as? [String: Any] else {
                return (nil, true)
            }
            return (config, false)
        } catch {
            return (nil, true)
        }
    }

    private static func transcriptedCommandPath(in config: [String: Any]) -> String? {
        guard let servers = config["mcpServers"] as? [String: Any],
              let transcripted = servers[serverName] as? [String: Any] else {
            return nil
        }

        return transcripted["command"] as? String
    }

    private static func installedBinaryMatchesBundled(
        installedBinaryURL: URL,
        bundledBinaryURL: URL?,
        installedBinaryExists: Bool,
        bundledBinaryExists: Bool,
        fileManager: FileManager
    ) -> Bool {
        guard installedBinaryExists,
              bundledBinaryExists,
              let bundledBinaryURL else {
            return true
        }

        if installedBinaryURL.standardizedFileURL.path == bundledBinaryURL.standardizedFileURL.path {
            return true
        }

        return fileManager.contentsEqual(atPath: installedBinaryURL.path, andPath: bundledBinaryURL.path)
    }

    /// Timestamped sibling copy of a config file. Shared with the Codex TOML
    /// path in `AgentMCPConnector`, so every agent-config rewrite leaves the
    /// original recoverable.
    static func backupConfig(at configURL: URL, fileManager: FileManager) throws -> URL? {
        guard fileManager.fileExists(atPath: configURL.path) else { return nil }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = configURL.deletingLastPathComponent()
            .appendingPathComponent("\(configURL.lastPathComponent).backup-\(timestamp)", isDirectory: false)
        try fileManager.copyItem(at: configURL, to: backupURL)
        fileManager.restrictFileToOwnerOnly(at: backupURL)
        return backupURL
    }
}

/// Runs a short-lived helper or CLI process with every wait bounded: the exit
/// wait is capped by `timeout`, both pipes are drained off-thread into
/// lock-protected buffers so a chatty child cannot stall against a full pipe
/// buffer, and the post-exit drain is capped by `pipeDrainTimeout` so a
/// grandchild that inherited the pipe write ends cannot block the caller
/// after the child itself has exited.
enum BoundedProcessRunner {
    struct Output {
        let status: Int32
        let stdoutData: Data
        let stderrData: Data
    }

    enum RunError: Error, Equatable {
        case timedOut
    }

    static let defaultPipeDrainTimeout: TimeInterval = 5

    private final class LockedDataBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func append(_ chunk: Data) {
            lock.lock()
            buffer.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
    }

    static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        pipeDrainTimeout: TimeInterval = defaultPipeDrainTimeout
    ) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        try process.run()

        let stdoutBuffer = LockedDataBuffer()
        let stderrBuffer = LockedDataBuffer()
        let drained = DispatchGroup()
        for (pipe, buffer) in [(stdout, stdoutBuffer), (stderr, stderrBuffer)] {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    buffer.append(chunk)
                }
                drained.leave()
            }
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            throw RunError.timedOut
        }

        // EOF only arrives once every inherited write end closes, and a
        // leaked grandchild can hold them open long after the child exited.
        // Take whatever has been drained so far instead of waiting forever.
        _ = drained.wait(timeout: .now() + pipeDrainTimeout)
        return Output(
            status: process.terminationStatus,
            stdoutData: stdoutBuffer.snapshot(),
            stderrData: stderrBuffer.snapshot()
        )
    }
}

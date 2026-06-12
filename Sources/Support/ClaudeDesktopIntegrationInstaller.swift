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
    case selfTestTimedOut(URL)

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
            return "Transcripted direct tools did not respond to the local check. Try again, or reinstall the helper."
        }
    }
}

enum ClaudeDesktopIntegrationInstaller {
    static let serverName = "transcripted"
    static let helperBinaryName = "transcripted-mcp"

    static var installedMCPBinaryURL: URL {
        FileManager.default.transcriptedAppSupportDir
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent(helperBinaryName, isDirectory: false)
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

        try installBundledBinary(
            from: bundledBinaryURL,
            to: installedBinaryURL,
            fileManager: fileManager
        )

        let backupURL = try writeClaudeDesktopConfig(
            commandPath: installedBinaryURL.path,
            configURL: configURL,
            fileManager: fileManager
        )

        let selfTest = try runSelfTest(binaryURL: installedBinaryURL, fileManager: fileManager)
        return ClaudeDesktopIntegrationInstallResult(
            configURL: configURL,
            installedBinaryURL: installedBinaryURL,
            backupURL: backupURL,
            selfTest: selfTest
        )
    }

    /// Silently re-copies the bundled helper over a previously installed one
    /// when their contents differ, e.g. after an app update. Configs are left
    /// untouched — they already point at the stable installed path. Never
    /// installs fresh: a missing installed helper means the user has not
    /// opted into agent setup yet.
    @discardableResult
    static func refreshInstalledHelperIfNeeded(
        bundledBinaryURL: URL? = bundledMCPBinaryURL(),
        installedBinaryURL: URL = installedMCPBinaryURL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard let bundledBinaryURL,
              fileManager.isExecutableFile(atPath: bundledBinaryURL.path),
              fileManager.fileExists(atPath: installedBinaryURL.path),
              bundledBinaryURL.standardizedFileURL.path != installedBinaryURL.standardizedFileURL.path,
              !fileManager.contentsEqual(atPath: installedBinaryURL.path, andPath: bundledBinaryURL.path) else {
            return false
        }

        try installBundledBinary(
            from: bundledBinaryURL,
            to: installedBinaryURL,
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
        let installDirectory = installedBinaryURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: installedBinaryURL.path) {
            try fileManager.removeItem(at: installedBinaryURL)
        }

        try fileManager.copyItem(at: bundledBinaryURL, to: installedBinaryURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: installedBinaryURL.path
        )
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

    static func runSelfTest(
        binaryURL: URL,
        fileManager: FileManager = .default,
        timeout: TimeInterval = 30
    ) throws -> TranscriptedMCPSelfTest {
        guard fileManager.isExecutableFile(atPath: binaryURL.path) else {
            throw ClaudeDesktopIntegrationError.installedBinaryNotExecutable(binaryURL)
        }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["--self-test"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        try process.run()

        // Drain both pipes while the helper runs so a noisy self-test cannot
        // fill a pipe buffer and stall before the timeout can fire.
        final class PipeOutputBox: @unchecked Sendable {
            var data = Data()
        }
        let stdoutBox = PipeOutputBox()
        let stderrBox = PipeOutputBox()
        let drained = DispatchGroup()
        for (pipe, box) in [(stdout, stdoutBox), (stderr, stderrBox)] {
            drained.enter()
            DispatchQueue.global(qos: .utility).async {
                box.data = pipe.fileHandleForReading.readDataToEndOfFile()
                drained.leave()
            }
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            throw ClaudeDesktopIntegrationError.selfTestTimedOut(binaryURL)
        }

        drained.wait()

        let stdoutData = stdoutBox.data
        let stderrData = stderrBox.data
        let output = String(decoding: stdoutData + stderrData, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw ClaudeDesktopIntegrationError.selfTestFailed(
                status: process.terminationStatus,
                output: output
            )
        }

        do {
            let selfTest = try JSONDecoder().decode(TranscriptedMCPSelfTest.self, from: stdoutData)
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

    private static func backupConfig(at configURL: URL, fileManager: FileManager) throws -> URL? {
        guard fileManager.fileExists(atPath: configURL.path) else { return nil }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let baseName = "\(configURL.lastPathComponent).backup-\(timestamp)"
        var backupURL = configURL.deletingLastPathComponent()
            .appendingPathComponent(baseName, isDirectory: false)
        var suffix = 2

        while fileManager.fileExists(atPath: backupURL.path) {
            backupURL = configURL.deletingLastPathComponent()
                .appendingPathComponent("\(baseName)-\(suffix)", isDirectory: false)
            suffix += 1
        }

        try fileManager.copyItem(at: configURL, to: backupURL)
        return backupURL
    }
}

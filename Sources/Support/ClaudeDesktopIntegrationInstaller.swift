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
    let configExists: Bool
    let configIsReadable: Bool
    let claudeDesktopLikelyInstalled: Bool

    var isInstalled: Bool {
        state == .installed
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
    case selfTestOutputUnreadable(String)

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
        case .selfTestOutputUnreadable:
            return "Transcripted direct tools ran, but the health check output could not be read."
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

        let state: ClaudeDesktopIntegrationStatus.State
        if installedBinaryExists && isConfiguredForInstalledBinary {
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

    static func configSnippet(commandPath: String = installedMCPBinaryURL.path) -> String {
        """
        {
          "mcpServers": {
            "\(serverName)": {
              "command": "\(commandPath)"
            }
          }
        }
        """
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
        fileManager: FileManager = .default
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

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: stdoutData + stderrData, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw ClaudeDesktopIntegrationError.selfTestFailed(
                status: process.terminationStatus,
                output: output
            )
        }

        do {
            return try JSONDecoder().decode(TranscriptedMCPSelfTest.self, from: stdoutData)
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

    private static func backupConfig(at configURL: URL, fileManager: FileManager) throws -> URL? {
        guard fileManager.fileExists(atPath: configURL.path) else { return nil }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = configURL.deletingLastPathComponent()
            .appendingPathComponent("\(configURL.lastPathComponent).backup-\(timestamp)", isDirectory: false)
        try fileManager.copyItem(at: configURL, to: backupURL)
        return backupURL
    }
}

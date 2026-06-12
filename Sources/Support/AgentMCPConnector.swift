import Foundation

/// MCP-capable agents Transcripted can connect by pointing the agent's own
/// config at the installed `transcripted-mcp` helper. Claude Desktop keeps its
/// richer install/self-test flow in `ClaudeDesktopIntegrationInstaller`; this
/// seam gives every other agent the same one-click connect.
enum AgentMCPAgent: String, CaseIterable, Identifiable {
    case claudeDesktop = "claude_desktop"
    case claudeCode = "claude_code"
    case codex
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeDesktop: return "Claude Desktop"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        }
    }

    var detail: String {
        switch self {
        case .claudeDesktop: return "Desktop app"
        case .claudeCode: return "CLI"
        case .codex: return "App and CLI"
        case .cursor: return "Editor"
        }
    }
}

struct AgentMCPConnectorPaths {
    let homeDirectory: URL
    let applicationDirectories: [URL]
    let systemBinaryDirectories: [URL]

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationDirectories: [URL]? = nil,
        systemBinaryDirectories: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        ]
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.applicationDirectories = applicationDirectories ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
        ]
        self.systemBinaryDirectories = systemBinaryDirectories
    }

    var claudeCodeUserConfigURL: URL {
        homeDirectory.appendingPathComponent(".claude.json", isDirectory: false)
    }

    var claudeCodeStateDirectory: URL {
        homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }

    var claudeCodeBinaryCandidates: [URL] {
        [
            homeDirectory.appendingPathComponent(".claude/local/claude", isDirectory: false),
            homeDirectory.appendingPathComponent(".local/bin/claude", isDirectory: false),
        ] + systemBinaryDirectories.map { $0.appendingPathComponent("claude", isDirectory: false) }
    }

    var codexConfigURL: URL {
        homeDirectory.appendingPathComponent(".codex/config.toml", isDirectory: false)
    }

    var codexStateDirectory: URL {
        homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    var codexBinaryCandidates: [URL] {
        [
            homeDirectory.appendingPathComponent(".local/bin/codex", isDirectory: false),
        ] + systemBinaryDirectories.map { $0.appendingPathComponent("codex", isDirectory: false) }
    }

    var cursorConfigURL: URL {
        homeDirectory.appendingPathComponent(".cursor/mcp.json", isDirectory: false)
    }

    var cursorStateDirectory: URL {
        homeDirectory.appendingPathComponent(".cursor", isDirectory: true)
    }

    func applicationExists(named name: String, fileManager: FileManager) -> Bool {
        applicationDirectories.contains { directory in
            fileManager.fileExists(atPath: directory.appendingPathComponent(name, isDirectory: true).path)
        }
    }
}

enum AgentMCPConnectorError: LocalizedError, Equatable {
    case agentCLINotFound(AgentMCPAgent)
    case agentCLIFailed(AgentMCPAgent, status: Int32, output: String)
    case agentCLITimedOut(AgentMCPAgent)
    case codexConfigUsesInlineServers

    var errorDescription: String? {
        switch self {
        case .agentCLINotFound(let agent):
            return "\(agent.displayName) was not found on this Mac."
        case .agentCLIFailed(let agent, _, let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "\(agent.displayName) could not register Transcripted."
                : trimmed
        case .agentCLITimedOut(let agent):
            return "\(agent.displayName) did not respond. Try again, or register Transcripted from the \(agent.displayName) side."
        case .codexConfigUsesInlineServers:
            return "Your Codex config defines mcp_servers inline. Add Transcripted there manually, or convert it to [mcp_servers.transcripted] table form."
        }
    }
}

enum AgentMCPConnector {
    static let serverName = ClaudeDesktopIntegrationInstaller.serverName

    // MARK: - Detection

    static func isDetected(
        _ agent: AgentMCPAgent,
        paths: AgentMCPConnectorPaths = AgentMCPConnectorPaths(),
        fileManager: FileManager = .default
    ) -> Bool {
        switch agent {
        case .claudeDesktop:
            return paths.applicationExists(named: "Claude.app", fileManager: fileManager)
        case .claudeCode:
            return claudeCodeBinary(paths: paths, fileManager: fileManager) != nil
                || fileManager.fileExists(atPath: paths.claudeCodeStateDirectory.path)
        case .codex:
            return paths.applicationExists(named: "Codex.app", fileManager: fileManager)
                || fileManager.fileExists(atPath: paths.codexStateDirectory.path)
                || paths.codexBinaryCandidates.contains { fileManager.isExecutableFile(atPath: $0.path) }
        case .cursor:
            return paths.applicationExists(named: "Cursor.app", fileManager: fileManager)
                || fileManager.fileExists(atPath: paths.cursorStateDirectory.path)
        }
    }

    // MARK: - Connection state

    static func isConnected(
        _ agent: AgentMCPAgent,
        helperCommandPath: String = ClaudeDesktopIntegrationInstaller.installedMCPBinaryURL.path,
        paths: AgentMCPConnectorPaths = AgentMCPConnectorPaths(),
        fileManager: FileManager = .default
    ) -> Bool {
        switch agent {
        case .claudeDesktop:
            return ClaudeDesktopIntegrationInstaller.currentStatus(fileManager: fileManager).isInstalled
        case .claudeCode:
            return configuredCommandPath(inJSONConfigAt: paths.claudeCodeUserConfigURL, fileManager: fileManager)
                == helperCommandPath
        case .codex:
            guard let text = try? String(contentsOf: paths.codexConfigURL, encoding: .utf8) else {
                return false
            }
            return codexConfiguredCommandPath(inConfigText: text) == helperCommandPath
        case .cursor:
            return configuredCommandPath(inJSONConfigAt: paths.cursorConfigURL, fileManager: fileManager)
                == helperCommandPath
        }
    }

    // MARK: - Connect

    /// Copies the bundled helper into place when it is missing or stale, so a
    /// Connect click is the single consent point for every agent.
    @discardableResult
    static func ensureHelperInstalled(
        bundledBinaryURL: URL? = ClaudeDesktopIntegrationInstaller.bundledMCPBinaryURL(),
        installedBinaryURL: URL = ClaudeDesktopIntegrationInstaller.installedMCPBinaryURL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let bundledBinaryURL,
              fileManager.isExecutableFile(atPath: bundledBinaryURL.path) else {
            throw ClaudeDesktopIntegrationError.bundledBinaryMissing(bundledBinaryURL)
        }

        let installedIsCurrent = fileManager.fileExists(atPath: installedBinaryURL.path)
            && fileManager.contentsEqual(atPath: installedBinaryURL.path, andPath: bundledBinaryURL.path)
        if !installedIsCurrent {
            try ClaudeDesktopIntegrationInstaller.installBundledBinary(
                from: bundledBinaryURL,
                to: installedBinaryURL,
                fileManager: fileManager
            )
        }
        return installedBinaryURL
    }

    /// Points the agent's config at the installed helper. Claude Desktop runs
    /// its own full install + self-test flow; for every other agent the
    /// helper must already be installed (callers run `ensureHelperInstalled`
    /// first).
    static func connect(
        _ agent: AgentMCPAgent,
        helperCommandPath: String = ClaudeDesktopIntegrationInstaller.installedMCPBinaryURL.path,
        paths: AgentMCPConnectorPaths = AgentMCPConnectorPaths(),
        fileManager: FileManager = .default,
        cliTimeout: TimeInterval = defaultCLITimeout
    ) throws {
        switch agent {
        case .claudeDesktop:
            // Claude Desktop keeps its dedicated install + self-test flow.
            _ = try ClaudeDesktopIntegrationInstaller.installForClaudeDesktop(fileManager: fileManager)
        case .claudeCode:
            try connectClaudeCode(
                helperCommandPath: helperCommandPath,
                paths: paths,
                fileManager: fileManager,
                cliTimeout: cliTimeout
            )
        case .codex:
            try connectCodex(helperCommandPath: helperCommandPath, paths: paths, fileManager: fileManager)
        case .cursor:
            try ClaudeDesktopIntegrationInstaller.writeMCPServersConfig(
                commandPath: helperCommandPath,
                configURL: paths.cursorConfigURL,
                fileManager: fileManager
            )
        }
    }

    // MARK: - Claude Code

    static func claudeCodeBinary(
        paths: AgentMCPConnectorPaths = AgentMCPConnectorPaths(),
        fileManager: FileManager = .default
    ) -> URL? {
        paths.claudeCodeBinaryCandidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Registers through the `claude` CLI instead of editing `~/.claude.json`
    /// directly — that file is Claude Code's live state file, and the CLI owns
    /// its format. Reading it for status is safe; writing it is not.
    private static func connectClaudeCode(
        helperCommandPath: String,
        paths: AgentMCPConnectorPaths,
        fileManager: FileManager,
        cliTimeout: TimeInterval
    ) throws {
        guard let binary = claudeCodeBinary(paths: paths, fileManager: fileManager) else {
            throw AgentMCPConnectorError.agentCLINotFound(.claudeCode)
        }

        // `mcp add` fails when the name already exists; remove first so
        // reconnect after an app move or helper path change stays one click.
        _ = try? runCLI(
            binary,
            arguments: ["mcp", "remove", "--scope", "user", serverName],
            timeout: cliTimeout
        )

        let result = try runCLI(
            binary,
            arguments: ["mcp", "add", "--scope", "user", serverName, helperCommandPath],
            timeout: cliTimeout
        )
        guard result.status == 0 else {
            throw AgentMCPConnectorError.agentCLIFailed(.claudeCode, status: result.status, output: result.output)
        }
    }

    // MARK: - Codex

    private static func connectCodex(
        helperCommandPath: String,
        paths: AgentMCPConnectorPaths,
        fileManager: FileManager
    ) throws {
        let configURL = paths.codexConfigURL
        try fileManager.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let existing = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let updated = try codexConfigText(updating: existing, commandPath: helperCommandPath)
        try updated.write(to: configURL, atomically: true, encoding: .utf8)
        fileManager.restrictFileToOwnerOnly(at: configURL)
    }

    static let codexServerTableHeader = "[mcp_servers.transcripted]"

    /// Conservative text-level TOML edit: replaces the `command` entry inside
    /// the `[mcp_servers.transcripted]` table, or appends the table when it is
    /// missing. Everything else in the user's config is preserved byte for
    /// byte. Throws instead of appending when the config defines `mcp_servers`
    /// as an inline table — appending a table header after that would corrupt
    /// the file with a duplicate-key error.
    static func codexConfigText(updating existing: String, commandPath: String) throws -> String {
        let commandLine = "command = \(tomlBasicString(commandPath))"
        var lines = existing.components(separatedBy: "\n")

        if let headerIndex = lines.firstIndex(where: { trimmedTOMLLine($0) == codexServerTableHeader }) {
            var tableEnd = lines.count
            for index in (headerIndex + 1)..<lines.count
            where trimmedTOMLLine(lines[index]).hasPrefix("[") {
                tableEnd = index
                break
            }

            if let commandIndex = ((headerIndex + 1)..<tableEnd).first(where: { index in
                lineDefinesTOMLCommandKey(trimmedTOMLLine(lines[index]))
            }) {
                lines[commandIndex] = commandLine
            } else {
                lines.insert(commandLine, at: headerIndex + 1)
            }

            return lines.joined(separator: "\n")
        }

        let definesInlineServers = lines.contains { line in
            let trimmed = trimmedTOMLLine(line)
            guard trimmed.hasPrefix("mcp_servers") else { return false }
            let remainder = trimmed.dropFirst("mcp_servers".count).trimmingCharacters(in: .whitespaces)
            return remainder.hasPrefix("=")
        }
        guard !definesInlineServers else {
            throw AgentMCPConnectorError.codexConfigUsesInlineServers
        }

        var text = existing
        if !text.isEmpty, !text.hasSuffix("\n") {
            text += "\n"
        }
        if !text.isEmpty {
            text += "\n"
        }
        text += "\(codexServerTableHeader)\n\(commandLine)\n"
        return text
    }

    static func codexConfiguredCommandPath(inConfigText text: String) -> String? {
        var inServerTable = false

        for rawLine in text.components(separatedBy: "\n") {
            let line = trimmedTOMLLine(rawLine)

            if line.hasPrefix("[") {
                inServerTable = line == codexServerTableHeader
                continue
            }

            guard inServerTable, lineDefinesTOMLCommandKey(line) else { continue }
            guard let equalsIndex = line.firstIndex(of: "=") else { continue }
            let value = String(line[line.index(after: equalsIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return tomlBasicStringValue(value)
        }

        return nil
    }

    /// Trims horizontal whitespace plus the stray `\r` left behind when a
    /// CRLF config is split on `\n`.
    private static func trimmedTOMLLine(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True only for the bare `command` key — not `command_timeout` or any
    /// other key that merely starts with "command".
    private static func lineDefinesTOMLCommandKey(_ trimmedLine: String) -> Bool {
        guard trimmedLine.hasPrefix("command") else { return false }
        let remainder = trimmedLine.dropFirst("command".count)
            .trimmingCharacters(in: .whitespaces)
        return remainder.hasPrefix("=")
    }

    static func tomlBasicString(_ value: String) -> String {
        var escaped = ""
        for character in value.unicodeScalars {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.unicodeScalars.append(character)
            }
        }
        return "\"\(escaped)\""
    }

    static func tomlBasicStringValue(_ quoted: String) -> String? {
        guard quoted.count >= 2, quoted.hasPrefix("\""), quoted.hasSuffix("\"") else {
            return nil
        }

        var value = ""
        var pendingEscape = false
        for character in quoted.dropFirst().dropLast() {
            if pendingEscape {
                switch character {
                case "\\": value.append("\\")
                case "\"": value.append("\"")
                case "n": value.append("\n")
                case "r": value.append("\r")
                case "t": value.append("\t")
                default: return nil
                }
                pendingEscape = false
            } else if character == "\\" {
                pendingEscape = true
            } else {
                value.append(character)
            }
        }

        return pendingEscape ? nil : value
    }

    // MARK: - Shared

    private static func configuredCommandPath(
        inJSONConfigAt configURL: URL,
        fileManager: FileManager
    ) -> String? {
        guard fileManager.fileExists(atPath: configURL.path),
              let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let transcripted = servers[serverName] as? [String: Any] else {
            return nil
        }

        return transcripted["command"] as? String
    }

    static let defaultCLITimeout: TimeInterval = 30

    private static func runCLI(
        _ executable: URL,
        arguments: [String],
        agent: AgentMCPAgent = .claudeCode,
        timeout: TimeInterval = defaultCLITimeout
    ) throws -> (status: Int32, output: String) {
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

        // Drain both pipes off-thread so a chatty CLI cannot fill a pipe
        // buffer and stall before its exit is observed.
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
            throw AgentMCPConnectorError.agentCLITimedOut(agent)
        }

        drained.wait()
        return (process.terminationStatus, String(decoding: stdoutBox.data + stderrBox.data, as: UTF8.self))
    }
}

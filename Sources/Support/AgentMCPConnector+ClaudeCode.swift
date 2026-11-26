import Darwin
import Foundation

extension AgentMCPConnectorPaths {
    /// Dynamic Node version-manager bin directories under `homeDirectory`
    /// (`~/.nvm/versions/node/*/bin` and `~/.fnm/node-versions/*/installation/bin`),
    /// ordered with the nvm default alias first (if present) and newest semver first.
    func nodeManagerBinaryDirectories(fileManager: FileManager = .default) -> [URL] {
        var directories: [URL] = []

        let nvmVersionsRoot = homeDirectory.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versionNames = try? fileManager.contentsOfDirectory(atPath: nvmVersionsRoot.path) {
            let defaultAlias = readNVMDefaultAliasPrefix(fileManager: fileManager)
            let sorted = Self.sortedNodeVersions(versionNames, preferredPrefix: defaultAlias)
            for version in sorted {
                directories.append(
                    nvmVersionsRoot
                        .appendingPathComponent(version, isDirectory: true)
                        .appendingPathComponent("bin", isDirectory: true)
                )
            }
        }

        let fnmVersionsRoot = homeDirectory.appendingPathComponent(".fnm/node-versions", isDirectory: true)
        if let versionNames = try? fileManager.contentsOfDirectory(atPath: fnmVersionsRoot.path) {
            let sorted = Self.sortedNodeVersions(versionNames, preferredPrefix: nil)
            for version in sorted {
                directories.append(
                    fnmVersionsRoot
                        .appendingPathComponent(version, isDirectory: true)
                        .appendingPathComponent("installation/bin", isDirectory: true)
                )
            }
        }

        return directories
    }

    /// Directories from the current process `PATH` (when `searchEnvironmentPATH` is on).
    func environmentPATHDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        guard searchEnvironmentPATH,
              let pathValue = environment["PATH"],
              !pathValue.isEmpty else {
            return []
        }
        return Self.parsePATHDirectories(pathValue)
    }

    static func parsePATHDirectories(_ pathValue: String) -> [URL] {
        var seen: Set<String> = []
        var urls: [URL] = []
        for rawComponent in pathValue.split(separator: ":") {
            let trimmed = rawComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.hasPrefix("/") else { continue }
            let standardized = URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
            if seen.insert(standardized.path).inserted {
                urls.append(standardized)
            }
        }
        return urls
    }

    private func readNVMDefaultAliasPrefix(fileManager: FileManager) -> String? {
        let aliasURL = homeDirectory.appendingPathComponent(".nvm/alias/default", isDirectory: false)
        guard fileManager.fileExists(atPath: aliasURL.path),
              let raw = try? String(contentsOf: aliasURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.first?.isNumber == true || trimmed.hasPrefix("v") else {
            return nil
        }
        return trimmed.hasPrefix("v") ? trimmed : "v\(trimmed)"
    }

    static func sortedNodeVersions(_ versions: [String], preferredPrefix: String?) -> [String] {
        func semverTuple(_ raw: String) -> (Int, Int, Int) {
            let trimmed = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
            let parts = trimmed.split(separator: ".").map { Int($0) ?? -1 }
            return (
                parts.count > 0 ? parts[0] : -1,
                parts.count > 1 ? parts[1] : -1,
                parts.count > 2 ? parts[2] : -1
            )
        }
        func matchesPreferred(_ version: String) -> Bool {
            guard let preferredPrefix else { return false }
            return version == preferredPrefix || version.hasPrefix(preferredPrefix + ".")
        }

        return versions
            .filter { !$0.hasPrefix(".") }
            .sorted { lhs, rhs in
                let lhsPref = matchesPreferred(lhs)
                let rhsPref = matchesPreferred(rhs)
                if lhsPref != rhsPref { return lhsPref }
                let lt = semverTuple(lhs)
                let rt = semverTuple(rhs)
                if lt != rt { return lt > rt }
                return lhs > rhs
            }
    }
}

extension AgentMCPConnector {
    // MARK: - Claude Code

    static let loginShellPATHLookupTimeout: TimeInterval = 2.0

    private struct ClaudeCodeBinaryResolution {
        let executable: URL
        let loginShellPATHDirectories: [URL]
    }

    static func claudeCodeBinary(
        paths: AgentMCPConnectorPaths = AgentMCPConnectorPaths(),
        fileManager: FileManager = .default,
        allowLoginShellLookup: Bool = false
    ) -> URL? {
        resolveClaudeCodeBinary(
            paths: paths,
            fileManager: fileManager,
            allowLoginShellLookup: allowLoginShellLookup
        )?.executable
    }

    private static func resolveClaudeCodeBinary(
        paths: AgentMCPConnectorPaths,
        fileManager: FileManager,
        allowLoginShellLookup: Bool
    ) -> ClaudeCodeBinaryResolution? {
        var candidates = paths.claudeCodeBinaryCandidates
        candidates.append(contentsOf: paths.nodeManagerBinaryDirectories(fileManager: fileManager)
            .map { $0.appendingPathComponent("claude", isDirectory: false) })
        if paths.searchEnvironmentPATH {
            candidates.append(URL(fileURLWithPath: "/opt/local/bin/claude", isDirectory: false))
            candidates.append(contentsOf: paths.environmentPATHDirectories()
                .map { $0.appendingPathComponent("claude", isDirectory: false) })
        }

        var seen: Set<String> = []
        for candidate in candidates {
            let path = candidate.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            if fileManager.isExecutableFile(atPath: path) {
                return ClaudeCodeBinaryResolution(executable: candidate, loginShellPATHDirectories: [])
            }
        }

        guard allowLoginShellLookup,
              paths.searchEnvironmentPATH || paths.loginShellPATHLookup != nil else {
            return nil
        }
        let rawShellDirectories = paths.loginShellPATHLookup?() ?? resolveLoginShellPATHDirectories()
        var seenShellDirs: Set<String> = []
        let validatedShellDirectories: [URL] = rawShellDirectories.compactMap { directory in
            let path = directory.standardizedFileURL.path
            guard !path.isEmpty, path.hasPrefix("/"), seenShellDirs.insert(path).inserted else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        for directory in validatedShellDirectories {
            let candidate = directory.appendingPathComponent("claude", isDirectory: false)
            let path = candidate.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            if fileManager.isExecutableFile(atPath: path) {
                return ClaudeCodeBinaryResolution(
                    executable: candidate,
                    loginShellPATHDirectories: validatedShellDirectories
                )
            }
        }
        return nil
    }

    /// Builds a child environment for running `claude` from a Finder-launched
    /// macOS `.app` whose inherited `PATH` lacks Homebrew, nvm, Volta, Bun, and
    /// other Node install locations (which otherwise fail `#!/usr/bin/env node`
    /// with exit 127). Also clears `CLAUDECODE` so dev launches inside Claude
    /// Code aren't rejected as nested sessions.
    static func claudeCodeCLIEnvironment(
        for executable: URL,
        paths: AgentMCPConnectorPaths,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        additionalPATHDirectories: [URL] = [],
        fileManager: FileManager = .default
    ) -> [String: String] {
        var env = baseEnvironment
        env.removeValue(forKey: "CLAUDECODE")

        var pathEntries: [String] = []
        var seen: Set<String> = []
        func appendDir(_ path: String) {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.hasPrefix("/"), seen.insert(trimmed).inserted else { return }
            pathEntries.append(trimmed)
        }

        appendDir(executable.deletingLastPathComponent().standardizedFileURL.path)
        appendDir(executable.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL.path)
        for dir in additionalPATHDirectories {
            appendDir(dir.standardizedFileURL.path)
        }

        for candidate in paths.claudeCodeBinaryCandidates {
            let dir = candidate.deletingLastPathComponent().standardizedFileURL.path
            if fileManager.fileExists(atPath: dir) {
                appendDir(dir)
            }
        }
        for dir in paths.nodeManagerBinaryDirectories(fileManager: fileManager) {
            appendDir(dir.standardizedFileURL.path)
        }
        for dir in paths.systemBinaryDirectories {
            appendDir(dir.standardizedFileURL.path)
        }
        if let existingPATH = baseEnvironment["PATH"] {
            for component in existingPATH.split(separator: ":") {
                appendDir(String(component))
            }
        }
        for standardDir in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            appendDir(standardDir)
        }

        env["PATH"] = pathEntries.joined(separator: ":")
        return env
    }

    /// Registers through the `claude` CLI first, with expanded discovery, a
    /// GUI-safe `PATH`, and already-exists repair. Only when the CLI cannot
    /// execute (binary not found or exit 126/127 — never on a hung CLI or a
    /// deliberate policy/validation refusal) and an existing, readable
    /// `~/.claude.json` is present, falls back to an atomic `0o600` JSON merge
    /// of `mcpServers.transcripted` with a concurrent-change check and a single
    /// rotating backup inside Application Support.
    static func connectClaudeCode(
        helperCommandPath: String,
        paths: AgentMCPConnectorPaths,
        fileManager: FileManager,
        cliTimeout: TimeInterval
    ) throws {
        guard let resolution = resolveClaudeCodeBinary(
            paths: paths,
            fileManager: fileManager,
            allowLoginShellLookup: true
        ) else {
            if mergeClaudeCodeUserConfigIfSafelyWritable(
                helperCommandPath: helperCommandPath,
                paths: paths,
                fileManager: fileManager
            ) {
                return
            }
            throw AgentMCPConnectorError.agentCLINotFound(.claudeCode)
        }
        let binary = resolution.executable

        let environment = claudeCodeCLIEnvironment(
            for: binary,
            paths: paths,
            additionalPATHDirectories: resolution.loginShellPATHDirectories,
            fileManager: fileManager
        )
        let workingDirectory: URL? = fileManager.fileExists(atPath: paths.homeDirectory.path)
            ? paths.homeDirectory
            : nil

        // `mcp add` fails when the name already exists; remove first so
        // reconnect after an app move or helper path change stays one click.
        _ = try? runCLI(
            binary,
            arguments: ["mcp", "remove", "--scope", "user", serverName],
            environment: environment,
            currentDirectoryURL: workingDirectory,
            timeout: cliTimeout
        )

        var result = try runCLI(
            binary,
            arguments: ["mcp", "add", "--scope", "user", serverName, helperCommandPath],
            environment: environment,
            currentDirectoryURL: workingDirectory,
            timeout: cliTimeout
        )

        if result.status != 0, outputIndicatesAlreadyExists(result.output) {
            // Older or differently scoped registrations may ignore `--scope user`
            // on remove; try removing without a scope flag and retry add once.
            _ = try? runCLI(
                binary,
                arguments: ["mcp", "remove", serverName],
                environment: environment,
                currentDirectoryURL: workingDirectory,
                timeout: cliTimeout
            )
            result = try runCLI(
                binary,
                arguments: ["mcp", "add", "--scope", "user", serverName, helperCommandPath],
                environment: environment,
                currentDirectoryURL: workingDirectory,
                timeout: cliTimeout
            )
        }

        guard result.status == 0 else {
            if cliExitIndicatesCannotExecute(result.status),
               mergeClaudeCodeUserConfigIfSafelyWritable(
                helperCommandPath: helperCommandPath,
                paths: paths,
                fileManager: fileManager
            ) {
                return
            }
            throw AgentMCPConnectorError.agentCLIFailed(.claudeCode, status: result.status, output: result.output)
        }
    }

    private static func cliExitIndicatesCannotExecute(_ status: Int32) -> Bool {
        status == 126 || status == 127
    }

    private static func outputIndicatesAlreadyExists(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("already exists")
            || lower.contains("already configured")
            || lower.contains("duplicate")
    }

    private struct ConfigFileSnapshot: Equatable {
        let size: Int64
        let mtimeSec: Int
        let mtimeNsec: Int
        let data: Data

        static func capture(at url: URL) -> ConfigFileSnapshot? {
            var st = stat()
            guard stat(url.path, &st) == 0,
                  (st.st_mode & S_IFMT) == S_IFREG,
                  let data = try? Data(contentsOf: url),
                  Int64(data.count) == Int64(st.st_size) else {
                return nil
            }
            return ConfigFileSnapshot(
                size: Int64(st.st_size),
                mtimeSec: st.st_mtimespec.tv_sec,
                mtimeNsec: st.st_mtimespec.tv_nsec,
                data: data
            )
        }
    }

    /// Safely updates `mcpServers.transcripted` in an existing, valid JSON
    /// `~/.claude.json` while preserving every other key, keeping a single
    /// rotating `0o600` backup inside Application Support, staging the update
    /// in a `0o600` temp file before rename, and aborting if `~/.claude.json`
    /// changed concurrently. Never creates `~/.claude.json` from scratch and
    /// never overwrites an unreadable/corrupt state file.
    static func mergeClaudeCodeUserConfigIfSafelyWritable(
        helperCommandPath: String,
        paths: AgentMCPConnectorPaths,
        fileManager: FileManager = .default,
        beforeCommit: (() -> Void)? = nil
    ) -> Bool {
        let configURL = paths.claudeCodeUserConfigURL.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: configURL.path),
              let initialSnapshot = ConfigFileSnapshot.capture(at: configURL),
              var root = (try? JSONSerialization.jsonObject(with: initialSnapshot.data)) as? [String: Any] else {
            return false
        }

        var servers: [String: Any]
        if let existingServers = root["mcpServers"] {
            guard let typedServers = existingServers as? [String: Any] else {
                return false
            }
            servers = typedServers
        } else {
            servers = [:]
        }

        servers[serverName] = [
            "type": "stdio",
            "command": helperCommandPath,
            "args": [String](),
        ]
        root["mcpServers"] = servers

        var stagedTempURL: URL?
        defer {
            if let stagedTempURL {
                _ = unlink(stagedTempURL.path)
            }
        }

        do {
            let encoded = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try writeRotatingClaudeCodeBackup(
                data: initialSnapshot.data,
                to: paths.claudeCodeFallbackBackupURL,
                fileManager: fileManager
            )
            let tempURL = try writeOwnerOnlyTempFile(
                data: encoded,
                in: configURL.deletingLastPathComponent(),
                prefix: configURL.lastPathComponent
            )
            stagedTempURL = tempURL

            beforeCommit?()

            // Re-verify size, mtime, and bytes immediately before rename so a
            // concurrent update from a running Claude Code is never lost.
            guard ConfigFileSnapshot.capture(at: configURL) == initialSnapshot else {
                return false
            }
            guard Darwin.rename(tempURL.path, configURL.path) == 0 else {
                return false
            }
            stagedTempURL = nil
        } catch {
            return false
        }

        return configuredCommandPath(inJSONConfigAt: configURL, fileManager: fileManager) == helperCommandPath
    }

    private static func writeRotatingClaudeCodeBackup(
        data: Data,
        to backupURL: URL,
        fileManager: FileManager
    ) throws {
        let backupDirectory = backupURL.deletingLastPathComponent()
        try fileManager.createPrivateDirectory(at: backupDirectory)
        let tempBackupURL = try writeOwnerOnlyTempFile(
            data: data,
            in: backupDirectory,
            prefix: backupURL.lastPathComponent
        )
        if Darwin.rename(tempBackupURL.path, backupURL.path) != 0 {
            let err = errno
            _ = unlink(tempBackupURL.path)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }

    /// Creates a unique temp file with `0o600` permissions from birth (no
    /// `0o644` window), writes all bytes, fsyncs, and closes it.
    private static func writeOwnerOnlyTempFile(
        data: Data,
        in directory: URL,
        prefix: String
    ) throws -> URL {
        let tempURL = directory.appendingPathComponent(
            ".\(prefix).tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var closed = false
        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var totalWritten = 0
                while totalWritten < rawBuffer.count {
                    let written = Darwin.write(
                        fd,
                        baseAddress.advanced(by: totalWritten),
                        rawBuffer.count - totalWritten
                    )
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    totalWritten += written
                }
            }
            _ = fchmod(fd, S_IRUSR | S_IWUSR)
            if fsync(fd) != 0, errno != ENOTSUP, errno != EINVAL {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if close(fd) != 0 {
                closed = true
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            closed = true
            return tempURL
        } catch {
            if !closed {
                _ = close(fd)
            }
            _ = unlink(tempURL.path)
            throw error
        }
    }

    static let loginShellPATHSentinel = "__TX__"

    static func parseLoginShellPATHOutput(_ rawOutput: String) -> [URL] {
        guard let range = rawOutput.range(of: loginShellPATHSentinel, options: .backwards) else {
            return []
        }
        let payload = String(rawOutput[range.upperBound...])
        return AgentMCPConnectorPaths.parsePATHDirectories(payload)
    }

    private static func resolveLoginShellPATHDirectories() -> [URL] {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"]
            .flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        let shellURL = URL(fileURLWithPath: shellPath, isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: shellURL.path) else { return [] }
        guard let output = try? BoundedProcessRunner.run(
            executable: shellURL,
            arguments: ["-lc", #"printf '__TX__%s' "$PATH""#],
            timeout: loginShellPATHLookupTimeout,
            pipeDrainTimeout: 1.0
        ), output.status == 0 else {
            return []
        }
        let rawOutput = String(decoding: output.stdoutData, as: UTF8.self)
        return parseLoginShellPATHOutput(rawOutput)
    }
}

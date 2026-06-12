import Foundation

func testAgentMCPConnector() {
    runSuite("AgentMCPConnector.codexConfigText — appends the server table to an existing config") {
        let existing = """
        model = "o4"

        [projects."/Users/me/code"]
        trust_level = "trusted"
        """

        let updated = (try? AgentMCPConnector.codexConfigText(
            updating: existing,
            commandPath: "/tmp/mcp/transcripted-mcp"
        )) ?? ""

        assertTrue(updated.hasPrefix(existing), "existing Codex config should be preserved byte for byte")
        assertTrue(
            updated.contains("[mcp_servers.transcripted]\ncommand = \"/tmp/mcp/transcripted-mcp\""),
            "Codex config should gain the Transcripted server table"
        )
        assertEqual(
            AgentMCPConnector.codexConfiguredCommandPath(inConfigText: updated),
            "/tmp/mcp/transcripted-mcp",
            "written Codex config should read back the same command path"
        )
    }

    runSuite("AgentMCPConnector.codexConfigText — replaces a stale command in place") {
        let existing = """
        [mcp_servers.transcripted]
        command = "/old/path/transcripted-mcp"
        startup_timeout_ms = 20000

        [mcp_servers.other]
        command = "/usr/local/bin/other-mcp"
        """

        let updated = (try? AgentMCPConnector.codexConfigText(
            updating: existing,
            commandPath: "/new/path/transcripted-mcp"
        )) ?? ""

        assertEqual(
            AgentMCPConnector.codexConfiguredCommandPath(inConfigText: updated),
            "/new/path/transcripted-mcp",
            "stale command should be replaced"
        )
        assertTrue(
            updated.contains("startup_timeout_ms = 20000"),
            "other keys in the Transcripted table should be preserved"
        )
        assertTrue(
            updated.contains("command = \"/usr/local/bin/other-mcp\""),
            "other MCP servers should be preserved"
        )
        assertFalse(updated.contains("/old/path"), "stale path should be gone")
    }

    runSuite("AgentMCPConnector.codexConfigText — updates legal table header variants without appending duplicates") {
        let existing = """
        [ mcp_servers . "transcripted" ] # installed manually
        command = "/old/path/transcripted-mcp"
        startup_timeout_ms = 20000

        [mcp_servers.other]
        command = "/usr/local/bin/other-mcp"
        """

        let updated = (try? AgentMCPConnector.codexConfigText(
            updating: existing,
            commandPath: "/new/path/transcripted-mcp"
        )) ?? ""

        assertTrue(
            updated.contains(#"[ mcp_servers . "transcripted" ] # installed manually"#),
            "legal existing table header spelling should be preserved"
        )
        assertFalse(
            updated.contains("\n[mcp_servers.transcripted]\ncommand = \"/new/path/transcripted-mcp\"\n"),
            "connect should not append a duplicate canonical table when a legal variant exists"
        )
        assertEqual(
            AgentMCPConnector.codexConfiguredCommandPath(inConfigText: updated),
            "/new/path/transcripted-mcp",
            "legal table variants should read back through the normal connection check"
        )
        assertTrue(
            updated.contains("startup_timeout_ms = 20000"),
            "other keys in the legal table variant should survive"
        )
    }

    runSuite("AgentMCPConnector.codexConfigText — updates quoted command keys in existing table variants") {
        let existing = """
        ["mcp_servers"."transcripted"]
        "command" = "/old/path/transcripted-mcp"
        """

        let updated = (try? AgentMCPConnector.codexConfigText(
            updating: existing,
            commandPath: "/new/path/transcripted-mcp"
        )) ?? ""

        assertEqual(
            AgentMCPConnector.codexConfiguredCommandPath(inConfigText: updated),
            "/new/path/transcripted-mcp",
            "quoted TOML keys should be treated as the same Transcripted server command"
        )
        assertFalse(updated.contains(#""command" = "/old/path/transcripted-mcp""#), "stale quoted command should be replaced")
    }

    runSuite("AgentMCPConnector.codexConfigText — refuses duplicate logical Transcripted tables") {
        let existing = """
        [mcp_servers.transcripted]
        command = "/first/transcripted-mcp"

        [ "mcp_servers" . "transcripted" ]
        command = "/second/transcripted-mcp"
        """

        do {
            _ = try AgentMCPConnector.codexConfigText(updating: existing, commandPath: "/new/transcripted-mcp")
            assertTrue(false, "duplicate logical Transcripted tables should throw instead of rewriting one copy")
        } catch let error as AgentMCPConnectorError {
            assertEqual(
                error,
                .codexConfigHasDuplicateTranscriptedTables,
                "duplicate logical tables should use the dedicated safety error"
            )
        } catch {
            assertTrue(false, "unexpected error type: \(error)")
        }
    }

    runSuite("AgentMCPConnector.codexConfigText — starts a fresh config cleanly") {
        let updated = (try? AgentMCPConnector.codexConfigText(updating: "", commandPath: "/tmp/transcripted-mcp")) ?? ""

        assertEqual(
            updated,
            "[mcp_servers.transcripted]\ncommand = \"/tmp/transcripted-mcp\"\n",
            "fresh Codex config should contain only the Transcripted table"
        )
    }

    runSuite("AgentMCPConnector TOML strings — escape and round-trip awkward paths") {
        for path in [
            "/Users/me/Application Support/Transcripted/mcp/transcripted-mcp",
            #"/Users/me/we"ird/transcripted-mcp"#,
            "/Users/me/back\\slash/transcripted-mcp",
        ] {
            let quoted = AgentMCPConnector.tomlBasicString(path)
            assertEqual(
                AgentMCPConnector.tomlBasicStringValue(quoted),
                path,
                "TOML string should round-trip: \(path)"
            )

            let config = (try? AgentMCPConnector.codexConfigText(updating: "", commandPath: path)) ?? ""
            assertEqual(
                AgentMCPConnector.codexConfiguredCommandPath(inConfigText: config),
                path,
                "Codex config should round-trip: \(path)"
            )
        }
    }

    runSuite("AgentMCPConnector.codexConfigText — refuses inline mcp_servers instead of corrupting") {
        let existing = """
        model = "o4"
        mcp_servers = { other = { command = "/usr/local/bin/other-mcp" } }
        """

        do {
            _ = try AgentMCPConnector.codexConfigText(updating: existing, commandPath: "/tmp/transcripted-mcp")
            assertTrue(false, "inline mcp_servers should throw instead of appending a duplicate table")
        } catch let error as AgentMCPConnectorError {
            assertEqual(error, .codexConfigUsesInlineServers, "inline servers should raise the dedicated error")
        } catch {
            assertTrue(false, "unexpected error type: \(error)")
        }
    }

    runSuite("AgentMCPConnector.codexConfigText — refuses dotted Transcripted definitions instead of appending a conflicting table") {
        let existing = """
        model = "o4"
        mcp_servers.transcripted.command = "/old/transcripted-mcp"
        """

        do {
            _ = try AgentMCPConnector.codexConfigText(updating: existing, commandPath: "/tmp/transcripted-mcp")
            assertTrue(false, "dotted Transcripted server definitions should throw instead of appending a duplicate table")
        } catch let error as AgentMCPConnectorError {
            assertEqual(
                error,
                .codexConfigUsesUnsupportedTranscriptedServer,
                "dotted Transcripted definitions should use the unsupported-variant safety error"
            )
        } catch {
            assertTrue(false, "unexpected error type: \(error)")
        }
    }

    runSuite("AgentMCPConnector.codexConfigText — refuses inline Transcripted server inside mcp_servers table") {
        let existing = """
        [mcp_servers]
        transcripted = { command = "/old/transcripted-mcp" }
        """

        do {
            _ = try AgentMCPConnector.codexConfigText(updating: existing, commandPath: "/tmp/transcripted-mcp")
            assertTrue(false, "inline Transcripted server under [mcp_servers] should throw instead of appending a conflicting table")
        } catch let error as AgentMCPConnectorError {
            assertEqual(
                error,
                .codexConfigUsesUnsupportedTranscriptedServer,
                "inline Transcripted server under [mcp_servers] should use the unsupported-variant safety error"
            )
        } catch {
            assertTrue(false, "unexpected error type: \(error)")
        }
    }

    runSuite("AgentMCPConnector.codexConfigText — never touches keys that merely start with 'command'") {
        let existing = """
        [mcp_servers.transcripted]
        command_timeout_sec = 9
        command = "/old/transcripted-mcp"
        """

        let updated = (try? AgentMCPConnector.codexConfigText(
            updating: existing,
            commandPath: "/new/transcripted-mcp"
        )) ?? ""

        assertTrue(
            updated.contains("command_timeout_sec = 9"),
            "a command_timeout_sec key must survive the rewrite untouched"
        )
        assertEqual(
            AgentMCPConnector.codexConfiguredCommandPath(inConfigText: updated),
            "/new/transcripted-mcp",
            "the bare command key should be the one replaced"
        )
        assertFalse(updated.contains("/old/transcripted-mcp"), "stale command value should be gone")
    }

    runSuite("AgentMCPConnector.codexConfiguredCommandPath — skips command-prefixed keys when reading") {
        let config = """
        [mcp_servers.transcripted]
        command_timeout_sec = 9
        command = "/tmp/transcripted-mcp"
        """

        assertEqual(
            AgentMCPConnector.codexConfiguredCommandPath(inConfigText: config),
            "/tmp/transcripted-mcp",
            "reader should skip command_timeout_sec and return the bare command value"
        )
    }

    runSuite("AgentMCPConnector.codexConfiguredCommandPath — ignores command keys in subtables") {
        let config = """
        [mcp_servers.transcripted]
        command = "/tmp/transcripted-mcp"

        [mcp_servers.transcripted.env]
        command = "/should/not/be/read"
        """

        assertEqual(
            AgentMCPConnector.codexConfiguredCommandPath(inConfigText: config),
            "/tmp/transcripted-mcp",
            "subtable command keys must not shadow the main table entry"
        )
    }

    runSuite("AgentMCPConnector.connect(.claudeCode) — registers through the claude CLI") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeCodeConnectTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let paths = AgentMCPConnectorPaths(
            homeDirectory: tempRoot,
            applicationDirectories: [],
            systemBinaryDirectories: []
        )
        let binaryURL = tempRoot.appendingPathComponent(".claude/local/claude", isDirectory: false)
        let callLogURL = tempRoot.appendingPathComponent("cli-calls.log", isDirectory: false)

        try? FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fakeCLI = """
        #!/bin/sh
        echo "$@" >> "\(callLogURL.path)"
        exit 0
        """
        try? fakeCLI.write(to: binaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: binaryURL.path)

        do {
            try AgentMCPConnector.connect(.claudeCode, helperCommandPath: "/tmp/transcripted-mcp", paths: paths)
        } catch {
            assertTrue(false, "Claude Code connect should not throw with a working CLI: \(error)")
        }

        let calls = ((try? String(contentsOf: callLogURL, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .map(String.init)
        assertEqual(calls.count, 2, "connect should call the CLI twice: remove, then add")
        assertEqual(
            calls.first ?? "",
            "mcp remove --scope user transcripted",
            "stale registrations should be removed first so reconnect stays one click"
        )
        assertEqual(
            calls.last ?? "",
            "mcp add --scope user transcripted /tmp/transcripted-mcp",
            "the helper should be registered user-scope under the transcripted name"
        )
    }

    runSuite("AgentMCPConnector.connect(.claudeCode) — surfaces CLI failures and missing CLI") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeCodeFailTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let paths = AgentMCPConnectorPaths(
            homeDirectory: tempRoot,
            applicationDirectories: [],
            systemBinaryDirectories: []
        )

        do {
            try AgentMCPConnector.connect(.claudeCode, helperCommandPath: "/tmp/transcripted-mcp", paths: paths)
            assertTrue(false, "missing CLI should throw")
        } catch let error as AgentMCPConnectorError {
            assertEqual(error, .agentCLINotFound(.claudeCode), "missing CLI should raise agentCLINotFound")
        } catch {
            assertTrue(false, "unexpected error type: \(error)")
        }

        let binaryURL = tempRoot.appendingPathComponent(".claude/local/claude", isDirectory: false)
        try? FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let failingCLI = """
        #!/bin/sh
        if [ "$1" = "mcp" ] && [ "$2" = "add" ]; then
            echo "registration exploded" >&2
            exit 1
        fi
        exit 0
        """
        try? failingCLI.write(to: binaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: binaryURL.path)

        do {
            try AgentMCPConnector.connect(.claudeCode, helperCommandPath: "/tmp/transcripted-mcp", paths: paths)
            assertTrue(false, "failing CLI add should throw")
        } catch let error as AgentMCPConnectorError {
            assertTrue(
                error.errorDescription?.contains("registration exploded") == true,
                "CLI stderr should reach the user-facing error, got: \(String(describing: error.errorDescription))"
            )
        } catch {
            assertTrue(false, "unexpected error type: \(error)")
        }
    }

    runSuite("AgentMCPConnector.connect(.claudeCode) — times out a hung CLI instead of waiting forever") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeCodeHangTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let paths = AgentMCPConnectorPaths(
            homeDirectory: tempRoot,
            applicationDirectories: [],
            systemBinaryDirectories: []
        )
        let binaryURL = tempRoot.appendingPathComponent(".claude/local/claude", isDirectory: false)

        try? FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "#!/bin/sh\nsleep 30\n".write(to: binaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: binaryURL.path)

        let started = Date()
        do {
            try AgentMCPConnector.connect(
                .claudeCode,
                helperCommandPath: "/tmp/transcripted-mcp",
                paths: paths,
                cliTimeout: 0.4
            )
            assertTrue(false, "hung CLI should throw a timeout error")
        } catch let error as AgentMCPConnectorError {
            assertEqual(error, .agentCLITimedOut(.claudeCode), "hung CLI should raise agentCLITimedOut")
        } catch {
            assertTrue(false, "unexpected error type: \(error)")
        }

        // Two CLI calls (remove + add) at 0.4s each plus termination grace.
        assertTrue(
            Date().timeIntervalSince(started) < 10,
            "timeout should fire promptly instead of waiting out the full sleep"
        )
    }

    runSuite("AgentMCPConnector.connect(.codex) — surfaces an unwritable config directory as an error") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedCodexReadOnlyTests-\(UUID().uuidString)", isDirectory: true)
        let paths = AgentMCPConnectorPaths(homeDirectory: tempRoot, applicationDirectories: [])
        let codexDirectory = paths.codexConfigURL.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: codexDirectory.path)
            try? FileManager.default.removeItem(at: tempRoot)
        }

        try? FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try? "model = \"o4\"\n".write(to: paths.codexConfigURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: codexDirectory.path)

        do {
            try AgentMCPConnector.connect(.codex, helperCommandPath: "/tmp/transcripted-mcp", paths: paths)
            assertTrue(false, "read-only ~/.codex should throw instead of silently failing")
        } catch {
            assertFalse(
                error.localizedDescription.isEmpty,
                "read-only config failure should carry a user-facing message"
            )
        }

        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: codexDirectory.path)
        assertEqual(
            (try? String(contentsOf: paths.codexConfigURL, encoding: .utf8)) ?? "",
            "model = \"o4\"\n",
            "failed connect must leave the existing config untouched"
        )
    }

    runSuite("AgentMCPConnector.codexConfiguredCommandPath — tolerates CRLF configs") {
        let crlfConfig = "[mcp_servers.transcripted]\r\ncommand = \"/tmp/transcripted-mcp\"\r\n"

        assertEqual(
            AgentMCPConnector.codexConfiguredCommandPath(inConfigText: crlfConfig),
            "/tmp/transcripted-mcp",
            "CRLF line endings should not hide an existing Codex entry"
        )
    }

    runSuite("AgentMCPConnector.codexConfiguredCommandPath — tolerates command comments") {
        let config = """
        [mcp_servers.transcripted] # managed manually
        command = "/tmp/transcripted-mcp" # installed helper
        """

        assertEqual(
            AgentMCPConnector.codexConfiguredCommandPath(inConfigText: config),
            "/tmp/transcripted-mcp",
            "inline comments after a legal command value should not hide an existing Codex entry"
        )
    }

    runSuite("AgentMCPConnector.connect(.cursor) — writes and reads back the Cursor MCP config") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedCursorConnectTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let paths = AgentMCPConnectorPaths(homeDirectory: tempRoot, applicationDirectories: [])

        try? FileManager.default.createDirectory(at: paths.cursorConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = """
        {
          "mcpServers": {
            "notes": { "command": "/usr/local/bin/notes-mcp" }
          }
        }
        """
        try? existing.write(to: paths.cursorConfigURL, atomically: true, encoding: .utf8)

        assertFalse(
            AgentMCPConnector.isConnected(.cursor, helperCommandPath: "/tmp/transcripted-mcp", paths: paths),
            "Cursor should start unconnected"
        )

        do {
            try AgentMCPConnector.connect(.cursor, helperCommandPath: "/tmp/transcripted-mcp", paths: paths)
        } catch {
            assertTrue(false, "Cursor connect should not throw: \(error)")
        }

        assertTrue(
            AgentMCPConnector.isConnected(.cursor, helperCommandPath: "/tmp/transcripted-mcp", paths: paths),
            "Cursor should be connected after connect"
        )

        guard let data = try? Data(contentsOf: paths.cursorConfigURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else {
            assertTrue(false, "Cursor config should stay valid JSON")
            return
        }
        assertNotNil(servers["notes"], "existing Cursor MCP servers should be preserved")
    }

    runSuite("AgentMCPConnector.connect(.codex) — creates ~/.codex/config.toml when missing") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedCodexConnectTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let paths = AgentMCPConnectorPaths(homeDirectory: tempRoot, applicationDirectories: [])

        do {
            try AgentMCPConnector.connect(.codex, helperCommandPath: "/tmp/transcripted-mcp", paths: paths)
        } catch {
            assertTrue(false, "Codex connect should not throw: \(error)")
        }

        assertTrue(
            AgentMCPConnector.isConnected(.codex, helperCommandPath: "/tmp/transcripted-mcp", paths: paths),
            "Codex should be connected after connect"
        )
        assertFalse(
            AgentMCPConnector.isConnected(.codex, helperCommandPath: "/other/helper", paths: paths),
            "Codex connection state should be path-exact"
        )
    }

    runSuite("AgentMCPConnector.connect(.codex) — backs up existing config before editing") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedCodexBackupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let paths = AgentMCPConnectorPaths(homeDirectory: tempRoot, applicationDirectories: [])
        let existing = """
        model = "o4"

        [projects."/Users/me/code"]
        trust_level = "trusted"
        """

        try? FileManager.default.createDirectory(at: paths.codexConfigURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? existing.write(to: paths.codexConfigURL, atomically: true, encoding: .utf8)

        do {
            try AgentMCPConnector.connect(.codex, helperCommandPath: "/tmp/transcripted-mcp", paths: paths)
        } catch {
            assertTrue(false, "Codex connect should back up and edit a normal config: \(error)")
        }

        let configDirectory = paths.codexConfigURL.deletingLastPathComponent()
        let backupNames = ((try? FileManager.default.contentsOfDirectory(atPath: configDirectory.path)) ?? [])
            .filter { $0.hasPrefix("config.toml.backup-") }
            .sorted()
        assertEqual(backupNames.count, 1, "Codex connect should leave one backup for the pre-edit config")

        if let backupName = backupNames.first {
            let backupURL = configDirectory.appendingPathComponent(backupName, isDirectory: false)
            assertEqual(
                (try? String(contentsOf: backupURL, encoding: .utf8)) ?? "",
                existing,
                "Codex backup should preserve the exact original config text"
            )
        }

        assertEqual(
            AgentMCPConnector.codexConfiguredCommandPath(inConfigText: (try? String(contentsOf: paths.codexConfigURL, encoding: .utf8)) ?? ""),
            "/tmp/transcripted-mcp",
            "edited Codex config should still connect successfully"
        )
    }

    runSuite("AgentMCPConnector.isConnected(.claudeCode) — reads the user config without writing it") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeCodeStatusTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let paths = AgentMCPConnectorPaths(homeDirectory: tempRoot, applicationDirectories: [])

        assertFalse(
            AgentMCPConnector.isConnected(.claudeCode, helperCommandPath: "/tmp/transcripted-mcp", paths: paths),
            "missing ~/.claude.json should read as not connected"
        )

        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let config = """
        {
          "numStartups": 12,
          "mcpServers": {
            "transcripted": { "command": "/tmp/transcripted-mcp" }
          }
        }
        """
        try? config.write(to: paths.claudeCodeUserConfigURL, atomically: true, encoding: .utf8)

        assertTrue(
            AgentMCPConnector.isConnected(.claudeCode, helperCommandPath: "/tmp/transcripted-mcp", paths: paths),
            "user-scope Transcripted entry should read as connected"
        )
    }

    runSuite("AgentMCPConnector.isDetected — uses app bundles and state directories") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedAgentDetectTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let applicationsDirectory = tempRoot.appendingPathComponent("Applications", isDirectory: true)
        let paths = AgentMCPConnectorPaths(
            homeDirectory: tempRoot,
            applicationDirectories: [applicationsDirectory],
            systemBinaryDirectories: []
        )

        assertFalse(AgentMCPConnector.isDetected(.claudeDesktop, paths: paths), "no Claude.app means not detected")
        assertFalse(AgentMCPConnector.isDetected(.claudeCode, paths: paths), "no claude CLI or ~/.claude means not detected")
        assertFalse(AgentMCPConnector.isDetected(.codex, paths: paths), "no Codex install means not detected")
        assertFalse(AgentMCPConnector.isDetected(.cursor, paths: paths), "no Cursor install means not detected")

        try? FileManager.default.createDirectory(
            at: applicationsDirectory.appendingPathComponent("Claude.app", isDirectory: true),
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: paths.claudeCodeStateDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: paths.codexStateDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: paths.cursorStateDirectory,
            withIntermediateDirectories: true
        )

        assertTrue(AgentMCPConnector.isDetected(.claudeDesktop, paths: paths), "Claude.app should detect Claude Desktop")
        assertTrue(AgentMCPConnector.isDetected(.claudeCode, paths: paths), "~/.claude should detect Claude Code")
        assertTrue(AgentMCPConnector.isDetected(.codex, paths: paths), "~/.codex should detect Codex")
        assertTrue(AgentMCPConnector.isDetected(.cursor, paths: paths), "~/.cursor should detect Cursor")
    }

    runSuite("AgentMCPConnector.ensureHelperInstalled — installs and refreshes the shared helper") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedEnsureHelperTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let bundledBinaryURL = tempRoot.appendingPathComponent("bundle/transcripted-mcp", isDirectory: false)
        let installedBinaryURL = tempRoot.appendingPathComponent("mcp/transcripted-mcp", isDirectory: false)

        try? FileManager.default.createDirectory(at: bundledBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "#!/bin/sh\necho v2\n".write(to: bundledBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundledBinaryURL.path)

        let installed = try? AgentMCPConnector.ensureHelperInstalled(
            bundledBinaryURL: bundledBinaryURL,
            installedBinaryURL: installedBinaryURL
        )

        assertEqual(installed?.path, installedBinaryURL.path, "ensure should return the stable installed path")
        assertEqual(
            (try? String(contentsOf: installedBinaryURL, encoding: .utf8)) ?? "",
            "#!/bin/sh\necho v2\n",
            "ensure should install the bundled helper when missing"
        )

        try? "#!/bin/sh\necho v1\n".write(to: installedBinaryURL, atomically: true, encoding: .utf8)
        _ = try? AgentMCPConnector.ensureHelperInstalled(
            bundledBinaryURL: bundledBinaryURL,
            installedBinaryURL: installedBinaryURL
        )
        assertEqual(
            (try? String(contentsOf: installedBinaryURL, encoding: .utf8)) ?? "",
            "#!/bin/sh\necho v2\n",
            "ensure should refresh a stale installed helper"
        )
    }
}

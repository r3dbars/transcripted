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

    runSuite("AgentMCPConnector.codexConfigText — refuses every alternate spelling of an existing server table") {
        let variants: [(label: String, config: String)] = [
            ("comment after header", "[mcp_servers.transcripted] # managed by transcripted\ncommand = \"/old/transcripted-mcp\"\n"),
            ("whitespace inside brackets", "[ mcp_servers.transcripted ]\ncommand = \"/old/transcripted-mcp\"\n"),
            ("quoted key", "[mcp_servers.\"transcripted\"]\ncommand = \"/old/transcripted-mcp\"\n"),
            ("literal-quoted key", "[mcp_servers.'transcripted']\ncommand = \"/old/transcripted-mcp\"\n"),
            ("array of tables", "[[mcp_servers.transcripted]]\ncommand = \"/old/transcripted-mcp\"\n"),
            ("sub-table header only", "[mcp_servers.transcripted.env]\nFOO = \"bar\"\n"),
            ("root dotted inline table", "mcp_servers.transcripted = { command = \"/old/transcripted-mcp\" }\n"),
            ("root dotted command key", "mcp_servers.transcripted.command = \"/old/transcripted-mcp\"\n"),
            ("root dotted quoted key", "mcp_servers.\"transcripted\".command = \"/old/transcripted-mcp\"\n"),
            ("assignment under [mcp_servers]", "[mcp_servers]\ntranscripted = { command = \"/old/transcripted-mcp\" }\n"),
        ]

        for variant in variants {
            do {
                _ = try AgentMCPConnector.codexConfigText(updating: variant.config, commandPath: "/tmp/transcripted-mcp")
                assertTrue(false, "\(variant.label) should throw instead of appending a duplicate table")
            } catch let error as AgentMCPConnectorError {
                assertEqual(
                    error,
                    .codexConfigDefinesServerInUnsupportedForm,
                    "\(variant.label) should raise the unsupported-form error"
                )
            } catch {
                assertTrue(false, "\(variant.label) raised an unexpected error type: \(error)")
            }
        }
    }

    runSuite("AgentMCPConnector.codexConfigText — refuses root-level dotted mcp_servers assignments") {
        let existing = "mcp_servers.other = { command = \"/usr/local/bin/other-mcp\" }\n"

        do {
            _ = try AgentMCPConnector.codexConfigText(updating: existing, commandPath: "/tmp/transcripted-mcp")
            assertTrue(false, "root dotted mcp_servers assignment should refuse instead of appending")
        } catch let error as AgentMCPConnectorError {
            assertEqual(error, .codexConfigUsesInlineServers, "dotted root assignment should reuse the inline-servers guidance")
        } catch {
            assertTrue(false, "unexpected error type: \(error)")
        }
    }

    runSuite("AgentMCPConnector.codexConfigText — still appends alongside other table-form servers") {
        for existing in [
            "[mcp_servers.other]\ncommand = \"/usr/local/bin/other-mcp\"\n",
            "[mcp_servers]\nother = { command = \"/usr/local/bin/other-mcp\" }\n",
        ] {
            let updated = (try? AgentMCPConnector.codexConfigText(
                updating: existing,
                commandPath: "/tmp/transcripted-mcp"
            )) ?? ""

            assertTrue(updated.hasPrefix(existing), "existing server entries should be preserved byte for byte")
            assertTrue(
                updated.contains("command = \"/usr/local/bin/other-mcp\""),
                "other MCP servers should survive the append"
            )
            assertEqual(
                AgentMCPConnector.codexConfiguredCommandPath(inConfigText: updated),
                "/tmp/transcripted-mcp",
                "appended table should read back the helper path"
            )
        }
    }

    runSuite("AgentMCPConnector.codexConfiguredCommandPath — reads alternate header spellings") {
        for config in [
            "[ mcp_servers.transcripted ]\ncommand = \"/tmp/transcripted-mcp\"\n",
            "[mcp_servers.\"transcripted\"] # managed elsewhere\ncommand = \"/tmp/transcripted-mcp\"\n",
        ] {
            assertEqual(
                AgentMCPConnector.codexConfiguredCommandPath(inConfigText: config),
                "/tmp/transcripted-mcp",
                "a hand-written header spelling should read as connected: \(config)"
            )
        }
    }

    runSuite("AgentMCPConnector.codexConfiguredCommandPath — ignores array-of-tables server entries") {
        let config = """
        [[mcp_servers.transcripted]]
        command = "/tmp/transcripted-mcp"
        """

        assertNil(
            AgentMCPConnector.codexConfiguredCommandPath(inConfigText: config),
            "array-of-tables entries are unsupported by connect and should not read as connected"
        )
    }

    runSuite("AgentMCPConnector.connect(.codex) — leaves a variant-spelled config untouched") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedCodexVariantTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let paths = AgentMCPConnectorPaths(homeDirectory: tempRoot, applicationDirectories: [])
        let codexDirectory = paths.codexConfigURL.deletingLastPathComponent()
        let existing = "[ mcp_servers.transcripted ]\ncommand = \"/old/transcripted-mcp\"\n"

        try? FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try? existing.write(to: paths.codexConfigURL, atomically: true, encoding: .utf8)

        do {
            try AgentMCPConnector.connect(.codex, helperCommandPath: "/tmp/transcripted-mcp", paths: paths)
            assertTrue(false, "variant-spelled server table should refuse to connect")
        } catch let error as AgentMCPConnectorError {
            assertEqual(error, .codexConfigDefinesServerInUnsupportedForm, "variant spelling should raise the unsupported-form error")
        } catch {
            assertTrue(false, "unexpected error type: \(error)")
        }

        assertEqual(
            (try? String(contentsOf: paths.codexConfigURL, encoding: .utf8)) ?? "",
            existing,
            "refused connect must leave the config untouched"
        )
        let leftoverBackups = ((try? FileManager.default.contentsOfDirectory(atPath: codexDirectory.path)) ?? [])
            .filter { $0.contains(".backup-") }
        assertEqual(leftoverBackups.count, 0, "refused connect should not leave backup files behind")
    }

    runSuite("AgentMCPConnector.connect(.codex) — backs up the existing config before the first write") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedCodexBackupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let paths = AgentMCPConnectorPaths(homeDirectory: tempRoot, applicationDirectories: [])
        let codexDirectory = paths.codexConfigURL.deletingLastPathComponent()

        try? FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try? "model = \"o4\"\n".write(to: paths.codexConfigURL, atomically: true, encoding: .utf8)

        do {
            try AgentMCPConnector.connect(.codex, helperCommandPath: "/tmp/transcripted-mcp", paths: paths)
        } catch {
            assertTrue(false, "Codex connect should not throw: \(error)")
        }

        func backupNames() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: codexDirectory.path)) ?? [])
                .filter { $0.hasPrefix("config.toml.backup-") }
        }

        let backups = backupNames()
        assertEqual(backups.count, 1, "modifying an existing Codex config should leave exactly one backup")
        if let backupName = backups.first {
            let backupURL = codexDirectory.appendingPathComponent(backupName, isDirectory: false)
            assertEqual(
                (try? String(contentsOf: backupURL, encoding: .utf8)) ?? "",
                "model = \"o4\"\n",
                "backup should preserve the pre-write config bytes"
            )
        }

        do {
            try AgentMCPConnector.connect(.codex, helperCommandPath: "/tmp/transcripted-mcp", paths: paths)
        } catch {
            assertTrue(false, "repeat Codex connect should not throw: \(error)")
        }
        assertEqual(backupNames().count, 1, "an unchanged reconnect should not pile up more backups")
    }

    runSuite("AgentMCPConnector.connect(.cursor) — surfaces the backup when an unreadable config is replaced") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedCursorRepairTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let paths = AgentMCPConnectorPaths(homeDirectory: tempRoot, applicationDirectories: [])

        try? FileManager.default.createDirectory(
            at: paths.cursorConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? "{ not json".write(to: paths.cursorConfigURL, atomically: true, encoding: .utf8)

        let result = try? AgentMCPConnector.connect(.cursor, helperCommandPath: "/tmp/transcripted-mcp", paths: paths)
        assertNotNil(result?.replacedConfigBackupURL, "replacing an unreadable config must surface the backup to callers")
        if let backupURL = result?.replacedConfigBackupURL {
            assertEqual(
                (try? String(contentsOf: backupURL, encoding: .utf8)) ?? "",
                "{ not json",
                "backup should preserve the unreadable config"
            )
        }
        assertTrue(
            AgentMCPConnector.isConnected(.cursor, helperCommandPath: "/tmp/transcripted-mcp", paths: paths),
            "Cursor should be connected after the repair"
        )

        let repeatResult = try? AgentMCPConnector.connect(.cursor, helperCommandPath: "/tmp/transcripted-mcp", paths: paths)
        assertNotNil(repeatResult, "reconnect over a valid config should succeed")
        assertNil(
            repeatResult?.replacedConfigBackupURL,
            "a readable config should connect without reporting a replacement backup"
        )
    }

    runSuite("AgentMCPConnector.replacedConfigNotice — names the agent, the backup file, and the loss") {
        let notice = AgentMCPConnector.replacedConfigNotice(
            for: .claudeDesktop,
            backupURL: URL(fileURLWithPath: "/cfg/claude_desktop_config.json.backup-2026-06-12T00-00-00Z")
        )

        assertTrue(notice.contains("Claude Desktop"), "notice should name the agent whose config was replaced")
        assertTrue(
            notice.contains("claude_desktop_config.json.backup-2026-06-12T00-00-00Z"),
            "notice should name the backup file so users can find it"
        )
        assertTrue(
            notice.lowercased().contains("re-add"),
            "notice should tell users their other MCP servers need re-adding"
        )
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

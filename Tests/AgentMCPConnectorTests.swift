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

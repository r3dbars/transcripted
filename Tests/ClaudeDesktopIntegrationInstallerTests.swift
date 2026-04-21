import Foundation

func testClaudeDesktopIntegrationInstaller() {
    runSuite("ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig — preserves existing MCP servers") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeConfigTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = """
        {
          "mcpServers": {
            "notes": {
              "command": "/usr/local/bin/notes-mcp"
            }
          },
          "globalShortcut": "disabled"
        }
        """
        try? existing.write(to: configURL, atomically: true, encoding: .utf8)

        let backupURL = try? ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig(
            commandPath: "/tmp/transcripted-mcp",
            configURL: configURL
        )
        assertNil(backupURL, "valid existing config should not be backed up")

        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let notes = servers["notes"] as? [String: Any],
              let transcripted = servers["transcripted"] as? [String: Any] else {
            assertTrue(false, "config should remain valid JSON with both MCP servers")
            return
        }

        assertEqual(root["globalShortcut"] as? String, "disabled", "top-level config should be preserved")
        assertEqual(notes["command"] as? String, "/usr/local/bin/notes-mcp", "other MCP server should be preserved")
        assertEqual(transcripted["command"] as? String, "/tmp/transcripted-mcp", "Transcripted command should be written")
    }

    runSuite("ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig — backs up invalid config") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeInvalidConfigTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "{ invalid json".write(to: configURL, atomically: true, encoding: .utf8)

        let backupURL = try? ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig(
            commandPath: "/tmp/transcripted-mcp",
            configURL: configURL
        )

        assertNotNil(backupURL, "invalid config should be backed up before writing a clean config")
        if let backupURL {
            assertTrue(FileManager.default.fileExists(atPath: backupURL.path), "backup file should exist")
        }

        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let transcripted = servers["transcripted"] as? [String: Any] else {
            assertTrue(false, "replacement config should be valid JSON")
            return
        }

        assertEqual(transcripted["command"] as? String, "/tmp/transcripted-mcp", "Transcripted command should be written after repair")
    }

    runSuite("ClaudeDesktopIntegrationInstaller.currentStatus — detects installed config") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeStatusTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let binaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: binaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "#!/bin/sh\nexit 0\n".write(to: binaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: binaryURL.path)
        _ = try? ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig(commandPath: binaryURL.path, configURL: configURL)

        let status = ClaudeDesktopIntegrationInstaller.currentStatus(
            configURL: configURL,
            installedBinaryURL: binaryURL,
            bundledBinaryURL: binaryURL
        )

        assertEqual(status.state, .installed, "matching executable and config should be installed")
        assertTrue(status.isInstalled, "installed convenience flag should be true")
        assertEqual(status.configuredCommandPath, binaryURL.path, "status should expose configured command")
    }
}

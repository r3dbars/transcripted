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

    runSuite("ClaudeDesktopIntegrationInstaller.configSnippet — emits parseable MCP config") {
        let commandPath = "Managed Helpers/transcripted-mcp"

        let snippet = ClaudeDesktopIntegrationInstaller.configSnippet(commandPath: commandPath)

        assertEqual(transcriptedCommandPath(inSnippet: snippet), commandPath, "snippet should decode to the requested helper command")
        assertEqual(mcpServerNames(inSnippet: snippet), ["transcripted"], "snippet should include only the Transcripted MCP server")
    }

    runSuite("ClaudeDesktopIntegrationInstaller.configSnippet — preserves command paths with spaces") {
        let commandPath = "Managed Helpers/Transcripted Direct Tools/transcripted-mcp"

        let snippet = ClaudeDesktopIntegrationInstaller.configSnippet(commandPath: commandPath)

        assertEqual(transcriptedCommandPath(inSnippet: snippet), commandPath, "snippet JSON should preserve spaces in helper paths")
    }

    runSuite("ClaudeDesktopIntegrationInstaller.configSnippet — escapes quoted and backslash paths") {
        let commandPath = #"Managed "Helpers"/Transcripted\Direct/transcripted-mcp"#

        let snippet = ClaudeDesktopIntegrationInstaller.configSnippet(commandPath: commandPath)

        assertEqual(transcriptedCommandPath(inSnippet: snippet), commandPath, "snippet JSON should escape quotes and backslashes without changing the path")
    }

    runSuite("ClaudeDesktopIntegrationInstaller.configSnippet — escapes newline paths") {
        let commandPath = "Managed Helpers/line\nbreak/transcripted-mcp"

        let snippet = ClaudeDesktopIntegrationInstaller.configSnippet(commandPath: commandPath)

        assertEqual(transcriptedCommandPath(inSnippet: snippet), commandPath, "snippet JSON should remain parseable when a path contains a newline")
    }

    runSuite("ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig — writes command paths with spaces") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeSpacedCommandConfigTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let commandPath = "Managed Helpers/Transcripted Direct Tools/transcripted-mcp"
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let backupURL = try? ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig(
            commandPath: commandPath,
            configURL: configURL
        )

        assertNil(backupURL, "fresh config with a spaced helper path should not create a backup")
        assertEqual(
            transcriptedCommandPath(inConfigAt: configURL),
            commandPath,
            "Claude config should preserve helper paths with spaces"
        )
    }

    runSuite("ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig — escapes quotes and backslashes") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeQuotedCommandConfigTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let commandPath = #"Managed "Helpers"/Transcripted\Direct/transcripted-mcp"#
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let backupURL = try? ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig(
            commandPath: commandPath,
            configURL: configURL
        )

        assertNil(backupURL, "fresh config with escaped helper characters should not create a backup")
        assertEqual(
            transcriptedCommandPath(inConfigAt: configURL),
            commandPath,
            "Claude config should escape quotes and backslashes without changing the helper path"
        )
    }

    runSuite("ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig — escapes newline command paths") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeNewlineCommandConfigTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let commandPath = "Managed Helpers/line\nbreak/transcripted-mcp"
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let backupURL = try? ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig(
            commandPath: commandPath,
            configURL: configURL
        )

        assertNil(backupURL, "fresh config with an escaped newline helper path should not create a backup")
        assertEqual(
            transcriptedCommandPath(inConfigAt: configURL),
            commandPath,
            "Claude config should remain parseable when the helper path contains a newline"
        )
    }

    runSuite("ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig — replaces stale Transcripted command safely") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeReplaceCommandConfigTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let commandPath = #"Managed "Helpers"/Transcripted Direct Tools/transcripted-mcp"#
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? """
        {
          "mcpServers": {
            "notes": {
              "command": "notes-helper"
            },
            "transcripted": {
              "command": "stale-helper"
            }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let backupURL = try? ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig(
            commandPath: commandPath,
            configURL: configURL
        )

        let servers = mcpServers(inConfigAt: configURL)
        let notes = servers?["notes"] as? [String: Any]
        assertNil(backupURL, "valid config with a stale Transcripted command should be repaired without backup")
        assertEqual(notes?["command"] as? String, "notes-helper", "repair should preserve unrelated MCP servers")
        assertEqual(
            transcriptedCommandPath(inConfigAt: configURL),
            commandPath,
            "repair should replace the stale Transcripted helper command with an escaped path"
        )
    }

    runSuite("ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig — creates missing config with secure permissions") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeFreshConfigTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let commandURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let backupURL = try? ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig(
            commandPath: commandURL.path,
            configURL: configURL
        )

        assertNil(backupURL, "fresh config should not create a backup")
        assertEqual(transcriptedCommandPath(inConfigAt: configURL), commandURL.path, "fresh config should point at the helper")
        let attributes = try? FileManager.default.attributesOfItem(atPath: configURL.path)
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue
        assertEqual(permissions, 0o600, "Claude config should be owner-readable and writable only")
    }

    runSuite("ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig — replaces malformed MCP server map") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeMalformedServersTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let commandURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? """
        {
          "mcpServers": ["not", "a", "map"],
          "globalShortcut": "disabled"
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let backupURL = try? ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig(
            commandPath: commandURL.path,
            configURL: configURL
        )

        assertNil(backupURL, "valid root config should be repaired without backup when only the MCP server map is malformed")
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any],
              let transcripted = servers["transcripted"] as? [String: Any] else {
            assertTrue(false, "config should be rewritten with an MCP server map")
            return
        }

        assertEqual(root["globalShortcut"] as? String, "disabled", "top-level config should survive MCP server map repair")
        assertEqual(transcripted["command"] as? String, commandURL.path, "Transcripted command should be written into the repaired server map")
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
        assertTrue(status.installedBinaryMatchesBundled, "installed helper should match bundled helper")
        assertEqual(status.configuredCommandPath, binaryURL.path, "status should expose configured command")
        assertNil(status.attentionMessage, "installed helper should not show a repair warning")
    }

    runSuite("ClaudeDesktopIntegrationInstaller.currentStatus — treats fresh helper-ready setup as not installed") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeFreshStatusTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: bundledBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "#!/bin/sh\nexit 0\n".write(to: bundledBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundledBinaryURL.path)

        let status = ClaudeDesktopIntegrationInstaller.currentStatus(
            configURL: configURL,
            installedBinaryURL: installedBinaryURL,
            bundledBinaryURL: bundledBinaryURL
        )

        assertEqual(status.state, .notInstalled, "fresh setup with bundled helper should invite install, not repair")
        assertFalse(status.isInstalled, "fresh setup should not be marked installed")
        assertTrue(status.bundledBinaryExists, "status should expose that the app can install direct tools")
        assertNil(status.configuredCommandPath, "fresh setup should not invent a configured command")
        assertNil(status.attentionMessage, "fresh setup should not show a repair warning")
    }

    runSuite("ClaudeDesktopIntegrationInstaller.currentStatus — prompts repair when config lacks Transcripted server") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeMissingServerStatusTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: installedBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bundledBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? """
        {
          "mcpServers": {
            "notes": {
              "command": "notes-helper"
            }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\nexit 0\n".write(to: installedBinaryURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\nexit 0\n".write(to: bundledBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: installedBinaryURL.path)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundledBinaryURL.path)

        let status = ClaudeDesktopIntegrationInstaller.currentStatus(
            configURL: configURL,
            installedBinaryURL: installedBinaryURL,
            bundledBinaryURL: bundledBinaryURL
        )

        assertEqual(status.state, .needsRepair, "config without Transcripted server should need repair")
        assertNil(status.configuredCommandPath, "status should not invent a command path when Transcripted server is absent")
        assertTrue(status.installedBinaryMatchesBundled, "matching helper should not be treated as stale")
        assertEqual(
            status.attentionMessage,
            "Claude Desktop points at another Transcripted helper. Repair will update the config.",
            "missing Transcripted server should use the config repair message"
        )
    }

    runSuite("ClaudeDesktopIntegrationInstaller.currentStatus — stays installed with extra Transcripted server fields") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeExtraServerFieldsStatusTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: installedBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bundledBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? """
        {
          "mcpServers": {
            "transcripted": {
              "args": ["--self-test"],
              "command": "\(installedBinaryURL.path)",
              "env": {
                "TRANSCRIPTED_DISABLE_FILE_LOGGER": "1"
              }
            }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\nexit 0\n".write(to: installedBinaryURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\nexit 0\n".write(to: bundledBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: installedBinaryURL.path)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundledBinaryURL.path)

        let status = ClaudeDesktopIntegrationInstaller.currentStatus(
            configURL: configURL,
            installedBinaryURL: installedBinaryURL,
            bundledBinaryURL: bundledBinaryURL
        )

        assertEqual(status.state, .installed, "extra server fields should not make a matching helper need repair")
        assertEqual(status.configuredCommandPath, installedBinaryURL.path, "status should still read the Transcripted command")
        assertNil(status.attentionMessage, "installed helper with extra fields should not show a repair warning")
    }

    runSuite("ClaudeDesktopIntegrationInstaller.currentStatus — repairs malformed MCP server map") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeMalformedServerMapStatusTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: installedBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bundledBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? #"{"mcpServers":["not","a","map"]}"#.write(to: configURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\nexit 0\n".write(to: installedBinaryURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\nexit 0\n".write(to: bundledBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: installedBinaryURL.path)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundledBinaryURL.path)

        let status = ClaudeDesktopIntegrationInstaller.currentStatus(
            configURL: configURL,
            installedBinaryURL: installedBinaryURL,
            bundledBinaryURL: bundledBinaryURL
        )

        assertEqual(status.state, .needsRepair, "valid config with malformed mcpServers should need repair")
        assertTrue(status.configIsReadable, "malformed server map should not be treated like unreadable JSON")
        assertNil(status.configuredCommandPath, "malformed server map should not invent a command")
        assertEqual(
            status.attentionMessage,
            "Claude Desktop points at another Transcripted helper. Repair will update the config.",
            "malformed server map should route users to config repair"
        )
    }

    runSuite("ClaudeDesktopIntegrationInstaller.currentStatus — repairs non-object Transcripted server") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeNonObjectServerStatusTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: installedBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bundledBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? #"{"mcpServers":{"transcripted":"helper"}}"#.write(to: configURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\nexit 0\n".write(to: installedBinaryURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\nexit 0\n".write(to: bundledBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: installedBinaryURL.path)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundledBinaryURL.path)

        let status = ClaudeDesktopIntegrationInstaller.currentStatus(
            configURL: configURL,
            installedBinaryURL: installedBinaryURL,
            bundledBinaryURL: bundledBinaryURL
        )

        assertEqual(status.state, .needsRepair, "non-object Transcripted server should need repair")
        assertNil(status.configuredCommandPath, "non-object Transcripted server should not decode a command")
        assertTrue(status.installedBinaryMatchesBundled, "matching helper should not be treated as stale")
        assertEqual(
            status.attentionMessage,
            "Claude Desktop points at another Transcripted helper. Repair will update the config.",
            "non-object Transcripted server should route users to config repair"
        )
    }

    runSuite("ClaudeDesktopIntegrationInstaller.currentStatus — repairs non-string command") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeNonStringCommandStatusTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: installedBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bundledBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? #"{"mcpServers":{"transcripted":{"command":["not","a","string"]}}}"#.write(to: configURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\nexit 0\n".write(to: installedBinaryURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\nexit 0\n".write(to: bundledBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: installedBinaryURL.path)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundledBinaryURL.path)

        let status = ClaudeDesktopIntegrationInstaller.currentStatus(
            configURL: configURL,
            installedBinaryURL: installedBinaryURL,
            bundledBinaryURL: bundledBinaryURL
        )

        assertEqual(status.state, .needsRepair, "non-string command should need config repair")
        assertNil(status.configuredCommandPath, "non-string command should not be exposed as a helper path")
        assertEqual(
            status.attentionMessage,
            "Claude Desktop points at another Transcripted helper. Repair will update the config.",
            "non-string command should route users to config repair"
        )
    }

    runSuite("ClaudeDesktopIntegrationInstaller.currentStatus — prompts repair when config is missing but helper exists") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeMissingConfigStatusTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: installedBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bundledBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "#!/bin/sh\nexit 0\n".write(to: installedBinaryURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\nexit 0\n".write(to: bundledBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: installedBinaryURL.path)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundledBinaryURL.path)

        let status = ClaudeDesktopIntegrationInstaller.currentStatus(
            configURL: configURL,
            installedBinaryURL: installedBinaryURL,
            bundledBinaryURL: bundledBinaryURL
        )

        assertEqual(status.state, .needsRepair, "missing Claude config with an installed helper should need repair")
        assertFalse(status.configExists, "status should expose the missing config")
        assertTrue(status.installedBinaryMatchesBundled, "matching helper should not be treated as stale")
        assertNotNil(status.attentionMessage, "missing config repair should be visible to the settings UI")
    }

    runSuite("ClaudeDesktopIntegrationInstaller.currentStatus — treats non-executable helper as missing") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeNonExecutableStatusTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: installedBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bundledBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "#!/bin/sh\nexit 0\n".write(to: installedBinaryURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\nexit 0\n".write(to: bundledBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: installedBinaryURL.path)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundledBinaryURL.path)
        _ = try? ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig(commandPath: installedBinaryURL.path, configURL: configURL)

        let status = ClaudeDesktopIntegrationInstaller.currentStatus(
            configURL: configURL,
            installedBinaryURL: installedBinaryURL,
            bundledBinaryURL: bundledBinaryURL
        )

        assertEqual(status.state, .needsRepair, "non-executable helper should need repair")
        assertFalse(status.installedBinaryExists, "non-executable helper should not count as installed")
        assertEqual(
            status.attentionMessage,
            "Claude Desktop direct tools are missing. Install will copy a fresh helper.",
            "non-executable helper should use the fresh-copy repair message"
        )
    }

    runSuite("ClaudeDesktopIntegrationInstaller.currentStatus — prioritizes unreadable config over stale helper") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeConfigPrecedenceTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: installedBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bundledBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "{ invalid json".write(to: configURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\nexit 0\n".write(to: installedBinaryURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\necho current\n".write(to: bundledBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: installedBinaryURL.path)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundledBinaryURL.path)

        let status = ClaudeDesktopIntegrationInstaller.currentStatus(
            configURL: configURL,
            installedBinaryURL: installedBinaryURL,
            bundledBinaryURL: bundledBinaryURL
        )

        assertEqual(status.state, .needsRepair, "unreadable config with stale helper should need repair")
        assertFalse(status.configIsReadable, "invalid config should be marked unreadable")
        assertFalse(status.installedBinaryMatchesBundled, "status should still expose stale helper details")
        assertEqual(
            status.attentionMessage,
            "Claude Desktop config is not readable JSON. Install will back it up and write a clean config.",
            "config repair should be the first visible action before helper replacement"
        )
    }

    runSuite("ClaudeDesktopIntegrationInstaller.currentStatus — detects stale installed helper") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeStaleHelperTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: installedBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bundledBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "#!/bin/sh\nexit 0\n".write(to: installedBinaryURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\necho current\n".write(to: bundledBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: installedBinaryURL.path)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundledBinaryURL.path)
        _ = try? ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig(commandPath: installedBinaryURL.path, configURL: configURL)

        let status = ClaudeDesktopIntegrationInstaller.currentStatus(
            configURL: configURL,
            installedBinaryURL: installedBinaryURL,
            bundledBinaryURL: bundledBinaryURL
        )

        assertEqual(status.state, .needsRepair, "stale installed helper should be repaired even when config points at it")
        assertFalse(status.installedBinaryMatchesBundled, "status should expose stale helper mismatch")
        assertEqual(
            status.attentionMessage,
            "Claude Desktop is using an older Transcripted helper. Update now to replace it.",
            "stale helper should have a direct user-facing repair reason"
        )
    }

    runSuite("ClaudeDesktopIntegrationInstaller.refreshInstalledHelperIfNeeded — replaces a stale installed helper") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeHelperRefreshTests-\(UUID().uuidString)", isDirectory: true)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: installedBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bundledBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "#!/bin/sh\nexit 0\n".write(to: installedBinaryURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\necho current\n".write(to: bundledBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: installedBinaryURL.path)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundledBinaryURL.path)

        let refreshed = try? ClaudeDesktopIntegrationInstaller.refreshInstalledHelperIfNeeded(
            bundledBinaryURL: bundledBinaryURL,
            installedBinaryURL: installedBinaryURL
        )

        assertEqual(refreshed, true, "stale installed helper should be refreshed at launch")
        assertEqual(
            (try? String(contentsOf: installedBinaryURL, encoding: .utf8)) ?? "",
            "#!/bin/sh\necho current\n",
            "refresh should copy the bundled helper bytes over the stale install"
        )
        assertTrue(
            FileManager.default.isExecutableFile(atPath: installedBinaryURL.path),
            "refreshed helper should stay executable"
        )
    }

    runSuite("ClaudeDesktopIntegrationInstaller.refreshInstalledHelperIfNeeded — leaves a current helper untouched") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeHelperFreshTests-\(UUID().uuidString)", isDirectory: true)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: installedBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bundledBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "#!/bin/sh\necho current\n".write(to: installedBinaryURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\necho current\n".write(to: bundledBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: installedBinaryURL.path)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundledBinaryURL.path)

        let refreshed = try? ClaudeDesktopIntegrationInstaller.refreshInstalledHelperIfNeeded(
            bundledBinaryURL: bundledBinaryURL,
            installedBinaryURL: installedBinaryURL
        )

        assertEqual(refreshed, false, "matching helper should not be rewritten on every launch")
    }

    runSuite("ClaudeDesktopIntegrationInstaller.refreshInstalledHelperIfNeeded — never installs fresh") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeHelperNoInstallTests-\(UUID().uuidString)", isDirectory: true)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: bundledBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "#!/bin/sh\necho current\n".write(to: bundledBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundledBinaryURL.path)

        let refreshed = try? ClaudeDesktopIntegrationInstaller.refreshInstalledHelperIfNeeded(
            bundledBinaryURL: bundledBinaryURL,
            installedBinaryURL: installedBinaryURL
        )

        assertEqual(refreshed, false, "refresh should not install a helper the user never set up")
        assertFalse(
            FileManager.default.fileExists(atPath: installedBinaryURL.path),
            "refresh must not create a new install without user consent"
        )
    }

    runSuite("ClaudeDesktopIntegrationInstaller.currentStatus — warns when bundled helper is missing") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeMissingBundleTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let status = ClaudeDesktopIntegrationInstaller.currentStatus(
            configURL: configURL,
            installedBinaryURL: installedBinaryURL,
            bundledBinaryURL: nil
        )

        assertEqual(
            status.attentionMessage,
            "This app build does not include Transcripted direct tools yet.",
            "missing bundled helper should explain that the current app build cannot install direct tools"
        )
    }

    runSuite("ClaudeDesktopIntegrationInstaller.currentStatus — warns before repairing unreadable config") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeUnreadableConfigStatusTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bundledBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "{ invalid json".write(to: configURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\nexit 0\n".write(to: bundledBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundledBinaryURL.path)

        let status = ClaudeDesktopIntegrationInstaller.currentStatus(
            configURL: configURL,
            installedBinaryURL: installedBinaryURL,
            bundledBinaryURL: bundledBinaryURL
        )

        assertFalse(status.configIsReadable, "invalid Claude Desktop config should be marked unreadable")
        assertEqual(
            status.attentionMessage,
            "Claude Desktop config is not readable JSON. Install will back it up and write a clean config.",
            "unreadable config should surface the backup-and-rewrite repair path"
        )
    }

    runSuite("ClaudeDesktopIntegrationInstaller.currentStatus — warns when installed helper is missing") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeMissingInstalledHelperTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: bundledBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "#!/bin/sh\nexit 0\n".write(to: bundledBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundledBinaryURL.path)
        _ = try? ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig(commandPath: installedBinaryURL.path, configURL: configURL)

        let status = ClaudeDesktopIntegrationInstaller.currentStatus(
            configURL: configURL,
            installedBinaryURL: installedBinaryURL,
            bundledBinaryURL: bundledBinaryURL
        )

        assertEqual(status.state, .needsRepair, "config pointing at a missing helper should need repair")
        assertEqual(
            status.attentionMessage,
            "Claude Desktop direct tools are missing. Install will copy a fresh helper.",
            "missing installed helper should explain that repair will copy a fresh binary"
        )
    }

    runSuite("ClaudeDesktopIntegrationInstaller.currentStatus — warns when config points elsewhere") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeWrongHelperStatusTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let otherBinaryURL = tempRoot
            .appendingPathComponent("other", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: installedBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: bundledBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "#!/bin/sh\nexit 0\n".write(to: installedBinaryURL, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\nexit 0\n".write(to: bundledBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: installedBinaryURL.path)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundledBinaryURL.path)
        _ = try? ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig(commandPath: otherBinaryURL.path, configURL: configURL)

        let status = ClaudeDesktopIntegrationInstaller.currentStatus(
            configURL: configURL,
            installedBinaryURL: installedBinaryURL,
            bundledBinaryURL: bundledBinaryURL
        )

        assertEqual(status.state, .needsRepair, "config pointing at another helper should need repair")
        assertTrue(status.installedBinaryMatchesBundled, "the installed helper itself can be current while config points elsewhere")
        assertEqual(
            status.attentionMessage,
            "Claude Desktop points at another Transcripted helper. Repair will update the config.",
            "wrong configured helper should explain that repair updates Claude Desktop config"
        )
    }

    runSuite("ClaudeDesktopIntegrationStatus.attentionMessage — stays quiet when installed") {
        let status = claudeDesktopStatusFixture(state: .installed)

        assertNil(status.attentionMessage, "installed Claude helper should not show a repair warning")
    }

    runSuite("ClaudeDesktopIntegrationStatus.attentionMessage — stays quiet before first install") {
        let status = claudeDesktopStatusFixture(
            state: .notInstalled,
            installedBinaryExists: false,
            configExists: false,
            configuredCommandPath: nil
        )

        assertNil(status.attentionMessage, "fresh setup should invite install without a warning banner")
    }

    runSuite("ClaudeDesktopIntegrationStatus.attentionMessage — prioritizes missing bundled helper") {
        let status = claudeDesktopStatusFixture(
            state: .needsRepair,
            bundledBinaryExists: false,
            installedBinaryMatchesBundled: false,
            configIsReadable: false
        )

        assertEqual(
            status.attentionMessage,
            "This app build does not include Transcripted direct tools yet.",
            "missing bundled helper should be the first visible blocker"
        )
    }

    runSuite("ClaudeDesktopIntegrationStatus.attentionMessage — prioritizes unreadable config before helper update") {
        let status = claudeDesktopStatusFixture(
            state: .needsRepair,
            installedBinaryExists: true,
            installedBinaryMatchesBundled: false,
            configExists: true,
            configIsReadable: false
        )

        assertEqual(
            status.attentionMessage,
            "Claude Desktop config is not readable JSON. Install will back it up and write a clean config.",
            "unreadable config should warn about backup before stale-helper repair"
        )
    }

    runSuite("ClaudeDesktopIntegrationInstaller.installForClaudeDesktop — copies helper, writes config, and reads self-test") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeInstallFlowTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? writeSelfTestHelper(to: bundledBinaryURL, stdout: """
        {"ok":true,"meetings_directory":"meetings","dictations_directory":"dictations","index_directory":"index","meeting_file_count":2,"dictation_file_count":3}
        """)

        do {
            let result = try ClaudeDesktopIntegrationInstaller.installForClaudeDesktop(
                bundledBinaryURL: bundledBinaryURL,
                installedBinaryURL: installedBinaryURL,
                configURL: configURL
            )

            assertTrue(FileManager.default.isExecutableFile(atPath: installedBinaryURL.path), "installed helper should be executable")
            assertTrue(
                FileManager.default.contentsEqual(atPath: bundledBinaryURL.path, andPath: installedBinaryURL.path),
                "installed helper should match the bundled helper"
            )
            assertNil(result.backupURL, "fresh config should not create a backup")
            assertEqual(result.selfTest.ok, true, "self-test should decode successful helper output")
            assertEqual(result.selfTest.meetingFileCount, 2, "meeting count should come from helper self-test")
            assertEqual(result.selfTest.dictationFileCount, 3, "dictation count should come from helper self-test")

            let commandPath = transcriptedCommandPath(inConfigAt: configURL)
            assertEqual(commandPath, installedBinaryURL.path, "Claude config should point at the installed helper")
        } catch {
            assertTrue(false, "install should succeed with an executable bundled helper: \(error)")
        }
    }

    runSuite("ClaudeDesktopIntegrationInstaller.installForClaudeDesktop — backs up invalid config during install") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeInstallBackupTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "{ invalid json".write(to: configURL, atomically: true, encoding: .utf8)
        try? writeSelfTestHelper(to: bundledBinaryURL, stdout: """
        {"ok":true,"meetings_directory":"meetings","dictations_directory":"dictations","index_directory":"index","meeting_file_count":0,"dictation_file_count":0}
        """)

        do {
            let result = try ClaudeDesktopIntegrationInstaller.installForClaudeDesktop(
                bundledBinaryURL: bundledBinaryURL,
                installedBinaryURL: installedBinaryURL,
                configURL: configURL
            )

            assertNotNil(result.backupURL, "invalid Claude config should be backed up during install")
            if let backupURL = result.backupURL,
               let backupContents = try? String(contentsOf: backupURL, encoding: .utf8) {
                assertEqual(backupContents, "{ invalid json", "backup should preserve the unreadable config")
            } else {
                assertTrue(false, "backup file should be readable")
            }
            assertEqual(transcriptedCommandPath(inConfigAt: configURL), installedBinaryURL.path, "repaired config should point at installed helper")
        } catch {
            assertTrue(false, "install should repair unreadable config after backing it up: \(error)")
        }
    }

    runSuite("ClaudeDesktopIntegrationInstaller.installForClaudeDesktop — preserves other MCP servers") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeInstallPreserveTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? """
        {
          "mcpServers": {
            "notes": {
              "command": "notes-helper"
            }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)
        try? writeSelfTestHelper(to: bundledBinaryURL, stdout: """
        {"ok":true,"meetings_directory":"meetings","dictations_directory":"dictations","index_directory":"index","meeting_file_count":1,"dictation_file_count":1}
        """)

        do {
            _ = try ClaudeDesktopIntegrationInstaller.installForClaudeDesktop(
                bundledBinaryURL: bundledBinaryURL,
                installedBinaryURL: installedBinaryURL,
                configURL: configURL
            )

            let servers = mcpServers(inConfigAt: configURL)
            let notes = servers?["notes"] as? [String: Any]
            assertEqual(notes?["command"] as? String, "notes-helper", "install should preserve existing MCP server entries")
            assertEqual(transcriptedCommandPath(inConfigAt: configURL), installedBinaryURL.path, "install should add Transcripted server entry")
        } catch {
            assertTrue(false, "install should preserve valid config while adding Transcripted: \(error)")
        }
    }

    runSuite("ClaudeDesktopIntegrationInstaller.installForClaudeDesktop — replaces stale installed helper") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeInstallStaleHelperTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: installedBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "#!/bin/sh\necho stale-helper\n".write(to: installedBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: installedBinaryURL.path)
        _ = try? ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig(commandPath: installedBinaryURL.path, configURL: configURL)
        try? writeSelfTestHelper(to: bundledBinaryURL, stdout: """
        {"ok":true,"meetings_directory":"meetings","dictations_directory":"dictations","index_directory":"index","meeting_file_count":4,"dictation_file_count":5}
        """)

        do {
            let result = try ClaudeDesktopIntegrationInstaller.installForClaudeDesktop(
                bundledBinaryURL: bundledBinaryURL,
                installedBinaryURL: installedBinaryURL,
                configURL: configURL
            )

            assertTrue(
                FileManager.default.contentsEqual(atPath: bundledBinaryURL.path, andPath: installedBinaryURL.path),
                "install should replace the stale helper with the bundled helper"
            )
            assertNil(result.backupURL, "valid config should not be backed up during helper update")
            assertEqual(result.selfTest.meetingFileCount, 4, "self-test should run against the replacement helper")
            assertEqual(result.selfTest.dictationFileCount, 5, "self-test should decode replacement helper output")
            assertEqual(transcriptedCommandPath(inConfigAt: configURL), installedBinaryURL.path, "config should keep pointing at the installed helper")
        } catch {
            assertTrue(false, "install should update a stale helper in place: \(error)")
        }
    }

    runSuite("ClaudeDesktopIntegrationInstaller.installForClaudeDesktop — repairs config pointing elsewhere") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeInstallWrongPathTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let otherBinaryURL = tempRoot
            .appendingPathComponent("other", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        _ = try? ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig(commandPath: otherBinaryURL.path, configURL: configURL)
        try? writeSelfTestHelper(to: bundledBinaryURL, stdout: """
        {"ok":true,"meetings_directory":"meetings","dictations_directory":"dictations","index_directory":"index","meeting_file_count":0,"dictation_file_count":1}
        """)

        do {
            let result = try ClaudeDesktopIntegrationInstaller.installForClaudeDesktop(
                bundledBinaryURL: bundledBinaryURL,
                installedBinaryURL: installedBinaryURL,
                configURL: configURL
            )

            assertNil(result.backupURL, "valid config pointing elsewhere should be rewritten without backup")
            assertEqual(transcriptedCommandPath(inConfigAt: configURL), installedBinaryURL.path, "repair should point Claude Desktop at the managed helper")
            assertTrue(FileManager.default.isExecutableFile(atPath: installedBinaryURL.path), "repair should install an executable helper")
        } catch {
            assertTrue(false, "install should repair a config pointing at another helper: \(error)")
        }
    }

    runSuite("ClaudeDesktopIntegrationInstaller.installForClaudeDesktop — rejects missing bundled helper without touching config") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeInstallMissingBundleTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        do {
            _ = try ClaudeDesktopIntegrationInstaller.installForClaudeDesktop(
                bundledBinaryURL: bundledBinaryURL,
                installedBinaryURL: installedBinaryURL,
                configURL: configURL
            )
            assertTrue(false, "install should reject a missing bundled helper")
        } catch let error as ClaudeDesktopIntegrationError {
            assertEqual(error, .bundledBinaryMissing(bundledBinaryURL), "missing bundled helper should be reported clearly")
            assertFalse(FileManager.default.fileExists(atPath: configURL.path), "failed install should not create Claude config")
            assertFalse(FileManager.default.fileExists(atPath: installedBinaryURL.path), "failed install should not create installed helper")
        } catch {
            assertTrue(false, "missing bundled helper should throw ClaudeDesktopIntegrationError: \(error)")
        }
    }

    runSuite("ClaudeDesktopIntegrationInstaller.installForClaudeDesktop — reports self-test failure") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeInstallSelfTestFailureTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? writeSelfTestHelper(to: bundledBinaryURL, stdout: "helper failed", exitCode: 7)

        do {
            _ = try ClaudeDesktopIntegrationInstaller.installForClaudeDesktop(
                bundledBinaryURL: bundledBinaryURL,
                installedBinaryURL: installedBinaryURL,
                configURL: configURL
            )
            assertTrue(false, "install should surface helper self-test failures")
        } catch let error as ClaudeDesktopIntegrationError {
            assertEqual(
                error,
                .selfTestFailed(status: 7, output: "helper failed\n"),
                "self-test failure should include exit status and helper output"
            )
            assertTrue(FileManager.default.isExecutableFile(atPath: installedBinaryURL.path), "failed self-test should still leave the copied helper for inspection")
            assertEqual(transcriptedCommandPath(inConfigAt: configURL), installedBinaryURL.path, "config should show which helper failed self-test")
        } catch {
            assertTrue(false, "self-test failure should throw ClaudeDesktopIntegrationError: \(error)")
        }
    }

    runSuite("ClaudeDesktopIntegrationInstaller.installForClaudeDesktop — reports unreadable self-test output") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeInstallUnreadableSelfTestTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? writeSelfTestHelper(to: bundledBinaryURL, stdout: "not json")

        do {
            _ = try ClaudeDesktopIntegrationInstaller.installForClaudeDesktop(
                bundledBinaryURL: bundledBinaryURL,
                installedBinaryURL: installedBinaryURL,
                configURL: configURL
            )
            assertTrue(false, "install should surface unreadable helper self-test output")
        } catch let error as ClaudeDesktopIntegrationError {
            assertEqual(
                error,
                .selfTestOutputUnreadable("not json\n"),
                "install should report unreadable self-test output from the copied helper"
            )
            assertEqual(
                error.errorDescription,
                "Transcripted direct tools ran, but the health check output could not be read.",
                "install should keep unreadable self-test output generic for users"
            )
            assertTrue(FileManager.default.isExecutableFile(atPath: installedBinaryURL.path), "failed self-test decode should leave the copied helper for inspection")
            assertEqual(transcriptedCommandPath(inConfigAt: configURL), installedBinaryURL.path, "config should show which helper produced unreadable self-test output")
        } catch {
            assertTrue(false, "unreadable self-test output should throw ClaudeDesktopIntegrationError: \(error)")
        }
    }

    runSuite("ClaudeDesktopIntegrationInstaller.runSelfTest — decodes successful helper output") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeSelfTestDecodeTests-\(UUID().uuidString)", isDirectory: true)
        let helperURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? writeSelfTestHelper(to: helperURL, stdout: """
        {"ok":true,"meetings_directory":"meetings","dictations_directory":"dictations","index_directory":"index","meeting_file_count":6,"dictation_file_count":7}
        """)

        do {
            let result = try ClaudeDesktopIntegrationInstaller.runSelfTest(binaryURL: helperURL)
            assertTrue(result.ok, "self-test ok flag should decode from helper JSON")
            assertEqual(result.meetingsDirectory, "meetings", "meeting directory should decode from snake-case helper JSON")
            assertEqual(result.dictationsDirectory, "dictations", "dictation directory should decode from snake-case helper JSON")
            assertEqual(result.indexDirectory, "index", "index directory should decode from snake-case helper JSON")
            assertEqual(result.meetingFileCount, 6, "meeting count should decode from helper JSON")
            assertEqual(result.dictationFileCount, 7, "dictation count should decode from helper JSON")
        } catch {
            assertTrue(false, "valid helper self-test JSON should decode: \(error)")
        }
    }

    runSuite("ClaudeDesktopIntegrationInstaller.runSelfTest — ignores stderr on successful helper output") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeSelfTestStderrSuccessTests-\(UUID().uuidString)", isDirectory: true)
        let helperURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? writeSelfTestHelper(
            to: helperURL,
            stdout: """
            {"ok":true,"meetings_directory":"meetings","dictations_directory":"dictations","index_directory":"index","meeting_file_count":1,"dictation_file_count":2}
            """,
            stderr: "diagnostic: helper checked local capture folders"
        )

        do {
            let result = try ClaudeDesktopIntegrationInstaller.runSelfTest(binaryURL: helperURL)
            assertEqual(result.meetingFileCount, 1, "successful stderr diagnostics should not poison JSON decoding")
            assertEqual(result.dictationFileCount, 2, "helper stdout should remain the self-test contract")
        } catch {
            assertTrue(false, "successful helper stderr output should be ignored: \(error)")
        }
    }

    runSuite("ClaudeDesktopIntegrationInstaller.runSelfTest — decodes current helper schema extras") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeSelfTestSchemaExtrasTests-\(UUID().uuidString)", isDirectory: true)
        let helperURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? writeSelfTestHelper(to: helperURL, stdout: """
        {"ok":true,"meetings_directory":"meetings","dictations_directory":"dictations","meeting_directories":["meetings","older-meetings"],"dictation_directories":["dictations"],"index_directory":"index","meeting_file_count":0,"dictation_file_count":0}
        """)

        do {
            let result = try ClaudeDesktopIntegrationInstaller.runSelfTest(binaryURL: helperURL)
            assertTrue(result.ok, "healthy helper output should be accepted")
            assertEqual(result.meetingsDirectory, "meetings", "primary meeting directory should still decode when helper emits directory arrays")
            assertEqual(result.dictationsDirectory, "dictations", "primary dictation directory should still decode when helper emits directory arrays")
            assertEqual(result.meetingFileCount, 0, "empty meeting libraries should be valid")
            assertEqual(result.dictationFileCount, 0, "empty dictation libraries should be valid")
        } catch {
            assertTrue(false, "current helper self-test schema should decode even with extra directory arrays: \(error)")
        }
    }

    runSuite("ClaudeDesktopIntegrationInstaller.runSelfTest — rejects unhealthy helper output") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeSelfTestUnhealthyTests-\(UUID().uuidString)", isDirectory: true)
        let helperURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let output = #"{"ok":false,"meetings_directory":"meetings","dictations_directory":"dictations","index_directory":"index","meeting_file_count":0,"dictation_file_count":0}"#
        try? writeSelfTestHelper(to: helperURL, stdout: output)

        do {
            _ = try ClaudeDesktopIntegrationInstaller.runSelfTest(binaryURL: helperURL)
            assertTrue(false, "self-test should reject a helper that reports ok=false")
        } catch let error as ClaudeDesktopIntegrationError {
            assertEqual(
                error,
                .selfTestReportedUnhealthy(output: "\(output)\n"),
                "ok=false self-test output should be reported as an unhealthy helper"
            )
            assertEqual(
                error.errorDescription,
                "Transcripted direct tools did not pass the local check.",
                "unhealthy self-test output should not expose raw helper JSON to users"
            )
        } catch {
            assertTrue(false, "unhealthy self-test output should throw ClaudeDesktopIntegrationError: \(error)")
        }
    }

    runSuite("ClaudeDesktopIntegrationInstaller.runSelfTest — preserves diagnostics for unhealthy helper output") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeSelfTestUnhealthyDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        let helperURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let output = #"{"ok":false,"meetings_directory":"meetings","dictations_directory":"dictations","index_directory":"index","meeting_file_count":1,"dictation_file_count":0}"#
        try? writeSelfTestHelper(to: helperURL, stdout: output, stderr: "diagnostic: index unavailable")

        do {
            _ = try ClaudeDesktopIntegrationInstaller.runSelfTest(binaryURL: helperURL)
            assertTrue(false, "self-test should reject unhealthy output even when the process exits successfully")
        } catch let error as ClaudeDesktopIntegrationError {
            assertEqual(
                error,
                .selfTestReportedUnhealthy(output: "\(output)\ndiagnostic: index unavailable\n"),
                "unhealthy self-test errors should keep helper diagnostics for debugging"
            )
        } catch {
            assertTrue(false, "unhealthy self-test output should throw ClaudeDesktopIntegrationError: \(error)")
        }
    }

    runSuite("ClaudeDesktopIntegrationInstaller.installForClaudeDesktop — reports unhealthy self-test output") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeInstallUnhealthySelfTestTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        let bundledBinaryURL = tempRoot
            .appendingPathComponent("bundle", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        let installedBinaryURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let output = #"{"ok":false,"meetings_directory":"meetings","dictations_directory":"dictations","index_directory":"index","meeting_file_count":0,"dictation_file_count":0}"#
        try? writeSelfTestHelper(to: bundledBinaryURL, stdout: output)

        do {
            _ = try ClaudeDesktopIntegrationInstaller.installForClaudeDesktop(
                bundledBinaryURL: bundledBinaryURL,
                installedBinaryURL: installedBinaryURL,
                configURL: configURL
            )
            assertTrue(false, "install should surface a helper self-test that reports ok=false")
        } catch let error as ClaudeDesktopIntegrationError {
            assertEqual(
                error,
                .selfTestReportedUnhealthy(output: "\(output)\n"),
                "install should report unhealthy self-test output from the copied helper"
            )
            assertTrue(FileManager.default.isExecutableFile(atPath: installedBinaryURL.path), "unhealthy self-test should leave the copied helper for inspection")
            assertEqual(transcriptedCommandPath(inConfigAt: configURL), installedBinaryURL.path, "config should show which helper reported an unhealthy self-test")
        } catch {
            assertTrue(false, "unhealthy install self-test output should throw ClaudeDesktopIntegrationError: \(error)")
        }
    }

    runSuite("ClaudeDesktopIntegrationInstaller.runSelfTest — rejects incomplete success payload") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeSelfTestIncompletePayloadTests-\(UUID().uuidString)", isDirectory: true)
        let helperURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? writeSelfTestHelper(to: helperURL, stdout: #"{"ok":true}"#)

        do {
            _ = try ClaudeDesktopIntegrationInstaller.runSelfTest(binaryURL: helperURL)
            assertTrue(false, "self-test should reject incomplete success JSON")
        } catch let error as ClaudeDesktopIntegrationError {
            assertEqual(
                error,
                .selfTestOutputUnreadable("{\"ok\":true}\n"),
                "partial self-test JSON should be reported as unreadable output"
            )
        } catch {
            assertTrue(false, "incomplete self-test output should throw ClaudeDesktopIntegrationError: \(error)")
        }
    }

    runSuite("ClaudeDesktopIntegrationInstaller.runSelfTest — rejects non-executable helper") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeSelfTestNonExecutableTests-\(UUID().uuidString)", isDirectory: true)
        let helperURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "#!/bin/sh\nexit 0\n".write(to: helperURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: helperURL.path)

        do {
            _ = try ClaudeDesktopIntegrationInstaller.runSelfTest(binaryURL: helperURL)
            assertTrue(false, "self-test should refuse to launch a non-executable helper")
        } catch let error as ClaudeDesktopIntegrationError {
            assertEqual(
                error,
                .installedBinaryNotExecutable(helperURL),
                "non-executable helper should be reported before launch"
            )
        } catch {
            assertTrue(false, "non-executable helper should throw ClaudeDesktopIntegrationError: \(error)")
        }
    }

    runSuite("ClaudeDesktopIntegrationInstaller.runSelfTest — includes stderr from failed helper") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeSelfTestFailureStderrTests-\(UUID().uuidString)", isDirectory: true)
        let helperURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? writeSelfTestHelper(
            to: helperURL,
            stdout: "stdout detail",
            stderr: "stderr detail",
            exitCode: 9
        )

        do {
            _ = try ClaudeDesktopIntegrationInstaller.runSelfTest(binaryURL: helperURL)
            assertTrue(false, "self-test should surface failed helper output")
        } catch let error as ClaudeDesktopIntegrationError {
            assertEqual(
                error,
                .selfTestFailed(status: 9, output: "stdout detail\nstderr detail\n"),
                "failed helper output should include stdout and stderr"
            )
            assertEqual(
                error.errorDescription,
                "stdout detail\nstderr detail",
                "user-facing self-test failure copy should trim combined helper output"
            )
        } catch {
            assertTrue(false, "failed helper should throw ClaudeDesktopIntegrationError: \(error)")
        }
    }

    runSuite("ClaudeDesktopIntegrationInstaller.runSelfTest — rejects unreadable success output") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeSelfTestUnreadableTests-\(UUID().uuidString)", isDirectory: true)
        let helperURL = tempRoot
            .appendingPathComponent("mcp", isDirectory: true)
            .appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? writeSelfTestHelper(to: helperURL, stdout: "not json")

        do {
            _ = try ClaudeDesktopIntegrationInstaller.runSelfTest(binaryURL: helperURL)
            assertTrue(false, "self-test should reject successful output that is not JSON")
        } catch let error as ClaudeDesktopIntegrationError {
            assertEqual(
                error,
                .selfTestOutputUnreadable("not json\n"),
                "unreadable self-test output should be reported separately from process failure"
            )
            assertEqual(
                error.errorDescription,
                "Transcripted direct tools ran, but the health check output could not be read.",
                "unreadable self-test output should keep user-facing error copy generic"
            )
        } catch {
            assertTrue(false, "unreadable self-test output should throw ClaudeDesktopIntegrationError: \(error)")
        }
    }

    runSuite("ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig — backs up non-object config") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeNonObjectConfigTests-\(UUID().uuidString)", isDirectory: true)
        let configURL = tempRoot
            .appendingPathComponent("Claude", isDirectory: true)
            .appendingPathComponent("claude_desktop_config.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? #"["not", "an", "object"]"#.write(to: configURL, atomically: true, encoding: .utf8)

        let backupURL = try? ClaudeDesktopIntegrationInstaller.writeClaudeDesktopConfig(
            commandPath: "/tmp/transcripted-mcp",
            configURL: configURL
        )

        assertNotNil(backupURL, "valid JSON with the wrong root type should be backed up before repair")
        if let backupURL,
           let backupContents = try? String(contentsOf: backupURL, encoding: .utf8) {
            assertEqual(backupContents, #"["not", "an", "object"]"#, "backup should preserve the non-object config")
        } else {
            assertTrue(false, "non-object config backup should be readable")
        }
        assertEqual(transcriptedCommandPath(inConfigAt: configURL), "/tmp/transcripted-mcp", "replacement config should contain the Transcripted helper")
    }

    runSuite("ClaudeDesktopIntegrationInstaller.bundledMCPBinaryURL — uses Helpers bundle location only") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedClaudeBundleTests-\(UUID().uuidString)", isDirectory: true)
        let appURL = tempRoot.appendingPathComponent("Transcripted.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let helpersURL = contentsURL.appendingPathComponent("Helpers", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let helperURL = helpersURL.appendingPathComponent("transcripted-mcp", isDirectory: false)
        let legacyResourceURL = resourcesURL.appendingPathComponent("transcripted-mcp", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try? FileManager.default.createDirectory(at: helpersURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try? """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>app.transcripted.test</string>
            <key>CFBundleName</key>
            <string>Transcripted</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
        </dict>
        </plist>
        """.write(to: contentsURL.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try? "#!/bin/sh\nexit 0\n".write(to: legacyResourceURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: legacyResourceURL.path)

        guard let bundle = Bundle(url: appURL) else {
            assertTrue(false, "test bundle should be loadable")
            return
        }

        let missingHelpersResult = ClaudeDesktopIntegrationInstaller.bundledMCPBinaryURL(
            bundle: bundle,
            fileManager: .default
        )
        assertNil(missingHelpersResult, "resource fallback should not be accepted")

        try? "#!/bin/sh\nexit 0\n".write(to: helperURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: helperURL.path)

        let helpersResult = ClaudeDesktopIntegrationInstaller.bundledMCPBinaryURL(
            bundle: bundle,
            fileManager: .default
        )
        assertEqual(helpersResult?.path, helperURL.path, "Helpers location should be accepted")
    }
}

private func writeSelfTestHelper(
    to url: URL,
    stdout: String,
    stderr: String = "",
    exitCode: Int = 0
) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var script = """
    #!/bin/sh
    cat <<'EOF'
    \(stdout)
    EOF

    """
    if !stderr.isEmpty {
        script += """
        cat >&2 <<'EOF'
        \(stderr)
        EOF

        """
    }
    script += """
    exit \(exitCode)
    """
    try script.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: url.path)
}

private func claudeDesktopStatusFixture(
    state: ClaudeDesktopIntegrationStatus.State,
    installedBinaryExists: Bool = true,
    bundledBinaryExists: Bool = true,
    installedBinaryMatchesBundled: Bool = true,
    configExists: Bool = true,
    configIsReadable: Bool = true,
    claudeDesktopLikelyInstalled: Bool = true,
    configuredCommandPath: String? = "managed-helper"
) -> ClaudeDesktopIntegrationStatus {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptedClaudeStatusFixture", isDirectory: true)
    return ClaudeDesktopIntegrationStatus(
        state: state,
        configURL: root.appendingPathComponent("claude_desktop_config.json", isDirectory: false),
        installedBinaryURL: root.appendingPathComponent("transcripted-mcp", isDirectory: false),
        bundledBinaryURL: root.appendingPathComponent("bundled-transcripted-mcp", isDirectory: false),
        configuredCommandPath: configuredCommandPath,
        installedBinaryExists: installedBinaryExists,
        bundledBinaryExists: bundledBinaryExists,
        installedBinaryMatchesBundled: installedBinaryMatchesBundled,
        configExists: configExists,
        configIsReadable: configIsReadable,
        claudeDesktopLikelyInstalled: claudeDesktopLikelyInstalled
    )
}

private func mcpServers(inConfigAt configURL: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: configURL),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return root["mcpServers"] as? [String: Any]
}

private func transcriptedCommandPath(inConfigAt configURL: URL) -> String? {
    let transcripted = mcpServers(inConfigAt: configURL)?["transcripted"] as? [String: Any]
    return transcripted?["command"] as? String
}

private func mcpServers(inSnippet snippet: String) -> [String: Any]? {
    guard let data = snippet.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return root["mcpServers"] as? [String: Any]
}

private func mcpServerNames(inSnippet snippet: String) -> [String] {
    mcpServers(inSnippet: snippet)?.keys.sorted() ?? []
}

private func transcriptedCommandPath(inSnippet snippet: String) -> String? {
    let transcripted = mcpServers(inSnippet: snippet)?["transcripted"] as? [String: Any]
    return transcripted?["command"] as? String
}

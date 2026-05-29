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
        assertTrue(status.installedBinaryMatchesBundled, "installed helper should match bundled helper")
        assertEqual(status.configuredCommandPath, binaryURL.path, "status should expose configured command")
        assertNil(status.attentionMessage, "installed helper should not show a repair warning")
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

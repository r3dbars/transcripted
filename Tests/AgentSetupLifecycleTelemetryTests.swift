import Foundation

func testAgentSetupLifecycleTelemetry() {
    runSuite("AgentSetupLifecycleTelemetry start outcomes distinguish retries and repairs") {
        assertEqual(
            AgentSetupLifecycleTelemetry.startOutcome(isRetry: false, priorStatus: .notInstalled),
            .started,
            "fresh installs should start as started"
        )
        assertEqual(
            AgentSetupLifecycleTelemetry.startOutcome(isRetry: false, priorStatus: .needsRepair),
            .resumed,
            "repair flows should register as resumed"
        )
        assertEqual(
            AgentSetupLifecycleTelemetry.startOutcome(isRetry: true, priorStatus: .needsRepair),
            .retried,
            "explicit retries should override prior repair state"
        )
    }

    runSuite("AgentSetupLifecycleTelemetry repair kinds stay coarse") {
        assertEqual(
            AgentSetupLifecycleTelemetry.repairKind(for: .notInstalled),
            .freshInstall,
            "missing setups should map to fresh_install"
        )
        assertEqual(
            AgentSetupLifecycleTelemetry.repairKind(for: .needsRepair),
            .repair,
            "broken setups should map to repair"
        )
        assertEqual(
            AgentSetupLifecycleTelemetry.repairKind(for: .ready),
            .connectOnly,
            "already-installed helpers should map to connect_only"
        )
        assertEqual(
            AgentSetupLifecycleTelemetry.repairKind(for: AgentMCPHelperInstallResult.Action.repair),
            .repair,
            "helper refresh actions should keep the same bounded repair taxonomy"
        )
    }

    runSuite("AgentSetupLifecycleTelemetry normalizes timeout failures to stalled") {
        let selfTestTimeout = ClaudeDesktopIntegrationError.selfTestTimedOut
        assertEqual(
            AgentSetupLifecycleTelemetry.failureKind(for: selfTestTimeout),
            "self_test_timed_out",
            "self-test timeouts should keep a bounded failure enum"
        )
        assertEqual(
            AgentSetupLifecycleTelemetry.failureOutcome(for: selfTestTimeout),
            .stalled,
            "self-test timeouts should count as stalled, not generic failed"
        )

        let cliTimeout = AgentMCPConnectorError.agentCLITimedOut(.claudeCode)
        assertEqual(
            AgentSetupLifecycleTelemetry.failureKind(for: cliTimeout),
            "agent_cli_timed_out",
            "CLI timeouts should keep a bounded failure enum"
        )
        assertEqual(
            AgentSetupLifecycleTelemetry.failureOutcome(for: cliTimeout),
            .stalled,
            "CLI timeouts should count as stalled"
        )

        let bundledMissing = ClaudeDesktopIntegrationError.bundledBinaryMissing(nil)
        assertEqual(
            AgentSetupLifecycleTelemetry.failureKind(for: bundledMissing),
            "bundled_helper_missing",
            "missing helpers should map to a stable failure enum"
        )
        assertEqual(
            AgentSetupLifecycleTelemetry.failureOutcome(for: bundledMissing),
            .failed,
            "non-timeout failures should stay generic failed"
        )
    }

    runSuite("AgentSetupLifecycleTelemetry treats connected agents with a missing helper as repair-needed") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSetupLifecycleTelemetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let homeDirectory = tempRoot.appendingPathComponent("home", isDirectory: true)
        let installedBinaryURL = tempRoot.appendingPathComponent("Transcripted/mcp/transcripted-mcp", isDirectory: false)
        let bundledBinaryURL = tempRoot.appendingPathComponent("bundle/transcripted-mcp", isDirectory: false)
        let paths = AgentMCPConnectorPaths(
            homeDirectory: homeDirectory,
            applicationDirectories: [],
            systemBinaryDirectories: []
        )
        let configURL = paths.cursorConfigURL

        try? FileManager.default.createDirectory(at: bundledBinaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "#!/bin/sh\necho bundled\n".write(to: bundledBinaryURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: bundledBinaryURL.path)
        _ = try? ClaudeDesktopIntegrationInstaller.writeMCPServersConfig(
            commandPath: installedBinaryURL.path,
            configURL: configURL,
            fileManager: .default
        )

        assertEqual(
            AgentSetupLifecycleTelemetry.priorStatus(
                for: .cursor,
                installedBinaryURL: installedBinaryURL,
                bundledBinaryURL: bundledBinaryURL,
                paths: paths,
                fileManager: .default
            ),
            .needsRepair,
            "a config that points at a missing helper should count as needs_repair"
        )
    }

    runSuite("AgentSetupLifecycleTelemetry treats an unrelated Claude config as a fresh install") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSetupClaudeFreshTelemetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configURL = tempRoot.appendingPathComponent("claude_desktop_config.json")
        let missingHelperURL = tempRoot.appendingPathComponent("transcripted-mcp")
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? """
        {
          "mcpServers": {
            "notes": { "command": "notes-helper" }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let claudeStatus = ClaudeDesktopIntegrationInstaller.currentStatus(
            configURL: configURL,
            installedBinaryURL: missingHelperURL,
            bundledBinaryURL: nil,
            fileManager: .default
        )
        assertEqual(
            claudeStatus.state,
            .needsRepair,
            "the install UI may still merge Transcripted into an existing Claude config"
        )

        let priorStatus = AgentSetupLifecycleTelemetry.priorStatus(
            for: .claudeDesktop,
            claudeDesktopStatus: claudeStatus,
            fileManager: .default
        )
        assertEqual(
            priorStatus,
            .notInstalled,
            "an unrelated readable Claude config should not count as a resumed Transcripted repair"
        )
        assertEqual(
            AgentSetupLifecycleTelemetry.repairKind(for: priorStatus),
            .freshInstall,
            "the first Transcripted install should stay in the fresh-install funnel"
        )
        assertEqual(
            AgentSetupLifecycleTelemetry.startOutcome(isRetry: false, priorStatus: priorStatus),
            .started,
            "the first Transcripted install should emit started, not resumed"
        )
    }

    runSuite("AgentSetupLifecycleTelemetry keeps malformed Claude setup in the repair funnel") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSetupClaudeRepairTelemetry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let configURL = tempRoot.appendingPathComponent("claude_desktop_config.json")
        let missingHelperURL = tempRoot.appendingPathComponent("transcripted-mcp")
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? #"{"mcpServers":["malformed"]}"#.write(
            to: configURL,
            atomically: true,
            encoding: .utf8
        )

        let claudeStatus = ClaudeDesktopIntegrationInstaller.currentStatus(
            configURL: configURL,
            installedBinaryURL: missingHelperURL,
            bundledBinaryURL: nil,
            fileManager: .default
        )
        let priorStatus = AgentSetupLifecycleTelemetry.priorStatus(
            for: .claudeDesktop,
            claudeDesktopStatus: claudeStatus,
            fileManager: .default
        )

        assertEqual(
            priorStatus,
            .needsRepair,
            "a malformed Claude MCP map should remain a repair instead of looking like a fresh install"
        )
        assertEqual(
            AgentSetupLifecycleTelemetry.repairKind(for: priorStatus),
            .repair,
            "malformed existing setup should retain the bounded repair taxonomy"
        )
    }
}

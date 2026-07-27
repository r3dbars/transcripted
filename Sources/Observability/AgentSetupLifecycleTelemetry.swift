import Foundation

enum AgentSetupLifecycleTelemetry {
    enum AgentTarget: String {
        case claudeDesktop = "claude_desktop"
        case claudeCode = "claude_code"
        case codex
        case cursor
    }

    enum SetupKind: String {
        case claudeDesktop = "claude_desktop"
        case claudeCode = "claude_code"
        case codexTools = "codex_tools"
        case cursor
    }

    enum Stage: String {
        case start
        case helperInstall = "helper_install"
        case agentConfig = "agent_config"
        case verification
        case finish
    }

    enum Outcome: String {
        case started
        case retried
        case resumed
        case advanced
        case verified
        case installed
        case stalled
        case failed
    }

    enum RepairKind: String {
        case freshInstall = "fresh_install"
        case repair
        case connectOnly = "connect_only"
    }

    static func priorStatus(
        for agent: AgentMCPAgent,
        helperCommandPath: String? = nil,
        installedBinaryURL: URL = ClaudeDesktopIntegrationInstaller.installedMCPBinaryURL,
        bundledBinaryURL: URL? = ClaudeDesktopIntegrationInstaller.bundledMCPBinaryURL(),
        paths: AgentMCPConnectorPaths = AgentMCPConnectorPaths(),
        fileManager: FileManager = .default
    ) -> ActivationTelemetry.AgentSetupPriorStatus {
        let expectedHelperPath = helperCommandPath ?? installedBinaryURL.path
        switch agent {
        case .claudeDesktop:
            switch ClaudeDesktopIntegrationInstaller.currentStatus(fileManager: fileManager).state {
            case .installed:
                return .installed
            case .needsRepair:
                return .needsRepair
            case .notInstalled:
                return .notInstalled
            }
        case .claudeCode, .codex, .cursor:
            let helperExists = fileManager.isExecutableFile(atPath: installedBinaryURL.path)
            let helperMatchesBundled: Bool
            if let bundledBinaryURL,
               fileManager.isExecutableFile(atPath: bundledBinaryURL.path) {
                helperMatchesBundled =
                    helperExists &&
                    fileManager.contentsEqual(atPath: installedBinaryURL.path, andPath: bundledBinaryURL.path)
            } else {
                helperMatchesBundled = helperExists
            }

            if AgentMCPConnector.configuredCommandPath(
                for: agent,
                paths: paths,
                fileManager: fileManager
            ) == expectedHelperPath {
                return helperExists && helperMatchesBundled ? .installed : .needsRepair
            }
            if helperExists {
                return .ready
            }
            return .notInstalled
        }
    }

    static func agentTarget(for agent: AgentMCPAgent) -> AgentTarget {
        switch agent {
        case .claudeDesktop:
            return .claudeDesktop
        case .claudeCode:
            return .claudeCode
        case .codex:
            return .codex
        case .cursor:
            return .cursor
        }
    }

    static func setupKind(for agent: AgentMCPAgent) -> SetupKind {
        switch agent {
        case .claudeDesktop:
            return .claudeDesktop
        case .claudeCode:
            return .claudeCode
        case .codex:
            return .codexTools
        case .cursor:
            return .cursor
        }
    }

    static func repairKind(for priorStatus: ActivationTelemetry.AgentSetupPriorStatus) -> RepairKind {
        switch priorStatus {
        case .needsRepair, .partial:
            return .repair
        case .installed, .ready:
            return .connectOnly
        case .notInstalled, .unknown:
            return .freshInstall
        }
    }

    static func startOutcome(
        isRetry: Bool,
        priorStatus: ActivationTelemetry.AgentSetupPriorStatus
    ) -> Outcome {
        if isRetry {
            return .retried
        }
        switch priorStatus {
        case .needsRepair, .partial:
            return .resumed
        case .installed, .notInstalled, .ready, .unknown:
            return .started
        }
    }

    static func failureKind(for error: Error) -> String {
        switch error {
        case ClaudeDesktopIntegrationError.bundledBinaryMissing:
            return "bundled_helper_missing"
        case ClaudeDesktopIntegrationError.installedBinaryNotExecutable:
            return "installed_helper_not_executable"
        case ClaudeDesktopIntegrationError.selfTestFailed:
            return "self_test_failed"
        case ClaudeDesktopIntegrationError.selfTestReportedUnhealthy:
            return "self_test_unhealthy"
        case ClaudeDesktopIntegrationError.selfTestOutputUnreadable:
            return "self_test_output_unreadable"
        case ClaudeDesktopIntegrationError.selfTestTimedOut:
            return "self_test_timed_out"
        case AgentMCPConnectorError.agentCLINotFound:
            return "agent_cli_not_found"
        case AgentMCPConnectorError.agentCLIFailed:
            return "agent_cli_failed"
        case AgentMCPConnectorError.agentCLITimedOut:
            return "agent_cli_timed_out"
        case AgentMCPConnectorError.codexConfigUsesInlineServers:
            return "codex_inline_servers_unsupported"
        case AgentMCPConnectorError.codexConfigDefinesServerInUnsupportedForm:
            return "codex_server_shape_unsupported"
        default:
            return "unknown"
        }
    }

    static func failureOutcome(for error: Error) -> Outcome {
        switch error {
        case ClaudeDesktopIntegrationError.selfTestTimedOut,
             AgentMCPConnectorError.agentCLITimedOut:
            return .stalled
        default:
            return .failed
        }
    }

    static func repairKind(for action: AgentMCPHelperInstallResult.Action) -> RepairKind? {
        switch action {
        case .unchanged:
            return nil
        case .freshInstall:
            return .freshInstall
        case .repair:
            return .repair
        }
    }

    static func track(
        agentTarget: AgentTarget,
        setupKind: SetupKind,
        surface: ActivationTelemetry.Surface,
        stage: Stage,
        outcome: Outcome,
        priorStatus: ActivationTelemetry.AgentSetupPriorStatus? = nil,
        repairKind: RepairKind? = nil,
        failureKind: String? = nil,
        durationSeconds: Double? = nil
    ) {
        var properties = [
            "agent_target": agentTarget.rawValue,
            "outcome": outcome.rawValue,
            "setup_kind": setupKind.rawValue,
            "stage": stage.rawValue,
            "surface": surface.rawValue,
        ]
        if let priorStatus {
            properties["prior_status"] = priorStatus.rawValue
        }
        if let repairKind {
            properties["repair_kind"] = repairKind.rawValue
        }
        if let failureKind {
            properties["failure_kind"] = failureKind
        }
        if let durationSeconds {
            properties["duration_bucket"] = AnalyticsReporter.durationBucket(seconds: max(0, durationSeconds))
        }

        AnalyticsReporter.track("agent_setup_lifecycle_observed", properties: properties)
    }
}

import Foundation

enum ActivationTelemetry {
    static let firstArtifactSavedTrackedKey = "activationFirstArtifactSavedTracked"

    enum ArtifactKind: String {
        case dictation
        case meeting
    }

    enum ArtifactActionKind: String {
        case openMarkdown = "open_markdown"
        case revealFolder = "reveal_folder"
        case preview
    }

    enum Surface: String {
        case onboarding
        case home
        case homeRow = "home_row"
        case homeMenu = "home_menu"
        case homePreview = "home_preview"
        case homeCurrentActivity = "home_current_activity"
        case agentSettings = "agent_settings"
        case meetingOverlay = "meeting_overlay"
        case dictationSave = "dictation_save"
        case meetingSave = "meeting_save"
    }

    enum WorkflowKind: String {
        case onboarding
        case betaModelPrep = "beta_model_prep"
        case localSummary = "local_summary"
        case speakerReview = "speaker_review"
        case agentSetup = "agent_setup"
        case meetingPrompt = "meeting_prompt"
        case failedMeetingRetry = "failed_meeting_retry"
        case artifactHandoff = "artifact_handoff"
    }

    enum WorkflowAbandonmentReasonKind: String {
        case blocked
        case cancelled
        case deleted
        case dismissed
        case failed
        case remindedLater = "reminded_later"
        case suppressed
        case unavailable
        case windowClosed = "window_closed"
    }

    enum AgentPromptKind: String {
        case localAgentPrompt = "local_agent_prompt"
        case claudeDesktopSetup = "claude_desktop_setup"
        case folderPaths = "folder_paths"
        case codexInboxSetup = "codex_inbox_setup"
        case liveMeetingCodexSetup = "live_meeting_codex_setup"
        case liveMeetingCoworkSetup = "live_meeting_cowork_setup"
        case liveMeetingPreview = "live_meeting_preview"
        case meetingBundle = "meeting_bundle"
        case meetingMarkdown = "meeting_markdown"
    }

    enum AgentTarget: String {
        case claudeDesktop = "claude_desktop"
        case claudeCode = "claude_code"
        case codex
        case cowork
        case cursor
        case fallbackFolder = "fallback_folder"
        case localAgent = "local_agent"
    }

    enum AgentPromptActionKind: String {
        case copied
        case opened
    }

    enum AgentPromptResult: String {
        case success
        case fallbackCopied = "fallback_copied"
        case failed
    }

    enum AgentSetupKind: String {
        case claudeDesktop = "claude_desktop"
        case claudeCode = "claude_code"
        case codexInbox = "codex_inbox"
        case codexTools = "codex_tools"
        case cursor
        case livePreview = "live_preview"
        case liveSidecar = "live_sidecar"
        case localPrompt = "local_prompt"
    }

    enum AgentSetupPriorStatus: String {
        case installed
        case needsRepair = "needs_repair"
        case notInstalled = "not_installed"
        case partial
        case ready
        case unknown
    }

    enum AgentSetupResult: String {
        case fallbackCopied = "fallback_copied"
        case failed
        case success
    }

    static func trackArtifactAction(
        artifactKind: ArtifactKind,
        actionKind: ArtifactActionKind,
        surface: Surface,
        artifactDate: Date? = nil,
        now: Date = Date()
    ) {
        AnalyticsReporter.track(
            "activation_artifact_action_clicked",
            properties: [
                "action_kind": actionKind.rawValue,
                "artifact_age_bucket": artifactAgeBucket(since: artifactDate, now: now),
                "artifact_kind": artifactKind.rawValue,
                "surface": surface.rawValue,
            ]
        )
    }

    @discardableResult
    static func markFirstArtifactSavedTrackedIfNeeded(userDefaults: UserDefaults = .standard) -> Bool {
        guard !userDefaults.bool(forKey: firstArtifactSavedTrackedKey) else { return false }

        userDefaults.set(true, forKey: firstArtifactSavedTrackedKey)
        return true
    }

    @discardableResult
    static func trackFirstArtifactSavedIfNeeded(
        artifactKind: ArtifactKind,
        surface: Surface,
        trigger: String,
        wordCountBucket: String? = nil,
        durationBucket: String? = nil,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        guard markFirstArtifactSavedTrackedIfNeeded(userDefaults: userDefaults) else {
            return false
        }

        var properties = [
            "artifact_kind": artifactKind.rawValue,
            "surface": surface.rawValue,
            "trigger": trigger,
        ]
        if let wordCountBucket {
            properties["word_count_bucket"] = wordCountBucket
        }
        if let durationBucket {
            properties["duration_bucket"] = durationBucket
        }

        AnalyticsReporter.track("activation_first_artifact_saved", properties: properties)
        return true
    }

    static func trackAgentPromptAction(
        promptKind: AgentPromptKind,
        actionKind: AgentPromptActionKind,
        agentTarget: AgentTarget,
        surface: Surface,
        result: AgentPromptResult = .success,
        artifactKind: ArtifactKind? = nil
    ) {
        var properties = [
            "action_kind": actionKind.rawValue,
            "agent_target": agentTarget.rawValue,
            "prompt_kind": promptKind.rawValue,
            "result": result.rawValue,
            "surface": surface.rawValue,
        ]
        if let artifactKind {
            properties["artifact_kind"] = artifactKind.rawValue
        }

        AnalyticsReporter.track("activation_agent_prompt_action_clicked", properties: properties)

        if result == .failed {
            trackWorkflowAbandoned(
                workflowKind: .artifactHandoff,
                stage: promptKind.rawValue,
                reasonKind: .failed,
                surface: surface,
                priorReadyState: agentTarget.rawValue
            )
        }
    }

    static func trackAgentSetupCTA(
        setupKind: AgentSetupKind,
        agentTarget: AgentTarget,
        surface: Surface,
        priorStatus: AgentSetupPriorStatus = .unknown,
        result: AgentSetupResult = .success
    ) {
        AnalyticsReporter.track(
            "activation_agent_setup_cta_clicked",
            properties: [
                "agent_target": agentTarget.rawValue,
                "prior_status": priorStatus.rawValue,
                "result": result.rawValue,
                "setup_kind": setupKind.rawValue,
                "surface": surface.rawValue,
            ]
        )

        if result == .failed {
            trackWorkflowAbandoned(
                workflowKind: .agentSetup,
                stage: setupKind.rawValue,
                reasonKind: .failed,
                surface: surface,
                priorReadyState: priorStatus.rawValue
            )
        }
    }

    static func trackWorkflowAbandoned(
        workflowKind: WorkflowKind,
        stage: String,
        reasonKind: WorkflowAbandonmentReasonKind,
        surface: Surface,
        elapsedBucket: String? = nil,
        priorReadyState: String? = nil
    ) {
        var properties = [
            "elapsed_bucket": elapsedBucket ?? "unknown",
            "reason_kind": reasonKind.rawValue,
            "stage": stage,
            "surface": surface.rawValue,
            "workflow_kind": workflowKind.rawValue,
        ]
        if let priorReadyState {
            properties["prior_ready_state"] = priorReadyState
        }

        AnalyticsReporter.track("workflow_abandoned", properties: properties)
    }

    @discardableResult
    static func trackReturnProxyIfEligible(
        priorArtifactKind: ArtifactKind,
        priorArtifactDate: Date,
        surface: Surface,
        now: Date = Date()
    ) -> Bool {
        guard let returnWindowBucket = returnWindowBucket(since: priorArtifactDate, now: now) else {
            return false
        }

        AnalyticsReporter.track(
            "activation_return_proxy_observed",
            properties: [
                "prior_artifact_kind": priorArtifactKind.rawValue,
                "proxy_kind": "home_recent_artifact",
                "return_window_bucket": returnWindowBucket,
                "surface": surface.rawValue,
            ]
        )
        return true
    }

    static func artifactAgeBucket(since date: Date?, now: Date = Date()) -> String {
        guard let date else { return "unknown" }
        let hours = max(0, now.timeIntervalSince(date)) / 3_600

        switch hours {
        case ..<12:
            return "lt_12h"
        case ..<24:
            return "12_24h"
        case ..<48:
            return "24_48h"
        case ..<168:
            return "2_7d"
        default:
            return "older"
        }
    }

    static func returnWindowBucket(since date: Date, now: Date = Date()) -> String? {
        let hours = max(0, now.timeIntervalSince(date)) / 3_600

        switch hours {
        case ..<18:
            return nil
        case ..<36:
            return "18_36h"
        case ..<72:
            return "36_72h"
        case ..<168:
            return "3_7d"
        default:
            return "older"
        }
    }
}

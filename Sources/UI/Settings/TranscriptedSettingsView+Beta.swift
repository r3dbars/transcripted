import AppKit
import SwiftUI

extension TranscriptedSettingsView {
    var betaPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Beta",
                summary: "Turn on experimental local features when you want to test them."
            )

            SettingsSection(
                title: "Experimental Features",
                detail: "These are off by default. Nothing runs automatically unless you turn it on here."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsToggleRow(
                        title: "AI meeting summaries",
                        detail: localMeetingSummariesEnabled
                            ? "On. Transcripted may prepare Gemma now; meeting summaries still run only when you choose Run AI summary."
                            : "Create private meeting summaries on this Mac. Turning this on may download or warm Gemma before your first summary.",
                        isOn: Binding(
                            get: { localMeetingSummariesEnabled },
                            set: { enabled in
                                localMeetingSummariesEnabled = enabled
                                LocalMeetingSummaryPreferences.setEnabled(enabled)
                                trackSettingsToggle("local_ai_meeting_summaries", enabled: enabled, page: .beta)
                                handleLocalMeetingSummaryToggle(enabled)
                            }
                        ),
                        help: "Opt in to local meeting summaries on Home.",
                        automationIdentifier: "transcripted.settings.beta.ai-meeting-summaries"
                    )

                    Picker("Summary provider", selection: Binding(
                        get: { localMeetingSummaryProvider },
                        set: { provider in
                            localMeetingSummaryProviderRawValue = provider.rawValue
                            LocalMeetingSummaryPreferences.setProvider(provider)
                            trackSettingsToggle("local_ai_meeting_summary_provider_\(provider.rawValue)", enabled: true, page: .beta)
                            refreshLocalSummarySetupStatus()
                            if localMeetingSummariesEnabled {
                                cancelLocalSummaryJobs()
                                clearHomeLocalSummaryNotice()
                                cancelLocalSummaryModelPreparation()
                                localSummaryModelPreparationStatus = nil
                                prepareLocalSummaryModelFromBeta()
                            }
                        }
                    )) {
                        ForEach(LocalMeetingSummaryProvider.allCases, id: \.self) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isLocalSummaryModelPreparing)
                    .help(isLocalSummaryModelPreparing
                        ? "Finish or cancel the current model setup before switching providers."
                        : "")

                    Text(localMeetingSummaryProvider.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    betaLocalSummarySetupStatus
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    SettingsToggleRow(
                        title: "Live meeting sidecar",
                        detail: betaLiveMeetingCodexEnabled
                            ? "On. Transcripted prepares a local folder that Codex or Claude Cowork can watch during active meetings."
                            : "Let Codex or Claude Cowork follow an active meeting through a local sidecar folder.",
                        isOn: Binding(
                            get: { betaLiveMeetingCodexEnabled },
                            set: { enabled in
                                betaLiveMeetingCodexEnabled = enabled
                                LiveMeetingCodexPreferences.setEnabled(enabled)
                                trackSettingsToggle("live_meeting_sidecar", enabled: enabled, page: .beta)
                                handleBetaLiveMeetingSidecarToggle(enabled)
                            }
                        ),
                        help: "Opt in to the live meeting sidecar workspace.",
                        automationIdentifier: "transcripted.settings.beta.live-meeting-sidecar"
                    )

                    betaLiveSidecarSetupStatus
                }
            }
        }
        .accessibilityIdentifier("transcripted.settings.page.beta")
    }

    private var betaLocalSummarySetupStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: localSummarySetupStatusSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(localSummarySetupStatusColor)
                    .frame(width: 22)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(localSummarySetupStatusTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(localSummarySetupStatusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                SettingsInlineActionButton(
                    title: "Check setup",
                    symbolName: "arrow.clockwise",
                    automationIdentifier: "transcripted.settings.beta.local-summary.check-setup"
                ) {
                    trackSettingsAction("check_local_summary_setup", page: .beta)
                    refreshLocalSummarySetupStatus()
                }

                if localMeetingSummariesEnabled, selectedLocalSummaryProviderIsReady {
                    SettingsInlineActionButton(
                        title: isLocalSummaryModelPreparing ? "Cancel setup" : localSummaryPrepareButtonTitle,
                        symbolName: isLocalSummaryModelPreparing ? "xmark.circle" : "tray.and.arrow.down",
                        tone: isLocalSummaryModelPreparing ? .warning : .neutral,
                        automationIdentifier: "transcripted.settings.beta.local-summary.prepare-model"
                    ) {
                        if isLocalSummaryModelPreparing {
                            trackSettingsAction("cancel_local_summary_model_prepare", page: .beta)
                            cancelLocalSummaryModelPreparation()
                            localSummaryModelPreparationStatus = "\(localMeetingSummaryProvider.title) setup cancelled. You can try again when this Mac is idle."
                        } else {
                            trackSettingsAction("prepare_local_summary_model", page: .beta)
                            prepareLocalSummaryModelFromBeta()
                        }
                    }
                }
            }

            if localMeetingSummaryProvider == .gemmaMLX, !localSummarySetupStatus.hasRuntime {
                SettingsInlineActionButton(
                    title: "Install uv",
                    symbolName: "arrow.down.circle",
                    tone: .warning,
                    automationIdentifier: "transcripted.settings.beta.local-summary.install-uv"
                ) {
                    trackSettingsAction("open_uv_install_guide", page: .beta)
                    openUVInstallGuide()
                }
            }

            if let localSummaryModelPreparationStatus {
                Text(localSummaryModelPreparationStatus)
                    .font(.caption)
                    .foregroundStyle(isLocalSummaryModelPreparing ? Color.accentColor : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Setup details", isExpanded: $showLocalSummarySetupDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    betaSetupDetailLine(
                        title: "Provider",
                        value: localMeetingSummaryProvider.title
                    )
                    ForEach(localSummarySetupDetails, id: \.title) { detail in
                        betaSetupDetailLine(title: detail.title, value: detail.value)
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private var betaLiveSidecarSetupStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: betaLiveMeetingCodexEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(betaLiveMeetingCodexEnabled ? Color.green : Color.secondary)
                    .frame(width: 22)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(betaLiveMeetingCodexEnabled ? "Sidecar workspace is on" : "Sidecar workspace is off")
                        .font(.subheadline.weight(.semibold))
                    Text(betaLiveSidecarDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                SettingsInlineActionButton(
                    title: "Open Agent setup",
                    symbolName: "sparkles",
                    tone: .accent,
                    automationIdentifier: "transcripted.settings.beta.open-agent-setup"
                ) {
                    trackSettingsAction("open_agent_setup_from_beta", page: .beta)
                    navigation.selectedPage = .connectAgent
                }

                if let betaFeatureStatus {
                    Label(
                        betaFeatureStatus,
                        systemImage: betaFeatureStatus.hasPrefix("Could not") ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(betaFeatureStatus.hasPrefix("Could not") ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 2)
    }

    private func betaSetupDetailLine(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openUVInstallGuide() {
        guard let url = URL(string: "https://docs.astral.sh/uv/getting-started/installation/") else { return }
        NSWorkspace.shared.open(url)
    }

    private var localSummaryPrepareButtonTitle: String {
        switch localMeetingSummaryProvider {
        case .gemmaMLX:
            return "Prepare Gemma"
        case .appleFoundation:
            return "Check Apple model"
        }
    }

    private var localSummarySetupDetails: [(title: String, value: String)] {
        switch localMeetingSummaryProvider {
        case .gemmaMLX:
            return [
                ("Model", "Gemma 4 12B 4-bit MLX"),
                ("Download", "First summary may download several GB into your local Hugging Face cache."),
                ("Runtime", localSummarySetupStatus.hasRuntime
                    ? "uv found at \(localSummarySetupStatus.uvPath ?? "")"
                    : "Install uv so Transcripted can run the local MLX package."),
                ("Hardware", "Recommended: Apple Silicon with 16 GB memory. 8 GB Macs are not supported yet."),
                ("Privacy", "Transcript text stays on this Mac. The model download comes from Hugging Face if it is not cached.")
            ]
        case .appleFoundation:
            return [
                ("Model", "Apple Foundation Models system model"),
                ("Context", appleSummarySetupStatus.contextSize > 0
                    ? "\(appleSummarySetupStatus.contextSize) tokens reported by this Mac."
                    : "Context size unavailable."),
                ("Runtime", appleSummarySetupStatus.isReady
                    ? "Apple Intelligence model is available."
                    : (appleSummarySetupStatus.unavailableReason ?? "Apple model unavailable.")),
                ("Hardware", "Uses the best Apple on-device model this Mac exposes. Core Advanced is used only when the system provides it."),
                ("Privacy", "Transcript text stays on this Mac and uses Apple's local model path.")
            ]
        }
    }

    private var localSummarySetupStatusTitle: String {
        if isLocalSummaryModelPreparing {
            return "Preparing \(localMeetingSummaryProvider.title)"
        }

        switch localMeetingSummaryProvider {
        case .gemmaMLX:
            if !localSummarySetupStatus.hasEnoughMemory {
                return "Not supported on this Mac"
            }
            if !localSummarySetupStatus.hasRuntime {
                return "Setup needed"
            }
        case .appleFoundation:
            if !appleSummarySetupStatus.isFrameworkAvailable {
                return "Framework unavailable"
            }
            if !appleSummarySetupStatus.isModelAvailable {
                return "Apple model unavailable"
            }
        }
        return "Runtime ready"
    }

    private var localSummarySetupStatusDetail: String {
        if isLocalSummaryModelPreparing {
            return "Transcripted is preparing \(localMeetingSummaryProvider.title). Home summaries stay paused so this Mac only runs one local summary job at a time."
        }

        switch localMeetingSummaryProvider {
        case .gemmaMLX:
            if !localSummarySetupStatus.hasEnoughMemory {
                return "This Mac reports \(localSummarySetupStatus.physicalMemoryGB) GB memory. Local Gemma summaries need at least \(localSummarySetupStatus.minimumMemoryGB) GB to avoid heavy swapping."
            }
            if !localSummarySetupStatus.hasRuntime {
                return "Install uv first. The first summary may download a large local Gemma model, then future summaries reuse the local cache."
            }
            return "uv is installed. Use Prepare Gemma to download or warm the local model before running a meeting summary."
        case .appleFoundation:
            if !appleSummarySetupStatus.isReady {
                return appleSummarySetupStatus.unavailableReason ?? "Apple on-device summaries are unavailable on this Mac right now."
            }
            return "Apple's on-device model is available with a \(appleSummarySetupStatus.contextSize)-token context. Transcripted will chunk long meetings before merging."
        }
    }

    private var localSummarySetupStatusSymbol: String {
        if isLocalSummaryModelPreparing {
            return "arrow.triangle.2.circlepath"
        }
        if selectedLocalSummaryProviderIsReady {
            return "checkmark.circle.fill"
        }
        return "exclamationmark.circle.fill"
    }

    private var localSummarySetupStatusColor: Color {
        if isLocalSummaryModelPreparing {
            return Color.accentColor
        }
        if selectedLocalSummaryProviderIsReady {
            return .green
        }
        return .orange
    }

    private var betaLiveSidecarDetail: String {
        if betaLiveMeetingCodexEnabled {
            return "Transcripted prepares the local workspace. Use Agent setup to open Codex, copy Cowork setup, or open the live preview."
        }
        return "Normal meeting transcripts still save as usual. Turn this on only when you want a local agent to watch active meetings."
    }
}

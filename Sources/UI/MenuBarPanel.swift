// MenuBarPanel.swift
// Single-pane menubar popover — SuperWhisper-inspired minimal layout.
// Sections: header → stats → shortcuts → style → agent (with chat).
// Onboarding overlays (auth + style) gate all content as before.

import SwiftUI

struct MenuBarPanelView: View {
    @ObservedObject var appState: DraftAppState

    @State private var showSettings = false
    @State private var settingsName = UserDefaults.standard.string(forKey: "user-display-name") ?? ""
    @State private var isStyleExpanded = false
    @State private var cachedStylePreview = ""

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerSection
                    sectionDivider

                    statsSection
                    sectionDivider

                    shortcutsSection
                    sectionDivider

                    styleSection

                    #if !BETA_BUILD
                    sectionDivider

                    AgentSection(
                        orchestrator: appState.analysisEngine,
                        chatEngine: appState.chatEngine,
                        auth: appState.drafter.getAuth()
                    )
                    .padding(.vertical, MenuTokens.sectionSpacing / 2)
                    #endif
                }
                .padding(.horizontal, MenuTokens.innerPadding)
            }

            // Onboarding overlays (sequential gates)
            // New standalone onboarding window sets "onboarding-completed" — skip old overlays
            #if BETA_BUILD
            if !UserDefaults.standard.bool(forKey: "onboarding-completed") {
                if !PermissionsOnboardingView.hasCompleted {
                    PermissionsOnboardingView(onComplete: {
                        PermissionsOnboardingView.markCompleted()
                    })
                } else if !appState.styleEngine.hasCompletedOnboarding {
                    StyleOnboardingView(styleEngine: appState.styleEngine, draftEngine: appState.drafter)
                }
            }
            #else
            if !appState.drafter.hasCredential {
                APIKeyEntryView(draftEngine: appState.drafter)
            } else if !appState.styleEngine.hasCompletedOnboarding {
                StyleOnboardingView(styleEngine: appState.styleEngine, draftEngine: appState.drafter)
            }
            #endif
        }
        .frame(width: MenuTokens.panelWidth, height: MenuTokens.panelHeight)
        .overlay(alignment: .topTrailing) {
            settingsGearButton
        }
        .onAppear {
            appState.feedbackStore.refreshStats()
            cachedStylePreview = computeStylePreview()
        }
        .onChange(of: appState.styleEngine.styleFileContents) {
            cachedStylePreview = computeStylePreview()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Draft")
                .font(.title3)
                .fontWeight(.semibold)

            HStack(spacing: 6) {
                Circle()
                    .fill(appState.sttRouter.isModelLoaded ? MenuTokens.statusGreen : MenuTokens.statusOrange)
                    .frame(width: MenuTokens.statusDotSize, height: MenuTokens.statusDotSize)
                Text(appState.sttRouter.isModelLoaded ? "Ready" : "Loading model...")
                    .font(.caption)
                    .foregroundColor(MenuTokens.textSecondary)
            }
        }
        .padding(.top, MenuTokens.innerPadding)
        .padding(.bottom, MenuTokens.sectionSpacing / 2)
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack {
            statColumn(value: formatNumber(appState.feedbackStore.stats.wordsDictated), label: "words\ndictated")
            Spacer()
            statColumn(value: "\(appState.feedbackStore.stats.messagesDrafted)", label: "messages\ndrafted")
            Spacer()
            statColumn(value: formatMinutes(appState.feedbackStore.stats.minutesSaved), label: "saved")
                .help(savedTooltip)
        }
        .padding(.vertical, MenuTokens.sectionSpacing / 2)
    }

    private func statColumn(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
            Text(label)
                .font(.caption)
                .foregroundColor(MenuTokens.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            let k = Double(n) / 1000.0
            return String(format: "%.1fk", k)
        }
        return "\(n)"
    }

    private func formatMinutes(_ m: Int) -> String {
        if m >= 60 {
            let h = Double(m) / 60.0
            return String(format: "%.1f hr", h)
        }
        return "\(m) min"
    }

    private var savedTooltip: String {
        let s = appState.feedbackStore.stats
        return """
        You dictated \(formatNumber(s.wordsDictated)) words across \(s.messagesDrafted) messages.
        Draft composed \(formatNumber(s.wordsDrafted)) words and you sent \(formatNumber(s.wordsAccepted)) words.
        At ~40 WPM typing, that's \(formatMinutes(s.minutesSaved)) you didn't have to type.
        """
    }

    // MARK: - Shortcuts

    private var shortcutsSection: some View {
        HStack(spacing: 12) {
            shortcutPill(key: "⌥D", label: "Draft")
            shortcutPill(key: "⌥Space", label: "Dictation")
            Spacer()
        }
        .padding(.vertical, MenuTokens.sectionSpacing / 2)
    }

    private func shortcutPill(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
            Text(label)
                .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(MenuTokens.pillBackground)
        .cornerRadius(MenuTokens.pillCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: MenuTokens.pillCornerRadius)
                .stroke(MenuTokens.pillBorder, lineWidth: 1)
        )
    }

    // MARK: - Writing Style

    private var styleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Writing Style")
                    .font(.headline)
                Spacer()
                Text("\(appState.styleEngine.exampleCount) ex.")
                    .font(.caption)
                    .foregroundColor(MenuTokens.textSecondary)
            }

            styleCard
        }
        .padding(.vertical, MenuTokens.sectionSpacing / 2)
    }

    @ViewBuilder
    private var styleCard: some View {
        if appState.styleEngine.exampleCount == 0 {
            Text("Accept a draft to start learning your style")
                .font(.callout)
                .foregroundColor(MenuTokens.textMuted)
                .padding(MenuTokens.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MenuTokens.cardBackground)
                .cornerRadius(MenuTokens.cardCornerRadius)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if isStyleExpanded {
                    ScrollView {
                        Text(appState.styleEngine.styleFileContents)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundColor(MenuTokens.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 180)
                    .scrollBounceBehavior(.basedOnSize)
                } else {
                    Text(cachedStylePreview)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(MenuTokens.textSecondary)
                        .lineLimit(MenuTokens.compactStyleLines)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Spacer()
                    Button(isStyleExpanded ? "Show less" : "Show more") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isStyleExpanded.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(MenuTokens.textSecondary)
                }
                .padding(.top, 6)
            }
            .padding(MenuTokens.cardPadding)
            .background(MenuTokens.cardBackground)
            .cornerRadius(MenuTokens.cardCornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: MenuTokens.cardCornerRadius)
                    .stroke(MenuTokens.cardBorder, lineWidth: 1)
            )
        }
    }

    private func computeStylePreview() -> String {
        let contents = appState.styleEngine.styleFileContents
        // Try to extract the Style Summary section
        if let range = contents.range(of: "## Style Summary") {
            let afterHeader = contents[range.upperBound...]
            let lines = afterHeader.split(separator: "\n", omittingEmptySubsequences: false)
            let meaningful = lines.drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            return meaningful.prefix(6).joined(separator: "\n")
        }
        // Fallback: first lines of the file
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.prefix(4).joined(separator: "\n")
    }

    // MARK: - Divider

    private var sectionDivider: some View {
        Divider()
            .padding(.vertical, 2)
    }

    // MARK: - Settings

    private var settingsGearButton: some View {
        Button(action: { showSettings.toggle() }) {
            Image(systemName: "gearshape")
                .font(.body)
                .foregroundColor(MenuTokens.textSecondary)
        }
        .buttonStyle(.plain)
        .padding(12)
        .popover(isPresented: $showSettings) {
            settingsPopover
        }
    }

    #if BETA_BUILD
    @ViewBuilder
    private var updateStatusSection: some View {
        switch appState.updateManager.state {
        case .idle:
            Text("v\(BetaConfig.appVersion)")
                .font(.caption)
                .foregroundColor(.secondary)
        case .downloading(let progress):
            VStack(spacing: 4) {
                ProgressView(value: progress)
                    .frame(width: 220)
                Text("Downloading update (\(Int(progress * 100))%)...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        case .installing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Installing update...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .failed(let message):
            Text("Update failed: \(message)")
                .font(.caption2)
                .foregroundColor(.red)
                .frame(width: 220, alignment: .leading)
        }
    }
    #endif

    private var settingsPopover: some View {
        VStack(spacing: 16) {
            Text("Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Your Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Your name", text: $settingsName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onChange(of: settingsName) {
                        let trimmed = settingsName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            UserDefaults.standard.set(trimmed, forKey: "user-display-name")
                        }
                    }
                Text("Used to identify your messages in screenshots")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Transcription Engine")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text("Parakeet (CoreML)")
                    .font(.body)
                    .frame(width: 220, alignment: .leading)

                if case .downloading(let progress) = appState.sttRouter.parakeetEngine.modelDownloadState {
                    ProgressView(value: progress)
                        .frame(width: 220)
                    Text("Downloading Parakeet model (\(Int(progress * 100))%)...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if case .failed(let reason) = appState.sttRouter.parakeetEngine.modelDownloadState {
                    Text("Model error: \(reason)")
                        .font(.caption2)
                        .foregroundColor(.red)
                }

                Text("CoreML Parakeet — local, ~0.2s latency")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            #if BETA_BUILD
            Divider()
            updateStatusSection
            #endif

            #if !BETA_BUILD
            Divider()

            VStack(spacing: 4) {
                Text("Credentials stored in macOS Keychain")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Auth: \(appState.drafter.authModeName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Switch Auth Method") {
                    appState.logger.log("🔑 AUTH reset")
                    appState.drafter.clearCredential()
                    showSettings = false
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
            #endif

            Divider()

            // MARK: - Feedback & Logs
            VStack(spacing: 8) {
                Text("Feedback")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 8) {
                    // Open mail with recent logs pre-filled
                    Button("Send Feedback + Logs") {
                        let logLines = appState.logger.entries.suffix(80).joined(separator: "\n")
                        let subject = "Draft Feedback"
                        let body = "What happened:\n[describe the issue here]\n\n---\nLogs:\n\(logLines)"
                        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
                        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                        if let url = URL(string: "mailto:hi@draftapp.com?subject=\(encodedSubject)&body=\(encodedBody)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)

                    // Copy logs to clipboard — useful if email doesn't work
                    Button("Copy Logs") {
                        let logText = appState.logger.entries.suffix(200).joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(logText, forType: .string)
                    }
                    .buttonStyle(.bordered)
                }

                Text("Last \(min(appState.logger.entries.count, 200)) log entries")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            Button("Quit Draft") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
    }
}

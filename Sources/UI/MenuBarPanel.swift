// MenuBarPanel.swift
// Menubar popover content — Style + Agent tabs with onboarding gates

import SwiftUI

struct MenuBarPanelView: View {
    @ObservedObject var appState: DraftAppState

    @State private var showSettings = false
    @State private var settingsName = UserDefaults.standard.string(forKey: "user-display-name") ?? ""

    var body: some View {
        ZStack {
            TabView {
                StyleProfileView(styleEngine: appState.styleEngine)
                    .tabItem { Label("Style", systemImage: "person.text.rectangle") }

                AgentTab(
                    orchestrator: appState.analysisEngine,
                    chatEngine: appState.chatEngine,
                    auth: appState.drafter.getAuth()
                )
                .tabItem { Label("Agent", systemImage: "brain.head.profile") }
            }
            .transaction { $0.animation = nil }

            // Onboarding overlays (sequential gates)
            if !appState.drafter.hasCredential {
                APIKeyEntryView(draftEngine: appState.drafter)
            } else if !appState.styleEngine.hasCompletedOnboarding {
                StyleOnboardingView(styleEngine: appState.styleEngine, draftEngine: appState.drafter)
            }
        }
        .frame(width: 500, height: 480)
        .overlay(alignment: .topTrailing) {
            Button(action: { showSettings.toggle() }) {
                Image(systemName: "gearshape")
                    .font(.body)
            }
            .buttonStyle(.plain)
            .padding(12)
            .popover(isPresented: $showSettings) {
                settingsPopover
            }
        }
    }

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

            Divider()

            Button("Quit Draft") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
    }
}

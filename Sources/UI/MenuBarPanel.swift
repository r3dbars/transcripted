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

            // Transcription engine picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Dictation Engine")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: Binding(
                    get: { appState.transcriptionEngine },
                    set: { appState.switchTranscriptionEngine(to: $0) }
                )) {
                    ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                if appState.transcriptionEngine == .whisper {
                    if appState.modelManager.isModelAvailable {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                            Text("Whisper model ready")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else if appState.modelManager.isDownloading {
                        VStack(spacing: 4) {
                            ProgressView(value: appState.modelManager.downloadProgress)
                                .frame(width: 220)
                            HStack {
                                Text("Downloading model (\(Int(appState.modelManager.downloadProgress * 100))%)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Cancel") { appState.modelManager.cancelDownload() }
                                    .font(.caption2)
                            }
                            .frame(width: 220)
                        }
                    } else if let error = appState.modelManager.downloadError {
                        VStack(spacing: 4) {
                            Text(error)
                                .font(.caption2)
                                .foregroundColor(.red)
                                .lineLimit(2)
                            Button("Retry Download") {
                                appState.modelManager.downloadModel()
                            }
                            .font(.caption2)
                        }
                    } else {
                        // Auto-download when Whisper is selected and model is missing
                        ProgressView()
                            .controlSize(.small)
                            .onAppear { appState.modelManager.downloadModel() }
                    }
                }
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

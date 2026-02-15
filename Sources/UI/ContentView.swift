// ContentView.swift
// Main app view — input area, voice controls, Draft button, polished output

import SwiftUI

struct ContentView: View {
    @StateObject private var speech = SpeechEngine()
    @StateObject private var drafter = DraftEngine()
    @State private var showSettings = false

    // Editable input text — syncs with speech engine
    @State private var inputText = ""

    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                // Header
                HStack {
                    Text("Draft")
                        .font(.title2)
                        .fontWeight(.semibold)

                    Spacer()

                    Text(speech.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Settings gear — re-enter API key
                    Button(action: { showSettings.toggle() }) {
                        Image(systemName: "gearshape")
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showSettings) {
                        VStack(spacing: 12) {
                            Text("API Key")
                                .font(.headline)
                            Text("Key is stored in macOS Keychain")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button("Reset API Key") {
                                drafter.clearAPIKey()
                                showSettings = false
                            }
                            .buttonStyle(.bordered)
                            .foregroundColor(.red)
                        }
                        .padding(20)
                    }
                }

                // Input area — editable text, syncs with voice
                TextEditor(text: $inputText)
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading, content: {
                        if inputText.isEmpty && !speech.isListening {
                            Text("Speak, type, or paste your rough thoughts here...")
                                .foregroundColor(.secondary)
                                .italic()
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    })
                    .disabled(drafter.isDrafting)

                // Voice indicator — show volatile text in blue below input
                if speech.isListening && !speech.volatileText.isEmpty {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text(speech.volatileText)
                            .font(.callout)
                            .foregroundColor(.blue)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }

                // Controls row
                HStack(spacing: 12) {
                    // Record / Stop
                    Button(action: {
                        if speech.isListening {
                            speech.stopListening()
                        } else {
                            speech.startListening()
                        }
                    }) {
                        HStack {
                            Image(systemName: speech.isListening ? "stop.circle.fill" : "mic.circle.fill")
                                .font(.title2)
                            Text(speech.isListening ? "Stop" : "Record")
                                .fontWeight(.medium)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(speech.isListening ? .red : .blue)
                    .keyboardShortcut(.space, modifiers: [])

                    // Draft button — the main action
                    Button(action: {
                        drafter.draftMessage(from: inputText)
                    }) {
                        HStack {
                            Image(systemName: "sparkles")
                                .font(.title2)
                            Text("Draft")
                                .fontWeight(.medium)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || drafter.isDrafting || !drafter.hasAPIKey)
                    .keyboardShortcut(.return, modifiers: .command)

                    Spacer()

                    // Clear
                    Button(action: {
                        inputText = ""
                        speech.clear()
                        drafter.clear()
                    }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Clear")
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.bordered)
                    .disabled(inputText.isEmpty && drafter.draftedText.isEmpty)
                }

                // Output area — polished message from Haiku
                if drafter.isDrafting || !drafter.draftedText.isEmpty || drafter.error != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Drafted Message")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)

                            Spacer()

                            if !drafter.draftedText.isEmpty {
                                Button(action: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(drafter.draftedText, forType: .string)
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.on.doc")
                                        Text("Copy")
                                    }
                                    .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }

                        if drafter.isDrafting {
                            HStack {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Drafting...")
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        } else if let error = drafter.error {
                            Text(error)
                                .font(.body)
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        } else {
                            ScrollView {
                                Text(drafter.draftedText)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(Color.purple.opacity(0.05))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                    )
                }
            }
            .padding(20)

            // API key entry overlay
            if !drafter.hasAPIKey {
                APIKeyEntryView(draftEngine: drafter)
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .task {
            _ = await speech.requestPermissions()
            drafter.checkAPIKey()
        }
        // Sync speech transcript into editable input
        .onChange(of: speech.finalTranscript) {
            inputText = speech.displayText
        }
        .onChange(of: speech.volatileText) {
            if speech.isListening {
                inputText = speech.finalTranscript
            }
        }
    }
}

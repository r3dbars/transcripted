import SwiftUI

// MARK: - TranscriptionProviderView
//
// Embed this in SettingsView (Recording tab) just above the Deepgram API key section:
//
//   TranscriptionProviderView()
//
// It shows a provider picker (Deepgram vs On-Device) and the server status
// when On-Device is selected.

@available(macOS 14.2, *)
struct TranscriptionProviderView: View {

    @AppStorage("transcriptionProvider") private var providerRaw: String = "deepgram"
    @StateObject private var localTranscription = LocalTranscription.shared

    private var provider: TranscriptionProvider {
        TranscriptionProvider(rawValue: providerRaw) ?? .deepgram
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Header
            HStack {
                Image(systemName: "cpu")
                    .foregroundStyle(.secondary)
                Text("Transcription Engine")
                    .font(.headline)
            }

            // Provider picker
            Picker("", selection: $providerRaw) {
                ForEach(TranscriptionProvider.allCases, id: \.rawValue) { p in
                    Text(p.displayName).tag(p.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: providerRaw) { _, _ in
                if provider == .local && !localTranscription.serverReady {
                    localTranscription.startServer()
                }
            }

            // Privacy description
            Text(provider.privacyDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            // On-device: server status + setup prompt
            if provider == .local {
                LocalServerStatusView()
                    .padding(.top, 4)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - LocalServerStatusView

@available(macOS 14.2, *)
struct LocalServerStatusView: View {

    @StateObject private var localTranscription = LocalTranscription.shared
    @State private var isStarting = false

    var body: some View {
        HStack(spacing: 10) {
            // Status dot
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.6), radius: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.subheadline.weight(.medium))
                if !statusDetail.isEmpty {
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !localTranscription.serverReady {
                Button(isStarting ? "Starting…" : "Start Server") {
                    isStarting = true
                    localTranscription.startServer()
                    // Reset button after timeout
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        isStarting = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isStarting)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(statusColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        localTranscription.serverReady ? .green : .orange
    }

    private var statusTitle: String {
        localTranscription.serverReady ? "On-device AI ready" : "Server not running"
    }

    private var statusDetail: String {
        if localTranscription.serverReady {
            return "Parakeet + Sortformer loaded · ~2.5GB"
        }
        return "Run inference_server/setup.sh once to install models"
    }
}

// MARK: - SpeakerProfilesView
//
// Optional: embed in Settings to let users see/correct voice profiles.
// Add as a new "Speakers" tab.

@available(macOS 14.2, *)
struct SpeakerProfilesView: View {

    @StateObject private var db = VoiceProfileDatabase.shared
    @State private var editingProfile: VoiceProfile?
    @State private var newName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if db.profiles.isEmpty {
                ContentUnavailableView(
                    "No Voice Profiles Yet",
                    systemImage: "person.wave.2",
                    description: Text("Profiles build automatically as you record meetings.")
                )
            } else {
                List(db.profiles) { profile in
                    HStack {
                        // Avatar
                        ZStack {
                            Circle()
                                .fill(.tint.opacity(0.15))
                                .frame(width: 36, height: 36)
                            Text(profile.name?.prefix(1).uppercased() ?? "?")
                                .font(.headline)
                                .foregroundStyle(.tint)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(profile.name ?? "Unknown Speaker")
                                    .font(.subheadline.weight(.medium))
                                if profile.autoLabeled {
                                    Label("Auto", systemImage: "sparkles")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .labelStyle(.titleAndIcon)
                                }
                            }
                            Text("\(profile.callCount) calls · "
                                + "Confidence: \(Int(profile.confidence * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Edit") {
                            editingProfile = profile
                            newName = profile.name ?? ""
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.tint)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .sheet(item: $editingProfile) { profile in
            VStack(spacing: 20) {
                Text("Set Speaker Name")
                    .font(.title2.weight(.semibold))
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                HStack {
                    Button("Cancel") { editingProfile = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        db.setName(newName, for: profile.id)
                        editingProfile = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(30)
        }
    }
}

// MARK: - Preview

#Preview {
    if #available(macOS 14.2, *) {
        VStack(spacing: 20) {
            TranscriptionProviderView()
            SpeakerProfilesView()
        }
        .padding()
        .frame(width: 500)
    }
}

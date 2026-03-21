import SwiftUI

@available(macOS 26.0, *)
struct SpeakersSettingsSection: View {

    @Binding var speakers: [SpeakerProfile]
    @Binding var speakersExpanded: Bool
    @Binding var editingId: UUID?
    @Binding var editingName: String
    @Binding var deleteConfirmId: UUID?
    @ObservedObject var clipPlayer: ClipAudioPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("VOICE FINGERPRINTS")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.panelTextMuted)
                .tracking(0.8)

            VStack(alignment: .leading, spacing: 0) {
                // Collapsible header
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        speakersExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: speakersExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.panelTextMuted)
                            .frame(width: 16)

                        Text("\(speakers.count) speaker\(speakers.count == 1 ? "" : "s")")
                            .font(.bodyMedium)
                            .foregroundColor(.panelTextPrimary)

                        Spacer()

                        Text("Tap to manage")
                            .font(.caption)
                            .foregroundColor(.panelTextMuted)
                    }
                    .padding(Spacing.md)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Expanded speaker list
                if speakersExpanded {
                    Rectangle()
                        .fill(Color.panelCharcoalSurface)
                        .frame(height: 1)
                        .padding(.horizontal, Spacing.md)

                    VStack(spacing: Spacing.xs) {
                        ForEach(speakers) { speaker in
                            inlineSpeakerRow(speaker)
                        }

                        if speakers.isEmpty {
                            Text("No speakers yet — record a call with system audio to start")
                                .font(.caption)
                                .foregroundColor(.panelTextMuted)
                                .padding(.vertical, Spacing.md)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.bottom, Spacing.md)
                    .padding(.top, Spacing.sm)
                }
            }
            .background {
                RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                    .fill(Color.panelCharcoalElevated)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                    .stroke(Color.panelCharcoalSurface, lineWidth: 1)
            }
        }
    }

    private func inlineSpeakerRow(_ speaker: SpeakerProfile) -> some View {
        HStack(spacing: Spacing.sm) {
            // Play button (only if persistent clip exists)
            if SpeakerClipExtractor.persistentClipURL(for: speaker.id) != nil {
                Button(action: { toggleClipPlayback(for: speaker.id) }) {
                    Image(systemName: isClipPlaying(speaker.id) ? "stop.fill" : "play.fill")
                        .font(.system(size: 10))
                        .foregroundColor(isClipPlaying(speaker.id) ? .accentBlue : .panelTextMuted)
                }
                .buttonStyle(.plain)
                .frame(width: 20)
                .help(isClipPlaying(speaker.id) ? "Stop" : "Play voice clip")
            }

            // Simple avatar
            ZStack {
                Circle()
                    .fill(Color.panelCharcoalSurface)
                    .frame(width: 28, height: 28)

                Text(speaker.displayName?.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.panelTextSecondary)
            }

            // Name
            if editingId == speaker.id {
                TextField("Name", text: $editingName, onCommit: {
                    commitNameEdit(for: speaker.id)
                })
                .textFieldStyle(.plain)
                .font(.bodySmall)
                .foregroundColor(.panelTextPrimary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.panelCharcoalSurface)
                        .overlay {
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.accentBlue, lineWidth: 1)
                        }
                }
                .onExitCommand { editingId = nil }
            } else {
                Text(speaker.displayName ?? "Unknown")
                    .font(.bodySmall)
                    .foregroundColor(speaker.displayName != nil ? .panelTextPrimary : .panelTextMuted)
                    .italic(speaker.displayName == nil)
                    .onTapGesture {
                        editingName = speaker.displayName ?? ""
                        editingId = speaker.id
                    }
            }

            // Meta
            Text("\(speaker.callCount) call\(speaker.callCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.panelTextMuted)

            Spacer()

            // Actions
            if deleteConfirmId == speaker.id {
                HStack(spacing: Spacing.xs) {
                    Text("Delete?")
                        .font(.caption)
                        .foregroundColor(.errorRed)
                    Button("Yes") {
                        SpeakerClipExtractor.deletePersistedClip(for: speaker.id)
                        SpeakerDatabase.shared.deleteSpeaker(id: speaker.id)
                        deleteConfirmId = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            speakers = SpeakerDatabase.shared.allSpeakers()
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.errorRed)
                    .buttonStyle(.plain)
                    Button("No") { deleteConfirmId = nil }
                        .font(.caption)
                        .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: Spacing.xs) {
                    if editingId != speaker.id {
                        Button {
                            editingName = speaker.displayName ?? ""
                            editingId = speaker.id
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 11))
                                .foregroundColor(.panelTextMuted)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        deleteConfirmId = speaker.id
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(.panelTextMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private func commitNameEdit(for id: UUID) {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editingId = nil
            return
        }
        SpeakerDatabase.shared.setDisplayName(id: id, name: trimmed, source: "user_manual")
        editingId = nil
        // Retroactively update all transcripts referencing this speaker
        Task.detached {
            TranscriptSaver.retroactivelyUpdateSpeaker(dbId: id, newName: trimmed)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            speakers = SpeakerDatabase.shared.allSpeakers()
        }
    }

    // MARK: - Clip Playback Helpers

    private func isClipPlaying(_ speakerId: UUID) -> Bool {
        guard let clipURL = SpeakerClipExtractor.persistentClipURL(for: speakerId) else { return false }
        return clipPlayer.isPlaying && clipPlayer.currentClipURL == clipURL
    }

    private func toggleClipPlayback(for speakerId: UUID) {
        guard let clipURL = SpeakerClipExtractor.persistentClipURL(for: speakerId) else { return }
        if isClipPlaying(speakerId) {
            clipPlayer.stop()
        } else {
            clipPlayer.play(url: clipURL)
        }
    }
}

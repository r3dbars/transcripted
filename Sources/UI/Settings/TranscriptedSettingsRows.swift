import AppKit
import SwiftUI

struct AutoEnterAppCandidate: Identifiable, Equatable {
    let bundleID: String
    let name: String

    var id: String { bundleID }

    static func runningApps() -> [AutoEnterAppCandidate] {
        let transcriptedBundleID = Bundle.main.bundleIdentifier
        let candidates = NSWorkspace.shared.runningApplications.compactMap { app -> AutoEnterAppCandidate? in
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  bundleID != transcriptedBundleID else {
                return nil
            }

            return AutoEnterAppCandidate(
                bundleID: bundleID,
                name: app.localizedName ?? bundleID
            )
        }

        var seen = Set<String>()
        return candidates
            .filter { seen.insert($0.bundleID).inserted }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

struct CorrectionDraftRow: Identifiable, Equatable {
    let id: UUID
    var spoken: String
    var replacement: String

    init(id: UUID = UUID(), spoken: String = "", replacement: String = "") {
        self.id = id
        self.spoken = spoken
        self.replacement = replacement
    }

    init(entry: CustomDictionaryEntry) {
        self.init(spoken: entry.spoken, replacement: entry.replacement)
    }

    static func rows(from rawText: String) -> [CorrectionDraftRow] {
        let rows = CustomDictionaryPreferences.entries(from: rawText).map(CorrectionDraftRow.init(entry:))
        return rows.isEmpty ? [CorrectionDraftRow()] : rows
    }

    static func rawText(from rows: [CorrectionDraftRow]) -> String {
        rows.compactMap { row in
            let spoken = row.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = row.replacement.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !spoken.isEmpty else { return nil }
            if replacement.isEmpty || replacement == spoken {
                return spoken
            }
            return "\(spoken) -> \(replacement)"
        }
        .joined(separator: "\n")
    }
}

struct CorrectionEditorRow: View {
    @Binding var spoken: String
    @Binding var replacement: String
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            TextField("okay ours", text: $spoken)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("Mistake"))

            TextField("OKRs", text: $replacement)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("Fix"))

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(SettingsHoverButtonStyle(tone: .destructive, cornerRadius: 7))
            .accessibilityLabel(Text("Remove correction"))
            .help("Remove this correction.")
        }
    }
}

struct ModelChoiceRow: View {
    let model: TranscriptionModelChoice
    let isPreferred: Bool
    let isEffective: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(symbolColor)
                .frame(width: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.title)
                        .font(.subheadline.weight(.semibold))

                    Text(statusLabel)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)
                }

                Text(model.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)
        }
    }

    private var symbolName: String {
        if isEffective { return "checkmark.circle.fill" }
        return "circle"
    }

    private var symbolColor: Color {
        if isEffective { return .green }
        return .secondary
    }

    private var statusLabel: String {
        if isEffective { return "Active" }
        if isPreferred { return "Preferred" }
        return model.availabilityStatus
    }

    private var statusColor: Color {
        if isEffective { return .green }
        return .secondary
    }
}

struct AutoEnterAllowedAppRow: View {
    let title: String
    let bundleID: String
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(bundleID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            SettingsInlineActionButton(
                title: "Remove",
                tone: .destructive,
                action: remove
            )
        }
    }
}

struct SettingsRecentMeetingAudioControl: View {
    let title: String
    let symbolName: String
    let isActive: Bool
    let isPlaying: Bool
    let scrubber: AnyView?
    let action: () -> Void

    init(
        title: String,
        symbolName: String,
        isActive: Bool,
        isPlaying: Bool,
        scrubber: AnyView? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbolName = symbolName
        self.isActive = isActive
        self.isPlaying = isPlaying
        self.scrubber = scrubber
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: symbolName)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(iconForeground)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(iconBackground))

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.22))
                            .frame(width: 44, height: 4)

                        Capsule()
                            .fill(playheadColor)
                            .frame(width: isPlaying ? 28 : 8, height: 4)

                        Circle()
                            .fill(playheadColor)
                            .frame(width: 8, height: 8)
                            .offset(x: isPlaying ? 24 : 4)
                    }
                    .frame(width: 44, height: 12)

                    Text(title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(SettingsHoverButtonStyle(
                tone: isActive ? .accent : .neutral,
                cornerRadius: 8,
                normalFill: background,
                normalStroke: stroke
            ))

            if let scrubber {
                scrubber
            }
        }
    }

    private var background: Color {
        isActive ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08)
    }

    private var stroke: Color {
        isActive ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.10)
    }

    private var iconBackground: Color {
        isActive ? Color.accentColor : Color.primary.opacity(0.12)
    }

    private var iconForeground: Color {
        isActive ? .white : .secondary
    }

    private var playheadColor: Color {
        isActive ? .accentColor : .secondary.opacity(0.65)
    }
}

struct SettingsFailedMeetingRow: View {
    let item: MeetingSessionController.FailedMeetingItem
    let canRetry: Bool
    let retryUnavailableReason: String?
    let audio: MeetingAudioAttachment?
    let retryAction: () -> Void
    let revealAudioAction: () -> Void
    let secondaryAction: () -> Void
    @ObservedObject private var playback = MeetingAudioPlayback.shared
    @State private var selectedPlaybackChoiceID: String?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: presentation.iconSystemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))

                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(item.meta)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            if let audio {
                let selectedChoice = selectedPlaybackChoice(for: audio)
                SettingsRecentMeetingAudioControl(
                    title: playback.buttonTitle(for: audio, choice: selectedChoice),
                    symbolName: playback.symbolName(for: audio, choice: selectedChoice),
                    isActive: playback.isActive(audio, choice: selectedChoice),
                    isPlaying: playback.isPlaying && playback.isActive(audio, choice: selectedChoice),
                    scrubber: playback.isActive(audio)
                        ? AnyView(MeetingAudioScrubber(attachment: audio, width: 190))
                        : nil
                ) {
                    playback.toggle(audio, choice: selectedChoice)
                }
                .help("\(playback.buttonTitle(for: audio, choice: selectedChoice)) retained meeting audio")

                MeetingAudioSourceMenu(
                    attachment: audio,
                    selectedChoiceID: selectedPlaybackChoiceBinding(for: audio)
                ) { choice in
                    if playback.isActive(audio) {
                        playback.switchSource(audio, choice: choice)
                    }
                }

                Button {
                    revealAudioAction()
                } label: {
                    Label("Show Audio", systemImage: "folder")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(SettingsHoverButtonStyle(
                    cornerRadius: 8,
                    normalFill: Color.primary.opacity(0.025),
                    normalStroke: Color.primary.opacity(0.06)
                ))
            }

            if item.isRetryable || item.isRetrying {
                Button {
                    retryAction()
                } label: {
                    Label(item.isRetrying ? "Retrying..." : "Try Again", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(SettingsHoverButtonStyle(
                    tone: .accent,
                    cornerRadius: 8,
                    normalFill: Color.accentColor.opacity(0.08),
                    normalStroke: Color.accentColor.opacity(0.16)
                ))
                .disabled(presentation.retryDisabled)
                .help(presentation.retryHelp)
            }

            Button(role: presentation.clearIsDestructive ? .destructive : nil) {
                secondaryAction()
            } label: {
                Label(presentation.clearTitle, systemImage: presentation.clearSymbolName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(SettingsHoverButtonStyle(
                tone: presentation.clearIsDestructive ? .destructive : .neutral,
                cornerRadius: 8,
                normalFill: presentation.clearIsDestructive ? Color.red.opacity(0.06) : Color.primary.opacity(0.025),
                normalStroke: presentation.clearIsDestructive ? Color.red.opacity(0.14) : Color.primary.opacity(0.06)
            ))
        }
    }

    private var presentation: FailedMeetingRecoveryPresentation {
        FailedMeetingRecoveryPresentation.make(
            failureKind: item.failureKind,
            canRetry: canRetry,
            retryUnavailableReason: retryUnavailableReason,
            isRetryable: item.isRetryable,
            isRetrying: item.isRetrying,
            hasAudioFiles: item.hasAudioFiles,
            hasRetainedAudioFiles: !item.audioURLs.isEmpty
        )
    }

    private var iconColor: Color {
        presentation.iconTone == .warning ? .orange : .secondary
    }

    private func selectedPlaybackChoice(for audio: MeetingAudioAttachment) -> MeetingAudioPlaybackChoice? {
        playback.activeChoice(for: audio) ?? audio.playbackChoice(id: selectedPlaybackChoiceID)
    }

    private func selectedPlaybackChoiceBinding(for audio: MeetingAudioAttachment) -> Binding<String?> {
        Binding(
            get: { selectedPlaybackChoice(for: audio)?.id },
            set: { selectedPlaybackChoiceID = $0 }
        )
    }
}

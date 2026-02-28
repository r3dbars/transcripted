import SwiftUI
import AppKit

/// Displays recent transcripts on the dashboard with timeline layout
/// Clean minimal design — no animated waveforms, no premium card wrapper
@available(macOS 14.0, *)
struct RecentTranscriptsView: View {

    let transcripts: [RecordingMetadata]

    // Group transcripts by time period
    private var groupedTranscripts: [(title: String, items: [RecordingMetadata])] {
        let calendar = Calendar.current
        let now = Date()

        var today: [RecordingMetadata] = []
        var yesterday: [RecordingMetadata] = []
        var thisWeek: [RecordingMetadata] = []
        var earlier: [RecordingMetadata] = []

        for transcript in transcripts {
            if calendar.isDateInToday(transcript.date) {
                today.append(transcript)
            } else if calendar.isDateInYesterday(transcript.date) {
                yesterday.append(transcript)
            } else if calendar.isDate(transcript.date, equalTo: now, toGranularity: .weekOfYear) {
                thisWeek.append(transcript)
            } else {
                earlier.append(transcript)
            }
        }

        var groups: [(title: String, items: [RecordingMetadata])] = []
        if !today.isEmpty { groups.append(("Today", today)) }
        if !yesterday.isEmpty { groups.append(("Yesterday", yesterday)) }
        if !thisWeek.isEmpty { groups.append(("This Week", thisWeek)) }
        if !earlier.isEmpty { groups.append(("Earlier", earlier)) }

        return groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Header
            HStack {
                Text("RECENT TRANSCRIPTS")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.panelTextMuted)
                    .tracking(0.8)

                Spacer()

                if !transcripts.isEmpty {
                    Text("\(transcripts.count)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.panelTextMuted)
                }
            }

            if transcripts.isEmpty {
                emptyState
            } else {
                // Timeline grouped by period
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    ForEach(Array(groupedTranscripts.enumerated()), id: \.offset) { index, group in
                        TimelineGroupView(
                            title: group.title,
                            transcripts: group.items,
                            isLastGroup: index == groupedTranscripts.count - 1
                        )
                    }
                }
            }
        }
        .padding(Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                .fill(Color.panelCharcoalElevated)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                .stroke(Color.panelCharcoalSurface, lineWidth: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            ZStack {
                Circle()
                    .fill(Color.panelCharcoalSurface)
                    .frame(width: 64, height: 64)

                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 24))
                    .foregroundColor(.panelTextMuted)
            }

            VStack(spacing: Spacing.xs) {
                Text("No transcripts yet")
                    .font(.bodyMedium)
                    .foregroundColor(.panelTextSecondary)

                Text("Your recordings will appear here")
                    .font(.caption)
                    .foregroundColor(.panelTextMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xl)
    }
}

// MARK: - Timeline Group

@available(macOS 14.0, *)
struct TimelineGroupView: View {

    let title: String
    let transcripts: [RecordingMetadata]
    let isLastGroup: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Section header
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.panelTextMuted)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.leading, 28)

            // Timeline items
            ForEach(Array(transcripts.enumerated()), id: \.element.id) { index, transcript in
                TimelineRowView(
                    transcript: transcript,
                    isFirst: index == 0,
                    isLast: index == transcripts.count - 1 && isLastGroup
                )
            }
        }
    }
}

// MARK: - Timeline Row

@available(macOS 14.0, *)
struct TimelineRowView: View {

    let transcript: RecordingMetadata
    let isFirst: Bool
    let isLast: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            // Timeline indicator
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : Color.panelCharcoalSurface)
                    .frame(width: 2, height: 12)

                Circle()
                    .fill(isHovered ? Color.panelTextSecondary : Color.panelCharcoalSurface)
                    .frame(width: 8, height: 8)

                Rectangle()
                    .fill(isLast ? Color.clear : Color.panelCharcoalSurface)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 16)

            // Content card
            Button {
                revealInFinder()
            } label: {
                HStack(spacing: Spacing.sm) {
                    // Content
                    VStack(alignment: .leading, spacing: 4) {
                        Text(transcript.displayTitle)
                            .font(.bodyMedium)
                            .fontWeight(.medium)
                            .foregroundColor(.panelTextPrimary)
                            .lineLimit(1)

                        // Metadata
                        HStack(spacing: Spacing.xs) {
                            MetadataPill(icon: "clock", text: formattedTime)
                            MetadataPill(icon: "timer", text: transcript.formattedDuration)

                            if transcript.speakerCount > 0 {
                                MetadataPill(icon: "person.2", text: "\(transcript.speakerCount)")
                            }

                            if transcript.wordCount > 100 {
                                MetadataPill(icon: "text.word.spacing", text: formatWordCount(transcript.wordCount))
                            }
                        }
                    }

                    Spacer()

                    // Open indicator on hover
                    if isHovered {
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.panelTextMuted)
                    }
                }
                .padding(Spacing.sm)
                .background {
                    RoundedRectangle(cornerRadius: Radius.lawsButton, style: .continuous)
                        .fill(isHovered ? Color.panelCharcoalSurface : Color.panelCharcoalSurface.opacity(0.5))
                }
                .contentShape(RoundedRectangle(cornerRadius: Radius.lawsButton))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovered = hovering
            }
        }
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: transcript.date)
    }

    private func formatWordCount(_ count: Int) -> String {
        if count >= 1000 {
            return "\(count / 1000)k"
        }
        return "\(count)"
    }

    private func revealInFinder() {
        guard let path = transcript.transcriptPath else {
            let url = TranscriptSaver.defaultSaveDirectory
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
            return
        }

        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Metadata Pill

@available(macOS 14.0, *)
struct MetadataPill: View {

    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))

            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(.panelTextMuted)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background {
            Capsule()
                .fill(Color.panelCharcoal)
        }
    }
}

// MARK: - Compact Transcript Row (for smaller spaces)

@available(macOS 14.0, *)
struct CompactTranscriptRow: View {

    let transcript: RecordingMetadata

    @State private var isHovered = false

    var body: some View {
        Button {
            revealInFinder()
        } label: {
            HStack(spacing: Spacing.sm) {
                Circle()
                    .fill(Color.panelTextMuted)
                    .frame(width: 6, height: 6)

                Text(transcript.displayTitle)
                    .font(.bodySmall)
                    .foregroundColor(.panelTextPrimary)
                    .lineLimit(1)

                Spacer()

                Text(transcript.formattedDuration)
                    .font(.caption)
                    .foregroundColor(.panelTextMuted)
            }
            .padding(.vertical, Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isHovered ? 0.8 : 1.0)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func revealInFinder() {
        guard let path = transcript.transcriptPath else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Preview

@available(macOS 14.0, *)
#Preview {
    VStack(spacing: Spacing.lg) {
        RecentTranscriptsView(
            transcripts: [
                RecordingMetadata(
                    date: Date(),
                    durationSeconds: 2700,
                    wordCount: 3500,
                    speakerCount: 4,
                    title: "Team Standup"
                ),
                RecordingMetadata(
                    date: Date().addingTimeInterval(-3600),
                    durationSeconds: 1200,
                    wordCount: 1500,
                    speakerCount: 2,
                    title: "Quick Sync"
                ),
                RecordingMetadata(
                    date: Date().addingTimeInterval(-86400),
                    durationSeconds: 5400,
                    wordCount: 7200,
                    speakerCount: 6,
                    title: "Client Kickoff - Acme Corp"
                ),
            ]
        )

        RecentTranscriptsView(transcripts: [])
    }
    .frame(width: 500)
    .padding()
    .background(Color.panelCharcoal)
}

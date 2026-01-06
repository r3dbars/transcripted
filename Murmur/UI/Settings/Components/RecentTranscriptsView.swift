import SwiftUI
import AppKit

/// Displays recent transcripts on the dashboard with timeline layout
/// "Night Studio" aesthetic with grouped sections and premium styling
@available(macOS 14.0, *)
struct RecentTranscriptsView: View {

    let transcripts: [RecordingMetadata]

    @State private var isHovered = false

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
                Text("Recent Transcripts")
                    .font(.headingSmall)
                    .foregroundColor(.panelTextPrimary)

                Spacer()

                if !transcripts.isEmpty {
                    Text("\(transcripts.count)")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.panelTextMuted)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background {
                            Capsule()
                                .fill(Color.panelCharcoalSurface)
                        }
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
        .premiumCard(isHovered: isHovered, glowColor: .accentBlue)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            // Illustration
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

            // Hint pill
            HStack(spacing: Spacing.xs) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundColor(.recordingCoral)

                Text("Start recording to get started")
                    .font(.caption)
                    .foregroundColor(.panelTextMuted)
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background {
                Capsule()
                    .fill(Color.recordingCoral.opacity(0.1))
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
                .padding(.leading, 28) // Align with content after timeline dot

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
    @State private var showOpenButton = false

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            // Timeline indicator
            VStack(spacing: 0) {
                // Line above dot
                Rectangle()
                    .fill(isFirst ? Color.clear : Color.panelCharcoalSurface)
                    .frame(width: 2, height: 12)

                // Dot with pulse on hover
                ZStack {
                    // Glow effect when hovered
                    if isHovered {
                        Circle()
                            .fill(Color.recordingCoral.opacity(0.3))
                            .frame(width: 16, height: 16)
                            .blur(radius: 4)
                    }

                    Circle()
                        .fill(isHovered ? Color.recordingCoral : Color.panelCharcoalSurface)
                        .frame(width: 8, height: 8)
                }

                // Line below dot
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
                    // Mini waveform thumbnail
                    MiniWaveformView(isHovered: isHovered)
                        .frame(width: 48, height: 32)

                    // Content
                    VStack(alignment: .leading, spacing: 4) {
                        // Title
                        Text(transcript.displayTitle)
                            .font(.bodyMedium)
                            .fontWeight(.medium)
                            .foregroundColor(.panelTextPrimary)
                            .lineLimit(1)

                        // Metadata pills
                        HStack(spacing: Spacing.xs) {
                            // Time
                            MetadataPill(
                                icon: "clock",
                                text: formattedTime
                            )

                            // Duration
                            MetadataPill(
                                icon: "timer",
                                text: transcript.formattedDuration
                            )

                            // Speakers (if any)
                            if transcript.speakerCount > 0 {
                                MetadataPill(
                                    icon: "person.2",
                                    text: "\(transcript.speakerCount)"
                                )
                            }

                            // Words (optional, show if significant)
                            if transcript.wordCount > 100 {
                                MetadataPill(
                                    icon: "text.word.spacing",
                                    text: formatWordCount(transcript.wordCount)
                                )
                            }
                        }
                    }

                    Spacer()

                    // Slide-in Open button
                    HStack(spacing: 4) {
                        Text("Open")
                            .font(.caption)
                            .fontWeight(.medium)

                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.recordingCoral)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 6)
                    .background {
                        Capsule()
                            .fill(Color.recordingCoral.opacity(0.15))
                    }
                    .opacity(isHovered ? 1 : 0)
                    .offset(x: isHovered ? 0 : 20)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
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
                withAnimation(.easeOut(duration: 0.2)) {
                    isHovered = hovering
                }
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
            // Open the Transcripted folder if no specific path
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

// MARK: - Mini Waveform View

@available(macOS 14.0, *)
struct MiniWaveformView: View {

    let isHovered: Bool

    // Static waveform data (normalized 0-1)
    private let waveformData: [CGFloat] = [
        0.3, 0.5, 0.7, 0.4, 0.8, 0.6, 0.9, 0.5, 0.7, 0.4,
        0.6, 0.8, 0.5, 0.7, 0.3, 0.6, 0.8, 0.4, 0.5, 0.7
    ]

    @State private var animationPhase: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let barWidth: CGFloat = 2
            let spacing: CGFloat = 1.5
            let barCount = min(waveformData.count, Int(width / (barWidth + spacing)))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    let normalizedHeight = waveformData[index % waveformData.count]
                    let animatedHeight = isHovered
                        ? normalizedHeight * (0.8 + 0.2 * sin(animationPhase + CGFloat(index) * 0.5))
                        : normalizedHeight

                    RoundedRectangle(cornerRadius: 1)
                        .fill(isHovered ? Color.recordingCoral : Color.panelTextMuted.opacity(0.5))
                        .frame(width: barWidth, height: max(2, height * animatedHeight * 0.8))
                }
            }
            .frame(width: width, height: height, alignment: .center)
        }
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.panelCharcoal)
        }
        .onChange(of: isHovered) { _, hovering in
            if hovering {
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    animationPhase = .pi * 2
                }
            } else {
                animationPhase = 0
            }
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
                // Dot indicator
                Circle()
                    .fill(Color.recordingCoral)
                    .frame(width: 6, height: 6)

                // Title
                Text(transcript.displayTitle)
                    .font(.bodySmall)
                    .foregroundColor(.panelTextPrimary)
                    .lineLimit(1)

                Spacer()

                // Duration
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
                RecordingMetadata(
                    date: Date().addingTimeInterval(-172800),
                    durationSeconds: 1920,
                    wordCount: 2100,
                    speakerCount: 3,
                    title: "Product Review"
                ),
                RecordingMetadata(
                    date: Date().addingTimeInterval(-604800),
                    durationSeconds: 3600,
                    wordCount: 4200,
                    speakerCount: 5,
                    title: "Quarterly Planning"
                )
            ]
        )

        RecentTranscriptsView(transcripts: [])
    }
    .frame(width: 500)
    .padding()
    .background(Color.panelCharcoal)
}

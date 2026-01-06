import SwiftUI
import AppKit

/// Full transcript browser with search functionality
/// Displays all transcripts with click-to-reveal in Finder
@available(macOS 14.0, *)
struct TranscriptsView: View {

    @ObservedObject var statsService: StatsService
    @Binding var searchQuery: String

    @State private var sortOrder: SortOrder = .newest
    @State private var allTranscripts: [RecordingMetadata] = []

    enum SortOrder: String, CaseIterable {
        case newest = "Newest"
        case oldest = "Oldest"
        case longest = "Longest"
        case shortest = "Shortest"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with search
            headerSection
                .padding(Spacing.lg)

            Divider()
                .background(Color.panelCharcoalSurface)

            // Transcript list
            if filteredTranscripts.isEmpty {
                emptyState
            } else {
                transcriptList
            }
        }
        .background(Color.panelCharcoal)
        .onAppear {
            allTranscripts = statsService.getAllRecordings()
        }
    }

    // MARK: - Filtered Transcripts

    private var filteredTranscripts: [RecordingMetadata] {
        var transcripts = allTranscripts

        // Apply search filter
        if !searchQuery.isEmpty {
            transcripts = transcripts.filter { transcript in
                transcript.displayTitle.localizedCaseInsensitiveContains(searchQuery)
            }
        }

        // Apply sort
        switch sortOrder {
        case .newest:
            transcripts.sort { $0.date > $1.date }
        case .oldest:
            transcripts.sort { $0.date < $1.date }
        case .longest:
            transcripts.sort { $0.durationSeconds > $1.durationSeconds }
        case .shortest:
            transcripts.sort { $0.durationSeconds < $1.durationSeconds }
        }

        return transcripts
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Title row
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Transcripts")
                        .font(.headingLarge)
                        .foregroundColor(.panelTextPrimary)

                    Text("\(allTranscripts.count) recordings")
                        .font(.bodySmall)
                        .foregroundColor(.panelTextSecondary)
                }

                Spacer()

                // Open folder button
                Button {
                    openTranscriptsFolder()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "folder")
                        Text("Open Folder")
                    }
                    .font(.bodySmall)
                    .foregroundColor(.panelTextSecondary)
                    .padding(.horizontal, Spacing.ms)
                    .padding(.vertical, Spacing.sm)
                    .background {
                        RoundedRectangle(cornerRadius: Radius.lawsButton)
                            .fill(Color.panelCharcoalElevated)
                    }
                }
                .buttonStyle(.plain)
            }

            // Search and sort row
            HStack(spacing: Spacing.md) {
                // Search field
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.panelTextMuted)

                    TextField("Search transcripts...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .foregroundColor(.panelTextPrimary)

                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.panelTextMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(Spacing.sm)
                .background {
                    RoundedRectangle(cornerRadius: Radius.lawsButton)
                        .fill(Color.panelCharcoalElevated)
                }

                // Sort picker
                Menu {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Button {
                            sortOrder = order
                        } label: {
                            HStack {
                                Text(order.rawValue)
                                if sortOrder == order {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(sortOrder.rawValue)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .font(.bodySmall)
                    .foregroundColor(.panelTextSecondary)
                    .padding(.horizontal, Spacing.ms)
                    .padding(.vertical, Spacing.sm)
                    .background {
                        RoundedRectangle(cornerRadius: Radius.lawsButton)
                            .fill(Color.panelCharcoalElevated)
                    }
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    // MARK: - Transcript List

    private var transcriptList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(filteredTranscripts) { transcript in
                    TranscriptListRow(transcript: transcript)
                }
            }
            .padding(Spacing.md)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            if searchQuery.isEmpty {
                // No transcripts at all
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundColor(.panelTextMuted)

                Text("No transcripts yet")
                    .font(.headingMedium)
                    .foregroundColor(.panelTextPrimary)

                Text("Start recording to build your transcript library")
                    .font(.bodyMedium)
                    .foregroundColor(.panelTextSecondary)
            } else {
                // No search results
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundColor(.panelTextMuted)

                Text("No matching transcripts")
                    .font(.headingMedium)
                    .foregroundColor(.panelTextPrimary)

                Text("Try a different search term")
                    .font(.bodyMedium)
                    .foregroundColor(.panelTextSecondary)

                Button {
                    searchQuery = ""
                } label: {
                    Text("Clear search")
                        .font(.bodySmall)
                        .foregroundColor(.recordingCoral)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func openTranscriptsFolder() {
        let url = TranscriptSaver.defaultSaveDirectory
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }
}

// MARK: - Transcript List Row

@available(macOS 14.0, *)
struct TranscriptListRow: View {

    let transcript: RecordingMetadata

    @State private var isHovered = false

    var body: some View {
        Button {
            revealInFinder()
        } label: {
            HStack(spacing: Spacing.md) {
                // Date column
                VStack(alignment: .leading, spacing: 2) {
                    Text(dayString)
                        .font(.headingSmall)
                        .foregroundColor(.panelTextPrimary)

                    Text(monthYearString)
                        .font(.caption)
                        .foregroundColor(.panelTextMuted)
                }
                .frame(width: 60, alignment: .leading)

                // Divider
                Rectangle()
                    .fill(Color.panelCharcoalSurface)
                    .frame(width: 1, height: 40)

                // Title and metadata
                VStack(alignment: .leading, spacing: 4) {
                    Text(transcript.displayTitle)
                        .font(.bodyMedium)
                        .foregroundColor(.panelTextPrimary)
                        .lineLimit(1)

                    HStack(spacing: Spacing.md) {
                        Label(timeString, systemImage: "clock")
                        Label(transcript.formattedDuration, systemImage: "timer")
                        if transcript.wordCount > 0 {
                            Label("\(transcript.wordCount) words", systemImage: "text.alignleft")
                        }
                        if transcript.speakerCount > 0 {
                            Label("\(transcript.speakerCount) speakers", systemImage: "person.2")
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.panelTextMuted)
                }

                Spacer()

                // Action indicator
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 18))
                    .foregroundColor(.panelTextMuted)
                    .opacity(isHovered ? 1 : 0.3)
            }
            .padding(Spacing.md)
            .background {
                RoundedRectangle(cornerRadius: Radius.lawsButton, style: .continuous)
                    .fill(isHovered ? Color.panelCharcoalElevated : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.lawsButton))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Date Formatting

    private var dayString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d"
        return formatter.string(from: transcript.date)
    }

    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: transcript.date)
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: transcript.date)
    }

    // MARK: - Actions

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

// MARK: - Preview

@available(macOS 14.0, *)
#Preview {
    TranscriptsView(
        statsService: StatsService.shared,
        searchQuery: .constant("")
    )
    .frame(width: 620, height: 600)
}

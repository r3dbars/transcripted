import SwiftUI

/// Simplified dashboard view - stats and recent transcripts only
/// No gamification, no achievements, no heat maps - just what matters
@available(macOS 26.0, *)
struct DashboardView: View {

    @ObservedObject var statsService: StatsService
    var failedTranscriptionManager: FailedTranscriptionManager?
    var taskManager: TranscriptionTaskManager?

    @State private var viewAppeared = false
    @State private var retryingIds: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Header with Open Folder button
                headerSection
                    .staggeredAppear(delay: 0)

                // Simple stats row
                statsSection
                    .staggeredAppear(delay: 0.1)

                // Failed transcriptions (only show if there are failures)
                if let manager = failedTranscriptionManager, manager.count > 0 {
                    failedTranscriptionsSection
                        .staggeredAppear(delay: 0.15)
                }

                // Recent transcripts
                RecentTranscriptsView(transcripts: statsService.recentTranscripts)
                    .frame(maxWidth: .infinity)
                    .staggeredAppear(delay: 0.2)
            }
            .padding(Spacing.lg)
        }
        .background(Color.panelCharcoal)
        .onAppear {
            viewAppeared = true
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Dashboard")
                    .font(.headingLarge)
                    .foregroundColor(.panelTextPrimary)

                Text("Your transcription activity")
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
                        .font(.system(size: 12))
                    Text("Open Folder")
                        .font(.bodySmall)
                }
                .foregroundColor(.panelTextSecondary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background {
                    RoundedRectangle(cornerRadius: Radius.lawsButton)
                        .fill(Color.panelCharcoalSurface)
                }
            }
            .buttonStyle(.plain)
            .help("Open transcripts folder in Finder")

            // Refresh button
            Button {
                Task {
                    await statsService.refreshStats()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14))
                    .foregroundColor(.panelTextSecondary)
            }
            .buttonStyle(.plain)
            .help("Refresh stats")
        }
    }

    // MARK: - Simple Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Period label
            Text("Last 30 days")
                .font(.caption)
                .foregroundColor(.panelTextMuted)
                .textCase(.uppercase)
                .tracking(1)

            // Simple inline stats
            HStack(spacing: Spacing.lg) {
                statItem(
                    value: "\(statsService.last30DaysRecordings)",
                    label: "meetings"
                )

                Text("•")
                    .foregroundColor(.panelTextMuted)

                statItem(
                    value: statsService.formattedLast30DaysDuration,
                    label: "recorded"
                )

                Text("•")
                    .foregroundColor(.panelTextMuted)

                statItem(
                    value: "\(statsService.last30DaysActionItems)",
                    label: "tasks"
                )
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radius.lawsCard)
                    .fill(Color.panelCharcoalElevated)
            }
        }
    }

    private func statItem(value: String, label: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Text(value)
                .font(.headingMedium)
                .foregroundColor(.panelTextPrimary)

            Text(label)
                .font(.bodySmall)
                .foregroundColor(.panelTextSecondary)
        }
    }

    // MARK: - Failed Transcriptions

    @ViewBuilder
    private var failedTranscriptionsSection: some View {
        if let manager = failedTranscriptionManager {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // Section header
                HStack {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.warningAmber)
                        Text("Failed Transcriptions")
                            .font(.bodyMedium)
                            .foregroundColor(.panelTextPrimary)
                        Text("(\(manager.count))")
                            .font(.bodySmall)
                            .foregroundColor(.panelTextMuted)
                    }

                    Spacer()

                    // Retry all button
                    if taskManager != nil, !manager.failedTranscriptions.isEmpty {
                        Button {
                            retryAllFailed()
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11))
                                Text("Retry All")
                                    .font(.caption)
                            }
                            .foregroundColor(.accentBlueLight)
                        }
                        .buttonStyle(.plain)
                        .disabled(!retryingIds.isEmpty)
                    }
                }

                // Failed items list
                VStack(spacing: Spacing.xs) {
                    ForEach(manager.failedTranscriptions.prefix(3)) { failed in
                        failedTranscriptionRow(failed)
                    }

                    // Show "and X more" if there are more than 3
                    if manager.count > 3 {
                        Text("and \(manager.count - 3) more...")
                            .font(.caption)
                            .foregroundColor(.panelTextMuted)
                            .padding(.top, Spacing.xs)
                    }
                }
                .padding(Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: Radius.lawsCard)
                        .fill(Color.panelCharcoalElevated)
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.lawsCard)
                                .stroke(Color.warningAmber.opacity(0.3), lineWidth: 1)
                        }
                }
            }
        }
    }

    private func failedTranscriptionRow(_ failed: FailedTranscription) -> some View {
        HStack(spacing: Spacing.sm) {
            // Timestamp
            VStack(alignment: .leading, spacing: 2) {
                Text(failed.formattedTimestamp)
                    .font(.bodySmall)
                    .foregroundColor(.panelTextPrimary)

                Text(failed.shortErrorMessage)
                    .font(.caption)
                    .foregroundColor(.panelTextMuted)
                    .lineLimit(1)
            }

            Spacer()

            // Retry button
            if retryingIds.contains(failed.id) {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 20, height: 20)
            } else if taskManager != nil {
                Button {
                    retryFailed(failed.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundColor(.accentBlueLight)
                }
                .buttonStyle(.plain)
                .help("Retry this transcription")
            }

            // Delete button
            Button {
                failedTranscriptionManager?.deleteFailedTranscription(id: failed.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(.panelTextMuted)
            }
            .buttonStyle(.plain)
            .help("Delete failed transcription")
        }
        .padding(.vertical, Spacing.xs)
    }

    private func retryFailed(_ id: UUID) {
        retryingIds.insert(id)

        Task {
            let success = await taskManager?.retryFailedTranscription(failedId: id) ?? false

            await MainActor.run {
                retryingIds.remove(id)
            }
        }
    }

    private func retryAllFailed() {
        guard let manager = failedTranscriptionManager else { return }

        for failed in manager.failedTranscriptions {
            retryFailed(failed.id)
        }
    }

    // MARK: - Actions

    private func openTranscriptsFolder() {
        let transcriptsFolder: URL
        if let customPath = UserDefaults.standard.string(forKey: "transcriptSaveLocation"),
           !customPath.isEmpty {
            transcriptsFolder = URL(fileURLWithPath: customPath)
        } else {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            transcriptsFolder = documentsPath.appendingPathComponent("Transcripted")
        }
        try? FileManager.default.createDirectory(at: transcriptsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(transcriptsFolder)
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview {
    DashboardView(
        statsService: StatsService.shared,
        failedTranscriptionManager: nil,
        taskManager: nil
    )
    .frame(width: 620, height: 600)
}

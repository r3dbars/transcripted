import SwiftUI

@available(macOS 26.0, *)
struct FailedTranscriptionsView: View {
    @ObservedObject var failedManager: FailedTranscriptionManager
    @ObservedObject var taskManager: TranscriptionTaskManager

    @State private var retryingIds: Set<UUID> = []
    @State private var showingDeleteConfirmation: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Failed Transcriptions")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("\(failedManager.count) failed transcription\(failedManager.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if !failedManager.failedTranscriptions.isEmpty {
                    Button(action: retryAll) {
                        Label("Retry All", systemImage: "arrow.clockwise")
                    }
                    .disabled(!retryingIds.isEmpty)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Content
            if failedManager.failedTranscriptions.isEmpty {
                // Empty state
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.green)

                    Text("No Failed Transcriptions")
                        .font(.headline)

                    Text("All your recordings have been successfully transcribed!")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()

            } else {
                // List of failed transcriptions
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(failedManager.failedTranscriptions) { failed in
                            FailedTranscriptionRow(
                                failed: failed,
                                isRetrying: retryingIds.contains(failed.id),
                                onRetry: { retry(failed.id) },
                                onDelete: { showingDeleteConfirmation = failed.id }
                            )
                            .padding(.horizontal)
                            .padding(.vertical, 8)

                            if failed.id != failedManager.failedTranscriptions.last?.id {
                                Divider()
                                    .padding(.leading, 16)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .alert("Delete Failed Transcription?", isPresented: .constant(showingDeleteConfirmation != nil)) {
            Button("Cancel", role: .cancel) {
                showingDeleteConfirmation = nil
            }
            Button("Delete", role: .destructive) {
                if let id = showingDeleteConfirmation {
                    delete(id)
                    showingDeleteConfirmation = nil
                }
            }
        } message: {
            Text("This will permanently delete the audio files. This action cannot be undone.")
        }
    }

    private func retry(_ id: UUID) {
        retryingIds.insert(id)

        Task {
            let success = await taskManager.retryFailedTranscription(failedId: id)

            await MainActor.run {
                retryingIds.remove(id)

                if success {
                    AppLogger.ui.info("Retry successful", ["id": "\(id)"])
                } else {
                    AppLogger.ui.error("Retry failed", ["id": "\(id)"])
                }
            }
        }
    }

    private func retryAll() {
        for failed in failedManager.failedTranscriptions {
            retry(failed.id)
        }
    }

    private func delete(_ id: UUID) {
        failedManager.deleteFailedTranscription(id: id)
    }
}

@available(macOS 26.0, *)
struct FailedTranscriptionRow: View {
    let failed: FailedTranscription
    let isRetrying: Bool
    let onRetry: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Status icon
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundColor(.orange)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                // Timestamp
                Text(failed.formattedTimestamp)
                    .font(.headline)

                // Error message
                Text(failed.shortErrorMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                // Metadata
                HStack(spacing: 12) {
                    Label(failed.formattedFileSize, systemImage: "doc.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if failed.retryCount > 0 {
                        Label("\(failed.retryCount) \(failed.retryCount == 1 ? "retry" : "retries")", systemImage: "arrow.clockwise")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    if let lastRetry = failed.lastRetryDate {
                        Label("Last: \(relativeTimeString(for: lastRetry))", systemImage: "clock")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Actions
            HStack(spacing: 8) {
                if isRetrying {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 20, height: 20)
                } else {
                    Button(action: onRetry) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Retry transcription")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Delete audio files")
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private func relativeTimeString(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

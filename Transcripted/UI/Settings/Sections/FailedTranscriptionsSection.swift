import SwiftUI

@available(macOS 26.0, *)
struct FailedTranscriptionsSettingsSection: View {

    var failedTranscriptionManager: FailedTranscriptionManager?
    var taskManager: TranscriptionTaskManager?
    @Binding var retryingIds: Set<UUID>

    @ViewBuilder
    var body: some View {
        if let manager = failedTranscriptionManager {
            VStack(alignment: .leading, spacing: Spacing.sm) {
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

                    if taskManager != nil, !manager.failedTranscriptions.isEmpty {
                        Button {
                            for failed in manager.failedTranscriptions {
                                retryFailed(failed.id)
                            }
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

                VStack(spacing: Spacing.xs) {
                    ForEach(manager.failedTranscriptions.prefix(3)) { failed in
                        HStack(spacing: Spacing.sm) {
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
                            }
                            Button {
                                failedTranscriptionManager?.deleteFailedTranscription(id: failed.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10))
                                    .foregroundColor(.panelTextMuted)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, Spacing.xs)
                    }

                    if manager.count > 3 {
                        Text("and \(manager.count - 3) more...")
                            .font(.caption)
                            .foregroundColor(.panelTextMuted)
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

    private func retryFailed(_ id: UUID) {
        retryingIds.insert(id)
        Task {
            let _ = await taskManager?.retryFailedTranscription(failedId: id) ?? false
            await MainActor.run { retryingIds.remove(id) }
        }
    }
}

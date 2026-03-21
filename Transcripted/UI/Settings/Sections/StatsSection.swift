import SwiftUI

@available(macOS 26.0, *)
struct StatsSettingsSection: View {

    @ObservedObject var statsService: StatsService
    var openTranscriptsFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("ALL TIME")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.panelTextMuted)
                .tracking(0.8)

            HStack(spacing: Spacing.md) {
                HStack(spacing: Spacing.lg) {
                    statItem(
                        value: "\(statsService.totalRecordings)",
                        label: "meetings"
                    )

                    Text("|")
                        .foregroundColor(.panelTextMuted)

                    statItem(
                        value: statsService.formattedTotalHours,
                        label: "recorded"
                    )
                }

                Spacer()

                // Open folder + Refresh
                HStack(spacing: Spacing.sm) {
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

                    Button {
                        Task { await statsService.refreshStats() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13))
                            .foregroundColor(.panelTextMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
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
}

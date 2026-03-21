import SwiftUI

@available(macOS 26.0, *)
struct SpeakerIntelligenceSettingsSection: View {

    @Binding var enableQwenInference: Bool
    @ObservedObject var qwenService: QwenService
    @Binding var qwenModelCached: Bool

    var body: some View {
        SettingsSectionCard(icon: "sparkles", title: "Speaker Intelligence") {
            VStack(alignment: .leading, spacing: Spacing.md) {
                SettingsToggleRow(
                    title: "Auto-Detect Speaker Names",
                    description: "Uses Qwen 4B to infer names from conversation context",
                    isOn: $enableQwenInference
                )

                Divider().background(Color.panelCharcoalSurface)

                // Model status + download
                HStack(spacing: Spacing.sm) {
                    Image(systemName: qwenModelStatusIcon)
                        .font(.system(size: 12))
                        .foregroundColor(qwenModelStatusColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Qwen 3.5-4B")
                            .font(.bodySmall)
                            .foregroundColor(.panelTextPrimary)

                        Text(qwenModelStatusText)
                            .font(.caption)
                            .foregroundColor(.panelTextMuted)
                    }

                    Spacer()

                    if qwenModelCached {
                        localBadge
                    } else if case .downloading(let progress) = qwenService.modelState {
                        // Download progress bar
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.panelTextMuted)
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .frame(width: 80)
                                .tint(.accentBlue)
                        }
                    } else if case .loading = qwenService.modelState {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 20, height: 20)
                    } else if case .failed = qwenService.modelState {
                        Button {
                            downloadQwenModel()
                        } label: {
                            Text("Retry")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.accentBlueLight)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            downloadQwenModel()
                        } label: {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 11))
                                Text("Download")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.accentBlueLight)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentBlue.opacity(0.15))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Reads the first 15 minutes of transcript to extract names from greetings and introductions. Runs 100% on-device.")
                    .font(.caption)
                    .foregroundColor(.panelTextMuted)
            }
        }
    }

    private var localBadge: some View {
        Text("Local")
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(.panelTextMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.panelCharcoalSurface)
            .cornerRadius(4)
    }

    // MARK: - Qwen Model Helpers

    private var qwenModelStatusIcon: String {
        if qwenModelCached { return "checkmark.circle.fill" }
        switch qwenService.modelState {
        case .downloading: return "arrow.down.circle.fill"
        case .loading: return "circle.dotted"
        case .failed: return "exclamationmark.circle.fill"
        default: return "arrow.down.circle"
        }
    }

    private var qwenModelStatusColor: Color {
        if qwenModelCached { return .attentionGreen }
        switch qwenService.modelState {
        case .downloading: return .accentBlue
        case .failed: return .errorRed
        default: return .panelTextMuted
        }
    }

    private var qwenModelStatusText: String {
        if qwenModelCached { return "Cached locally" }
        switch qwenService.modelState {
        case .downloading(let progress): return "Downloading… \(Int(progress * 100))%"
        case .loading: return "Loading model…"
        case .failed(let msg): return "Failed: \(msg)"
        default: return "Not downloaded (~2.5 GB)"
        }
    }

    private func downloadQwenModel() {
        Task {
            await qwenService.loadModel()
            if case .ready = qwenService.modelState {
                qwenModelCached = true
                qwenService.unload()  // Free memory — we just wanted to cache it
            }
        }
    }
}

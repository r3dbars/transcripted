import SwiftUI

/// Model Setup step - Downloads and initializes AI models
/// Dark theme with progress bars matching pill aesthetic
@available(macOS 26.0, *)
struct ModelSetupStep: View {
    @Bindable var state: OnboardingState
    @State private var appeared = false

    var body: some View {
        VStack(spacing: Spacing.lg) {
            VStack(spacing: Spacing.sm) {
                Text("Setting Up AI Models")
                    .font(.displayMedium)
                    .foregroundColor(.panelTextPrimary)

                Text("Downloading speech recognition models for local use")
                    .font(.bodyLarge)
                    .foregroundColor(.panelTextSecondary)
            }
            .padding(.top, Spacing.lg)

            VStack(spacing: Spacing.md) {
                ModelDownloadCard(
                    icon: "waveform",
                    title: "Speech Recognition",
                    description: "Parakeet TDT V3 — converts speech to text",
                    isReady: state.parakeetReady,
                    isLoading: state.isLoadingModels && !state.parakeetReady,
                    progress: state.parakeetProgress,
                    phaseText: state.parakeetPhase
                )

                ModelDownloadCard(
                    icon: "person.2.fill",
                    title: "Speaker Diarization",
                    description: "PyAnnote — identifies who said what",
                    isReady: state.diarizationReady,
                    isLoading: state.isLoadingModels && !state.diarizationReady,
                    progress: state.diarizationProgress,
                    phaseText: state.diarizationPhase
                )
            }
            .padding(.horizontal, Spacing.lg)

            Spacer()

            if state.isLoadingModels && state.downloadSpeed > 1000 {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.panelTextMuted)

                    Text(formatSpeed(state.downloadSpeed))
                        .font(.caption)
                        .foregroundColor(.panelTextMuted)

                    if let eta = state.estimatedTimeRemaining, eta > 0, eta < 3600 {
                        Text("—")
                            .font(.caption)
                            .foregroundColor(.panelTextMuted.opacity(0.5))
                        Text("~\(formatETA(eta)) remaining")
                            .font(.caption)
                            .foregroundColor(.panelTextMuted)
                    }
                }
                .transition(.opacity)
            }

            if let error = state.modelError, !state.isLoadingModels {
                VStack(spacing: Spacing.sm) {
                    VStack(spacing: Spacing.xs) {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: errorIcon(for: state.modelErrorKind))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.errorRed)
                            Text(state.modelErrorKind?.title ?? "Download Failed")
                                .font(.bodyMedium)
                                .fontWeight(.semibold)
                                .foregroundColor(.panelTextPrimary)
                        }

                        Text(error)
                            .font(.bodySmall)
                            .foregroundColor(.panelTextSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.md)
                            .fill(Color.errorRed.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.md)
                            .strokeBorder(Color.errorRed.opacity(0.2), lineWidth: 1)
                    )

                    Button("Retry Download") {
                        Task { await state.loadModels() }
                    }
                    .buttonStyle(.bordered)
                    .tint(.recordingCoral)
                }
                .padding(.horizontal, Spacing.xxl)
                .transition(.opacity)
            }

            if state.modelsReady {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.attentionGreen)
                    Text("Models ready — everything runs locally on your Mac")
                        .font(.bodyMedium)
                        .foregroundColor(.panelTextPrimary)
                }
                .padding(Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Radius.lg)
                        .fill(Color.attentionGreen.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.lg)
                        .strokeBorder(Color.attentionGreen.opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal, Spacing.xxl)
                .padding(.bottom, Spacing.lg)
                .transition(.opacity)
            }
        }
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.3)) {
                appeared = true
            }
            if !state.modelsReady && !state.isLoadingModels {
                Task { await state.loadModels() }
            }
        }
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        } else if bytesPerSecond >= 1_000 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
        }
        return ""
    }

    private func formatETA(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return "\(Int(seconds))s"
        } else {
            let minutes = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(minutes)m \(secs)s"
        }
    }

    private func errorIcon(for kind: DownloadErrorKind?) -> String {
        switch kind {
        case .networkOffline: return "wifi.slash"
        case .tlsFailure: return "lock.slash"
        case .timeout: return "clock.badge.exclamationmark"
        case .diskSpace: return "externaldrive.badge.xmark"
        case .serverError: return "server.rack"
        default: return "exclamationmark.triangle.fill"
        }
    }
}

// MARK: - Model Download Card

@available(macOS 26.0, *)
private struct ModelDownloadCard: View {
    let icon: String
    let title: String
    let description: String
    let isReady: Bool
    let isLoading: Bool
    let progress: Double
    let phaseText: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.12))
                        .frame(width: 44, height: 44)

                    if isReady {
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.attentionGreen)
                    } else if isLoading {
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.recordingCoral)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.panelTextMuted)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.bodyMedium)
                        .fontWeight(.semibold)
                        .foregroundColor(.panelTextPrimary)

                    Text(description)
                        .font(.bodySmall)
                        .foregroundColor(.panelTextSecondary)

                    if isLoading {
                        Text(phaseText)
                            .font(.caption)
                            .foregroundColor(.recordingCoral)
                            .lineLimit(1)
                    } else if isReady {
                        Text("Ready")
                            .font(.caption)
                            .foregroundColor(.attentionGreen)
                    }
                }

                Spacer()
            }

            if isLoading {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.panelCharcoalSurface)
                            .frame(height: 6)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.recordingCoral)
                            .frame(width: max(0, geo.size.width * progress), height: 6)
                            .animation(.easeInOut, value: progress)
                    }
                }
                .frame(height: 6)
            }
        }
        .padding(Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.lg)
                .fill(isReady ? Color.attentionGreen.opacity(0.08) : Color.panelCharcoalElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(
                    isReady ? Color.attentionGreen.opacity(0.3) :
                    isLoading ? Color.recordingCoral.opacity(0.3) :
                    Color.panelCharcoalSurface,
                    lineWidth: 1
                )
        )
    }

    private var statusColor: Color {
        if isReady { return .attentionGreen }
        if isLoading { return .recordingCoral }
        return .panelTextMuted
    }
}

// MARK: - Preview

#if DEBUG
@available(macOS 26.0, *)
#Preview("Loading") {
    let state = OnboardingState()
    state.isLoadingModels = true
    return ModelSetupStep(state: state)
        .frame(width: 640, height: 560)
        .background(Color.panelCharcoal)
}

@available(macOS 26.0, *)
#Preview("Ready") {
    let state = OnboardingState()
    state.parakeetReady = true
    state.diarizationReady = true
    return ModelSetupStep(state: state)
        .frame(width: 640, height: 560)
        .background(Color.panelCharcoal)
}

@available(macOS 26.0, *)
#Preview("Error") {
    let state = OnboardingState()
    state.modelError = "Network connection failed"
    return ModelSetupStep(state: state)
        .frame(width: 640, height: 560)
        .background(Color.panelCharcoal)
}
#endif

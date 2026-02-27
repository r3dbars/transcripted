import SwiftUI

/// Main container view for the settings window
/// Displays sidebar navigation on the left and content area on the right
@available(macOS 26.0, *)
struct SettingsContainerView: View {

    @ObservedObject var statsService: StatsService
    @ObservedObject var navigationState: SettingsNavigationState
    var failedTranscriptionManager: FailedTranscriptionManager?
    var taskManager: TranscriptionTaskManager?

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            SettingsSidebarView(
                selectedTab: $navigationState.selectedTab,
                statsService: statsService
            )
            .frame(width: 180)

            // Divider
            Rectangle()
                .fill(Color.panelCharcoalSurface)
                .frame(width: 1)

            // Content area
            ZStack {
                Color.panelCharcoal
                    .ignoresSafeArea()

                contentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, maxWidth: 1200, minHeight: 500, maxHeight: 900)
        .background(Color.panelCharcoal)
        // Migration overlay
        .overlay {
            if navigationState.isMigrating {
                MigrationOverlayView(
                    progress: navigationState.migrationProgress,
                    status: navigationState.migrationStatus
                )
            }
        }
        // Migration complete alert
        .alert("Migration Complete", isPresented: $navigationState.showMigrationComplete) {
            Button("OK") {
                navigationState.showMigrationComplete = false
            }
        } message: {
            Text("Successfully imported \(navigationState.migratedCount) existing transcripts to your dashboard.")
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch navigationState.selectedTab {
        case .dashboard:
            DashboardView(
                statsService: statsService,
                failedTranscriptionManager: failedTranscriptionManager,
                taskManager: taskManager
            )
            .transition(.opacity.combined(with: .move(edge: .trailing)))

        case .preferences:
            PreferencesView()
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
    }
}

// MARK: - Migration Overlay

@available(macOS 26.0, *)
struct MigrationOverlayView: View {
    let progress: Double
    let status: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            VStack(spacing: Spacing.lg) {
                // Icon
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 48))
                    .foregroundColor(.recordingCoral)
                    .rotationEffect(.degrees(progress * 360))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: progress)

                // Title
                Text("Importing Transcripts")
                    .font(.headingLarge)
                    .foregroundColor(.panelTextPrimary)

                // Progress bar
                VStack(spacing: Spacing.sm) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            // Background
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.panelCharcoalSurface)
                                .frame(height: 8)

                            // Progress
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.recordingCoral)
                                .frame(width: geometry.size.width * progress, height: 8)
                                .animation(.easeInOut(duration: 0.2), value: progress)
                        }
                    }
                    .frame(height: 8)
                    .frame(width: 300)

                    // Status text
                    Text(status)
                        .font(.bodySmall)
                        .foregroundColor(.panelTextSecondary)
                        .lineLimit(1)
                }

                // Percentage
                Text("\(Int(progress * 100))%")
                    .font(.headingMedium)
                    .foregroundColor(.panelTextMuted)
            }
            .padding(Spacing.xl)
            .background {
                RoundedRectangle(cornerRadius: Radius.lawsCard)
                    .fill(Color.panelCharcoalElevated)
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            }
        }
    }
}

// MARK: - Preview

@available(macOS 26.0, *)
#Preview {
    SettingsContainerView(
        statsService: StatsService.shared,
        navigationState: SettingsNavigationState()
    )
}

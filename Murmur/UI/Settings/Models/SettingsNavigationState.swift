import SwiftUI
import Combine

/// Navigation tab options for the settings window
enum SettingsTab: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case preferences = "Preferences"

    var id: String { rawValue }

    /// SF Symbol icon for the tab
    var icon: String {
        switch self {
        case .dashboard: return "chart.bar.fill"
        case .preferences: return "gearshape.fill"
        }
    }

    /// Description for accessibility
    var accessibilityLabel: String {
        switch self {
        case .dashboard: return "Dashboard with stats and activity"
        case .preferences: return "App preferences and settings"
        }
    }
}

/// Observable state manager for settings navigation
@available(macOS 14.0, *)
@MainActor
final class SettingsNavigationState: ObservableObject {

    /// Currently selected tab
    @Published var selectedTab: SettingsTab = .dashboard

    /// Whether migration is in progress
    @Published var isMigrating: Bool = false

    /// Migration progress (0.0 to 1.0)
    @Published var migrationProgress: Double = 0

    /// Migration status message
    @Published var migrationStatus: String = ""

    /// Whether to show migration complete alert
    @Published var showMigrationComplete: Bool = false

    /// Number of transcripts migrated
    @Published var migratedCount: Int = 0

    init() {}

    /// Select a tab with animation
    func selectTab(_ tab: SettingsTab) {
        withAnimation(.lawsStateChange) {
            selectedTab = tab
        }
    }

    /// Start migration process
    func startMigration() async {
        isMigrating = true
        migrationProgress = 0
        migrationStatus = "Scanning transcripts..."

        let count = await TranscriptScanner.migrateExistingTranscripts { progress, status in
            Task { @MainActor in
                self.migrationProgress = progress
                self.migrationStatus = status
            }
        }

        migratedCount = count
        isMigrating = false

        if count > 0 {
            showMigrationComplete = true
        }
    }

    /// Check if migration is needed
    func checkMigrationNeeded() -> Bool {
        return TranscriptScanner.needsMigration()
    }
}

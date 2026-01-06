import SwiftUI

/// Main dashboard view displaying stats, activity, and recent transcripts
/// "Night Studio" aesthetic with premium cards and staggered animations
@available(macOS 14.0, *)
struct DashboardView: View {

    @ObservedObject var statsService: StatsService
    @StateObject private var achievementManager = AchievementManager.shared
    @State private var viewAppeared = false

    /// Determine if stats are "glowing" (above average performance)
    private var isGlowingUp: Bool {
        // Glow when user has high engagement: 7+ day streak or 10+ recordings this month
        statsService.currentStreak >= 7 || statsService.last30DaysRecordings >= 10
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    // Header (immediate)
                    headerSection
                        .staggeredAppear(delay: 0)

                    // Stats cards row with optional glow effect (100ms delay)
                    ZStack {
                        // "The Glow Up" - warm glow behind stats when performing well
                        if isGlowingUp {
                            GlowUpEffect(isActive: isGlowingUp, color: .recordingCoral)
                                .frame(height: 200)
                                .offset(y: 20)
                                .allowsHitTesting(false)
                        }

                        statsCardsSection
                    }
                    .staggeredAppear(delay: 0.1)

                    // Motivational message (150ms delay)
                    motivationalSection
                        .staggeredAppear(delay: 0.15)

                    // Activity section - expanded full width heat map (200ms delay)
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        Text("Activity")
                            .font(.caption)
                            .foregroundColor(.panelTextMuted)
                            .textCase(.uppercase)
                            .tracking(1)

                        HeatMapView(statsService: statsService)
                            .frame(maxWidth: .infinity)
                    }
                    .staggeredAppear(delay: 0.2)

                    // Recent transcripts (250ms delay)
                    RecentTranscriptsView(transcripts: statsService.recentTranscripts)
                        .frame(maxWidth: .infinity)
                        .staggeredAppear(delay: 0.25)
                }
                .padding(Spacing.lg)
            }
            .background(Color.panelCharcoal)

            // Achievement overlay
            if let achievement = achievementManager.pendingAchievement {
                AchievementView(achievement: achievement) {
                    achievementManager.dismissAchievement()
                }
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .onAppear {
            viewAppeared = true
            // Check for achievements when view appears
            checkForAchievements()
        }
    }

    private func checkForAchievements() {
        achievementManager.checkAchievements(
            totalRecordings: statsService.totalRecordings,
            currentStreak: statsService.currentStreak,
            totalActionItems: statsService.totalActionItems,
            totalHours: statsService.totalHoursTranscribed
        )
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Dashboard")
                    .font(.headingLarge)
                    .foregroundColor(.panelTextPrimary)

                Text("Your transcription activity at a glance")
                    .font(.bodySmall)
                    .foregroundColor(.panelTextSecondary)
            }

            Spacer()

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

    // MARK: - Stats Cards

    private var statsCardsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Period label
            Text("Last 30 days")
                .font(.caption)
                .foregroundColor(.panelTextMuted)
                .textCase(.uppercase)
                .tracking(1)

            // Stats row
            HStack(spacing: Spacing.md) {
                // Main stats
                StatsCardView(
                    icon: "clock.fill",
                    value: statsService.formattedLast30DaysDuration,
                    label: "Time Transcribed"
                )

                StatsCardView(
                    icon: "doc.text.fill",
                    value: "\(statsService.last30DaysRecordings)",
                    label: "Meetings"
                )

                StatsCardView(
                    icon: "checkmark.circle.fill",
                    value: "\(statsService.last30DaysActionItems)",
                    label: "Action Items",
                    accentColor: .attentionGreen
                )

                // Streak card
                StreakCardView(
                    streak: statsService.currentStreak,
                    isActive: statsService.currentStreak > 0
                )
            }
        }
    }

    // MARK: - Motivational Message

    @ViewBuilder
    private var motivationalSection: some View {
        if !statsService.motivationalMessage.isEmpty {
            HStack(spacing: Spacing.sm) {
                Text(statsService.motivationalMessage)
                    .font(.bodyMedium)
                    .foregroundColor(.accentBlueLight)
                    .italic()
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radius.lawsButton, style: .continuous)
                    .fill(Color.accentBlue.opacity(0.1))
            }
        }
    }
}

// MARK: - All Time Stats (Optional additional section)

@available(macOS 14.0, *)
struct AllTimeStatsSection: View {

    @ObservedObject var statsService: StatsService

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Header with toggle
            Button {
                withAnimation(.lawsStateChange) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("All Time Stats")
                        .font(.headingSmall)
                        .foregroundColor(.panelTextPrimary)

                    Spacer()

                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundColor(.panelTextSecondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                // All time stats grid
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: Spacing.md) {
                    StatPill(label: "Total Recordings", value: "\(statsService.totalRecordings)")
                    StatPill(label: "Total Hours", value: statsService.formattedTotalHours)
                    StatPill(label: "Avg Duration", value: statsService.formattedAverageDuration)
                    StatPill(label: "Action Items", value: "\(statsService.totalActionItems)")
                    StatPill(label: "Longest Streak", value: "\(statsService.longestStreak) days")
                    StatPill(label: "Current Streak", value: "\(statsService.currentStreak) days")
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                .fill(Color.panelCharcoalElevated)
        }
    }
}

// MARK: - Stat Pill

@available(macOS 14.0, *)
struct StatPill: View {

    let label: String
    let value: String

    var body: some View {
        VStack(spacing: Spacing.xs) {
            Text(value)
                .font(.headingMedium)
                .foregroundColor(.panelTextPrimary)

            Text(label)
                .font(.caption)
                .foregroundColor(.panelTextMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
    }
}

// MARK: - Empty Dashboard State

@available(macOS 14.0, *)
struct EmptyDashboardView: View {

    var body: some View {
        VStack(spacing: Spacing.xl) {
            // Illustration
            ZStack {
                Circle()
                    .fill(Color.panelCharcoalSurface)
                    .frame(width: 120, height: 120)

                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 48))
                    .foregroundColor(.panelTextMuted)
            }

            // Text
            VStack(spacing: Spacing.sm) {
                Text("No recordings yet")
                    .font(.headingMedium)
                    .foregroundColor(.panelTextPrimary)

                Text("Start your first recording to see your stats and activity here.")
                    .font(.bodyMedium)
                    .foregroundColor(.panelTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            // Hint
            HStack(spacing: Spacing.xs) {
                Image(systemName: "lightbulb.fill")
                    .font(.caption)
                    .foregroundColor(.warningAmber)

                Text("Click the floating pill near your dock to start recording")
                    .font(.caption)
                    .foregroundColor(.panelTextMuted)
            }
            .padding(Spacing.sm)
            .background {
                RoundedRectangle(cornerRadius: Radius.lawsButton)
                    .fill(Color.warningAmber.opacity(0.1))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Spacing.xxl)
    }
}

// MARK: - Preview

@available(macOS 14.0, *)
#Preview {
    DashboardView(statsService: StatsService.shared)
        .frame(width: 620, height: 600)
}

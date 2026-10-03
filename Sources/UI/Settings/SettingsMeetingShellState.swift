import Foundation
import TranscriptedCore

/// The meeting-session values the Settings shell reads, as plain values.
/// The shell holds the session as a plain `let` and re-renders through
/// `SettingsShellMeetingRenderGate`, which publishes only when this (or
/// Home's displayed percent, or the wall minute) changes. Recording time
/// and raw progress are left out on purpose: they tick many times a second.
///
/// Anything new the shell reads from `meetingSession` in its body belongs
/// here, or the window won't redraw when it changes.
struct SettingsMeetingShellState: Equatable {
    let state: MeetingSessionController.State
    /// Home's activity row with `progress` cleared; the percent it shows is
    /// in the key separately, only while Home is selected.
    let activity: HomeTranscriptionActivityPresentation?
    /// The session is preparing, transcribing or saving (Home's Cancel).
    let isProcessing: Bool
    let warmupStatus: MeetingSessionController.ModelWarmupStatus
    let lastSavedTitle: String?
    let lastSavedTranscriptURL: URL?
    let savedMeetingReplacementCommitCount: Int
    let failedMeetings: [MeetingSessionController.FailedMeetingItem]
    let hasRuntimeDiagnosticsWork: Bool
    let isSpeakerReviewPending: Bool

    @MainActor
    init(
        session: MeetingSessionController,
        activity: HomeTranscriptionActivityPresentation?
    ) {
        state = session.state
        self.activity = activity.map(Self.withoutProgress)
        isProcessing = session.displayStatus.isProcessing
        warmupStatus = session.warmupStatus
        lastSavedTitle = session.lastSavedTitle
        lastSavedTranscriptURL = session.lastSavedTranscriptURL
        savedMeetingReplacementCommitCount = session.savedMeetingReplacementCommitCount
        failedMeetings = session.failedMeetings
        hasRuntimeDiagnosticsWork = session.hasRuntimeDiagnosticsWork
        isSpeakerReviewPending = session.isSpeakerReviewPending
    }

    @MainActor
    static func homeActivity(for session: MeetingSessionController) -> HomeTranscriptionActivityPresentation? {
        HomeTranscriptionActivityPresentation.make(
            sessionState: session.state,
            displayStatus: session.displayStatus,
            warmupStatus: session.warmupStatus,
            lastSavedTitle: session.lastSavedTitle,
            lastSavedTranscriptURL: session.lastSavedTranscriptURL
        )
    }

    private static func withoutProgress(
        _ activity: HomeTranscriptionActivityPresentation
    ) -> HomeTranscriptionActivityPresentation {
        HomeTranscriptionActivityPresentation(
            symbolName: activity.symbolName,
            title: activity.title,
            status: activity.status,
            detail: activity.detail,
            tone: activity.tone,
            progress: nil,
            transcriptURL: activity.transcriptURL
        )
    }
}

typealias SettingsShellMeetingRenderGate = SettingsMeetingRenderGate<SettingsMeetingRenderKey<SettingsMeetingShellState>>

extension SettingsMeetingRenderGate where Key == SettingsMeetingRenderKey<SettingsMeetingShellState> {
    /// Watches every session change, but publishes only when something the
    /// shell shows changed.
    convenience init(
        session: MeetingSessionController,
        navigation: TranscriptedSettingsNavigationModel,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.init(
            changes: session.objectWillChange,
            makeKey: {
                let activity = SettingsMeetingShellState.homeActivity(for: session)
                return SettingsMeetingRenderKey.make(
                    coarse: SettingsMeetingShellState(session: session, activity: activity),
                    activityProgress: activity?.progress,
                    showsActivityPercent: navigation.selectedPage == .home,
                    now: now()
                )
            }
        )
    }
}

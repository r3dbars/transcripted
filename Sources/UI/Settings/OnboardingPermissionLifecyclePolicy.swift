import Foundation

/// What onboarding does when its window's lifecycle moves. Permission state is
/// refreshed from bounded events (the app coming back, a permission change),
/// never by polling, and a live system-audio check only ever starts from its
/// explicit button, so no event here can start one.
enum OnboardingPermissionLifecyclePolicy {
    enum Event: CaseIterable {
        /// The app became active again, usually back from System Settings.
        case appBecameActive
        /// Something posted `transcriptedPermissionsDidChange`.
        case permissionsChanged
        /// App-termination cleanup is about to quit the app.
        case appWillTerminate
        /// The onboarding window went away.
        case windowDisappeared
    }

    /// Run in this order: `clearSystemSettingsHandoff`, `cancelSystemAudioCheck`,
    /// `refreshPermissions`, `trackAbandonment`.
    struct Effects: OptionSet, Equatable {
        let rawValue: Int

        /// The user is back from System Settings, so leaving now isn't a
        /// System Settings handoff.
        static let clearSystemSettingsHandoff = Effects(rawValue: 1 << 0)
        /// Stop an in-flight system-audio check; its late result is dropped.
        static let cancelSystemAudioCheck = Effects(rawValue: 1 << 1)
        /// Re-read permission state (prompt-free) and track what changed.
        static let refreshPermissions = Effects(rawValue: 1 << 2)
        /// Report the flow as abandoned unless it already finished.
        static let trackAbandonment = Effects(rawValue: 1 << 3)
    }

    static func effects(for event: Event) -> Effects {
        switch event {
        case .appBecameActive:
            return [.clearSystemSettingsHandoff, .refreshPermissions]
        case .permissionsChanged:
            return [.refreshPermissions]
        case .appWillTerminate:
            return [.trackAbandonment]
        case .windowDisappeared:
            return [.cancelSystemAudioCheck, .trackAbandonment]
        }
    }

    /// What a finished system-audio check puts on screen.
    struct SystemAudioCheckResult: Equatable {
        let state: TranscriptedPermissionAccess.SystemAudioPermissionState
        let probeResult: TranscriptedPermissionAccess.SystemAudioPermissionProbeResult?
        let isGranted: Bool
    }

    /// Nil when the check was cancelled (onboarding was left): its late
    /// result must not touch the screen. Otherwise the typed result, so an
    /// unknown answer isn't collapsed into a plain "not granted".
    static func systemAudioCheckResult(
        _ decision: TranscriptedPermissionAccess.SystemAudioPermissionAccessDecision,
        checkWasCancelled: Bool
    ) -> SystemAudioCheckResult? {
        guard !checkWasCancelled else { return nil }
        return SystemAudioCheckResult(
            state: decision.state,
            probeResult: decision.probeResult,
            isGranted: decision.state.isGranted
        )
    }
}

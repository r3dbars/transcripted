import SwiftUI

/// Single owner for the "revalidate System Audio Recording permission for
/// status surfaces" pattern.
///
/// Two Settings surfaces need to re-check the live System Audio Recording
/// permission state whenever their view becomes active or polls — the
/// Settings shell (`TranscriptedSettingsView`) and onboarding
/// (`PermissionsOnboardingView`) — and both used to hand-roll identical
/// guard/task/completion logic. This is the one place that logic lives now;
/// both call sites route through it so the in-flight-task guard and the
/// "skip when status is already known-unknown" check can't drift apart.
///
/// `@MainActor` because both call sites are `View`-conforming SwiftUI types
/// (implicitly main-actor isolated).
@MainActor
enum SystemAudioPermissionRevalidator {
    /// Revalidates System Audio Recording permission if a revalidation isn't
    /// already in flight for this call site.
    ///
    /// - Parameters:
    ///   - task: the call site's own `@State` task slot. Used both to
    ///     prevent overlapping revalidation runs and so the caller can cancel
    ///     it directly (e.g. on `onDisappear`).
    ///   - onUpdated: runs on the main actor after revalidation completes, so
    ///     the caller can refresh its own permission-state mirror.
    static func revalidateForStatusSurfaces(
        task: Binding<Task<Void, Never>?>,
        onUpdated: @escaping () -> Void
    ) {
        guard task.wrappedValue == nil else { return }
        guard TranscriptedPermissionAccess.systemAudioRecordingStatus() != .unknown else { return }
        task.wrappedValue = Task { @MainActor in
            _ = await TranscriptedPermissionAccess.revalidateSystemAudioRecordingStatus()
            onUpdated()
            task.wrappedValue = nil
        }
    }
}

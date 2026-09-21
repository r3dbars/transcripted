import SwiftUI

/// Single owner for the "revalidate System Audio Recording permission for
/// status surfaces" pattern.
///
/// The Settings shell re-checks previously known System Audio Recording
/// evidence through this helper. Onboarding instead owns an explicit,
/// cancellable Check action; activating onboarding must not start a probe.
///
/// `@MainActor` because the call site is a `View`-conforming SwiftUI type
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

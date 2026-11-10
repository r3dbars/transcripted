import Foundation

/// Admission for a new capture across its permission await. Existing capture
/// teardown and permission-request cancellation keep their own lifecycles.
@MainActor
enum MeetingRecordingStartAdmission {
    static func resolve<Decision>(
        isAllowed: @MainActor () -> Bool,
        permission: @MainActor () async -> Decision
    ) async -> Decision? {
        guard isAllowed() else { return nil }
        let decision = await permission()
        guard isAllowed() else { return nil }
        return decision
    }
}

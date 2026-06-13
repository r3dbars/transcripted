import Foundation

/// Foundation-pure resolver for the Auto Enter app display-name fallback chain,
/// extracted from `TranscriptedSettingsView.autoEnterDisplayName(for:)`.
///
/// Resolution order (unchanged from the original inline implementation):
/// 1. a matching in-memory candidate's name (running-app candidate list)
/// 2. a workspace/app-name lookup, INJECTED as a closure so the real
///    `NSWorkspace.shared.urlForApplication(...)` lookup stays in the view while
///    this decision stays testable without a real app install
/// 3. the raw bundle identifier as a last-resort fallback
enum AutoEnterDisplayNameResolver {
    /// - Parameters:
    ///   - bundleID: the bundle identifier whose display name is being resolved.
    ///   - candidateNames: bundleID → display-name pairs for the currently known
    ///     app candidates (mirrors `autoEnterAppCandidates`). The first matching
    ///     bundleID wins, matching the original `first(where:)` semantics.
    ///   - workspaceLookup: returns the workspace-derived display name for a
    ///     bundle identifier, or `nil` when no app is installed for it. In the
    ///     real view this is the deletingPathExtension().lastPathComponent of the
    ///     URL returned by `NSWorkspace.shared.urlForApplication(...)`.
    static func resolve(
        bundleID: String,
        candidateNames: [(bundleID: String, name: String)],
        workspaceLookup: (String) -> String?
    ) -> String {
        if let candidate = candidateNames.first(where: { $0.bundleID == bundleID }) {
            return candidate.name
        }

        if let workspaceName = workspaceLookup(bundleID) {
            return workspaceName
        }

        return bundleID
    }
}

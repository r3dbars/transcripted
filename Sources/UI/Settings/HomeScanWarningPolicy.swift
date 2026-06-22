import Foundation

/// Copy + presentation model for the Home capture-library scan warning card.
///
/// The card names what went wrong with the meetings folder and keeps a clear
/// action hierarchy: a primary Retry, a Reveal-in-Finder escape hatch, and a
/// Dismiss so the user can clear the card after they've looked.
struct HomeScanWarningCardModel: Equatable {
    let title: String
    let detail: String
    let retryTitle: String
    let revealTitle: String
}

/// Foundation-pure mapping from a meetings-folder scan diagnosis to the warning
/// card, so the priority and copy can be unit-tested without SwiftUI.
enum HomeScanWarningPolicy {
    static let retryTitle = "Retry"
    static let revealTitle = "Reveal in Finder"

    /// Returns a warning card only for a genuinely damaged/broken path. An empty
    /// list (`ok`) or a folder that simply doesn't exist yet (`missingFolder`)
    /// is the normal empty state and must not raise a warning.
    static func card(for diagnosis: RecentMeetingsScanDiagnosis) -> HomeScanWarningCardModel? {
        guard case let .damagedPath(reason) = diagnosis else { return nil }
        return HomeScanWarningCardModel(
            title: "Can't read your meetings folder",
            detail: detail(for: reason),
            retryTitle: retryTitle,
            revealTitle: revealTitle
        )
    }

    private static func detail(for reason: RecentMeetingsScanDamageReason) -> String {
        switch reason {
        case .notADirectory:
            return "Your saved-meetings location points at a file instead of a folder, so Transcripted can't list recent meetings. Reveal it in Finder to fix the path, then retry."
        case .unreadable:
            return "Transcripted couldn't read your saved-meetings folder. It may have been moved, renamed, or had its permissions changed. Reveal it in Finder to check, then retry."
        }
    }
}

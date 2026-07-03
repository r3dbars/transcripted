import Foundation

/// One of the Home surface's three independent alert states.
///
/// They are presented through a single `.alert(item:)` because several legacy
/// `.alert(item:)` stacked on one SwiftUI view shadow all but the last.
enum HomeRootAlertSlot: String, Equatable {
    case deleteConfirmation
    case deleteFailure
    case audioRetention
}

/// Which of the three Home alert states are currently set.
struct HomeRootAlertStates: Equatable {
    var hasDeleteConfirmation: Bool
    var hasDeleteFailure: Bool
    var hasAudioRetention: Bool
}

/// Routing for the single Home alert presenter. Kept Foundation-pure so the
/// priority and dismissal rules can be unit-tested without SwiftUI.
enum HomeRootAlertPolicy {
    /// The alert that should present, in priority order, when more than one
    /// state is set. Only one is set in the common case; the order keeps the
    /// shared presenter deterministic.
    ///
    /// This is also the slot the dismissal path must clear, and *only* that
    /// slot: a confirm action can raise a follow-up alert (for example a delete
    /// failure) before SwiftUI writes nil to dismiss the confirmation. Because
    /// the confirmation outranks the failure here, dismissal clears the
    /// confirmation and the freshly-set failure survives to present next. If
    /// dismissal cleared every state instead, that failure would be wiped before
    /// it could appear.
    static func activeSlot(_ states: HomeRootAlertStates) -> HomeRootAlertSlot? {
        if states.hasDeleteConfirmation { return .deleteConfirmation }
        if states.hasDeleteFailure { return .deleteFailure }
        if states.hasAudioRetention { return .audioRetention }
        return nil
    }
}

enum HomeActionFailureCopy {
    static let retryTitle = "Try again"
    static let detailsTitle = "Copy Details"

    static func message(forFailureTitle title: String) -> String {
        let normalized = title.lowercased()

        if normalized.contains("rename") {
            return "Transcripted couldn't rename this meeting. Check that the file is still in your capture folder, then try again."
        }

        if normalized.contains("delete dictation") {
            return "Transcripted couldn't remove this dictation. Check that your dictation file is available, then try again."
        }

        if normalized.contains("delete") || normalized.contains("dismiss") || normalized.contains("remove") {
            return "Transcripted couldn't remove this item. Check that your capture folder is available, then try again."
        }

        return "Transcripted couldn't finish that action. Check that your capture folder is available, then try again."
    }
}

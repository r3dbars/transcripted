// StaleAccessibilityGrantPolicy.swift
// Spots paste-back that keeps going nowhere while Accessibility says it's on.

import Foundation

/// After a reinstall under the same bundle id, macOS can keep an old
/// Accessibility grant: `AXIsProcessTrusted()` says yes, but the ⌘V that
/// paste-back posts never reaches the app, so nothing reads the borrowed
/// clipboard and every paste ends "not confirmed". This counts those takes
/// in a row and says when to point the user at re-granting Accessibility.
///
/// Only an unconfirmed paste that no app read counts: a read right after ⌘V
/// proves the keystroke arrived, so event posting works. Several apps must be
/// involved, so one app with no text box can't trip it. In memory only, per
/// launch; it never changes how paste-back runs.
struct StaleAccessibilityGrantTracker: Equatable {
    /// Unconfirmed pastes in a row before the hint shows.
    static let unconfirmedThreshold = 3
    /// Different target apps among them.
    static let distinctTargetThreshold = 2

    /// What one paste attempt says about the grant.
    enum Observation: Equatable {
        /// Pasted, likely pasted, or ⌘V was read: posting works. Resets.
        case pasteReachedTarget
        /// Accessibility reported off: the normal "Accessibility is off"
        /// notice covers it. Resets.
        case accessibilityOff
        /// Accessibility said on, paste wasn't confirmed, and nothing read
        /// the clipboard. Counts.
        case unconfirmedWithoutRead(targetID: String?)
        /// Focus moved, the event couldn't be made, the clipboard was busy,
        /// cancelled: says nothing about the grant. No change.
        case unrelated
    }

    private(set) var consecutiveUnconfirmed = 0
    private(set) var targetIDs: Set<String> = []

    /// True once the streak is long enough, and across enough apps, that a
    /// stale grant is the likeliest cause.
    var suggestsRegrant: Bool {
        consecutiveUnconfirmed >= Self.unconfirmedThreshold
            && targetIDs.count >= Self.distinctTargetThreshold
    }

    mutating func record(_ observation: Observation) {
        switch observation {
        case .pasteReachedTarget, .accessibilityOff:
            consecutiveUnconfirmed = 0
            targetIDs = []
        case .unconfirmedWithoutRead(let targetID):
            consecutiveUnconfirmed += 1
            if let targetID, !targetID.isEmpty {
                targetIDs.insert(targetID)
            }
        case .unrelated:
            break
        }
    }

    /// Classifies a paste outcome. `pasteEvidence` is the paster's
    /// `paste_evidence` diagnostic (`clipboard_read`, `read_outside_window`
    /// or `none`); only `none` means no app read the clipboard at all.
    static func observation(
        outcome: TextPasteOutcome,
        pasteEvidence: String?,
        targetID: String?
    ) -> Observation {
        switch outcome {
        case .pasted, .likelyPasted:
            return .pasteReachedTarget
        case .copied(_, reason: .accessibilityMissing):
            return .accessibilityOff
        case .copied(_, reason: .pasteNotConfirmed):
            // An unknown evidence value is not proof the keystroke was lost.
            guard pasteEvidence == "none" else { return .pasteReachedTarget }
            return .unconfirmedWithoutRead(targetID: targetID)
        case .copied, .failed:
            return .unrelated
        }
    }
}

/// Words for the "paste keeps going nowhere" notice. The island hint is one
/// clipped line, so it stays short.
enum StaleAccessibilityGrantCopy {
    static let islandTitle = "Not pasted"
    static let islandHint = "Paste keeps failing. Turn Accessibility off and on."
    static let islandActionTitle = "Settings"
    static let fallbackMessage =
        "Paste keeps not landing, even though Accessibility is on. macOS may be holding an old permission: in System Settings > Privacy & Security > Accessibility, turn Transcripted off and back on. Your text is on the clipboard — press ⌘V."
}

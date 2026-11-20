// FloatingOverlayController+NotPasted.swift
// What a "didn't paste" notice carries, and how long it stays. Split out of
// FloatingOverlayController.swift to keep that file inside its size limit.

import Foundation

extension FloatingOverlayController {
    struct NotPastedNotice {
        /// A take that didn't paste closes after this long (held while the
        /// pointer is on the island), with a ring on Dismiss.
        static let dismissSeconds: Double = 15
        /// The 15-minute cap's saved words never close by themselves: its
        /// Paste is the one-click way to get up to 15 minutes of words in.
        static let capSavedDismissSeconds: Double? = nil

        let text: String
        let actionTitle: String
        let hint: String?
        let watchesForManualPaste: Bool
        var dismissSeconds: Double? = NotPastedNotice.dismissSeconds
        let action: () -> Void
    }
}

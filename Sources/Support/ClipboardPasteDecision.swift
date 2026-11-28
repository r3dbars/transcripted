// ClipboardPasteDecision.swift
// Whether paste-back may borrow the clipboard, and what to do when a paste
// cannot be confirmed. Pure values so tests cover the Sentry APPLE-MACOS-2B
// cases without a real pasteboard.

import Foundation

/// Whether dictation paste-back may overwrite the current clipboard.
enum ClipboardSnapshotPastePlan: Equatable {
    /// Leave the current clipboard. The dictation stays in history (the
    /// island can offer Copy). Used for a clipboard that changed under us,
    /// a password-manager copy we could not read, or something too large
    /// to set aside.
    case refuse(ClipboardSnapshotCause)
    /// Borrow the clipboard and paste. Restore whatever representations
    /// were captured when that is possible; otherwise leave the dictation
    /// on the clipboard.
    case paste
}

/// How to keep the dictation available after an unconfirmed paste.
enum ClipboardFallbackRecoveryPlan: Equatable {
    /// This pasteboard generation already holds the dictation text.
    case keepExistingDictation
    /// Write the dictation as plain text (empty clipboard, or items with
    /// no string, including a rich rewrite that dropped the text).
    case recopyDictation
    /// A different copy is on the pasteboard; leave it.
    case leaveChangedClipboard
}

enum ClipboardPasteDecision {
    /// Incomplete file promises, `dyn.*` types, and other unreadable
    /// representations are not a reason to skip paste. A concealed
    /// password whose payload was not captured still refuses, as does a
    /// clipboard that changed during the snapshot. An oversized item
    /// refuses only when nothing restorable was captured.
    static func snapshotPastePlan(
        isComplete: Bool,
        cause: ClipboardSnapshotCause?,
        privacyPayloadMissing: Bool,
        hasCapturedRestorableData: Bool,
        changeCountMatches: Bool
    ) -> ClipboardSnapshotPastePlan {
        if !changeCountMatches {
            return .refuse(.changed)
        }
        if isComplete {
            return .paste
        }
        if privacyPayloadMissing {
            return .refuse(cause ?? .unreadable)
        }
        switch cause {
        case .changed:
            return .refuse(.changed)
        case .tooLarge:
            return hasCapturedRestorableData ? .paste : .refuse(.tooLarge)
        case .unreadable, .timeout, .none:
            return .paste
        }
    }

    /// After a confirmed paste, put captured representations back when the
    /// snapshot is complete or at least one real type was saved. An exotic
    /// item that captured nothing must not clear the dictation recovery copy.
    static func shouldRestoreCapturedItems(
        isComplete: Bool,
        hasCapturedRestorableData: Bool
    ) -> Bool {
        isComplete || hasCapturedRestorableData
    }

    /// `generationChanged` is a pasteboard changeCount shift while reading
    /// this generation. `currentString` is the string on that same generation,
    /// or nil when the read raced or the item has no string.
    static func fallbackRecovery(
        currentString: String?,
        dictation: String,
        generationChanged: Bool
    ) -> ClipboardFallbackRecoveryPlan {
        if generationChanged {
            return .leaveChangedClipboard
        }
        if currentString == dictation {
            return .keepExistingDictation
        }
        if currentString != nil {
            return .leaveChangedClipboard
        }
        return .recopyDictation
    }
}

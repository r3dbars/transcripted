// ClipboardRestoringTextPaster+SavedClipboard.swift
// The clipboard saved before a "press ⌘V" fallback, shared by every paster,
// and put back when the next paste starts. Split out of
// ClipboardRestoringTextPaster.swift.

import AppKit
import Foundation

extension ClipboardRestoringTextPaster {
    /// The user's clipboard from before a paste that fell back to "press ⌘V".
    /// The fallback copy stays on the clipboard for the user; this puts their
    /// own clipboard back when the next paste starts, but only if the clipboard
    /// still holds exactly that fallback copy. Cancelling or dismissing a
    /// fallback never restores it on its own, so the recovery text stays put
    /// until the user starts another paste. Shared by every paster (dictation,
    /// Paste Last, the menu bar) because they all borrow the same clipboard:
    /// a Paste Last right after a fallback must still give it back.
    private static var clipboardSavedBeforeFallback: (restore: PendingClipboardRestore, savedAt: CFAbsoluteTime)?

    /// Only called right after this paster itself wrote `pending.temporaryString`
    /// as a plain fallback copy. A same-text clipboard someone else wrote is a
    /// user or clipboard-manager copy and must never be restored over later.
    func saveClipboardForNextPaste(_ pending: PendingClipboardRestore) {
        saveClipboardForNextPaste(
            pending.savedItems,
            fallbackText: pending.temporaryString,
            fallbackChangeCount: pending.pasteboard.changeCount,
            pasteboard: pending.pasteboard
        )
    }

    func saveClipboardForNextPaste(
        _ savedItems: PasteboardSnapshot,
        fallbackText: String,
        fallbackChangeCount: Int,
        pasteboard: any ClipboardPasteboard
    ) {
        // A password manager's copy (or any item marked "don't keep") must not
        // come back later, so drop it here. Clearing also stops an older save
        // from outliving this newer fallback.
        guard savedItems.isComplete, !savedItems.containsPrivacyMarker else {
            Self.clipboardSavedBeforeFallback = nil
            return
        }
        Self.clipboardSavedBeforeFallback = (
            restore: PendingClipboardRestore(
                savedItems: savedItems,
                temporaryString: fallbackText,
                temporaryChangeCount: fallbackChangeCount,
                pasteboard: pasteboard
            ),
            savedAt: CFAbsoluteTimeGetCurrent()
        )
    }

    /// Puts back the clipboard saved before the last fallback copy, unless the
    /// clipboard changed since (the user copied something, or a clipboard
    /// manager rewrote it) or the save is too old to be what the user expects
    /// back. A changed clipboard is always left alone.
    func restoreClipboardSavedBeforeFallback(on pasteboard: any ClipboardPasteboard) {
        guard let entry = Self.clipboardSavedBeforeFallback,
              Self.isSamePasteboard(entry.restore.pasteboard, pasteboard) else { return }
        Self.clipboardSavedBeforeFallback = nil
        guard CFAbsoluteTimeGetCurrent() - entry.savedAt
            <= TranscriptedConstants.clipboardSavedBeforeFallbackMaxAge else { return }
        let saved = entry.restore
        restoreClipboardSnapshot(
            saved.savedItems,
            matching: saved.temporaryString,
            changeCount: saved.temporaryChangeCount,
            to: saved.pasteboard
        )
    }

    /// NSPasteboard(name:) can hand back a new object for the same system
    /// pasteboard, so match real pasteboards by name.
    private static func isSamePasteboard(
        _ lhs: any ClipboardPasteboard,
        _ rhs: any ClipboardPasteboard
    ) -> Bool {
        if lhs === rhs { return true }
        guard let lhs = lhs as? NSPasteboard, let rhs = rhs as? NSPasteboard else { return false }
        return lhs.name == rhs.name
    }

    /// Copies text for a manual ⌘V on a path that never borrowed the clipboard
    /// (focus moved first, or Accessibility is off), saving the user's clipboard
    /// first so the next paste can put it back. When the clipboard can't be
    /// saved safely it still copies the text: recovery beats restore here.
    func copyTextForManualPaste(
        _ text: String,
        to pasteboard: any ClipboardPasteboard,
        isCurrentOperation: () -> Bool
    ) -> Bool {
        let snapshotChangeCount = pasteboard.changeCount
        let savedItems = snapshotPasteboardItems(from: pasteboard)
        // Materializing a lazy clipboard can run other code; a cancelled or
        // changed clipboard is not the user's to overwrite on our behalf.
        guard isCurrentOperation() else { return false }
        let snapshotIsCurrent = pasteboard.changeCount == snapshotChangeCount
        guard copyTextToClipboard(text, to: pasteboard) else { return false }
        if snapshotIsCurrent {
            saveClipboardForNextPaste(
                savedItems,
                fallbackText: text,
                fallbackChangeCount: pasteboard.changeCount,
                pasteboard: pasteboard
            )
        }
        return true
    }
}

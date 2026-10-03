// NotchIslandDropView+Dictation.swift
// The dictation hover's drop-down: the live words (when the preview is
// streaming), then Cancel and "Insert into <app>" with the app's own icon.
// Split out of NotchIslandView.swift.

import AppKit

extension NotchIslandDropView {
    func buildDictationTarget(appName: String?, icon: () -> NSImage?, showsPreview: Bool, isWriting: Bool) {
        if showsPreview, let preview = dictationPreviewView {
            preview.removeFromSuperview()
            add(preview)
            readableText.append(preview)
            DispatchQueue.main.async { [weak preview] in preview?.scrollToNewest() }
        }
        // Released: the words are being written; there's nothing to press.
        guard !isWriting else { return }
        add(buttonRow(leading: [], trailing: [
            button("Cancel", .plain, .dictationCancel),
            button(Self.insertTitle(appName: appName), .accent, .dictationStop, appIcon: appName == nil ? nil : icon()),
        ]))
    }

    /// The live words are one view every dictation drop-down shares. A kept
    /// drop-down can come back only while it still holds them.
    var canComeBack: Bool {
        guard case .dictationTarget(_, true, _) = drop else { return true }
        return dictationPreviewView?.isDescendant(of: self) ?? false
    }

    /// A kept drop-down is on screen again: show the newest words, as a new
    /// one does when it opens.
    func cameBack() {
        guard case .dictationTarget(_, true, _) = drop, let preview = dictationPreviewView else { return }
        DispatchQueue.main.async { [weak preview] in preview?.scrollToNewest() }
    }

    /// The take that just landed. When the live words were up, the same view
    /// already shows the written text, so it stays instead of jumping.
    func buildJustInserted(text: String) {
        if let preview = dictationPreviewView, preview.finalText == text {
            preview.removeFromSuperview()
            add(preview)
            readableText.append(preview)
            DispatchQueue.main.async { [weak preview] in preview?.scrollToNewest() }
        } else {
            add(body("“\(text)”", maxLines: 3))
        }
        add(buttonRow(leading: [
            button("Copy", .plain, .copyLastDictation),
            button("Paste again", .plain, .pasteLastDictation),
        ], trailing: []))
    }

    static func insertTitle(appName: String?) -> String {
        guard let appName, !appName.isEmpty else { return "Insert now" }
        return "Insert into \(appName)"
    }
}

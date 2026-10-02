// NotchIslandDropView+Dictation.swift
// The dictation hover's drop-down: the live words (when the preview is
// streaming), then Cancel and "Insert into <app>" with the app's own icon.
// Split out of NotchIslandView.swift.

import AppKit

extension NotchIslandDropView {
    func buildDictationTarget(appName: String?, icon: NSImage?, showsPreview: Bool, isWriting: Bool) {
        if showsPreview, let preview = dictationPreviewView {
            preview.removeFromSuperview()
            add(preview)
            readableText.append(preview)
        }
        // Released: the words are being written; there's nothing to press.
        guard !isWriting else { return }
        add(buttonRow(leading: [], trailing: [
            button("Cancel", .plain, .dictationCancel),
            button(Self.insertTitle(appName: appName), .accent, .dictationStop, appIcon: appName == nil ? nil : icon),
        ]))
    }

    /// The take that just landed. When the live words were up, the same view
    /// already shows the written text, so it stays instead of jumping.
    func buildJustInserted(text: String) {
        if let preview = dictationPreviewView, preview.finalText == text {
            preview.removeFromSuperview()
            add(preview)
            readableText.append(preview)
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

// ClipboardRestoringTextPaster.swift
// Pastes text into the current target app by borrowing the clipboard briefly
// and restoring the prior clipboard contents after Cmd+V completes.

import AppKit
import ApplicationServices
import Foundation

enum TextPasteCopyReason: Equatable {
    case accessibilityMissing
    case pasteEventCreationFailed
}

enum TextPasteOutcome: Equatable {
    case pasted
    case copied(String, reason: TextPasteCopyReason)
    case failed(String)

    var diagnosticName: String {
        switch self {
        case .pasted:
            return "pasted"
        case .copied:
            return "copied"
        case .failed:
            return "failed"
        }
    }

    var diagnosticMessage: String {
        switch self {
        case .pasted:
            return "Dictation pasted successfully"
        case .copied(let message, reason: _), .failed(let message):
            return message
        }
    }

    var copyReason: TextPasteCopyReason? {
        switch self {
        case .copied(_, reason: let reason):
            return reason
        case .pasted, .failed:
            return nil
        }
    }
}

@MainActor
final class ClipboardRestoringTextPaster {
    private typealias PasteboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

    private var clipboardRestoreTask: Task<Void, Never>?

    deinit {
        clipboardRestoreTask?.cancel()
    }

    func cancelPendingClipboardRestore() {
        clipboardRestoreTask?.cancel()
        clipboardRestoreTask = nil
    }

    func paste(_ text: String) -> TextPasteOutcome {
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            copyTextToClipboard(text)
            return .copied(
                "Couldn't paste automatically. Accessibility is off, so the text was copied.",
                reason: .accessibilityMissing
            )
        }

        let pasteboard = NSPasteboard.general
        let savedItems = snapshotPasteboardItems(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard let vDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false) else {
            return .copied(
                "Couldn't paste automatically. The text was copied instead.",
                reason: .pasteEventCreationFailed
            )
        }

        vDown.flags = .maskCommand
        vDown.post(tap: .cghidEventTap)

        vUp.flags = .maskCommand
        vUp.post(tap: .cghidEventTap)

        let changeCountAfterSet = pasteboard.changeCount
        clipboardRestoreTask?.cancel()
        clipboardRestoreTask = Task { @MainActor in
            defer {
                restorePasteboardItems(savedItems, to: pasteboard)
            }

            let startTime = CFAbsoluteTimeGetCurrent()
            while CFAbsoluteTimeGetCurrent() - startTime < TranscriptedConstants.clipboardRestoreTimeout {
                try? await Task.sleep(nanoseconds: TranscriptedConstants.clipboardPollInterval)
                if pasteboard.changeCount != changeCountAfterSet {
                    break
                }
            }
        }

        return .pasted
    }

    func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func snapshotPasteboardItems(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        pasteboard.pasteboardItems?.map { item in
            var typeData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typeData[type] = data
                }
            }
            return typeData
        } ?? []
    }

    private func restorePasteboardItems(_ savedItems: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items = savedItems.map { typeData -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in typeData {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}

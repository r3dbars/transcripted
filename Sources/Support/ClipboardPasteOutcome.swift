// ClipboardPasteOutcome.swift
// What a paste-back attempt reports: the outcome, why it fell back or failed,
// how a missed dictation is offered back, and the timing and confirmation
// diagnostics. Split out of ClipboardRestoringTextPaster.swift.

import Foundation

enum TextPasteCopyReason: Equatable {
    case accessibilityMissing
    case pasteEventCreationFailed
    case focusChanged
    case pasteNotConfirmed
}

enum TextPasteFailureReason: String, Equatable {
    case cancelled = "cancelled"
    case clipboardSnapshotIncomplete = "clipboard_snapshot_incomplete"
    case focusChangeClipboardWriteFailed = "focus_change_clipboard_write_failed"
    case accessibilityFallbackClipboardWriteFailed = "accessibility_fallback_clipboard_write_failed"
    case temporaryClipboardWriteFailed = "temporary_clipboard_write_failed"
    case pasteDispatchClipboardRecoveryFailed = "paste_dispatch_clipboard_recovery_failed"
    case fallbackClipboardRecoveryUnverified = "fallback_clipboard_recovery_unverified"
    case unknown
}

/// How a dictation that didn't paste is handed back to the user.
enum DictationNotPastedOffer: Equatable {
    /// The words are on the clipboard: paste them where they go.
    case onClipboard
    /// The clipboard held something paste-back couldn't set aside, so the
    /// words never went on it: offer to copy them.
    case clipboardBusy
}

extension TextPasteOutcome {
    var notPastedOffer: DictationNotPastedOffer? {
        switch self {
        case .copied:
            return .onClipboard
        case .failed(_, reason: .clipboardSnapshotIncomplete):
            return .clipboardBusy
        case .pasted, .likelyPasted, .failed:
            return nil
        }
    }
}

enum TextPasteOutcome: Equatable {
    case pasted
    /// Cmd+V went out, the target stayed frontmost, and the borrowed clipboard
    /// was read right after it, but no Accessibility signal proved the text
    /// landed. Electron apps, Chrome text areas, and GPU terminals expose no
    /// such signal, so this is what a normal paste into them looks like. The
    /// user's clipboard is restored as after `.pasted`. The read is not
    /// attributed to the target process, so this never authorizes Auto Enter.
    case likelyPasted
    case copied(String, reason: TextPasteCopyReason)
    case failed(String, reason: TextPasteFailureReason)

    var diagnosticName: String {
        switch self {
        case .pasted:
            return "pasted"
        case .likelyPasted:
            return "likely_pasted"
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
        case .likelyPasted:
            return "Dictation most likely pasted: the target read the clipboard right after Cmd+V"
        case .copied(let message, reason: _), .failed(let message, reason: _):
            return message
        }
    }

    var copyReason: TextPasteCopyReason? {
        switch self {
        case .copied(_, reason: let reason):
            return reason
        case .pasted, .likelyPasted, .failed:
            return nil
        }
    }

    var failureReason: TextPasteFailureReason? {
        switch self {
        case .failed(_, reason: let reason):
            return reason
        case .pasted, .likelyPasted, .copied:
            return nil
        }
    }
}

struct ClipboardPasteConfirmationDiagnostic: Equatable {
    let event: String
    let context: [String: String]

    static let lateConfirmedEvent = "dictation_paste_late_confirmed"

    /// The target confirmed over Accessibility after a dictation paste had
    /// already ended its wait as a likely paste (`ClipboardLateConfirmationWatch`).
    /// The paste still reports `target_confirmation_mode=clipboard_read`; this
    /// is what tells such takes apart from ones nothing ever confirmed.
    static func lateConfirmed(mode: String?) -> ClipboardPasteConfirmationDiagnostic {
        ClipboardPasteConfirmationDiagnostic(
            event: lateConfirmedEvent,
            context: ["confirmation_mode": mode ?? "unknown"]
        )
    }
}

struct ClipboardPasteTiming: Equatable {
    let startedAt: CFAbsoluteTime
    let dispatchStartedAt: CFAbsoluteTime?
    let dispatchFinishedAt: CFAbsoluteTime?
    let clipboardReadAt: CFAbsoluteTime?
    let confirmationStartedAt: CFAbsoluteTime?
    let confirmationFinishedAt: CFAbsoluteTime?
    var accessibilityCaptureMS: Int? = nil
    var clipboardSnapshotMS: Int? = nil

    func measurements() -> [String: Int] {
        var values: [String: Int] = [:]
        values["paste_ax_capture_ms"] = accessibilityCaptureMS
        values["paste_clipboard_snapshot_ms"] = clipboardSnapshotMS
        values["paste_prepare_ms"] = milliseconds(from: startedAt, to: dispatchStartedAt)
        values["paste_dispatch_ms"] = milliseconds(from: dispatchStartedAt, to: dispatchFinishedAt)
        if let dispatchStartedAt,
           let clipboardReadAt,
           clipboardReadAt >= dispatchStartedAt {
            values["paste_clipboard_read_ms"] = milliseconds(
                from: dispatchStartedAt,
                to: clipboardReadAt
            )
        }
        values["paste_confirmation_wait_ms"] = milliseconds(
            from: confirmationStartedAt,
            to: confirmationFinishedAt
        )
        return values
    }

    private func milliseconds(from start: CFAbsoluteTime?, to end: CFAbsoluteTime?) -> Int? {
        guard let start, let end else { return nil }
        return max(0, Int(((end - start) * 1_000).rounded()))
    }
}

enum DictationTargetConfirmationMode: String, Equatable {
    case textValue = "text_value"
    case selectionRange = "selection_range"
    case changeNotification = "change_notification"
    /// No Accessibility confirmation, but the target stayed frontmost and the
    /// borrowed clipboard was read right after Cmd+V (`.likelyPasted`).
    case clipboardRead = "clipboard_read"
    case none

    static func resolve(
        outcome: TextPasteOutcome,
        diagnostic: ClipboardPasteConfirmationDiagnostic?
    ) -> DictationTargetConfirmationMode {
        if outcome == .likelyPasted {
            return .clipboardRead
        }
        guard diagnostic?.event == "dictation_paste_confirmed" else {
            return .none
        }
        return accessibilityMode(diagnostic?.context["confirmation_mode"])
    }

    /// The coarse mode for an Accessibility `confirmation_mode`; `none` for
    /// anything else.
    static func accessibilityMode(_ confirmationMode: String?) -> DictationTargetConfirmationMode {
        switch confirmationMode {
        case "text_value":
            return .textValue
        case "selection_range":
            return .selectionRange
        case "target_change_notification":
            return .changeNotification
        default:
            return .none
        }
    }
}

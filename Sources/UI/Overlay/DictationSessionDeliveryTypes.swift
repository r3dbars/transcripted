// DictationSessionDeliveryTypes.swift
// Stop timing and paste-outcome helpers shared by the dictation session controller files.

import AppKit

struct DictationStopTiming {
    let requestedAt: CFAbsoluteTime
    /// Which recorder this take used, read before the mic stops.
    var micBackend: String?
    var micStoppedAt: CFAbsoluteTime?
    var snapshotStartedAt: CFAbsoluteTime?
    var snapshotFinishedAt: CFAbsoluteTime?
    var recoveryCheckpointStartedAt: CFAbsoluteTime?
    var recoveryCheckpointFinishedAt: CFAbsoluteTime?
    var modelWaitStartedAt: CFAbsoluteTime?
    var modelReadyAt: CFAbsoluteTime?
    var transcriptionStartedAt: CFAbsoluteTime?
    var transcribedAt: CFAbsoluteTime?
    var cleanedAt: CFAbsoluteTime?
    var pasteStartedAt: CFAbsoluteTime?
    var pastedAt: CFAbsoluteTime?
    var pasteBreakdown: ClipboardPasteTiming?
    var autoEnterStartedAt: CFAbsoluteTime?
    var autoEnterFinishedAt: CFAbsoluteTime?
    var finalizationStartedAt: CFAbsoluteTime?
    var savePublishedAt: CFAbsoluteTime?
    var saveStartedAt: CFAbsoluteTime?
    var savedAt: CFAbsoluteTime?
    var completedAt: CFAbsoluteTime?

    func measurements() -> [String: Int] {
        var values: [String: Int] = [:]
        values["stop_to_mic_stop_ms"] = milliseconds(from: requestedAt, to: micStoppedAt)
        values["snapshot_resample_ms"] = milliseconds(from: snapshotStartedAt, to: snapshotFinishedAt)
        values["recovery_checkpoint_ms"] = milliseconds(
            from: recoveryCheckpointStartedAt,
            to: recoveryCheckpointFinishedAt
        )
        values["mic_stop_to_decode_start_ms"] = milliseconds(from: micStoppedAt, to: transcriptionStartedAt)
        values["model_wait_ms"] = milliseconds(from: modelWaitStartedAt, to: modelReadyAt)
        values["decode_ms"] = milliseconds(from: transcriptionStartedAt, to: transcribedAt)
        values["cleanup_ms"] = milliseconds(from: transcribedAt, to: cleanedAt)
        values["paste_ms"] = milliseconds(from: pasteStartedAt, to: pastedAt)
        if let pasteBreakdown {
            values.merge(pasteBreakdown.measurements()) { _, new in new }
            values["stop_to_paste_dispatch_ms"] = milliseconds(
                from: requestedAt,
                to: pasteBreakdown.dispatchFinishedAt
            )
        }
        values["auto_enter_ms"] = milliseconds(from: autoEnterStartedAt, to: autoEnterFinishedAt)
        values["save_ms"] = milliseconds(from: saveStartedAt, to: savedAt)
        values["save_publication_wait_ms"] = milliseconds(from: savedAt, to: savePublishedAt)
        values["finalization_ms"] = milliseconds(from: finalizationStartedAt, to: savePublishedAt)
        values["stop_to_paste_ms"] = milliseconds(from: requestedAt, to: pastedAt)
        values["stop_to_save_ms"] = milliseconds(from: requestedAt, to: savedAt)
        values["stop_to_done_ms"] = milliseconds(from: requestedAt, to: completedAt)
        return values
    }

    private func milliseconds(from start: CFAbsoluteTime?, to end: CFAbsoluteTime?) -> Int? {
        guard let start, let end else { return nil }
        return max(0, Int(((end - start) * 1_000).rounded()))
    }
}

typealias DictationPasteOutcome = TextPasteOutcome

extension TextPasteOutcome {
    var diagnosticLevel: EventLevel {
        switch self {
        case .pasted, .likelyPasted:
            return .info
        case .copied:
            return .warning
        case .failed:
            return .error
        }
    }
}

extension TextPasteCopyReason {
    var diagnosticName: String {
        switch self {
        case .accessibilityMissing:
            return "accessibility_missing"
        case .pasteEventCreationFailed:
            return "paste_event_creation_failed"
        case .focusChanged:
            return "focus_changed"
        case .pasteNotConfirmed:
            return "paste_not_confirmed"
        }
    }
}

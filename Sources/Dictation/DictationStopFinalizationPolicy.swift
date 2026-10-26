import Foundation

enum DictationStopFinalizationOrder: String {
    case saveAfterAutoEnter
    case saveBeforeAutoEnter

    static func parse(_ value: String) -> DictationStopFinalizationOrder? {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()

        switch normalized {
        case "saveafterautoenter", "save_after_auto_enter":
            return .saveAfterAutoEnter
        case "savebeforeautoenter", "save_before_auto_enter":
            return .saveBeforeAutoEnter
        default:
            return nil
        }
    }
}

/// The app always saves before Auto Enter. The order setting exists only so
/// the stop benchmark, the Lab and dictation-stop-autoeval.sh can compare runs.
enum DictationStopFinalizationPolicy {
    static let order: DictationStopFinalizationOrder = .saveBeforeAutoEnter
}

struct DictationStopFinalizationResult<AutoEnterOutcome, SaveResult> {
    let autoEnterOutcome: AutoEnterOutcome
    let saveResult: SaveResult
}

enum DictationStopFinalizer {
    /// Starts the save off the main actor, sends Auto Enter, then awaits the save.
    @MainActor
    static func finalize<SaveResult, AutoEnterOutcome>(
        startSaving: () -> Task<SaveResult, Never>,
        finishSaving: (Task<SaveResult, Never>) async -> SaveResult,
        performAutoEnter: () async -> AutoEnterOutcome
    ) async -> DictationStopFinalizationResult<AutoEnterOutcome, SaveResult> {
        let saveTask = startSaving()
        let autoEnterOutcome = await performAutoEnter()
        let saveResult = await finishSaving(saveTask)
        return DictationStopFinalizationResult(
            autoEnterOutcome: autoEnterOutcome,
            saveResult: saveResult
        )
    }
}

// MARK: - Delivery

extension TextPasteOutcome {
    /// What dictation history, analytics and diagnostics all record. A likely
    /// paste counts as pasted: the target read the clipboard right after Cmd+V.
    var delivery: DictationDelivery {
        switch self {
        case .pasted, .likelyPasted:
            return .pasted
        case .copied:
            return .copied
        case .failed:
            return .failed
        }
    }

    /// The delivery keys every completion event carries, so the diagnostics
    /// trail and analytics report the same value dictation history saves.
    var deliveryProperties: [String: String] {
        var properties = ["delivery": delivery.rawValue]
        if let failureReason {
            properties["failure_kind"] = failureReason.rawValue
        }
        return properties
    }
}

/// What the pill shows once a finished take was delivered (or not) and saved.
enum DictationDeliveryPresentation: Equatable {
    case success(title: String)
    /// A calm notice that a newer take's start may replace.
    case clipboardNotice(String)
    /// The words are on the clipboard; the notice offers Paste where they go.
    case notPasted(message: String, unconfirmed: Bool)
    /// The words never reached the clipboard; the notice offers to copy them.
    case clipboardBusy(message: String)
    case error(String)

    static let likelyPastedAutoSendNotice = "Pasted. Press Return to send it."
    static let pendingAudioNotice = "The recording is safe locally, but saving its audio needs repair."

    /// Audio retention must not take away Copy, Paste, or an Auto Enter warning.
    /// Only a successful paste has no immediate delivery-recovery action to lose.
    var canOfferAudioRetentionRetry: Bool {
        if case .success = self { return true }
        return false
    }

    func addingPendingAudioNotice(_ pending: Bool) -> Self {
        guard pending else { return self }
        switch self {
        case .success: return self
        case .clipboardNotice(let message): return .clipboardNotice("\(message) \(Self.pendingAudioNotice)")
        case .notPasted(let message, let unconfirmed): return .notPasted(message: "\(message) \(Self.pendingAudioNotice)", unconfirmed: unconfirmed)
        case .clipboardBusy(let message): return .clipboardBusy(message: "\(message) \(Self.pendingAudioNotice)")
        case .error(let message): return .error("\(message) \(Self.pendingAudioNotice)")
        }
    }

    static func resolve(
        outcome: TextPasteOutcome,
        saveFailureMessage: String?,
        autoSend: DictationAutoSendOutcome,
        autoSendExpected: Bool
    ) -> DictationDeliveryPresentation {
        switch outcome {
        case .pasted:
            if let saveFailureMessage {
                return .error(saveFailureMessage)
            }
            if case .failed(let failure) = autoSend {
                return .error(failure.message)
            }
            return .success(title: autoSend.confirmationTitle ?? "Pasted")
        case .likelyPasted:
            // No Accessibility proof, but the target stayed in front and read
            // the clipboard right after Cmd+V, so the text almost certainly
            // landed. Offering another paste could paste it twice.
            if let saveFailureMessage {
                return .error(saveFailureMessage)
            }
            // Auto Enter only presses Return after a confirmed paste.
            return autoSendExpected
                ? .clipboardNotice(likelyPastedAutoSendNotice)
                : .success(title: "Pasted")
        case .copied(let message, reason: let reason):
            if let saveFailureMessage {
                return .error("\(message) \(saveFailureMessage)")
            }
            // The text is safe on the clipboard: a calm "press ⌘V" notice,
            // not a warning-triangle error.
            return .notPasted(message: message, unconfirmed: reason == .pasteNotConfirmed)
        case .failed(let message, reason: _):
            let combined = saveFailureMessage.map { "\(message) \($0)" } ?? message
            if saveFailureMessage == nil, outcome.notPastedOffer == .clipboardBusy {
                return .clipboardBusy(message: combined)
            }
            return .error(combined)
        }
    }
}

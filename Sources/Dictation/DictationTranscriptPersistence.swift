import Foundation

/// Measures the writer itself, independently of Auto Enter and MainActor publication.
struct DictationTranscriptPersistenceResult: Sendable {
    let saved: SavedDictationTranscript?
    let failureError: Error?
    let startedAt: CFAbsoluteTime
    let finishedAt: CFAbsoluteTime

    var failureMessage: String? {
        guard failureError != nil else { return nil }
        return "Transcripted couldn't save a local copy of this dictation. Check your save location and available disk space."
    }

    static func measure(
        now: () -> CFAbsoluteTime = CFAbsoluteTimeGetCurrent,
        save: () throws -> SavedDictationTranscript
    ) -> Self {
        let startedAt = now()
        do {
            let saved = try save()
            return Self(saved: saved, failureError: nil, startedAt: startedAt, finishedAt: now())
        } catch {
            return Self(saved: nil, failureError: error, startedAt: startedAt, finishedAt: now())
        }
    }
}

enum DictationSessionCompletionPolicy {
    static func canPublish(sessionID: UUID, currentSessionID: UUID, isDictating: Bool, cancelled: Bool) -> Bool {
        sessionID == currentSessionID && isDictating && !cancelled
    }
}

struct DictationSessionCapCompletionTelemetry {
    let delivery: DictationDelivery
    let failureKind: String?
}

enum DictationSessionCapCompletionTelemetryPolicy {
    static func snapshot(saveSucceeded: Bool) -> DictationSessionCapCompletionTelemetry {
        DictationSessionCapCompletionTelemetry(
            delivery: saveSucceeded ? .savedWithoutPaste : .failed,
            failureKind: saveSucceeded ? nil : "markdown_save_failed"
        )
    }

    /// The `dictation_completed` properties for a take the cap saved. Delivery
    /// comes from the save result, so a failed save never claims a saved one,
    /// and the cap never auto-sends.
    static func completionProperties(
        saveSucceeded: Bool,
        durationBucket: String,
        trigger: String,
        wordCountBucket: String
    ) -> [String: String] {
        let telemetry = snapshot(saveSucceeded: saveSucceeded)
        var properties: [String: String] = [
            "delivery": telemetry.delivery.rawValue,
            "auto_send": "disabled",
            "duration_bucket": durationBucket,
            "trigger": trigger,
            "word_count_bucket": wordCountBucket,
        ]
        if let failureKind = telemetry.failureKind {
            properties["failure_kind"] = failureKind
        }
        return properties
    }
}

/// How a take the 5-minute cap finalized without pasting is saved and shown.
enum DictationSessionCapSavePolicy {
    /// The cap saves to Markdown without pasting; history records it as such.
    static let delivery: DictationDelivery = .savedWithoutPaste

    enum Presentation: Equatable {
        /// Good news, not an error: the words are saved, with a way to paste them.
        case savedNotice(message: String, actionTitle: String)
        case error(String)
    }

    static func presentation(saveFailureMessage: String?) -> Presentation {
        if let saveFailureMessage {
            return .error(saveFailureMessage)
        }
        // There's no paste-last shortcut any more; Dictations keeps the text.
        return .savedNotice(
            message: "Saved to Markdown. Paste it now, or find it later in Dictations.",
            actionTitle: "Paste It"
        )
    }

    enum PasteItResult: Equatable {
        case pasted
        case error(String)
    }

    /// What the notice's Paste It button shows after it tries to paste.
    static func pasteItResult(_ outcome: TextPasteOutcome) -> PasteItResult {
        switch outcome {
        case .pasted, .likelyPasted:
            return .pasted
        case .copied(let message, reason: _), .failed(let message, reason: _):
            return .error(message)
        }
    }
}

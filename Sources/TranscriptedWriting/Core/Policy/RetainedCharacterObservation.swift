import Foundation

/// A text-free count of how many accepted suggestion characters were still
/// present at one horizon, or an explicit reason that count was not observed.
///
/// Missingness and zero are different facts. A missing horizon must never be
/// stored or read as zero retained characters.
public struct RetainedCharacterObservation: Codable, Equatable, Sendable {
    public let retainedCharacters: Int?
    public let missingness: RetentionMissingness?

    public init(retainedCharacters: Int) throws {
        guard retainedCharacters >= 0 else {
            throw RetainedCharacterObservationError.negativeCount
        }
        self.retainedCharacters = retainedCharacters
        missingness = nil
    }

    public init(missingness: RetentionMissingness) {
        retainedCharacters = nil
        self.missingness = missingness
    }

    /// Test and decoder hook. Call `validated()` before treating this as a fact.
    init(unchecked retainedCharacters: Int?, missingness: RetentionMissingness?) {
        self.retainedCharacters = retainedCharacters
        self.missingness = missingness
    }

    public var isObserved: Bool { retainedCharacters != nil }

    public func validated() throws -> RetainedCharacterObservation {
        switch (retainedCharacters, missingness) {
        case (let count?, nil) where count >= 0:
            return self
        case (nil, .some):
            return self
        default:
            throw RetainedCharacterObservationError.ambiguous
        }
    }
}

public enum RetentionMissingness: String, Codable, CaseIterable, Sendable {
    case notYetObserved = "not-yet-observed"
    case observerStopped = "observer-stopped"
    case segmentClosedEarly = "segment-closed-early"
    case privacyExcluded = "privacy-excluded"
    case legacySchema = "legacy-schema"
}

public enum RetainedCharacterObservationError: Error, Equatable, Sendable {
    case ambiguous
    case negativeCount
}

/// A ghost that was on screen long enough to be read, versus a flicker.
///
/// Two hundred milliseconds is a conservative glance floor: shorter than that
/// is treated as not-read so a flash-and-Tab cannot look like attention.
public enum SettledVisibility {
    public static let minimumReadMilliseconds = 200

    public static func countsAsRead(_ milliseconds: Int?) -> Bool {
        guard let milliseconds, milliseconds >= minimumReadMilliseconds else {
            return false
        }
        return true
    }
}

/// Typed-through is a local, text-free judgment at opportunity close:
/// the ghost settled long enough to be a read, the writer typed at least
/// one key, and they did not Tab or Escape.
///
/// Matching the ghost is not required and must not be stored. A flicker
/// shorter than `SettledVisibility.minimumReadMilliseconds` that is then
/// typed through is ignored, not typed-through.
public enum TypedThroughRule {
    public static func isEligible(
        displayed: Bool,
        settledVisibleMilliseconds: Int?
    ) -> Bool {
        displayed && SettledVisibility.countsAsRead(settledVisibleMilliseconds)
    }

    /// Close-time classification. Accept and dismiss win over type-through.
    public static func isTypedThrough(
        displayed: Bool,
        settledVisibleMilliseconds: Int?,
        typedAfterShow: Bool,
        accepted: Bool,
        dismissed: Bool
    ) -> Bool {
        !accepted && !dismissed && typedAfterShow
            && isEligible(
                displayed: displayed,
                settledVisibleMilliseconds: settledVisibleMilliseconds
            )
    }
}

/// In-memory count of how much of an accepted span is still in the field.
///
/// `accepted` and `window` stay in RAM for the watch only. They are never
/// part of the event. A missing window is a missingness reason, never zero.
public enum RetainedSpanWatch {
    public static let fiveSecondHorizon: TimeInterval = 5
    public static let thirtySecondHorizon: TimeInterval = 30
    /// Privacy-safe idle close: the writer stopped, so the segment ended.
    public static let idleSegmentSeconds: TimeInterval = 60
    public static let maximumPendingWatches = 32

    /// Longest prefix of `accepted` that still occurs as a contiguous
    /// substring in `window`. Edits that break the prefix count as replacement
    /// from that point. The window is typically context-before-caret.
    public static func retainedCharacters(accepted: String, window: String) -> Int {
        guard !accepted.isEmpty else { return 0 }
        var kept = 0
        var prefix = ""
        prefix.reserveCapacity(accepted.count)
        for character in accepted {
            prefix.append(character)
            if window.contains(prefix) {
                kept += 1
            } else {
                break
            }
        }
        return kept
    }

    public static func observation(
        accepted: String,
        window: String?
    ) throws -> RetainedCharacterObservation {
        guard let window else {
            return RetainedCharacterObservation(missingness: .observerStopped)
        }
        return try RetainedCharacterObservation(
            retainedCharacters: retainedCharacters(accepted: accepted, window: window)
        ).validated()
    }

    /// Characters gone at an earlier horizon cannot return at a later one.
    /// A retyped span is authored text, not retained text.
    public static func monotone(
        _ later: RetainedCharacterObservation,
        notExceeding earlier: RetainedCharacterObservation
    ) -> RetainedCharacterObservation {
        guard let laterCount = later.retainedCharacters,
              let earlierCount = earlier.retainedCharacters,
              laterCount > earlierCount,
              let clamped = try? RetainedCharacterObservation(
                  retainedCharacters: earlierCount
              ) else { return later }
        return clamped
    }

    public static func closedEarlyIfStillWaiting(
        _ observation: RetainedCharacterObservation
    ) -> RetainedCharacterObservation {
        if observation.missingness == .notYetObserved {
            return RetainedCharacterObservation(missingness: .segmentClosedEarly)
        }
        return observation
    }
}

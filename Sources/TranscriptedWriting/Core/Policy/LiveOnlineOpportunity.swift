import Foundation

/// One shown ghost, held only until the text-free event can be written.
///
/// Accept starts an in-memory span watch. The accepted string is dropped
/// when the last horizon is filled. The event never contains it.
public struct LiveOnlineOpportunity: Equatable, Sendable {
    public enum AcceptKind: String, Sendable {
        case word
        case all
    }

    public enum CloseReason: String, Sendable {
        case accepted
        case dismissed
        case typedThrough = "typed-through"
        case ignored
        case segment
        case privacyExcluded = "privacy-excluded"
        case observerStopped = "observer-stopped"
    }

    public private(set) var id: UUID
    public let shownAt: Date
    public let sessionDigestSHA256: String
    /// H01 arm tag. `champion` unless the disabled-by-default block
    /// randomization harness is running, so ordinary events are unchanged.
    public let variant: String
    public private(set) var appCategory: String
    public private(set) var register: String
    public let boundary: String
    public let safeOpportunity: Bool
    public var candidateCharacters: Int
    public var candidateWordCount: Int
    /// `TextFreeCandidateSource` raw value: dictionary suffix, base model,
    /// personal, or agreement. Set from the app's receipt, never guessed.
    public private(set) var candidateSource: String
    /// Characters the writer authored since the previous opportunity in this
    /// segment (typed or accepted), counted once. Never the context length:
    /// a long document shown ten ghosts would otherwise count its whole
    /// body ten times and bury the value per thousand characters.
    public let opportunityCharacters: Int
    /// The app's receipt for the model that produced this ghost; `nil` for a
    /// dictionary ghost or an app older than the receipt.
    public private(set) var generatorMilliseconds: Int?
    public private(set) var firstStableWordMilliseconds: Int?
    public private(set) var configurationDigestSHA256: String?
    public var typedAfterShow: Bool
    public var acceptedKind: AcceptKind?
    public var accepted: String
    public var acceptedCharacterCount: Int
    public var dismissed: Bool
    public var nextActionMilliseconds: Int?
    public var settledVisibleMilliseconds: Int?

    public init(
        id: UUID = UUID(),
        shownAt: Date,
        sessionDigestSHA256: String,
        variant: String = "champion",
        appCategory: String,
        register: String,
        boundary: String,
        safeOpportunity: Bool,
        candidateCharacters: Int,
        candidateWordCount: Int,
        candidateSource: TextFreeCandidateSource,
        opportunityCharacters: Int,
        generatorMilliseconds: Int? = nil,
        firstStableWordMilliseconds: Int? = nil,
        configurationDigestSHA256: String? = nil
    ) {
        self.id = id
        self.shownAt = shownAt
        self.sessionDigestSHA256 = sessionDigestSHA256
        self.variant = variant
        self.appCategory = appCategory
        self.register = register
        self.boundary = boundary
        self.safeOpportunity = safeOpportunity
        self.candidateCharacters = max(0, candidateCharacters)
        self.candidateWordCount = max(0, candidateWordCount)
        self.candidateSource = candidateSource.rawValue
        self.opportunityCharacters = max(1, opportunityCharacters)
        self.generatorMilliseconds = generatorMilliseconds.map { min(300_000, max(0, $0)) }
        self.firstStableWordMilliseconds = firstStableWordMilliseconds.map { min(300_000, max(0, $0)) }
        self.configurationDigestSHA256 = configurationDigestSHA256
        typedAfterShow = false
        acceptedKind = nil
        accepted = ""
        acceptedCharacterCount = 0
        dismissed = false
        nextActionMilliseconds = nil
        settledVisibleMilliseconds = nil
    }

    public var didAccept: Bool { acceptedKind != nil }

    /// The model took over a ghost the dictionary opened: the record keeps
    /// its interaction history (shown time, typing, acceptance) but is
    /// re-keyed to the model opportunity the app answered — its id, the
    /// register the generator composed with, and the configuration digest —
    /// so the event reads as what it now is: a model ghost.
    public mutating func adoptModelOpportunity(
        id: UUID,
        register: ContinuationRegister,
        configurationDigestSHA256: String?
    ) {
        self.id = id
        self.register = register.rawValue
        appCategory = TextFreeAppCategory.from(register: register).rawValue
        if let configurationDigestSHA256 { self.configurationDigestSHA256 = configurationDigestSHA256 }
    }

    /// A later receipt for the same ghost: the terminal line after a
    /// streamed partial opened the record, or the model extending a
    /// dictionary ghost. Timings fill in only where they were missing; the
    /// source moves to the model only when the model's text is what is now
    /// on screen.
    public mutating func noteReceipt(
        source: TextFreeCandidateSource?,
        generatorMilliseconds: Int?,
        firstStableWordMilliseconds: Int?
    ) {
        if let source { candidateSource = source.rawValue }
        if self.generatorMilliseconds == nil, let generatorMilliseconds {
            self.generatorMilliseconds = min(300_000, max(0, generatorMilliseconds))
        }
        if self.firstStableWordMilliseconds == nil, let firstStableWordMilliseconds {
            self.firstStableWordMilliseconds = min(300_000, max(0, firstStableWordMilliseconds))
        }
    }

    public mutating func noteVisibleCandidate(characters: Int, wordCount: Int) {
        candidateCharacters = max(candidateCharacters, characters)
        candidateWordCount = max(candidateWordCount, wordCount)
    }

    public mutating func noteTyped(at time: Date) {
        recordNextAction(at: time)
        typedAfterShow = true
    }

    public mutating func noteAccepted(_ text: String, kind: AcceptKind, at time: Date) {
        recordNextAction(at: time)
        if acceptedKind == nil {
            acceptedKind = kind
        }
        accepted += text
        acceptedCharacterCount += text.count
    }

    /// Drop the span so it cannot be written later. Counts stay.
    public mutating func wipeAcceptedText() {
        accepted = ""
    }

    public mutating func noteDismissed(at time: Date) {
        recordNextAction(at: time)
        dismissed = true
    }

    public mutating func settleVisible(at time: Date) {
        let milliseconds = milliseconds(from: shownAt, to: time)
        settledVisibleMilliseconds = max(settledVisibleMilliseconds ?? 0, milliseconds)
    }

    public func outcome() -> String {
        if didAccept {
            return acceptedKind == .all ? "accepted-all" : "accepted-word"
        }
        if dismissed { return "dismissed" }
        if TypedThroughRule.isTypedThrough(
            displayed: true,
            settledVisibleMilliseconds: settledVisibleMilliseconds,
            typedAfterShow: typedAfterShow,
            accepted: false,
            dismissed: false
        ) {
            return "typed-through"
        }
        return "ignored"
    }

    public func finishedEvent(
        retentionAt5Seconds: RetainedCharacterObservation,
        retentionAt30Seconds: RetainedCharacterObservation,
        retentionAtSegmentClose: RetainedCharacterObservation,
        replacedCharactersWithin5Seconds: Int = 0
    ) throws -> TextFreeOnlineEvent {
        let acceptedCount = acceptedCharacterCount
        let outcome = outcome()
        let isAccept = outcome == "accepted-all" || outcome == "accepted-word"
        return TextFreeOnlineEvent(
            id: id,
            occurredAt: shownAt,
            sessionDigestSHA256: sessionDigestSHA256,
            variant: variant,
            appCategory: appCategory,
            register: register,
            boundary: boundary,
            safeOpportunity: safeOpportunity,
            generated: true,
            displayed: true,
            outcome: outcome,
            acceptedCharacters: isAccept ? acceptedCount : 0,
            replacedCharactersWithin5Seconds: isAccept ? replacedCharactersWithin5Seconds : 0,
            nextActionMilliseconds: nextActionMilliseconds,
            generatorMilliseconds: generatorMilliseconds,
            firstStableWordMilliseconds: firstStableWordMilliseconds,
            settledVisibleMilliseconds: settledVisibleMilliseconds,
            candidateCharacters: max(candidateCharacters, isAccept ? acceptedCount : 0),
            candidateSourceBucket: candidateSource,
            candidateLengthBucket: TextFreeLengthBucket.from(wordCount: candidateWordCount).rawValue,
            configurationDigestSHA256: configurationDigestSHA256,
            opportunityCharacters: opportunityCharacters,
            retentionAt5Seconds: try retentionAt5Seconds.validated(),
            retentionAt30Seconds: try retentionAt30Seconds.validated(),
            retentionAtSegmentClose: try retentionAtSegmentClose.validated()
        )
    }

    public func eventWithoutAcceptedSpan() throws -> TextFreeOnlineEvent {
        if didAccept {
            let missing = RetainedCharacterObservation(missingness: .observerStopped)
            return try finishedEvent(
                retentionAt5Seconds: missing,
                retentionAt30Seconds: missing,
                retentionAtSegmentClose: missing
            )
        }
        // Same 5s default Lab already uses for a finished non-accept:
        // accepted minus replaced is zero. Later horizons stay missing.
        let zero = try RetainedCharacterObservation(retainedCharacters: 0)
        let pending = RetainedCharacterObservation(missingness: .notYetObserved)
        return try finishedEvent(
            retentionAt5Seconds: zero,
            retentionAt30Seconds: pending,
            retentionAtSegmentClose: pending
        )
    }

    private mutating func recordNextAction(at time: Date) {
        if nextActionMilliseconds == nil {
            nextActionMilliseconds = milliseconds(from: shownAt, to: time)
        }
        settleVisible(at: time)
    }

    private func milliseconds(from start: Date, to end: Date) -> Int {
        let value = Int((max(0, end.timeIntervalSince(start)) * 1_000).rounded())
        return min(300_000, value)
    }
}

/// Pending accept whose horizons are not all known yet.
public struct PendingRetainedWatch: Equatable, Sendable {
    public var opportunity: LiveOnlineOpportunity
    public var retentionAt5Seconds: RetainedCharacterObservation
    public var retentionAt30Seconds: RetainedCharacterObservation
    public var retentionAtSegmentClose: RetainedCharacterObservation

    public init(opportunity: LiveOnlineOpportunity) {
        self.opportunity = opportunity
        retentionAt5Seconds = RetainedCharacterObservation(missingness: .notYetObserved)
        retentionAt30Seconds = RetainedCharacterObservation(missingness: .notYetObserved)
        retentionAtSegmentClose = RetainedCharacterObservation(missingness: .notYetObserved)
    }

    public var accepted: String { opportunity.accepted }

    public var isComplete: Bool {
        retentionAt5Seconds.missingness != .notYetObserved
            && retentionAt30Seconds.missingness != .notYetObserved
            && retentionAtSegmentClose.missingness != .notYetObserved
    }

    public mutating func observeFiveSeconds(window: String?) throws {
        guard retentionAt5Seconds.missingness == .notYetObserved else { return }
        retentionAt5Seconds = try RetainedSpanWatch.observation(
            accepted: accepted,
            window: window
        )
        if let kept = retentionAt5Seconds.retainedCharacters {
            let replaced = max(0, accepted.count - kept)
            // Five-second replacement is the v2 field; keep it honest.
            _ = replaced
        }
    }

    public mutating func observeThirtySeconds(window: String?) throws {
        guard retentionAt30Seconds.missingness == .notYetObserved else { return }
        retentionAt30Seconds = RetainedSpanWatch.monotone(
            try RetainedSpanWatch.observation(accepted: accepted, window: window),
            notExceeding: retentionAt5Seconds
        )
    }

    public mutating func observeSegment(window: String?) throws {
        guard retentionAtSegmentClose.missingness == .notYetObserved else { return }
        var observed = RetainedSpanWatch.monotone(
            try RetainedSpanWatch.observation(accepted: accepted, window: window),
            notExceeding: retentionAt30Seconds
        )
        observed = RetainedSpanWatch.monotone(observed, notExceeding: retentionAt5Seconds)
        retentionAtSegmentClose = observed
    }

    public mutating func markPrivacyExcluded() {
        if retentionAt5Seconds.missingness == .notYetObserved {
            retentionAt5Seconds = RetainedCharacterObservation(missingness: .privacyExcluded)
        }
        if retentionAt30Seconds.missingness == .notYetObserved {
            retentionAt30Seconds = RetainedCharacterObservation(missingness: .privacyExcluded)
        }
        if retentionAtSegmentClose.missingness == .notYetObserved {
            retentionAtSegmentClose = RetainedCharacterObservation(missingness: .privacyExcluded)
        }
        opportunity.wipeAcceptedText()
    }

    public mutating func closeSegment(window: String?) throws {
        try observeSegment(window: window)
        retentionAt5Seconds = RetainedSpanWatch.closedEarlyIfStillWaiting(retentionAt5Seconds)
        retentionAt30Seconds = RetainedSpanWatch.closedEarlyIfStillWaiting(retentionAt30Seconds)
    }

    public mutating func stopObserver() {
        if retentionAt5Seconds.missingness == .notYetObserved {
            retentionAt5Seconds = RetainedCharacterObservation(missingness: .observerStopped)
        }
        if retentionAt30Seconds.missingness == .notYetObserved {
            retentionAt30Seconds = RetainedCharacterObservation(missingness: .observerStopped)
        }
        if retentionAtSegmentClose.missingness == .notYetObserved {
            retentionAtSegmentClose = RetainedCharacterObservation(missingness: .observerStopped)
        }
        opportunity.wipeAcceptedText()
    }

    public mutating func finishedEvent() throws -> TextFreeOnlineEvent {
        let replaced: Int
        if let kept = retentionAt5Seconds.retainedCharacters {
            replaced = max(0, opportunity.acceptedCharacterCount - kept)
        } else {
            replaced = 0
        }
        let event = try opportunity.finishedEvent(
            retentionAt5Seconds: retentionAt5Seconds,
            retentionAt30Seconds: retentionAt30Seconds,
            retentionAtSegmentClose: retentionAtSegmentClose,
            replacedCharactersWithin5Seconds: replaced
        )
        opportunity.wipeAcceptedText()
        return event
    }
}

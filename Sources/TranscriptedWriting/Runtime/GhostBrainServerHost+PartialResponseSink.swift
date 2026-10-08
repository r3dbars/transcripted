#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation
import Security

extension GhostBrainServerHost {
    /// Serializes partial writes from the engine's stream loop. A failed
    /// write means the input method is gone or wedged; the sink then cancels
    /// inference instead of letting the helper run for nobody.
    ///
    /// It is also the streaming gate for "Personal suggestions
    /// (experimental)". A personal answer may replace the base ghost's first
    /// word, and the keyboard grows a visible ghost rather than rewriting it
    /// — which is why this sink used to be constructed disabled outright
    /// whenever the toggle was on, silently costing every request its
    /// word-by-word ghost. Instead the sink now holds the FIRST stable
    /// prefix, and only that one, for a short bounded window while the
    /// personal lookup races:
    ///
    /// - a replacement that wins inside the window closes the stream and the
    ///   request answers with one final line (nothing was shown, so nothing
    ///   is rewritten);
    /// - a base or agreed answer, or an expired window, releases the held
    ///   prefix and streaming continues exactly as it does with the toggle
    ///   off;
    /// - once anything has been written the terminal line honours the base
    ///   ghost (`PersonalSuggestionPolicy.finalSuggestion`), so a late
    ///   personal answer can never rewrite what the writer is reading.
    ///
    /// Internal, not private, so the state machine is provable without a
    /// live socket: `write` is injected, and `expireHold` is the window
    /// firing.
    final class PartialResponseSink: @unchecked Sendable {
        /// One event per request, fixed vocabulary, no candidate text.
        enum HoldOutcome: String, CaseIterable {
            /// Streamed with nothing ever held — no personal lookup ran, or it
            /// answered before the first prefix. (The diagnostic is recorded
            /// only for streaming peers, so there is no "unstreamed" case.)
            case notHeld = "not-held"
            /// A prefix was held and the personal answer released it in time.
            case streamed
            /// A prefix was held until the window expired, then released.
            case expired
            /// A personal replacement won while holding; final-only.
            case finalOnly = "final-only"
            /// The request ended while the prefix was still held: the writer
            /// got no streamed ghost because the personal lookup never
            /// answered in time. The one outcome that costs the writer.
            case heldUntilEnd = "held-until-end"
        }

        private enum GateState { case streaming, holding, closed }

        private let enabled: Bool
        private let register: ContinuationRegister
        private let midWordContext: Bool
        private let opportunityID: String?
        private var firstStableWordMilliseconds: Int?
        private let holdDeadlineNanoseconds: UInt64
        private let targetIsCurrent: @Sendable () -> Bool
        private let write: @Sendable (GhostBrainResponse) -> Bool
        private let lock = NSLock()
        private var state: GateState
        private var failed = false
        private var failureHandler: (() -> Void)?
        private var heldPartial: String?
        private var holdStartedAt: Date?
        private var heldMilliseconds = 0
        private var wroteAnything = false
        private var personalLookup: PersonalLookupState
        private var outcome: HoldOutcome
        private var expiryTimer: Task<Void, Never>?

        init(
            enabled: Bool,
            holdingForPersonal: Bool,
            register: ContinuationRegister,
            midWordContext: Bool = false,
            opportunityID: String? = nil,
            holdDeadlineNanoseconds: UInt64,
            targetIsCurrent: @escaping @Sendable () -> Bool,
            write: @escaping @Sendable (GhostBrainResponse) -> Bool
        ) {
            self.enabled = enabled
            self.register = register
            self.midWordContext = midWordContext
            self.opportunityID = opportunityID
            self.holdDeadlineNanoseconds = holdDeadlineNanoseconds
            self.targetIsCurrent = targetIsCurrent
            self.write = write
            let holding = enabled && holdingForPersonal
            state = holding ? .holding : .streaming
            personalLookup = holding ? .pending : .resolved(nil)
            outcome = .notHeld
        }

        var onWriteFailure: (() -> Void)? {
            get { lock.withLock { failureHandler } }
            set { lock.withLock { failureHandler = newValue } }
        }

        /// Whether any prefix reached the keyboard. The terminal line must
        /// honour the base ghost whenever this is true.
        var didStream: Bool { lock.withLock { wroteAnything } }

        func send(_ partial: CompletionSuggestion, firstStableWordMilliseconds: Int? = nil) {
            guard enabled else { return }
            lock.withLock {
                if self.firstStableWordMilliseconds == nil { self.firstStableWordMilliseconds = firstStableWordMilliseconds }
            }
            guard targetIsCurrent() else {
                lock.withLock {
                    guard !failed else { return }
                    failed = true
                    failureHandler?()
                }
                return
            }
            let text = GhostBrainServerHost.servedText(partial.visibleText, midWord: midWordContext)
            guard !text.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            guard !failed, state != .closed else { return }
            if state == .holding {
                heldPartial = text
                applyDecisionLocked()
                return
            }
            writeLocked(text)
        }

        /// The personal lookup answered. Called at most once per request,
        /// from the observer that shares the lookup task with
        /// `awaitPersonalPrediction`.
        func resolvePersonal(_ prediction: PersonalNextWordPrediction?) {
            lock.lock()
            defer { lock.unlock() }
            personalLookup = .resolved(prediction)
            guard state == .holding else { return }
            applyDecisionLocked()
        }

        /// The bounded hold window elapsed: release the prefix and stream.
        /// A personal answer that lands after this can no longer replace it.
        func expireHold() {
            lock.lock()
            defer { lock.unlock() }
            guard state == .holding else { return }
            releaseLocked(outcome: .expired)
        }

        /// No further partials may be written for this request. Taken before
        /// the terminal line is written so a held prefix can never be
        /// flushed into the middle of it.
        func finish() {
            let timer: Task<Void, Never>? = lock.withLock {
                if state == .holding {
                    stopHoldClockLocked()
                    if heldPartial != nil { outcome = .heldUntilEnd }
                }
                state = .closed
                heldPartial = nil
                let timer = expiryTimer
                expiryTimer = nil
                return timer
            }
            timer?.cancel()
        }

        /// The request's one hold event. Fixed words and a duration only.
        func holdDiagnostics() -> [String: String] {
            lock.withLock {
                ["outcome": outcome.rawValue, "heldMilliseconds": String(heldMilliseconds)]
            }
        }

        private func applyDecisionLocked() {
            switch PersonalSuggestionPolicy.streamDecision(
                basePrefix: heldPartial,
                personalLookup: personalLookup
            ) {
            case .hold:
                startHoldClockLocked()
            case .stream:
                releaseLocked(outcome: holdStartedAt == nil ? .notHeld : .streamed)
            case .finalOnly:
                stopHoldClockLocked()
                state = .closed
                heldPartial = nil
                outcome = .finalOnly
            }
        }

        private func releaseLocked(outcome released: HoldOutcome) {
            stopHoldClockLocked()
            state = .streaming
            outcome = released
            if let heldPartial {
                self.heldPartial = nil
                writeLocked(heldPartial)
            }
        }

        /// Only a prefix that actually exists starts the clock — a personal
        /// lookup still running while the generator has produced nothing has
        /// delayed no ghost, and must not be reported as if it had.
        private func startHoldClockLocked() {
            guard heldPartial != nil, holdStartedAt == nil, expiryTimer == nil else { return }
            holdStartedAt = Date()
            expiryTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.holdDeadlineNanoseconds ?? 0)
                guard !Task.isCancelled else { return }
                self?.expireHold()
            }
        }

        private func stopHoldClockLocked() {
            if let holdStartedAt {
                heldMilliseconds = GhostBrainServerHost.milliseconds(from: holdStartedAt, to: Date())
                self.holdStartedAt = nil
            }
            expiryTimer?.cancel()
            expiryTimer = nil
        }

        private func writeLocked(_ text: String) {
            guard !failed else { return }
            if write(GhostBrainResponse.partial(
                text,
                register: register,
                opportunityID: opportunityID,
                firstStableWordMilliseconds: firstStableWordMilliseconds
            )) {
                wroteAnything = true
            } else {
                failed = true
                DiagnosticsLog.shared.record("ghost-partial-write-failed", metadata: [:])
                failureHandler?()
            }
        }
    }
}

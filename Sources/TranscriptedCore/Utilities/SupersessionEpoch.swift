import Foundation

/// A pure, allocation-free "is this async completion still current, or has it been
/// superseded" counter.
///
/// The tree re-implements this exact question — "did something newer start before
/// my async work finished?" — roughly three dozen times as raw `Int`/`UInt64`
/// fields with hand-placed `guard x == y` checks (e.g. `FloatingOverlayController
/// .hideGeneration`, `HomeViewModel.refreshGeneration`, `STTRouter
/// .backgroundWarmupGeneration`, `WhisperEngine.initializationGeneration`). Every
/// one of those sites hand-rolls the same three moves — bump, capture, compare —
/// with subtly different semantics at the edges (does a bump also fence out
/// current holders? does a successful comparison consume anything?). This type
/// names those moves once so a reader only has to learn the vocabulary a single
/// time.
///
/// `SupersessionEpoch` intentionally carries **no isolation opinion** — no lock,
/// no `@MainActor`. Every migrated call site so far is a `@MainActor`-hosted
/// field (mirroring `ParakeetRecoveryState`, which is a plain `Equatable` struct
/// mutated only under its host's own confinement). The host is responsible for
/// serializing access, exactly as it already does for the raw counter it
/// replaces.
///
/// ### Vocabulary
///
/// - `begin()` — "I am starting a new unit of work; give me a token that proves
///   I am the current owner." Mirrors the bump-then-capture pairs at
///   `HomeViewModel.loadCurrentLimits` (`refreshGeneration += 1; let generation =
///   refreshGeneration`), `SpeakerPeopleSettingsViewModel.refresh`,
///   `TranscriptedSettingsView.refreshHomeDashboard`, `STTRouter
///   .scheduleSelectedModelWarmup`, `WhisperEngine.initialize`, and
///   `NemotronEngine.initialize`.
/// - `snapshot()` — "let me read the current token without claiming ownership of
///   anything." Mirrors `FloatingOverlayController.hideWithConfirmAnimation` /
///   `hideWithCancelAnimation`, which capture `let gen = hideGeneration` before
///   kicking off an animation, purely to compare against later — the capture
///   site never "began" a unit of work via a bump of its own.
/// - `isCurrent(_:)` — a pure, repeatable "is this token still the live one?"
///   check. Mirrors the several independent guard checks scattered through
///   `WhisperEngine.load(model:generation:)` and `NemotronEngine.load
///   (generation:)`, each of which re-checks the same captured generation at a
///   different suspension point without consuming anything.
/// - `invalidate()` — "something reset or is starting over, and nobody in
///   particular owns the new epoch." Mirrors the bare `hideGeneration &+= 1` in
///   `FloatingOverlayController.showPanel()` / `cancelPendingHideForActiveDictation
///   ()`, and the `cleanup()`/`cancel()` bumps in `STTRouter`, `WhisperEngine`,
///   `NemotronEngine`, and `HomeViewModel` that exist purely to fence out
///   whatever async work was previously in flight.
/// - `finishIfCurrent(_:)` — "my owned unit of work reached its terminal
///   outcome; tell me whether I am still allowed to publish it." Does **not**
///   bump — the epoch stays open for whatever comes next. Mirrors the
///   `generation == self.refreshGeneration` / `generation == self
///   .backgroundWarmupGeneration` checks that gate applying a `Task`'s result in
///   `HomeViewModel`, `SpeakerPeopleSettingsViewModel`, `TranscriptedSettingsView
///   .refreshHomeDashboard`, and `STTRouter.scheduleSelectedModelWarmup`, and the
///   `initializationGeneration == generation` check at the very end of
///   `WhisperEngine.initialize` / `NemotronEngine.initialize` that decides
///   whether the caller still owns clearing its own tracking fields.
/// - `supersedeIfCurrent(_:)` — a terminal outcome that must also fence out every
///   other holder of the current token, e.g. a timeout that "wins" the race and
///   needs to make sure the original attempt can no longer publish anything late.
///   Mirrors `ParakeetRecoveryState.timeoutRecovery(generation:)`, which compares
///   against the current generation and then bumps it in the same operation
///   (`guard generation == self.generation, isRecovering else { return false };
///   self.generation &+= 1; ...; return true`).
/// - `predictedNext()` — names the "predict the generation a stop is about to
///   mint" pattern used at `MeetingCaptureBridge.stopAndAwaitFiles`, which reads
///   `audio.currentRecordingSessionGeneration &+ 1` to pre-register the
///   generation a synchronous `audio.stop()` call is about to produce, before
///   that call actually bumps it. **Hazard:** the prediction is only valid if
///   nothing else can bump the epoch between the call to `predictedNext()` and
///   the actual `begin()`/bump that is expected to produce the predicted value
///   — exactly as `MeetingCaptureBridge` relies on `audio.stop()` being the very
///   next synchronous statement after computing `stopGeneration`. Do not cache a
///   `predictedNext()` result across a suspension point or any code that could
///   itself call `begin()`/`invalidate()`/`supersedeIfCurrent(_:)`.
///
/// All arithmetic uses `&+` — this is a long-running counter for in-process
/// liveness checks, not an identity that must never repeat, so overflow wrapping
/// (once every ~584 billion years at 1 bump/ns) is an accepted, deliberate
/// behavior rather than a bug to guard against.
public struct SupersessionEpoch: Equatable, Sendable {
    /// An opaque, comparable point-in-time reading of a `SupersessionEpoch`.
    ///
    /// Tokens can only be produced by their owning `SupersessionEpoch` (via
    /// `begin()`, `snapshot()`, or `predictedNext()`), which keeps arbitrary code
    /// from constructing a token that happens to compare equal by accident.
    ///
    /// `rawValue` is exposed read-only for logging/telemetry interop — several
    /// existing call sites already thread a raw `UInt64` generation number
    /// through structured log context (e.g. `MeetingCaptureBridge`'s
    /// `"stopGeneration"` / `"currentGeneration"` log fields, and
    /// `ParakeetZombieRecoveryTerminal.generation`). Migrated call sites that
    /// need to log a generation number can read `token.rawValue` instead of
    /// reintroducing a parallel raw counter just for logging.
    public struct Token: Equatable, Sendable {
        public let rawValue: UInt64

        fileprivate init(rawValue: UInt64) {
            self.rawValue = rawValue
        }
    }

    /// The epoch's current token. Starts at the zero generation, matching every
    /// migrated raw-counter field's `= 0` initial value.
    public private(set) var current: Token

    public init() {
        current = Token(rawValue: 0)
    }

    /// Test-only escape hatch for constructing an epoch already positioned at an
    /// arbitrary raw generation, so wraparound behavior can be exercised without
    /// looping `begin()` `UInt64.max` times. Not public — reachable only from
    /// within this module, e.g. via `@testable import`.
    init(testRawValue: UInt64) {
        current = Token(rawValue: testRawValue)
    }

    /// Starts a new epoch that the caller now owns, and returns the token that
    /// proves ownership. Use this at the top of an operation that is about to
    /// kick off async work whose eventual completion must be checked against
    /// staleness (the bump-then-capture half of the `begin`/`finishIfCurrent`
    /// pair).
    @discardableResult
    public mutating func begin() -> Token {
        current = Token(rawValue: current.rawValue &+ 1)
        return current
    }

    /// Reads the current token without claiming ownership of a new epoch. Use
    /// this to capture "the epoch as of right now" purely for a later
    /// comparison, when the capturing call site did not itself start a new unit
    /// of work (the observe-then-verify half of the `snapshot`/`isCurrent` pair).
    public func snapshot() -> Token {
        current
    }

    /// Pure, repeatable check: is `t` still the live token? Never mutates, and
    /// may be called any number of times against the same captured token across
    /// several suspension points within one logical unit of work.
    public func isCurrent(_ t: Token) -> Bool {
        t == current
    }

    /// Bumps the epoch with no particular new owner — the "something reset, or
    /// is starting fresh, and every previously-issued token is now stale" move.
    /// Use this for cleanup/cancel/reset paths that exist purely to fence out
    /// whatever was previously in flight, not to hand out a new token to
    /// anything in particular.
    public mutating func invalidate() {
        current = Token(rawValue: current.rawValue &+ 1)
    }

    /// Compares `t` against the current token **without bumping**. Returns
    /// `true` when the caller's owned unit of work (previously started with
    /// `begin()`) is still current and is therefore allowed to publish its
    /// result. The epoch stays open afterward — this is a terminal check for
    /// the caller's own attempt, not a reset for everyone else.
    @discardableResult
    public mutating func finishIfCurrent(_ t: Token) -> Bool {
        t == current
    }

    /// Compares `t` against the current token **and bumps it** when they match.
    /// Use this for a terminal outcome that must also fence out every other
    /// holder of the current token — e.g. a timeout that "wins" a race and needs
    /// to guarantee the original attempt can no longer publish a late result.
    /// Returns `false` (without bumping) when `t` is already stale.
    @discardableResult
    public mutating func supersedeIfCurrent(_ t: Token) -> Bool {
        guard t == current else { return false }
        current = Token(rawValue: current.rawValue &+ 1)
        return true
    }

    /// Predicts the token a future `begin()` (or equivalent bump) is about to
    /// mint, **without** bumping the epoch now. Exists for call sites that must
    /// pre-register the generation an imminent synchronous operation is about to
    /// produce, before that operation itself performs the bump (see
    /// `MeetingCaptureBridge.stopAndAwaitFiles`, which is not migrated onto this
    /// type but is the pattern this operation names).
    ///
    /// - Warning: The prediction is only valid until the next call that mutates
    ///   this epoch. Do not hold a `predictedNext()` result across a suspension
    ///   point, or across any code that might itself call `begin()`,
    ///   `invalidate()`, or `supersedeIfCurrent(_:)` — doing so silently
    ///   invalidates the prediction and reintroduces the exact staleness bug
    ///   this type exists to prevent.
    public func predictedNext() -> Token {
        Token(rawValue: current.rawValue &+ 1)
    }
}

/// A single-slot claim check keyed by a `SupersessionEpoch.Token`.
///
/// Pairs naturally with `SupersessionEpoch` for the common "stash a payload that
/// only the owner of a given generation may later retrieve" shape — e.g. a
/// pending continuation, a callback, or a piece of async-attempt state that must
/// not be handed to a caller holding a stale token.
public struct ClaimSlot<Payload> {
    private var entry: (token: SupersessionEpoch.Token, payload: Payload)?

    public init() {}

    /// Installs `payload` under `token`, unconditionally displacing whatever was
    /// previously stored (regardless of which token owned it). Returns the
    /// displaced payload, if any, so the caller can decide how to handle it
    /// (e.g. resume a displaced continuation with a cancellation error).
    @discardableResult
    public mutating func install(_ payload: Payload, ownedBy token: SupersessionEpoch.Token) -> Payload? {
        let displaced = entry?.payload
        entry = (token, payload)
        return displaced
    }

    /// Removes and returns the stored payload only if it is currently owned by
    /// `token`; leaves the slot untouched and returns `nil` otherwise. The
    /// compare-and-consume operation — call this from the one place that is
    /// allowed to claim the payload for `token`.
    public mutating func takeIfOwned(by token: SupersessionEpoch.Token) -> Payload? {
        guard let entry, entry.token == token else { return nil }
        self.entry = nil
        return entry.payload
    }

    /// Reads the stored payload without removing it, only if it is currently
    /// owned by `token`.
    public func peekIfOwned(by token: SupersessionEpoch.Token) -> Payload? {
        guard let entry, entry.token == token else { return nil }
        return entry.payload
    }

    /// Removes and returns whatever is stored, regardless of which token owns
    /// it. Use for unconditional teardown paths (e.g. host shutdown) that must
    /// clear the slot no matter what.
    @discardableResult
    public mutating func clear() -> Payload? {
        defer { entry = nil }
        return entry?.payload
    }

    /// Clears the slot only if it is currently owned by `token`. Returns
    /// whether anything was cleared.
    @discardableResult
    public mutating func clearIfOwned(by token: SupersessionEpoch.Token) -> Bool {
        guard let entry, entry.token == token else { return false }
        self.entry = nil
        return true
    }
}

extension ClaimSlot: Sendable where Payload: Sendable {}

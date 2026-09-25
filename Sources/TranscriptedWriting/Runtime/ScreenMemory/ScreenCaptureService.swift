#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Carbon.HIToolbox.Events
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Owns Screen Memory's capture pipeline end to end: ScreenCaptureKit
/// full-display capture, Vision OCR, per-window attribution. Memory-only in
/// this phase — nothing here persists a `ScreenSnapshot` anywhere; the
/// latest one lives in `latestSnapshot` until the next capture replaces it
/// or the process exits.
///
/// Every capture attempt is routed through `CaptureTriggerPolicy` (Core,
/// pure) with freshly observed state, so the covenant's non-negotiables —
/// the user's own master toggle (on by default, always visible and
/// switchable), Secure Event Input, screen lock, per-app exclusion against
/// every visible window, an active text field, and the 1/2s cadence cap —
/// are enforced by tested logic, not re-derived here.
actor ScreenCaptureService {
    enum CaptureOutcome: Equatable, Sendable {
        case captured(blockCount: Int)
        case skipped(CaptureTriggerPolicy.BlockReason)
        case permissionNotGranted
        case captureFailed
    }

    enum CaptureReservation: Equatable, Sendable {
        case reserved(previousCaptureAt: Date?)
        case blocked(CaptureTriggerPolicy.BlockReason)
    }

    private var lastCaptureAt: Date?
    private var lastContentResetAt: Date?
    private var lastActivityAt: Date?
    private(set) var latestSnapshot: ScreenSnapshot?
    /// The most recent window-only capture, kept separately from
    /// `latestSnapshot` so a full-display read landing a second later can
    /// never replace a good conversation read with a weaker one (display
    /// reads attribute blocks to windows best-effort; window reads are
    /// exact). `freshScene` asks this one first.
    private(set) var latestWindowSnapshot: ScreenSnapshot?
    private var pendingTextFieldCaptureTask: Task<Void, Never>?
    private var activeTextFieldSessionIdentifier: String?
    private var activeTypingTarget: TypingTargetIdentity?
    private var typingTargetGeneration: UInt64 = 0
    private var textFieldRequiresFullRefresh = false

    /// Counts every capture that reaches `performCapture` (cadence/exclusion
    /// already cleared it). Referencing needs OTHER windows' text, which a
    /// single-window capture can never see by construction — the filter
    /// physically excludes every other window's pixels — so this forces a
    /// full-display pass on every Nth capture to keep referencing fed. `3` is
    /// a simple, documented choice: frequent enough that referenceSnippets
    /// stay usable within the 20s staleness window (`ScreenScene`'s
    /// `defaultStalenessCapSeconds`), infrequent enough that most captures
    /// still get the window-only path's ~2x OCR speedup and exact
    /// attribution.
    /// Window-first capture (`CaptureKindPolicy`): the display is read only
    /// when the last window capture found no conversation and the previous
    /// display read has aged past the scene staleness window.
    private var lastWindowSceneHadConversation: Bool?
    private var lastFullDisplayCaptureAt: Date?

    /// Injectable for tests: the real system checks (TCC, lock screen,
    /// secure input, ScreenCaptureKit itself) are not something a unit test
    /// should have to actually perform on a display. `enabled` and
    /// `excludedApps` are providers, not stored state, so TildeSettings
    /// stays the single source of truth — flipping the menu toggle or
    /// editing the (Personal-History-shared) exclusion list takes effect on
    /// the very next trigger with nothing to keep in sync.
    private let enabled: @Sendable () -> Bool
    private let excludedApps: @Sendable () -> Set<String>
    private let permissionGranted: @Sendable () -> Bool
    private let screenLocked: @Sendable () -> Bool
    private let secureInputActive: @Sendable () -> Bool
    // Not @Sendable: closures without an isolation annotation are treated as
    // callable from any isolation domain, which is exactly what triggers a
    // "sending risks data races" error the moment an actor-isolated,
    // non-Sendable ScreenCaptureKit value (SCContentFilter,
    // SCStreamConfiguration) is passed into one. `captureImage` is not
    // injectable for that reason — see the direct SCScreenshotManager call
    // in `performCapture` — everything that IS a plain Sendable value stays
    // injectable for tests.
    private let shareableContent: () async throws -> SCShareableContent
    private let recognizeText: (CGImage) async throws -> [ScreenTextRecognizer.RecognizedBlock]
    private let now: @Sendable () -> Date
    private let diagnostics: @Sendable (String, [String: String]) -> Void
    private let axWindowText: @Sendable (SCWindow, SCDisplay) -> AXWindowTextReader.Result?

    init(
        enabled: @escaping @Sendable () -> Bool,
        excludedApps: @escaping @Sendable () -> Set<String>,
        permissionGranted: @escaping @Sendable () -> Bool = { ScreenRecordingPermission.isGranted() },
        screenLocked: @escaping @Sendable () -> Bool = { ScreenLockObserver.isLocked() },
        secureInputActive: @escaping @Sendable () -> Bool = { IsSecureEventInputEnabled() },
        shareableContent: @escaping () async throws -> SCShareableContent = {
            try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        },
        recognizeText: @escaping (CGImage) async throws -> [ScreenTextRecognizer.RecognizedBlock] = {
            try await ScreenTextRecognizer.recognize(image: $0)
        },
        axWindowText: @escaping @Sendable (SCWindow, SCDisplay) -> AXWindowTextReader.Result? = {
            AXWindowTextReader.read(for: $0, display: $1)
        },
        now: @escaping @Sendable () -> Date = Date.init,
        diagnostics: @escaping @Sendable (String, [String: String]) -> Void = { event, metadata in
            DiagnosticsLog.shared.record(event, metadata: metadata)
        }
    ) {
        self.enabled = enabled
        self.excludedApps = excludedApps
        self.permissionGranted = permissionGranted
        self.screenLocked = screenLocked
        self.secureInputActive = secureInputActive
        self.shareableContent = shareableContent
        self.recognizeText = recognizeText
        self.axWindowText = axWindowText
        self.now = now
        self.diagnostics = diagnostics
    }

    /// The focused-window trigger. It may refresh context while an IMKit
    /// text session is active, but an ordinary app switch with no active
    /// text field is rejected by the shared capture policy.
    @discardableResult
    func noteWindowChanged(target: TypingTargetIdentity? = nil) async -> CaptureOutcome {
        if let sessionIdentifier = activeTextFieldSessionIdentifier {
            adoptTarget(target, sessionIdentifier: sessionIdentifier, forceNewGeneration: false)
        }
        return await attemptCapture(trigger: .windowChanged)
    }

    /// A real IMKit input session became active. The first refresh uses the
    /// full display so Vision's `.accurate` recognizer rebuilds a complete
    /// scene. The safety gates and two-second heavy-capture ceiling still
    /// apply.
    /// The conversation changed in place. Everything captured before this
    /// moment is the WRONG conversation: serving it beats nothing only if
    /// wrong beats silence, and it does not. Invalidate first, then try to
    /// capture fresh content like a field focus would.
    @discardableResult
    func noteContentReset(
        sessionIdentifier: String,
        target: TypingTargetIdentity? = nil
    ) async -> CaptureOutcome {
        lastContentResetAt = now()
        activeTextFieldSessionIdentifier = sessionIdentifier
        adoptTarget(target, sessionIdentifier: sessionIdentifier, forceNewGeneration: true)
        lastActivityAt = now()
        textFieldRequiresFullRefresh = true
        pendingTextFieldCaptureTask?.cancel()
        pendingTextFieldCaptureTask = nil
        let outcome = await attemptTextFieldCapture(trigger: .textFieldFocused)
        scheduleRetryAfterCadenceIfNeeded(outcome, trigger: .textFieldFocused)
        return outcome
    }

    @discardableResult
    func noteTextFieldFocused(
        sessionIdentifier: String,
        target: TypingTargetIdentity? = nil
    ) async -> CaptureOutcome {
        activeTextFieldSessionIdentifier = sessionIdentifier
        adoptTarget(target, sessionIdentifier: sessionIdentifier, forceNewGeneration: false)
        lastActivityAt = now()
        textFieldRequiresFullRefresh = true
        pendingTextFieldCaptureTask?.cancel()
        pendingTextFieldCaptureTask = nil
        let outcome = await attemptTextFieldCapture(trigger: .textFieldFocused)
        scheduleRetryAfterCadenceIfNeeded(outcome, trigger: .textFieldFocused)
        return outcome
    }

    /// The IME has observed 250ms without another printable keystroke. Only
    /// the active session may refresh; a late pulse from an old field is
    /// ignored.
    @discardableResult
    func noteTypingPaused(
        sessionIdentifier: String,
        target: TypingTargetIdentity? = nil
    ) async -> CaptureOutcome? {
        guard activeTextFieldSessionIdentifier == sessionIdentifier else { return nil }
        adoptTarget(target, sessionIdentifier: sessionIdentifier, forceNewGeneration: false)
        lastActivityAt = now()
        pendingTextFieldCaptureTask?.cancel()
        pendingTextFieldCaptureTask = nil
        let trigger = CaptureTriggerPolicy.Trigger.typingPause(
            elapsedSeconds: CaptureTriggerPolicy.typingPauseThresholdSeconds
        )
        let outcome = await attemptTextFieldCapture(trigger: trigger)
        scheduleRetryAfterCadenceIfNeeded(outcome, trigger: trigger)
        return outcome
    }

    /// Stops delayed refreshes for the field that actually lost focus. A
    /// stale blur from an older IMKit controller cannot cancel a newer one.
    func noteTextFieldBlurred(sessionIdentifier: String) {
        guard activeTextFieldSessionIdentifier == sessionIdentifier else { return }
        activeTextFieldSessionIdentifier = nil
        activeTypingTarget = nil
        pendingTextFieldCaptureTask?.cancel()
        pendingTextFieldCaptureTask = nil
    }

    /// A completion request reached the socket: the IME is actively
    /// serving the user, which is the "session" the typing-pause trigger
    /// requires. This does not read or forward the request's content — it
    /// is purely a timestamp pulse.
    /// Screen Memory plan Phase 2 PR 2b: the completion path's read of the
    /// capture pipeline. Purely reads `latestSnapshot` and hands it to
    /// `ScreenScene.freshScene`'s staleness gate — never triggers
    /// `attemptCapture`, so a completion request can call this and get an
    /// answer immediately, whether or not a capture happens to be in
    /// flight.
    ///
    /// Exclusion is re-checked here against `excludedApps()`'s CURRENT
    /// value, not just at capture time: a snapshot can be up to
    /// `ScreenScene.defaultStalenessCapSeconds` (20s) old, and the
    /// exclusion list can change at any moment in between (the user adding
    /// an app to it right after a capture must not leave that app's text
    /// readable from the cached snapshot for the rest of the staleness
    /// window). Blocks owned by a now-excluded app are dropped before
    /// classification ever sees them.
    func freshScene(
        frontmostBundleID: String?,
        fieldText: String,
        fieldSessionIdentifier: String? = nil,
        expectedTarget: TypingTargetIdentity? = nil,
        now: Date = Date()
    ) -> ScreenScene.Scene? {
        // The master toggle is re-checked here, not only in the app's scene
        // provider: this actor is the object that holds the screen text, so
        // it is also the object that refuses to hand it over. Anything still
        // in memory when the toggle went off is dropped by
        // `forgetCapturedScreenState()`; this closes the same door for a
        // capture that lands between the two.
        guard enabled() else { return nil }
        guard latestSnapshot != nil else { return nil }
        let target = activeTypingTarget
        if let fieldSessionIdentifier,
           target?.fieldSessionIdentifier != fieldSessionIdentifier {
            return nil
        }
        if let expectedTarget,
           target?.matchesWindowAndField(of: expectedTarget) != true {
            return nil
        }
        let currentlyExcluded = excludedApps()
        let resetAt = lastContentResetAt
        func filtered(_ snapshot: ScreenSnapshot?) -> ScreenSnapshot? {
            guard let snapshot else { return nil }
            // Bundle matching is not enough: two Slack/Chrome windows can
            // coexist. Only the exact target generation may feed a reply.
            if snapshot.evidence.source != .unspecified,
               snapshot.evidence.target != target {
                return nil
            }
            // A snapshot from before the last content reset is the wrong
            // conversation, not merely a stale one — never serve it.
            if let resetAt, snapshot.capturedAt < resetAt { return nil }
            guard !currentlyExcluded.isEmpty else { return snapshot }
            let keptBlocks = snapshot.blocks.filter {
                guard let owner = $0.windowOwnerBundleIdentifier else { return true }
                return !currentlyExcluded.contains(owner)
            }
            return ScreenSnapshot(
                capturedAt: snapshot.capturedAt,
                displayID: snapshot.displayID,
                blocks: keptBlocks,
                evidence: snapshot.evidence
            )
        }
        let classificationStart = self.now()
        // Window read first: it is the exact read of the app being typed
        // into. Only when it holds no conversation does the latest read of
        // any kind get a turn — that is where reference snippets from
        // other windows come from.
        var scene: ScreenScene.Scene?
        if latestWindowSnapshot != latestSnapshot,
           let windowScene = ScreenScene.freshScene(
               from: filtered(latestWindowSnapshot),
               now: now,
               frontmostBundleID: frontmostBundleID,
               fieldText: fieldText
           ),
           windowScene.mode == .replying {
            scene = windowScene
        } else {
            scene = ScreenScene.freshScene(
                from: filtered(latestSnapshot),
                now: now,
                frontmostBundleID: frontmostBundleID,
                fieldText: fieldText
            )
        }
        // Count-only diagnostics (2026-08-16 dogfood fix): mode plus two
        // integers, never the OCR'd text itself, so a classification going
        // wrong live is never opaque again — this was the exact gap that
        // made tonight's bug take a live dogfood session plus a manual
        // "hand the model the block directly" test to even confirm.
        // `DiagnosticsMetadataRedactor`'s allowlist enforces the fixed
        // vocabulary/integers-only shape at the log-writing layer, but the
        // event is only fired here, after a real classification ran (a
        // `nil` scene -- no snapshot yet, or too stale -- logs nothing,
        // matching every other "no signal" path in this file).
        // "P99 at every section" (2026-08-18): `milliseconds` times only the
        // `ScreenScene.freshScene` call itself, using the same injectable
        // `now()` clock as the rest of this actor — the block-filtering work
        // above is O(blocks) and cheap; classification (turn/reference
        // bucketing) is the part worth a percentile.
        if let scene {
            let classificationMilliseconds = Self.milliseconds(from: classificationStart, to: self.now())
            diagnostics("scene-classified", [
                "mode": scene.mode.rawValue,
                "turns": String(scene.conversationTurns.count),
                "refs": String(scene.referenceSnippets.count),
                "milliseconds": String(classificationMilliseconds),
            ])
        }
        return scene
    }

    /// Turning the Screen Memory master toggle off has to do more than stop
    /// the next capture. A snapshot can be served for up to
    /// `ScreenScene.defaultStalenessCapSeconds` after it was taken, so a
    /// toggle that only blocked future captures would leave the last look at
    /// the screen answering completions for another twenty seconds. This
    /// drops everything the actor is holding — both snapshots, the pending
    /// capture task, and the typing target they were attributed to — so
    /// there is nothing left to serve if the toggle comes back on.
    ///
    /// `lastContentResetAt` is moved forward rather than cleared: it is the
    /// "anything older than this is the wrong conversation" watermark, and a
    /// capture already in flight must not be able to land behind it.
    func forgetCapturedScreenState(now moment: Date = Date()) {
        pendingTextFieldCaptureTask?.cancel()
        pendingTextFieldCaptureTask = nil
        latestSnapshot = nil
        latestWindowSnapshot = nil
        activeTypingTarget = nil
        activeTextFieldSessionIdentifier = nil
        textFieldRequiresFullRefresh = false
        lastWindowSceneHadConversation = nil
        lastFullDisplayCaptureAt = nil
        lastContentResetAt = moment
    }

    /// The last gate before recognized screen text is retained in memory.
    /// `enabled()` is re-read here instead of being inherited from
    /// `attemptCapture`'s check because OCR suspends the capture for tens of
    /// milliseconds and the master toggle can go off inside that window; a
    /// capture that started while enabled must not land afterwards. Paired
    /// with `forgetCapturedScreenState()`, which runs after the setting is
    /// written: either this read already sees the new value and drops the
    /// snapshot, or the snapshot is stored first and the clear removes it.
    private func retainsCapturedScreenText() -> Bool {
        guard enabled() else {
            record(.skip(.disabled))
            return false
        }
        return true
    }

    /// Test seam: injects a snapshot directly, bypassing the entire
    /// ScreenCaptureKit/Vision pipeline that a unit test cannot drive.
    /// Production code always reaches `latestSnapshot` through a real
    /// `attemptCapture`; nothing outside tests calls this.
    func setLatestSnapshotForTesting(_ snapshot: ScreenSnapshot?) {
        latestSnapshot = snapshot
    }

    func setLatestWindowSnapshotForTesting(_ snapshot: ScreenSnapshot?) {
        latestWindowSnapshot = snapshot
    }

    func setLastContentResetAtForTesting(_ date: Date?) {
        lastContentResetAt = date
    }

    func noteCompletionActivity() {
        lastActivityAt = now()
    }

    /// Updates exact window ownership without making every repeated focus or
    /// typing pulse a new generation. A real window/session/content change
    /// invalidates older snapshots immediately; silence beats serving the
    /// previous conversation while the replacement capture is in flight.
    private func adoptTarget(
        _ proposed: TypingTargetIdentity?,
        sessionIdentifier: String,
        forceNewGeneration: Bool
    ) {
        guard let proposed,
              proposed.windowIdentifier != nil,
              proposed.processIdentifier != nil else {
            if forceNewGeneration || activeTypingTarget != nil {
                typingTargetGeneration &+= 1
                activeTypingTarget = nil
                lastContentResetAt = now()
                latestWindowSnapshot = nil
                textFieldRequiresFullRefresh = true
            }
            return
        }
        let candidate = TypingTargetIdentity(
            bundleIdentifier: proposed.bundleIdentifier,
            processIdentifier: proposed.processIdentifier,
            windowIdentifier: proposed.windowIdentifier,
            fieldSessionIdentifier: sessionIdentifier,
            generation: activeTypingTarget?.generation ?? typingTargetGeneration
        )
        let changed = activeTypingTarget?.matchesWindowAndField(of: candidate) != true
        guard forceNewGeneration || changed else { return }
        typingTargetGeneration &+= 1
        activeTypingTarget = TypingTargetIdentity(
            bundleIdentifier: candidate.bundleIdentifier,
            processIdentifier: candidate.processIdentifier,
            windowIdentifier: candidate.windowIdentifier,
            fieldSessionIdentifier: sessionIdentifier,
            generation: typingTargetGeneration
        )
        lastContentResetAt = now()
        latestWindowSnapshot = nil
        textFieldRequiresFullRefresh = true
    }

    @discardableResult
    private func attemptTextFieldCapture(
        trigger: CaptureTriggerPolicy.Trigger
    ) async -> CaptureOutcome {
        let outcome = await attemptCapture(
            trigger: trigger,
            forceFullDisplay: textFieldRequiresFullRefresh,
            forceFullOCR: textFieldRequiresFullRefresh
        )
        if case .captured = outcome {
            textFieldRequiresFullRefresh = false
        }
        return outcome
    }

    private func scheduleRetryAfterCadenceIfNeeded(
        _ outcome: CaptureOutcome,
        trigger: CaptureTriggerPolicy.Trigger
    ) {
        guard activeTextFieldSessionIdentifier != nil,
              case let .skipped(.cadence(secondsRemaining)) = outcome else { return }
        pendingTextFieldCaptureTask?.cancel()
        pendingTextFieldCaptureTask = Task { [weak self] in
            let nanoseconds = UInt64(max(0, secondsRemaining) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            let retry = await self.attemptTextFieldCapture(trigger: trigger)
            await self.scheduleRetryAfterCadenceIfNeeded(retry, trigger: trigger)
        }
    }

    private func attemptCapture(
        trigger: CaptureTriggerPolicy.Trigger,
        forceFullDisplay: Bool = false,
        forceFullOCR: Bool = false
    ) async -> CaptureOutcome {
        let moment = now()
        let isEnabled = enabled()

        guard isEnabled else {
            record(.skip(.disabled))
            return .skipped(.disabled)
        }
        guard permissionGranted() else {
            diagnostics("screen-capture-skipped", ["reason": "no-permission"])
            return .permissionNotGranted
        }
        guard activeTextFieldSessionIdentifier != nil else {
            record(.skip(.noActiveTextField))
            return .skipped(.noActiveTextField)
        }
        guard let captureTarget = activeTypingTarget,
              captureTarget.windowIdentifier != nil,
              captureTarget.processIdentifier != nil else {
            record(.skip(.noTargetWindow))
            return .skipped(.noTargetWindow)
        }

        let sessionActive = CaptureTriggerPolicy.isCompletionSessionActive(
            lastActivityAt: lastActivityAt,
            now: moment
        )

        // Reserve the cadence slot BEFORE the first suspension point below.
        // Actor reentrancy means another trigger can run its own synchronous
        // prefix while this call is suspended on `await shareableContent()`;
        // without reserving here, both calls would read the same stale
        // `lastCaptureAt`, both pass the 1-per-5s cadence check, and both go
        // on to capture. Recording `moment` now closes that window; if this
        // attempt turns out not to actually capture (enumeration failure,
        // excluded window, etc.), the reservation is rolled back below.
        let priorCaptureAt: Date?
        switch reserveCaptureSlot(trigger: trigger, at: moment) {
        case let .reserved(previous): priorCaptureAt = previous
        case let .blocked(reason): return .skipped(reason)
        }

        // Visible-window enumeration is required to honor "exclude if ANY
        // visible window belongs to an excluded app" — not just frontmost.
        // If we cannot enumerate, we cannot prove the exclusion list is
        // satisfied, so this fails closed rather than capturing blind.
        guard let content = try? await shareableContent() else {
            rollbackCaptureSlot(reservedAt: moment, to: priorCaptureAt)
            diagnostics("screen-capture-skipped", ["reason": "enumeration-failed"])
            return .captureFailed
        }
        guard activeTypingTarget == captureTarget else {
            rollbackCaptureSlot(reservedAt: moment, to: priorCaptureAt)
            record(.skip(.targetChanged))
            return .skipped(.targetChanged)
        }
        let visibleOwners = content.windows.compactMap(\.owningApplication?.bundleIdentifier)

        // Re-read `enabled()` here rather than reusing the `isEnabled`
        // captured above: `shareableContent()` just suspended this call,
        // and the user can flip the Screen Memory toggle off during that
        // window. Deciding off a value read before the only await point in
        // this method would let a capture that started while enabled land
        // — and get stored into `latestSnapshot` — after the toggle reads
        // off everywhere else in the app.
        let stillEnabled = enabled()
        let decision = CaptureTriggerPolicy.decision(
            for: trigger,
            enabled: stillEnabled,
            screenLocked: screenLocked(),
            secureInputActive: secureInputActive(),
            textFieldActive: activeTextFieldSessionIdentifier != nil,
            completionSessionActive: sessionActive,
            visibleWindowOwnerBundleIdentifiers: visibleOwners,
            excludedApps: excludedApps(),
            // Cadence was already enforced above (and its slot reserved);
            // passing `nil` here avoids re-checking it against the
            // now-reserved `lastCaptureAt`, which would always read as "too
            // soon" since it was just set to `moment`.
            lastCaptureAt: nil,
            now: moment
        )
        guard case let .skip(reason) = decision else {
            // decision is exhaustively .capture or .skip — reaching here means .capture.
            let outcome = await performCapture(
                content: content,
                moment: moment,
                target: captureTarget,
                forceFullDisplay: forceFullDisplay,
                forceFullOCR: forceFullOCR
            )
            if case .captured = outcome {
                return outcome
            }
            rollbackCaptureSlot(reservedAt: moment, to: priorCaptureAt)
            return outcome
        }
        rollbackCaptureSlot(reservedAt: moment, to: priorCaptureAt)
        record(.skip(reason))
        return .skipped(reason)
    }

    /// Atomically reserves the trigger-specific cadence slot before the
    /// first suspension point. Tests call this seam to prove the actor path,
    /// not only the pure policy in isolation.
    func reserveCaptureSlot(
        trigger: CaptureTriggerPolicy.Trigger,
        at moment: Date
    ) -> CaptureReservation {
        let prior = lastCaptureAt
        switch CaptureTriggerPolicy.cadenceDecision(
            for: trigger,
            lastCaptureAt: prior,
            now: moment
        ) {
        case .capture:
            lastCaptureAt = moment
            return .reserved(previousCaptureAt: prior)
        case let .skip(reason):
            record(.skip(reason))
            return .blocked(reason)
        }
    }

    private func rollbackCaptureSlot(reservedAt: Date, to prior: Date?) {
        // Do not erase a newer successful reservation if this task resumed
        // after another actor call advanced the slot.
        guard lastCaptureAt == reservedAt else { return }
        lastCaptureAt = prior
    }

    private func commitCaptureSlot(at moment: Date) {
        if let current = lastCaptureAt, current > moment { return }
        lastCaptureAt = moment
    }

    /// Chooses window-only vs full-display capture and dispatches to the
    /// matching path. `CaptureKindPolicy` decides when the display is worth
    /// reading (see its doc comment); on any capture that isn't forced full,
    /// `frontmostWindow` still has to actually find a layer-0 window or this
    /// falls back to full-display anyway — a window-only capture is never
    /// attempted blind.
    private func performCapture(
        content: SCShareableContent,
        moment: Date,
        target: TypingTargetIdentity,
        forceFullDisplay: Bool,
        forceFullOCR: Bool
    ) async -> CaptureOutcome {
        guard let targetWindow = Self.targetWindow(for: target, among: content.windows),
              let display = Self.display(containing: targetWindow, in: content.displays) else {
            diagnostics("screen-capture-skipped", ["reason": "no-display"])
            return .captureFailed
        }

        let kind = CaptureKindPolicy.kind(
            forcedFullDisplay: forceFullDisplay,
            lastWindowSceneHadConversation: lastWindowSceneHadConversation,
            secondsSinceLastFullDisplay: lastFullDisplayCaptureAt.map { moment.timeIntervalSince($0) },
            stalenessCapSeconds: ScreenScene.defaultStalenessCapSeconds
        )
        let zRanks = Self.onScreenZOrderRanks()

        if kind == .window {
            // Accessibility-first: the exact strings the app draws, in ~1ms,
            // when the user granted the permission and the app's tree
            // carries real text. Anything less falls straight through to
            // the screenshot+OCR path unchanged.
            let axStart = now()
            if let result = axWindowText(targetWindow, display) {
                let snapshot = ScreenSnapshot(
                    capturedAt: moment,
                    displayID: display.displayID,
                    blocks: result.blocks,
                    evidence: ScreenTextExtractionEvidence(
                        source: .accessibility,
                        completed: result.completed,
                        confidence: result.confidence,
                        observedAt: moment,
                        recognizedAt: moment,
                        target: target
                    )
                )
                guard retainsCapturedScreenText() else { return .skipped(.disabled) }
                latestSnapshot = snapshot
                latestWindowSnapshot = snapshot
                commitCaptureSlot(at: moment)
                lastWindowSceneHadConversation = ScreenScene.classify(
                    snapshot: snapshot,
                    frontmostBundleID: target.bundleIdentifier,
                    fieldText: ""
                ).mode == .replying
                diagnostics(
                    "screen-capture-completed",
                    [
                        "blocks": String(result.blocks.count),
                        "duration_ms": String(Self.milliseconds(from: axStart, to: now())),
                        "ocrMilliseconds": "0",
                        "kind": "ax",
                        "ocrScope": "skipped",
                    ]
                )
                return .captured(blockCount: result.blocks.count)
            }
            return await performWindowCapture(
                window: targetWindow,
                display: display,
                moment: moment,
                target: target,
                forceFullOCR: forceFullOCR
            )
        }
        return await performFullDisplayCapture(
            content: content,
            display: display,
            zRanks: zRanks,
            moment: moment,
            target: target,
            forceFullOCR: forceFullOCR
        )
    }

    /// Captures ONLY the frontmost app's frontmost layer-0 window
    /// (`SCContentFilter(desktopIndependentWindow:)`) — the captured image
    /// physically contains that one window's pixels, so every OCR block is
    /// stamped with that window's bundle id and frame directly, with no
    /// per-block attribution guessing (contrast `performFullDisplayCapture`,
    /// which still needs `WindowAttribution` because it can see several
    /// windows at once). Roughly halves OCR latency too: Vision has one
    /// window's worth of pixels to walk instead of the whole display.
    private func performWindowCapture(
        window: SCWindow,
        display: SCDisplay,
        moment: Date,
        target: TypingTargetIdentity,
        forceFullOCR: Bool
    ) async -> CaptureOutcome {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        // Capture at the display's native pixel scale, not point size.
        // `.fast` OCR reads 1x (half-resolution on Retina) text as noise;
        // the 2026-08-23 sweep measured its 9-15x speedup only at native
        // resolution, and the live app was silently capturing at 1x.
        let scale = Self.pixelScale(of: display)
        configuration.width = max(1, Int((window.frame.width * scale).rounded()))
        configuration.height = max(1, Int((window.frame.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let dutyCycleStart = now()
        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            // Vision's boxes are normalized against the captured WINDOW
            // image here, not the display — map each one through the
            // window's own display-normalized frame before it becomes a
            // `TextBlock`, or every downstream consumer (bubble-width gates,
            // speaker bucketing in `ScreenScene`) silently misreads
            // window-relative widths as display-relative ones.
            let windowFrame = Self.normalize(window.frame, in: display.frame)
            let ownerBundleIdentifier = window.owningApplication?.bundleIdentifier

            // "P99 at every section" (2026-08-18): the duty cycle above
            // covers screenshot+OCR together, which is what the power probe
            // budget cares about, but tells capture and OCR apart is exactly
            // what a percentile table needs to point at which half of the
            // duty cycle regressed. The OCR pass times only its own
            // `recognizeText` call using the same injectable clock as
            // `dutyCycleMilliseconds`.
            func fullWindowOCR() async throws -> ([ScreenSnapshot.TextBlock], Int) {
                let ocrStart = now()
                let recognized = try await recognizeText(image)
                let ocrMilliseconds = Self.milliseconds(from: ocrStart, to: now())
                let mapped = recognized.map { block -> ScreenSnapshot.TextBlock in
                    ScreenSnapshot.TextBlock(
                        text: block.text,
                        boundingBox: WindowAttribution.mapWindowRelativeBox(block.boundingBox, windowFrame: windowFrame),
                        windowOwnerBundleIdentifier: ownerBundleIdentifier,
                        windowIdentifier: window.windowID,
                        windowTitle: window.title,
                        windowFrame: windowFrame,
                        confidence: block.confidence
                    )
                }
                return (mapped, ocrMilliseconds)
            }

            let (blocks, ocrMilliseconds) = try await fullWindowOCR()
            let ocrScope = "full"

            let dutyCycleMilliseconds = Self.milliseconds(from: dutyCycleStart, to: now())
            let source: ScreenTextExtractionSource = .visionFull
            let reuseCount = 0
            let recognizedAt = moment
            guard activeTypingTarget == target else {
                record(.skip(.targetChanged))
                return .skipped(.targetChanged)
            }
            // An older capture may finish after a newer one for the same
            // target. It spent the work, but must not roll memory backward.
            if let current = latestSnapshot,
               current.evidence.target == target,
               current.capturedAt > moment {
                return .captured(blockCount: blocks.count)
            }
            let snapshot = ScreenSnapshot(
                capturedAt: moment,
                displayID: display.displayID,
                blocks: blocks,
                evidence: ScreenTextExtractionEvidence(
                    source: source,
                    completed: true,
                    confidence: Self.aggregateConfidence(of: blocks),
                    observedAt: moment,
                    recognizedAt: recognizedAt,
                    reuseCount: reuseCount,
                    target: target
                )
            )
            guard retainsCapturedScreenText() else { return .skipped(.disabled) }
            latestSnapshot = snapshot
            latestWindowSnapshot = snapshot
            commitCaptureSlot(at: moment)
            // Count-free probe of the thing the display read would add:
            // if this window already reads as a conversation, other
            // windows' reference snippets are never consulted.
            lastWindowSceneHadConversation = ScreenScene.classify(
                snapshot: snapshot,
                frontmostBundleID: window.owningApplication?.bundleIdentifier,
                fieldText: ""
            ).mode == .replying
            diagnostics(
                "screen-capture-completed",
                [
                    "blocks": String(blocks.count),
                    "duration_ms": String(dutyCycleMilliseconds),
                    "ocrMilliseconds": String(ocrMilliseconds),
                    "kind": "window",
                    "ocrScope": ocrScope,
                ]
            )
            return .captured(blockCount: blocks.count)
        } catch {
            let dutyCycleMilliseconds = Self.milliseconds(from: dutyCycleStart, to: now())
            diagnostics(
                "screen-capture-failed",
                ["duration_ms": String(dutyCycleMilliseconds), "kind": "window"]
            )
            return .captureFailed
        }
    }

    /// The original full-display path, unchanged in behavior: captures the
    /// active display, OCRs everything visible on it, and attributes each
    /// block to a window via `WindowAttribution`'s z-order-aware geometry
    /// match. This is what keeps "referencing" fed — it is the only path
    /// that can ever see a window other than the frontmost one.
    private func performFullDisplayCapture(
        content: SCShareableContent,
        display: SCDisplay,
        zRanks: [CGWindowID: Int],
        moment: Date,
        target: TypingTargetIdentity,
        forceFullOCR: Bool
    ) async -> CaptureOutcome {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = Self.pixelScale(of: display)
        configuration.width = Int((Double(display.width) * scale).rounded())
        configuration.height = Int((Double(display.height) * scale).rounded())
        configuration.showsCursor = false
        configuration.capturesAudio = false

        // Duty-cycle instrumentation (Phase 1b, docs/plans/screen-memory.md):
        // wall-clock time for capture+OCR only, in whole milliseconds, no
        // screen text. This is the number the power probe harness
        // (script/capture_power_probe.sh) reads back out of the diagnostics
        // log to check the <250ms OCR p95 budget — reuses the same
        // injectable `now` clock tests already control, rather than adding a
        // second time source.
        let dutyCycleStart = now()

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            // `SCShareableContent.windows` documents no ordering guarantee,
            // and `windowLayer` alone cannot recover z-order: every normal
            // app window is layer 0, so sorting by layer is a no-op there
            // and the list order decides attribution. That misattributes
            // whole regions when several windows occupy the same frame (a
            // user who stacks half-screen windows — live bug 2026-08-18:
            // the visible chat's blocks attributed to a same-position
            // window BEHIND it, so the own-window filter discarded the
            // whole conversation). `CGWindowListCopyWindowInfo` with
            // `.optionOnScreenOnly` IS documented front-to-back; rank by
            // it, keeping `windowLayer` only as the fallback for windows
            // missing from that list. `zRanks` is a parameter here (computed
            // once in `performCapture`, the same ranks used to pick the
            // frontmost window for the window-only path) rather than
            // recomputed. Building this list is pure/cheap geometry, needed
            // regardless of OCR scope.
            let frontToBackWindows = content.windows.sorted {
                Self.frontToBackPrecedes($0, $1, zRanks: zRanks)
            }
            let windows = frontToBackWindows.map { window in
                WindowAttribution.WindowInfo(
                    bundleIdentifier: window.owningApplication?.bundleIdentifier,
                    windowIdentifier: window.windowID,
                    title: window.title,
                    frame: Self.normalize(window.frame, in: display.frame)
                )
            }

            // "P99 at every section" (2026-08-18): `ocrStart` marks the
            // moment the screenshot finished, so `ocrMilliseconds` isolates
            // `recognizeText` from the screenshot half of the duty cycle —
            // same purpose and same injectable clock as `performWindowCapture`'s
            // split. Each new block is attributed to a window the same way
            // the original full-display path always did — `boundingBox`
            // here is already display-relative, unlike the window path, so
            // no window-frame remap is needed.
            func fullDisplayOCR() async throws -> ([ScreenSnapshot.TextBlock], Int) {
                let ocrStart = now()
                let recognized = try await recognizeText(image)
                let ocrMilliseconds = Self.milliseconds(from: ocrStart, to: now())
                let mapped = recognized.map { block -> ScreenSnapshot.TextBlock in
                    let owner = WindowAttribution.attribute(boundingBox: block.boundingBox, frontToBackWindows: windows)
                    return ScreenSnapshot.TextBlock(
                        text: block.text,
                        boundingBox: block.boundingBox,
                        windowOwnerBundleIdentifier: owner?.bundleIdentifier,
                        windowIdentifier: owner?.windowIdentifier,
                        windowTitle: owner?.title,
                        windowFrame: owner?.frame,
                        confidence: block.confidence
                    )
                }
                return (mapped, ocrMilliseconds)
            }

            let (blocks, ocrMilliseconds) = try await fullDisplayOCR()
            let ocrScope = "full"

            let dutyCycleMilliseconds = Self.milliseconds(from: dutyCycleStart, to: now())
            let source: ScreenTextExtractionSource = .visionFull
            let reuseCount = 0
            let recognizedAt = moment
            guard activeTypingTarget == target else {
                record(.skip(.targetChanged))
                return .skipped(.targetChanged)
            }
            if let current = latestSnapshot,
               current.evidence.target == target,
               current.capturedAt > moment {
                return .captured(blockCount: blocks.count)
            }
            let snapshot = ScreenSnapshot(
                capturedAt: moment,
                displayID: display.displayID,
                blocks: blocks,
                evidence: ScreenTextExtractionEvidence(
                    source: source,
                    completed: true,
                    confidence: Self.aggregateConfidence(of: blocks),
                    observedAt: moment,
                    recognizedAt: recognizedAt,
                    reuseCount: reuseCount,
                    target: target
                )
            )
            guard retainsCapturedScreenText() else { return .skipped(.disabled) }
            latestSnapshot = snapshot
            commitCaptureSlot(at: moment)
            lastFullDisplayCaptureAt = moment
            diagnostics(
                "screen-capture-completed",
                [
                    "blocks": String(blocks.count),
                    "duration_ms": String(dutyCycleMilliseconds),
                    "ocrMilliseconds": String(ocrMilliseconds),
                    "kind": "display",
                    "ocrScope": ocrScope,
                ]
            )
            return .captured(blockCount: blocks.count)
        } catch {
            // Failed attempts still spent wall-clock time in
            // ScreenCaptureKit/Vision (e.g. a slow timeout) and count toward
            // the duty cycle the power probe measures, so the same
            // duration_ms field is attached here too.
            let dutyCycleMilliseconds = Self.milliseconds(from: dutyCycleStart, to: now())
            diagnostics("screen-capture-failed", ["duration_ms": String(dutyCycleMilliseconds), "kind": "display"])
            return .captureFailed
        }
    }

    /// Whole milliseconds between two instants, floored at zero so a clock
    /// that does not advance (the common case in tests, which hold `now`
    /// fixed) reports `0` rather than a negative number. Internal, not
    /// private, so `ScreenCaptureServiceTests` can prove the rounding/floor
    /// behavior directly — `performCapture` itself stays untestable at unit
    /// level like the rest of ScreenCaptureKit-shaped code in this type (see
    /// the type doc comment), so this is the one piece of the duty-cycle
    /// math that CAN be proven without a live display.
    /// Backing pixels per point for the display being captured; 2 on
    /// Retina panels, 1 otherwise. Falls back to 1 when the display has no
    /// pixel dimensions (mirrored/virtual displays during setup).
    static func pixelScale(of display: SCDisplay) -> Double {
        // `CGDisplayPixelsWide` reports the LOGICAL width in scaled Retina
        // modes (it equals `display.width`), which is exactly the 1x trap
        // this helper exists to avoid. The display mode carries the true
        // backing size.
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        return pixelScale(pixelWidth: mode?.pixelWidth ?? 0, pointWidth: display.width)
    }

    static func pixelScale(pixelWidth: Int, pointWidth: Int) -> Double {
        guard pixelWidth > 0, pointWidth > 0 else { return 1 }
        return max(1, (Double(pixelWidth) / Double(pointWidth)).rounded())
    }

    static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    private static func aggregateConfidence(of blocks: [ScreenSnapshot.TextBlock]) -> Double {
        let values = blocks.compactMap(\.confidence)
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func record(_ decision: CaptureTriggerPolicy.Decision) {
        guard case let .skip(reason) = decision else { return }
        diagnostics("screen-capture-skipped", ["reason": Self.describe(reason)])
    }

    private static func describe(_ reason: CaptureTriggerPolicy.BlockReason) -> String {
        switch reason {
        case .disabled: return "disabled"
        case .screenLocked: return "screen-locked"
        case .secureInput: return "secure-input"
        case .noActiveTextField: return "no-active-text-field"
        case .noActiveCompletionSession: return "no-active-session"
        case .belowTypingPauseThreshold: return "below-threshold"
        case .excludedWindow: return "excluded-app"
        case .cadence: return "cadence"
        case .noTargetWindow: return "no-target-window"
        case .targetChanged: return "target-changed"
        }
    }

    private static func targetWindow(
        for target: TypingTargetIdentity,
        among windows: [SCWindow]
    ) -> SCWindow? {
        guard let windowIdentifier = target.windowIdentifier,
              let processIdentifier = target.processIdentifier else { return nil }
        return windows.first {
            $0.windowID == windowIdentifier
                && $0.owningApplication?.processID == processIdentifier
                && (target.bundleIdentifier == nil
                    || $0.owningApplication?.bundleIdentifier == target.bundleIdentifier)
        }
    }

    private static func display(containing window: SCWindow, in displays: [SCDisplay]) -> SCDisplay? {
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        return displays.first(where: { $0.frame.contains(center) }) ?? displays.first
    }

    /// True front-to-back ranks for on-screen windows, from
    /// `CGWindowListCopyWindowInfo` — the one window API whose ordering IS
    /// documented ("returned in order from front to back"). Keyed by
    /// `CGWindowID` for lookup against `SCWindow.windowID`.
    private static func onScreenZOrderRanks() -> [CGWindowID: Int] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }
        var ranks: [CGWindowID: Int] = [:]
        for (rank, entry) in info.enumerated() {
            if let number = entry[kCGWindowNumber as String] as? NSNumber {
                ranks[CGWindowID(truncating: number)] = rank
            }
        }
        return ranks
    }

    /// Documented z-order rank first. A window missing from the on-screen
    /// list sorts behind every ranked one — "not on screen" must never win
    /// an attribution over a visible window — with the old layer proxy only
    /// breaking ties between two unranked windows.
    private static func frontToBackPrecedes(
        _ a: SCWindow,
        _ b: SCWindow,
        zRanks: [CGWindowID: Int]
    ) -> Bool {
        switch (zRanks[a.windowID], zRanks[b.windowID]) {
        case let (rankA?, rankB?): return rankA < rankB
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return a.windowLayer < b.windowLayer
        }
    }

    /// `SCWindow.frame` is in global desktop points; `display.frame` is that
    /// same display's placement in that same global space. Normalizing by
    /// the display's own frame — not (0,0)-(screenWidth,screenHeight)) —
    /// keeps multi-monitor arrangements correct: a window's frame is
    /// expressed relative to the display it was captured from, matching the
    /// 0...1 space Vision's OCR boxes already use for that capture.
    static func normalize(_ frame: CGRect, in displayFrame: CGRect) -> NormalizedDisplayRect {
        guard displayFrame.width > 0, displayFrame.height > 0 else {
            return NormalizedDisplayRect(x: 0, y: 0, width: 0, height: 0)
        }
        return NormalizedDisplayRect(
            x: (frame.origin.x - displayFrame.origin.x) / displayFrame.width,
            y: (frame.origin.y - displayFrame.origin.y) / displayFrame.height,
            width: frame.width / displayFrame.width,
            height: frame.height / displayFrame.height
        )
    }
}

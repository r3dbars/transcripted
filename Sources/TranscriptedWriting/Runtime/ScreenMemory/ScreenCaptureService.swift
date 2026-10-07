#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Carbon.HIToolbox.Events
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Owns Screen Memory's capture pipeline end to end: the focused window's
/// Accessibility text, or a ScreenCaptureKit capture of that one window plus
/// Vision OCR. Memory-only — nothing here persists a `ScreenSnapshot`
/// anywhere; the latest one lives in `latestSnapshot` until the next capture
/// replaces it or the process exits.
///
/// Screen Memory reads ONLY the window the user is typing in (owner
/// decision 2026-09-29; setup says "Reads the window you're replying in").
/// There is no full-display capture. `FocusedWindowCapturePolicy` (Core,
/// pure) picks that window at capture time and refuses — capturing
/// nothing — when it can't prove the window is the focused window of the
/// frontmost app, in the Writing app scope, and not excluded.
///
/// Every capture attempt is also routed through `CaptureTriggerPolicy`
/// (Core, pure) with freshly observed state, so the covenant's
/// non-negotiables — the user's own master toggle, Secure Event Input,
/// screen lock, per-app exclusion (still checked against every visible
/// window, the conservative rule from full-display days), an active text
/// field, and the cadence cap — are enforced by tested logic, not
/// re-derived here.
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
    private var pendingTextFieldCaptureTask: Task<Void, Never>?
    private var activeTextFieldSessionIdentifier: String?
    private var activeTypingTarget: TypingTargetIdentity?
    private var typingTargetGeneration: UInt64 = 0
    private var textFieldRequiresFullRefresh = false

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
    /// The Writing app scope, re-checked on the chosen window at capture
    /// time. The app bridge already gates each trigger on it; this makes
    /// the actor that reads the screen refuse on its own too.
    private let appInScope: @Sendable (String) -> Bool
    private let frontmostApplicationProcessIdentifier: @Sendable () -> Int32?
    private let keyboardFocusProcessIdentifier: @Sendable () -> Int32?

    init(
        enabled: @escaping @Sendable () -> Bool,
        excludedApps: @escaping @Sendable () -> Set<String>,
        appInScope: @escaping @Sendable (String) -> Bool = {
            WritingPreferences().allows(appBundleIdentifier: $0)
        },
        frontmostApplicationProcessIdentifier: @escaping @Sendable () -> Int32? = {
            KeyboardFocusProbe.frontmostApplicationProcessIdentifier()
        },
        keyboardFocusProcessIdentifier: @escaping @Sendable () -> Int32? = {
            KeyboardFocusProbe.keyboardFocusProcessIdentifier()
        },
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
        self.appInScope = appInScope
        self.frontmostApplicationProcessIdentifier = frontmostApplicationProcessIdentifier
        self.keyboardFocusProcessIdentifier = keyboardFocusProcessIdentifier
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

    /// A real IMKit input session became active. The first refresh reads
    /// the focused window from scratch. The safety gates and cadence
    /// ceiling still apply.
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
        // Nothing is being typed into, so no window's text stays held.
        latestSnapshot = nil
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
        // Every snapshot is a read of the focused window alone, so there is
        // only one to classify.
        let scene = ScreenScene.freshScene(
            from: filtered(latestSnapshot),
            now: now,
            frontmostBundleID: frontmostBundleID,
            fieldText: fieldText
        )
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
    /// drops everything the actor is holding — the snapshot, the pending
    /// capture task, and the typing target it was attributed to — so
    /// there is nothing left to serve if the toggle comes back on.
    ///
    /// `lastContentResetAt` is moved forward rather than cleared: it is the
    /// "anything older than this is the wrong conversation" watermark, and a
    /// capture already in flight must not be able to land behind it.
    func forgetCapturedScreenState(now moment: Date = Date()) {
        pendingTextFieldCaptureTask?.cancel()
        pendingTextFieldCaptureTask = nil
        latestSnapshot = nil
        activeTypingTarget = nil
        activeTextFieldSessionIdentifier = nil
        textFieldRequiresFullRefresh = false
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
    /// The old window's text is dropped, not just hidden: Screen Memory
    /// holds only the window the user is typing in now.
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
                latestSnapshot = nil
                lastContentResetAt = now()
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
        latestSnapshot = nil
        lastContentResetAt = now()
        textFieldRequiresFullRefresh = true
    }

    @discardableResult
    private func attemptTextFieldCapture(
        trigger: CaptureTriggerPolicy.Trigger
    ) async -> CaptureOutcome {
        let outcome = await attemptCapture(
            trigger: trigger,
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

    /// Reads the focused window and nothing else. `FocusedWindowCapturePolicy`
    /// must name the target window first — the focused window of the
    /// frontmost app, in scope and not excluded — or nothing is captured.
    /// Then Accessibility text for that window, or a capture of that one
    /// window plus OCR. There is no full-display fallback.
    private func performCapture(
        content: SCShareableContent,
        moment: Date,
        target: TypingTargetIdentity,
        forceFullOCR: Bool
    ) async -> CaptureOutcome {
        let zRanks = Self.onScreenZOrderRanks()
        let candidates = content.windows.compactMap { window -> FocusedWindowCapturePolicy.Window? in
            guard let owner = window.owningApplication else { return nil }
            return FocusedWindowCapturePolicy.Window(
                windowIdentifier: window.windowID,
                processIdentifier: owner.processID,
                bundleIdentifier: owner.bundleIdentifier,
                layer: window.windowLayer,
                zOrderRank: zRanks[window.windowID]
            )
        }
        let choice = FocusedWindowCapturePolicy.choose(
            target: target,
            windows: candidates,
            focus: FocusedWindowCapturePolicy.FocusEvidence(
                frontmostApplicationProcessIdentifier: frontmostApplicationProcessIdentifier(),
                keyboardFocusProcessIdentifier: keyboardFocusProcessIdentifier()
            ),
            excludedApps: excludedApps(),
            appInScope: appInScope,
            ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        guard case let .capture(windowIdentifier) = choice,
              let targetWindow = content.windows.first(where: { $0.windowID == windowIdentifier }) else {
            let refusal: FocusedWindowCapturePolicy.Refusal
            if case let .refuse(reason) = choice { refusal = reason } else { refusal = .windowNotVisible }
            diagnostics("screen-capture-skipped", ["reason": Self.skipReason(for: refusal)])
            return .skipped(Self.blockReason(for: refusal))
        }
        guard let display = Self.display(containing: targetWindow, in: content.displays) else {
            diagnostics("screen-capture-skipped", ["reason": "no-display"])
            return .captureFailed
        }

        // Accessibility-first: the exact strings the app draws, in ~1ms,
        // when the user granted the permission and the app's tree carries
        // real text. Anything less falls through to capturing and OCRing
        // the same window.
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
            commitCaptureSlot(at: moment)
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

    /// Captures ONLY the window `FocusedWindowCapturePolicy` chose
    /// (`SCContentFilter(desktopIndependentWindow:)`) — the captured image
    /// holds that one window's own pixels, never whatever overlaps it, so
    /// every OCR block is stamped with that window's bundle id and frame
    /// directly. Vision also has one window's worth of pixels to walk
    /// instead of the whole display.
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
            commitCaptureSlot(at: moment)
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

    private func record(_ decision: CaptureTriggerPolicy.Decision) {
        guard case let .skip(reason) = decision else { return }
        diagnostics("screen-capture-skipped", ["reason": Self.describe(reason)])
    }
}

import Foundation

/// Decides whether a Screen Memory capture may fire. Pure and deterministic —
/// no ScreenCaptureKit, no Vision, no I/O — so the covenant's non-negotiables
/// (secure-input and lock-screen exclusion, active-field requirement,
/// per-app exclusion against EVERY visible window, cadence cap) are testable
/// without ever touching a real display. The app supplies the observed state; this type
/// only says yes or no and why.
public enum CaptureTriggerPolicy {
    /// What asked for a capture. Every trigger requires an active text
    /// field. `windowChanged` is independent of a completion session;
    /// `typingPause` only counts once the user has been
    /// still for the threshold AND a completion session is active — a stray
    /// pause with no writing underway is not a trigger.
    public enum Trigger: Equatable, Sendable {
        case windowChanged
        case textFieldFocused
        case typingPause(elapsedSeconds: TimeInterval)
    }

    public enum Decision: Equatable, Sendable {
        case capture
        case skip(BlockReason)
    }

    public enum BlockReason: Equatable, Sendable {
        case disabled
        case screenLocked
        case secureInput
        case noActiveTextField
        case noActiveCompletionSession
        case belowTypingPauseThreshold
        case excludedWindow(appBundleIdentifier: String)
        case cadence(secondsRemaining: TimeInterval)
        case noTargetWindow
        case targetChanged
    }

    /// Typing must be still this long, with a session active, before a pause
    /// counts as a trigger.
    public static let typingPauseThresholdSeconds: TimeInterval = 0.25
    /// Hard ceiling regardless of how many triggers fire: never more than one
    /// capture per this many seconds. Owner directive 2026-08-18: fresher
    /// conversation context is worth the extra duty cycles — was 5.0; the
    /// power probe (script/capture_power_probe.sh) still bounds per-capture
    /// cost, so the ceiling change scales total cost by at most 2.5x while
    /// typing, and captures still only fire on real triggers.
    public static let cadenceCapSeconds: TimeInterval = 2.0
    /// Focus and window changes signal that the content probably changed —
    /// the previous snapshot is the wrong conversation, and waiting out the
    /// full cadence serves stale context (live 2026-08-23: switching
    /// threads inside one window kept the old thread's scene for up to 2s).
    /// These triggers get a tighter floor instead of a bypass so a focus
    /// storm still cannot exceed ~2 captures per second.
    public static let contentChangeCadenceFloorSeconds: TimeInterval = 0.5
    /// A completion session is "active" if the IME's last observed activity
    /// (a completion request reaching the socket) was within this long ago.
    /// Chosen to comfortably span the typing-pause threshold itself: a
    /// pause trigger fires at 250ms, so activity from just before that pause
    /// must still read as an active session.
    public static let sessionActivityWindowSeconds: TimeInterval = 10.0

    /// Pure decision: given a trigger and every piece of observed state, say
    /// whether to capture and, if not, exactly why — every reason is
    /// distinguishable so callers (and tests) never have to guess which gate
    /// closed the door.
    ///
    /// - Parameters:
    ///   - visibleWindowOwnerBundleIdentifiers: Bundle identifiers of every
    ///     currently visible window's owning app — not just the frontmost
    ///     one. Capture is full-display, so a Signal window sitting behind
    ///     the focused editor still excludes the capture if Signal is on the
    ///     exclusion list.
    public static func decision(
        for trigger: Trigger,
        enabled: Bool,
        screenLocked: Bool,
        secureInputActive: Bool,
        textFieldActive: Bool,
        completionSessionActive: Bool,
        visibleWindowOwnerBundleIdentifiers: [String],
        excludedApps: Set<String>,
        lastCaptureAt: Date?,
        now: Date
    ) -> Decision {
        guard enabled else { return .skip(.disabled) }
        guard !screenLocked else { return .skip(.screenLocked) }
        guard !secureInputActive else { return .skip(.secureInput) }
        guard textFieldActive else { return .skip(.noActiveTextField) }

        if case let .typingPause(elapsedSeconds) = trigger {
            guard completionSessionActive else { return .skip(.noActiveCompletionSession) }
            guard elapsedSeconds >= typingPauseThresholdSeconds else {
                return .skip(.belowTypingPauseThreshold)
            }
        }

        // Union with the always-excluded set (password managers, Keychain
        // Access) on every call — never trust a caller to have already
        // merged it. A fresh install with an empty settings store, or a
        // caller that forgets the union, must still exclude these apps.
        let effectiveExcludedApps = DefaultExcludedApps.union(with: excludedApps)
        if let excludedOwner = visibleWindowOwnerBundleIdentifiers.first(where: effectiveExcludedApps.contains) {
            return .skip(.excludedWindow(appBundleIdentifier: excludedOwner))
        }

        return cadenceDecision(for: trigger, lastCaptureAt: lastCaptureAt, now: now)
    }

    /// The one cadence calculation used by both the pure policy and the
    /// actor's atomic reservation. Keeping trigger-specific floors here
    /// prevents orchestration from silently replacing the 0.5s focus/window
    /// path with the ordinary 2s typing ceiling.
    public static func cadenceDecision(
        for trigger: Trigger,
        lastCaptureAt: Date?,
        now: Date
    ) -> Decision {
        guard let lastCaptureAt else { return .capture }
        let floor: TimeInterval
        switch trigger {
        case .windowChanged, .textFieldFocused: floor = contentChangeCadenceFloorSeconds
        case .typingPause: floor = cadenceCapSeconds
        }
        let sinceLastCapture = now.timeIntervalSince(lastCaptureAt)
        guard sinceLastCapture < floor else { return .capture }
        return .skip(.cadence(secondsRemaining: floor - sinceLastCapture))
    }

    /// Whether the last observed IME activity is recent enough to call a
    /// completion session "active" — the input the app feeds into
    /// `decision(for:...completionSessionActive:...)` above.
    public static func isCompletionSessionActive(lastActivityAt: Date?, now: Date) -> Bool {
        guard let lastActivityAt else { return false }
        let elapsed = now.timeIntervalSince(lastActivityAt)
        return elapsed >= 0 && elapsed <= sessionActivityWindowSeconds
    }
}

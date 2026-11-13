// PhysicalShortcutDetector.swift
// The CGEvent tap that turns physical keys into dictation and meeting
// shortcuts. Chord matching lives in PhysicalShortcutMatcher; Fn/media-key
// diagnostics live in PhysicalShortcutTapPolicy. Keep tap callbacks small
// and hop logging onto the main actor through `onLog`.

import AppKit
@preconcurrency import CoreFoundation
import CoreGraphics

// PhysicalShortcutAction and PhysicalShortcutBinding live in
// PhysicalShortcutMatcher.swift so the pure chord-resolution precedence can be
// fast-tested independently of this CGEventTap engine.

enum PhysicalShortcutPhase {
    case press
    case release
    /// A Push to Talk release after a quick press with no other key in
    /// between (`DictationHoldKeyTapPolicy`).
    case tapRelease
    /// A Push to Talk release after another key or modifier went down while
    /// it was held (Fn+arrow). Stops like `.release`; named apart for
    /// diagnostics only.
    case chordRelease
    /// Another key went down while a hands-free modifier that fired on press
    /// was held, or inside a shared Push to Talk modifier's chord window.
    case comboInterrupted
}

final class PhysicalShortcutDetector: @unchecked Sendable { // tap thread + main; state behind stateLock
    /// Shared with `ContextCaptureEngine.updateAccessibilityRetryMonitor()`,
    /// which matches on this exact message to decide whether to poll for
    /// Accessibility permission. Keep both call sites on this constant so a
    /// wording change here can't silently break that retry.
    static let accessibilityPermissionErrorMessage = PhysicalShortcutTriggerStatus.accessibilityPermissionErrorMessage

    /// Cached binding snapshot, rebuilt by ContextCaptureEngine on
    /// .hotkeysDidChange. The event tap runs on a dedicated run loop so
    /// Transcripted main-thread work cannot delay global keyboard delivery.
    private var shortcutBindings: [PhysicalShortcutBinding] = []
    var onShortcut: ((PhysicalShortcutAction, PhysicalShortcutPhase) -> Void)?
    /// Event name, message, context. The engine hops this onto the main
    /// actor before `EventReporter` — the tap thread never logs directly.
    var onLog: ((String, String, [String: String]) -> Void)?

    private let stateLock = NSRecursiveLock()
    private struct InstalledTap {
        let port: CFMachPort
        let context: TapCallbackContext
    }
    /// The port and its unretained callback pointer always retire together.
    private var installedTap: InstalledTap?
    private var tapRecovery: PhysicalShortcutTapRecovery? { installedTap?.context.recovery }
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapRunLoopStop: PhysicalShortcutTapRunLoopStop?
    private var tapThread: Thread?
    private var diagnosticRateLimiter = PhysicalShortcutDiagnosticRateLimiter()
    private var activePushToTalkKeyCode: UInt32? {
        didSet {
            guard activePushToTalkKeyCode != nil, activePushToTalkKeyCode != oldValue else { return }
            pushToTalkTap.pressed(at: ProcessInfo.processInfo.systemUptime)
        }
    }
    private var pushToTalkTap = PushToTalkTapTracker()
    private var consumedKeyCodes: Set<UInt32> = []
    private var pendingModifierShortcut: PendingModifierShortcut?
    private var pendingModifierGeneration: UInt64 = 0
    /// A hands-free modifier that other shortcuts share (Right Option vs
    /// Option+M) and that fired on press, followed until it's released so a
    /// key that goes down meanwhile reports `.comboInterrupted`.
    private var handsFreeComboTracker = HandsFreeModifierComboTracker()
    /// The same for a Push to Talk modifier that fired on press, but only a
    /// key inside the chord window makes it a combo.
    private var pushToTalkComboWindow = PushToTalkModifierComboWindow()
    /// When a key was last typed, so a hands-free modifier pressed mid-typing
    /// still waits for release (see `firesSharedModifierOnPress`).
    private var lastTypedKeyDownUptime: TimeInterval = -.infinity
    /// Mirrors `DictationSessionController.isDictating`, pushed from the main
    /// actor, so a hands-free press that would stop a dictation waits for
    /// release.
    private var isDictating = false

    private struct PendingModifierShortcut {
        let press: DelayedModifierShortcutPress
        let workItem: DispatchWorkItem?
    }

    /// Hill-climb knob `dictation.hotkey.chord_delay_s`.
    static let modifierChordDelay: TimeInterval = 0.14

    /// The run-loop thread retains this context until its last callback has
    /// returned. An old port can never handle events as a replacement tap.
    private final class TapCallbackContext: @unchecked Sendable {
        weak var detector: PhysicalShortcutDetector?
        let recovery: PhysicalShortcutTapRecovery

        init(detector: PhysicalShortcutDetector, recovery: PhysicalShortcutTapRecovery) {
            self.detector = detector
            self.recovery = recovery
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let context = Unmanaged<TapCallbackContext>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        guard let detector = context.detector else { return Unmanaged.passUnretained(event) }
        return detector.handle(type: type, event: event, recovery: context.recovery)
    }

    func updateDictationActive(_ isDictating: Bool) {
        stateLock.lock()
        self.isDictating = isDictating
        stateLock.unlock()
    }

    func updateShortcutBindings(_ bindings: [PhysicalShortcutBinding]) {
        stateLock.lock()
        shortcutBindings = bindings
        stateLock.unlock()
    }

    func install() -> String? {
        remove()

        let eventMask = PhysicalShortcutTapPolicy.eventsOfInterestMask()

        let recovery = PhysicalShortcutTapRecovery()
        let callbackContext = TapCallbackContext(detector: self, recovery: recovery)
        let userInfo = Unmanaged.passUnretained(callbackContext).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.callback,
            userInfo: userInfo
        ) else {
            resetState()
            return PhysicalShortcutTriggerStatus.tapCreateFailureMessage(
                accessibilityGranted: TranscriptedPermissionAccess.isGranted(.accessibility)
            )
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            Self.retire(tap: tap, context: callbackContext)
            resetState()
            return PhysicalShortcutTriggerStatus.failedToStartMessage
        }

        stateLock.lock()
        installedTap = InstalledTap(port: tap, context: callbackContext)
        runLoopSource = source
        stateLock.unlock()
        startTapThread(tap: tap, source: source, callbackContext: callbackContext)
        return nil
    }

    func remove() {
        stateLock.lock()
        let source = runLoopSource
        let installation = installedTap
        let tapRunLoop = tapRunLoop
        let tapRunLoopStop = tapRunLoopStop
        tapRecovery?.invalidate()
        installedTap = nil
        runLoopSource = nil
        self.tapRunLoop = nil
        self.tapRunLoopStop = nil
        self.tapThread = nil
        stateLock.unlock()

        if let source, let tapRunLoop {
            CFRunLoopRemoveSource(tapRunLoop, source, .commonModes)
        }
        tapRunLoopStop?.request()
        if let installation {
            Self.retire(tap: installation.port, context: installation.context)
        }

        // A key held across a reinstall (wake recovery) keeps its hold, so the
        // new tap's key-up still ends the take; one let go gets its release.
        stateLock.lock()
        reconcileActivePushToTalkAfterTapDisabled()
        stateLock.unlock()
    }

    private func startTapThread(tap: CFMachPort, source: CFRunLoopSource, callbackContext: TapCallbackContext) {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            autoreleasepool {
                guard let self else {
                    PhysicalShortcutDetector.retire(tap: tap, context: callbackContext)
                    ready.signal()
                    return
                }

                let runLoop = CFRunLoopGetCurrent()
                let stop = PhysicalShortcutTapRunLoopStop(enqueue: { action in
                    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, action)
                    CFRunLoopWakeUp(runLoop)
                }, stop: {
                    CFRunLoopStop(runLoop)
                })
                self.stateLock.lock()
                let isCurrent = self.tapRecovery === callbackContext.recovery
                if isCurrent {
                    self.tapRunLoop = runLoop
                    self.tapRunLoopStop = stop
                }
                self.stateLock.unlock()
                guard isCurrent else {
                    PhysicalShortcutDetector.retire(tap: tap, context: callbackContext)
                    ready.signal()
                    return
                }

                CFRunLoopAddSource(runLoop, source, .commonModes)
                callbackContext.recovery.requestStartup {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                ready.signal()
                // Stop queued before Run executes within its first activation.
                // Both values outlive the loop's last callback; native cleanup
                // independently retains the context until port invalidation.
                withExtendedLifetime((callbackContext, stop)) { CFRunLoopRun() }
            }
        }
        thread.name = "TranscriptedPhysicalShortcutTap"
        thread.qualityOfService = .userInteractive

        stateLock.lock()
        let isCurrent = tapRecovery === callbackContext.recovery
        if isCurrent { tapThread = thread }
        stateLock.unlock()
        guard isCurrent else {
            Self.retire(tap: tap, context: callbackContext)
            return
        }

        thread.start()
        ready.wait()
    }

    private static func retire(tap: CFMachPort, context: TapCallbackContext) {
        context.recovery.invalidate(teardown: {
            withExtendedLifetime(context) {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
        })
    }

    private func resetState() {
        pendingModifierShortcut?.workItem?.cancel()
        pendingModifierShortcut = nil
        handsFreeComboTracker.reset()
        pushToTalkComboWindow.reset()
        activePushToTalkKeyCode = nil
        consumedKeyCodes.removeAll()
    }

    private func handle(type: CGEventType, event: CGEvent, recovery: PhysicalShortcutTapRecovery) -> Unmanaged<CGEvent>? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard tapRecovery === recovery else { return Unmanaged.passUnretained(event) }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reconcileActivePushToTalkAfterTapDisabled()
            if let tap = installedTap?.port,
               let reason = PhysicalShortcutTapPolicy.tapDisabledReason(for: type) {
                // APPLE-MACOS-6H: WindowServer can stall this call. Doing it
                // in the callback under stateLock also stranded wake's
                // remove() on main. Each install owns its recovery lifetime;
                // queued work for a removed tap cannot re-enable a new one.
                recovery.request(enable: {
                    CGEvent.tapEnable(tap: tap, enable: true)
                    return CGEvent.tapIsEnabled(tap: tap)
                }, completed: { [weak self] reenabled in
                    self?.reportTapRecovery(recovery, reason: reason, reenabled: reenabled)
                })
            }
            return Unmanaged.passUnretained(event)
        }

        if PhysicalShortcutTapPolicy.mustPassThrough(eventTypeRawValue: type.rawValue) {
            handleSystemDefined(event)
            return Unmanaged.passUnretained(event)
        }

        let shortcutBindings = self.shortcutBindings
        guard !shortcutBindings.isEmpty else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = PhysicalDictationTriggerPreferences.modifiers(from: event.flags)

        switch type {
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // A key while a press-fired hands-free modifier is still held
            // makes that press a combo (Option+M, or typing é with Option+E).
            // No physical key-state check here: this tap consumed the
            // modifier's flagsChanged, so the session state never saw it
            // go down (see HandsFreeModifierComboTracker).
            if handsFreeComboTracker.keyDown() {
                onShortcut?(.dictationHandsFree, .comboInterrupted)
            }
            if pushToTalkComboWindow.keyDown(at: ProcessInfo.processInfo.systemUptime) {
                // Option+M or Right Option+E: not a hold. Its release passes
                // through, as when the chord delay was still pending.
                activePushToTalkKeyCode = nil
                onShortcut?(.dictationPushToTalk, .comboInterrupted)
            }
            if let activePushToTalkKeyCode, activePushToTalkKeyCode != keyCode {
                pushToTalkTap.otherKeyWentDown()
            }
            lastTypedKeyDownUptime = ProcessInfo.processInfo.systemUptime
            if !isRepeat {
                // Any real keyDown drops a pending chord (Option then M).
                cancelPendingModifierShortcut()
            }
            let matched = isRepeat
                ? nil
                : PhysicalShortcutMatcher.matchingKeyDownShortcut(
                    shortcutBindings, keyCode: keyCode, modifiers: modifiers
                )
            var sequenceState = PhysicalShortcutKeySequencePolicy.State(
                consumedKeyCodes: consumedKeyCodes,
                activePushToTalkKeyCode: activePushToTalkKeyCode
            )
            let decision = PhysicalShortcutKeySequencePolicy.keyDown(
                keyCode: keyCode,
                isRepeat: isRepeat,
                matched: matched,
                state: &sequenceState
            )
            consumedKeyCodes = sequenceState.consumedKeyCodes
            activePushToTalkKeyCode = sequenceState.activePushToTalkKeyCode
            switch decision {
            case .firePress(let action):
                cancelPendingModifierShortcut()
                onShortcut?(action, .press)
                return nil
            case .swallow:
                return nil
            case .passThrough:
                return Unmanaged.passUnretained(event)
            case .passThroughAndLogMismatch:
                cancelPendingModifierShortcut()
                logModifierMismatchIfNeeded(keyCode: keyCode, modifiers: modifiers, bindings: shortcutBindings)
                return Unmanaged.passUnretained(event)
            case .firePushToTalkRelease:
                return Unmanaged.passUnretained(event)
            }

        case .keyUp:
            var sequenceState = PhysicalShortcutKeySequencePolicy.State(
                consumedKeyCodes: consumedKeyCodes,
                activePushToTalkKeyCode: activePushToTalkKeyCode
            )
            let decision = PhysicalShortcutKeySequencePolicy.keyUp(keyCode: keyCode, state: &sequenceState)
            consumedKeyCodes = sequenceState.consumedKeyCodes
            activePushToTalkKeyCode = sequenceState.activePushToTalkKeyCode
            switch decision {
            case .firePushToTalkRelease:
                onShortcut?(.dictationPushToTalk, pushToTalkReleasePhase())
                return nil
            case .swallow:
                return nil
            case .passThrough, .passThroughAndLogMismatch, .firePress:
                return Unmanaged.passUnretained(event)
            }

        case .flagsChanged:
            if let activePushToTalkKeyCode, activePushToTalkKeyCode != keyCode {
                pushToTalkTap.otherKeyWentDown()
            }
            pushToTalkComboWindow.flagsChanged(
                keyCode: keyCode,
                modifiers: modifiers,
                isPushToTalkRelease: PhysicalShortcutMatcher.matchesRelease(
                    for: .dictationPushToTalk, in: shortcutBindings, keyCode: keyCode, modifiers: modifiers
                )
            )
            if handsFreeComboTracker.flagsChanged(
                keyCode: keyCode,
                modifiers: modifiers,
                isHandsFreeRelease: PhysicalShortcutMatcher.matchesRelease(
                    for: .dictationHandsFree, in: shortcutBindings, keyCode: keyCode, modifiers: modifiers
                )
            ) {
                return nil
            }

            if pendingModifierShortcut?.press.keyCode == keyCode,
               let pending = pendingModifierShortcut,
               PhysicalShortcutMatcher.matchesRelease(
                for: pending.press.action, in: shortcutBindings, keyCode: keyCode, modifiers: modifiers
               ) {
                cancelPendingModifierShortcut()
                if pending.press.action == .dictationPushToTalk {
                    // Let go inside the chord delay with no other key: a tap.
                    onShortcut?(.dictationPushToTalk, .press)
                    onShortcut?(.dictationPushToTalk, .tapRelease)
                } else {
                    onShortcut?(pending.press.action, .press)
                }
                return nil
            }

            if activePushToTalkKeyCode == keyCode,
               PhysicalShortcutMatcher.matchesRelease(
                for: .dictationPushToTalk, in: shortcutBindings, keyCode: keyCode, modifiers: modifiers
               ) {
                activePushToTalkKeyCode = nil
                onShortcut?(.dictationPushToTalk, pushToTalkReleasePhase())
                return nil
            }

            guard let shortcut = PhysicalShortcutMatcher.matchingFlagsChangedPressShortcut(
                shortcutBindings, keyCode: keyCode, modifiers: modifiers
            ) else {
                return Unmanaged.passUnretained(event)
            }

            switch shortcut.action {
            case .dictationPushToTalk:
                guard activePushToTalkKeyCode == nil else { return nil }
                let sharesModifier = PhysicalShortcutMatcher.hasChordUsingModifier(
                    keyCode, in: shortcutBindings, excluding: shortcut.action
                )
                if sharesModifier, PhysicalShortcutMatcher.firesSharedModifierOnPress(
                    secondsSinceLastTypedKey: ProcessInfo.processInfo.systemUptime - lastTypedKeyDownUptime,
                    isDictating: isDictating
                ) {
                    // Start on press: waiting out the chord delay added 0.14 s
                    // to every hold of the default Right Option key. A combo
                    // key inside that window drops the start. Mid-typing, or
                    // when this press would stop a take, it still waits.
                    cancelPendingModifierShortcut()
                    activePushToTalkKeyCode = keyCode
                    pushToTalkComboWindow.firedOnPress(
                        keyCode: keyCode,
                        at: ProcessInfo.processInfo.systemUptime,
                        window: Self.modifierChordDelay
                    )
                    onShortcut?(.dictationPushToTalk, .press)
                } else if sharesModifier {
                    schedulePendingModifierShortcut(keyCode: keyCode, action: .dictationPushToTalk)
                } else {
                    activePushToTalkKeyCode = keyCode
                    onShortcut?(.dictationPushToTalk, .press)
                }
            case .dictationHandsFree:
                // A modifier other shortcuts share used to wait for release,
                // which added the whole hold to every start. It now fires on
                // press unless a key was just typed.
                let sharesModifier = PhysicalShortcutMatcher.hasChordUsingModifier(
                    keyCode, in: shortcutBindings, excluding: shortcut.action
                )
                if sharesModifier, !PhysicalShortcutMatcher.firesSharedModifierOnPress(
                    secondsSinceLastTypedKey: ProcessInfo.processInfo.systemUptime - lastTypedKeyDownUptime,
                    isDictating: isDictating
                ) {
                    schedulePendingModifierShortcut(keyCode: keyCode, action: .dictationHandsFree)
                } else {
                    cancelPendingModifierShortcut()
                    // A press that starts a take is always followed, not just
                    // a shared modifier: with Tap to toggle on Fn, Fn+arrow
                    // must not leave a take running. A press that stops one
                    // isn't (see handlePhysicalDictationHandsFreeComboInterrupted).
                    handsFreeComboTracker.firedOnPress(keyCode: keyCode, sharesModifier: sharesModifier || !isDictating)
                    onShortcut?(.dictationHandsFree, .press)
                }
            case .meeting:
                if PhysicalShortcutMatcher.hasChordUsingModifier(
                    keyCode, in: shortcutBindings, excluding: shortcut.action
                ) {
                    schedulePendingModifierShortcut(keyCode: keyCode, action: .meeting)
                } else {
                    cancelPendingModifierShortcut()
                    onShortcut?(.meeting, .press)
                }
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleSystemDefined(_ event: CGEvent) {
        let dictation = shortcutBindings.first { $0.action != .meeting }
        guard PhysicalShortcutMediaKeyPolicy.shouldInspectSystemDefined(
            dictationBinding: dictation?.binding
        ) else {
            return
        }
        guard let nsEvent = NSEvent(cgEvent: event),
              let parsed = PhysicalShortcutMediaKeyPolicy.parseAuxControl(
                subtype: Int(nsEvent.subtype.rawValue),
                data1: nsEvent.data1
              ) else {
            return
        }
        guard PhysicalShortcutMediaKeyPolicy.dictationFunctionKeyArrivedAsMediaKey(
            nxKeyType: parsed.nxKeyType,
            dictationBinding: dictation?.binding
        ) else {
            return
        }
        emitLog(
            event: PhysicalShortcutDiagnosticEvent.mediaKey,
            message: "Configured dictation F-key arrived as a media key",
            context: PhysicalShortcutMediaKeyPolicy.mediaKeyContext(nxKeyType: parsed.nxKeyType),
            rateLimited: true
        )
    }

    private func reportTapRecovery(_ recovery: PhysicalShortcutTapRecovery, reason: String, reenabled: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard tapRecovery === recovery else { return }
        emitLog(
            event: PhysicalShortcutDiagnosticEvent.tapDisabled,
            message: "Physical shortcut tap was disabled",
            context: PhysicalShortcutTapPolicy.tapDisabledContext(reason: reason, reenabled: reenabled),
            rateLimited: false
        )
    }

    private func logModifierMismatchIfNeeded(
        keyCode: UInt32,
        modifiers: UInt32,
        bindings: [PhysicalShortcutBinding]
    ) {
        guard let saved = bindings.first(where: {
            PhysicalShortcutModifierMismatchPolicy.shouldLog(
                action: $0.action,
                saved: $0.binding,
                keyCode: keyCode,
                modifiers: modifiers
            )
        }) else {
            return
        }
        emitLog(
            event: PhysicalShortcutDiagnosticEvent.modifierMismatch,
            message: "Saved shortcut key pressed with different modifiers",
            context: PhysicalShortcutModifierMismatchPolicy.context(keyCode: saved.binding.keyCode),
            rateLimited: true
        )
    }

    private func emitLog(
        event: String,
        message: String,
        context: [String: String],
        rateLimited: Bool
    ) {
        if rateLimited {
            let now = ProcessInfo.processInfo.systemUptime
            guard diagnosticRateLimiter.shouldEmit(event, now: now) else { return }
        }
        onLog?(event, message, context)
    }

    private func schedulePendingModifierShortcut(keyCode: UInt32, action: PhysicalShortcutAction) {
        cancelPendingModifierShortcut()
        pendingModifierGeneration &+= 1
        let press = DelayedModifierShortcutPress(
            generation: pendingModifierGeneration,
            keyCode: keyCode,
            action: action
        )

        let workItem: DispatchWorkItem?
        if action == .dictationPushToTalk {
            // Read on this thread now: the work item runs on main, which can
            // be late, and a late stamp would make a hold look like a tap.
            let pressUptime = ProcessInfo.processInfo.systemUptime
            let delayedWorkItem = DispatchWorkItem { [weak self] in
                guard let self else { return }

                self.stateLock.lock()
                defer { self.stateLock.unlock() }
                let currentPress = self.pendingModifierShortcut?.press
                // Still pending means still held with no other key: a release
                // or a keyDown cancels it. Not the session key state: this
                // tap consumed the modifier's flagsChanged, so that state
                // never saw it go down, and a shared modifier (Right Option
                // vs Option+M) never started dictation.
                let shouldActivate = PhysicalShortcutMatcher.shouldActivateDelayedModifierPress(
                    current: currentPress,
                    expected: press
                )
                if currentPress == press {
                    self.pendingModifierShortcut = nil
                }
                guard shouldActivate else { return }
                self.activePushToTalkKeyCode = keyCode
                self.pushToTalkTap.pressed(at: pressUptime)
                // Keep press delivery inside the same lock-protected transition as
                // ownership. Otherwise a release can enqueue before this press.
                self.onShortcut?(action, .press)
            }
            workItem = delayedWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.modifierChordDelay, execute: delayedWorkItem)
        } else {
            workItem = nil
        }

        pendingModifierShortcut = PendingModifierShortcut(
            press: press,
            workItem: workItem
        )
    }

    private func cancelPendingModifierShortcut() {
        pendingModifierShortcut?.workItem?.cancel()
        pendingModifierShortcut = nil
    }

    private func pushToTalkReleasePhase() -> PhysicalShortcutPhase {
        switch pushToTalkTap.release(at: ProcessInfo.processInfo.systemUptime) {
        case .tap: return .tapRelease
        case .hold: return .release
        case .chord: return .chordRelease
        }
    }

    private func reconcileActivePushToTalkAfterTapDisabled() {
        cancelPendingModifierShortcut()
        // Its release may have been missed while the tap was off.
        handsFreeComboTracker.reset()
        pushToTalkComboWindow.reset()

        let reconciled = PhysicalShortcutMatcher.reconcileAfterTapDisabled(
            activePushToTalkKeyCode: activePushToTalkKeyCode,
            consumedKeyCodes: consumedKeyCodes,
            isPhysicallyDown: Self.isPhysicalKeyDown
        )
        activePushToTalkKeyCode = reconciled.activePushToTalkKeyCode
        consumedKeyCodes = reconciled.consumedKeyCodes
        if reconciled.synthesizesPushToTalkRelease {
            onShortcut?(.dictationPushToTalk, .release)
        }
    }

    /// Hardware key state, read when the tap may have missed events. Not the
    /// session state: this tap consumes the bound key's events, so that state
    /// never sees it go down and a held take would end early.
    private static func isPhysicalKeyDown(_ keyCode: UInt32) -> Bool {
        PhysicalShortcutMatcher.isPhysicalKeyDown(
            keyCode,
            modifierFlags: PhysicalDictationTriggerPreferences.modifiers(
                from: CGEventSource.flagsState(.hidSystemState)
            ),
            keyState: hardwareKeyState
        )
    }

    private static func hardwareKeyState(_ keyCode: UInt32) -> Bool {
        CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode))
    }
}

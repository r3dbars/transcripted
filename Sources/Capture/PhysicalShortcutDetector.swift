// PhysicalShortcutDetector.swift
// The CGEventTap engine behind ContextCaptureEngine's physical shortcuts.
// Moved out of ContextCaptureEngine.swift.

import AppKit
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
    /// Another key went down while a hands-free modifier that fired on press
    /// was held, or inside a shared Push to Talk modifier's chord window.
    case comboInterrupted
}

final class PhysicalShortcutDetector {
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

    private let stateLock = NSRecursiveLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
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

    private static let modifierChordDelay: TimeInterval = 0.14

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let detector = Unmanaged<PhysicalShortcutDetector>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return detector.handle(type: type, event: event)
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

        let eventMask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
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
            CFMachPortInvalidate(tap)
            resetState()
            return PhysicalShortcutTriggerStatus.failedToStartMessage
        }

        eventTap = tap
        runLoopSource = source
        startTapThread(tap: tap, source: source)
        return nil
    }

    func remove() {
        stateLock.lock()
        let source = runLoopSource
        let eventTap = eventTap
        let tapRunLoop = tapRunLoop
        runLoopSource = nil
        self.eventTap = nil
        self.tapRunLoop = nil
        self.tapThread = nil
        stateLock.unlock()

        if let source {
            CFRunLoopRemoveSource(tapRunLoop ?? CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let tapRunLoop {
            CFRunLoopStop(tapRunLoop)
        }

        stateLock.lock()
        resetState()
        stateLock.unlock()
    }

    private func startTapThread(tap: CFMachPort, source: CFRunLoopSource) {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            autoreleasepool {
                guard let self else {
                    ready.signal()
                    return
                }

                let runLoop = CFRunLoopGetCurrent()
                self.stateLock.lock()
                self.tapRunLoop = runLoop
                self.stateLock.unlock()

                CFRunLoopAddSource(runLoop, source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                ready.signal()
                CFRunLoopRun()
            }
        }
        thread.name = "TranscriptedPhysicalShortcutTap"
        thread.qualityOfService = .userInteractive

        stateLock.lock()
        tapThread = thread
        stateLock.unlock()

        thread.start()
        ready.wait()
    }

    private func resetState() {
        pendingModifierShortcut?.workItem?.cancel()
        pendingModifierShortcut = nil
        handsFreeComboTracker.reset()
        pushToTalkComboWindow.reset()
        activePushToTalkKeyCode = nil
        consumedKeyCodes.removeAll()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        stateLock.lock()
        defer { stateLock.unlock() }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reconcileActivePushToTalkAfterTapDisabled()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
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
            if isRepeat, consumedKeyCodes.contains(keyCode) {
                return nil
            }

            guard !isRepeat else {
                return Unmanaged.passUnretained(event)
            }

            guard let shortcut = matchingKeyDownShortcut(shortcutBindings, keyCode: keyCode, modifiers: modifiers) else {
                cancelPendingModifierShortcut()
                return Unmanaged.passUnretained(event)
            }

            cancelPendingModifierShortcut()
            consumedKeyCodes.insert(keyCode)

            switch shortcut.action {
            case .dictationPushToTalk:
                guard activePushToTalkKeyCode == nil else { return nil }
                activePushToTalkKeyCode = keyCode
                onShortcut?(.dictationPushToTalk, .press)
            case .dictationHandsFree:
                onShortcut?(.dictationHandsFree, .press)
            case .meeting:
                onShortcut?(.meeting, .press)
            }
            return nil

        case .keyUp:
            if activePushToTalkKeyCode == keyCode {
                activePushToTalkKeyCode = nil
                consumedKeyCodes.remove(keyCode)
                onShortcut?(.dictationPushToTalk, pushToTalkReleasePhase())
                return nil
            }

            if consumedKeyCodes.remove(keyCode) != nil {
                return nil
            }

            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            if let activePushToTalkKeyCode, activePushToTalkKeyCode != keyCode {
                pushToTalkTap.otherKeyWentDown()
            }
            pushToTalkComboWindow.flagsChanged(
                keyCode: keyCode,
                modifiers: modifiers,
                isPushToTalkRelease: matchesRelease(for: .dictationPushToTalk, in: shortcutBindings, keyCode: keyCode, modifiers: modifiers)
            )
            if handsFreeComboTracker.flagsChanged(
                keyCode: keyCode,
                modifiers: modifiers,
                isHandsFreeRelease: matchesRelease(for: .dictationHandsFree, in: shortcutBindings, keyCode: keyCode, modifiers: modifiers)
            ) {
                return nil
            }

            if pendingModifierShortcut?.press.keyCode == keyCode,
               let pending = pendingModifierShortcut,
               matchesRelease(for: pending.press.action, in: shortcutBindings, keyCode: keyCode, modifiers: modifiers) {
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
               matchesRelease(for: .dictationPushToTalk, in: shortcutBindings, keyCode: keyCode, modifiers: modifiers) {
                activePushToTalkKeyCode = nil
                onShortcut?(.dictationPushToTalk, pushToTalkReleasePhase())
                return nil
            }

            guard let shortcut = matchingFlagsChangedPressShortcut(shortcutBindings, keyCode: keyCode, modifiers: modifiers) else {
                return Unmanaged.passUnretained(event)
            }

            switch shortcut.action {
            case .dictationPushToTalk:
                guard activePushToTalkKeyCode == nil else { return nil }
                let sharesModifier = hasChordUsingModifier(keyCode, in: shortcutBindings, excluding: shortcut.action)
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
                let sharesModifier = hasChordUsingModifier(keyCode, in: shortcutBindings, excluding: shortcut.action)
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
                if hasChordUsingModifier(keyCode, in: shortcutBindings, excluding: shortcut.action) {
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

    // Chord-resolution matchers live in PhysicalShortcutMatcher so their
    // exact-then-fallback precedence stays Foundation-pure and fast-testable.
    // These thin wrappers keep the detector's call sites unchanged.
    private func matchingKeyDownShortcut(
        _ shortcuts: [PhysicalShortcutBinding],
        keyCode: UInt32,
        modifiers: UInt32
    ) -> PhysicalShortcutBinding? {
        PhysicalShortcutMatcher.matchingKeyDownShortcut(shortcuts, keyCode: keyCode, modifiers: modifiers)
    }

    private func matchingFlagsChangedPressShortcut(
        _ shortcuts: [PhysicalShortcutBinding],
        keyCode: UInt32,
        modifiers: UInt32
    ) -> PhysicalShortcutBinding? {
        PhysicalShortcutMatcher.matchingFlagsChangedPressShortcut(shortcuts, keyCode: keyCode, modifiers: modifiers)
    }

    private func matchesRelease(
        for action: PhysicalShortcutAction,
        in shortcuts: [PhysicalShortcutBinding],
        keyCode: UInt32,
        modifiers: UInt32
    ) -> Bool {
        PhysicalShortcutMatcher.matchesRelease(for: action, in: shortcuts, keyCode: keyCode, modifiers: modifiers)
    }

    private func hasChordUsingModifier(
        _ keyCode: UInt32,
        in shortcuts: [PhysicalShortcutBinding],
        excluding action: PhysicalShortcutAction
    ) -> Bool {
        PhysicalShortcutMatcher.hasChordUsingModifier(keyCode, in: shortcuts, excluding: action)
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
                    expected: press,
                    isPhysicallyDown: true
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
        pushToTalkTap.isTap(releasedAt: ProcessInfo.processInfo.systemUptime) ? .tapRelease : .release
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

    /// Real session state, read when the tap may have missed events.
    private static func isPhysicalKeyDown(_ keyCode: UInt32) -> Bool {
        PhysicalShortcutMatcher.isPhysicalKeyDown(
            keyCode,
            modifierFlags: PhysicalDictationTriggerPreferences.modifiers(
                from: CGEventSource.flagsState(.combinedSessionState)
            ),
            keyState: sessionKeyState
        )
    }

    private static func sessionKeyState(_ keyCode: UInt32) -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }
}

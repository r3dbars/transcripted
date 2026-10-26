import CoreGraphics
import Foundation

/// Write for Me's key: fn (Globe) unless they pick another single key in Settings
/// (`NextSentencePreferences.hotkey()`, read on every press so a change applies at once). A quick tap opens
/// the card (or, with it open, starts and finishes listening). Holding it on its own is push-to-talk.
/// It works whether or not the card is open, so this tap is on whenever Next Sentence is. What each
/// press means is `NextSentenceKeyGesture`; this only feeds it events.
///
/// The key used with another key (fn-arrows, ⌘-shortcuts) is left alone, and another key during a hold
/// cancels it. A modifier key always passes through; a function key that's Write for Me's key is kept
/// from doing its usual job. If dictation or meetings use the same key, it does nothing here. With fn, set
/// "Press 🌐 key to" to "Do Nothing" in Keyboard settings if macOS also does something with it.
final class NextSentenceFnKey: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let onTap: @MainActor @Sendable () -> Void
    private let onHoldStart: @MainActor @Sendable () -> Void
    private let onHoldEnd: @MainActor @Sendable () -> Void
    private let onHoldCancel: @MainActor @Sendable () -> Void
    /// Only touched on the main thread: the tap's run loop source and the hold timer both run there.
    private var gesture = NextSentenceKeyGesture()

    init(onTap: @escaping @MainActor @Sendable () -> Void,
         onHoldStart: @escaping @MainActor @Sendable () -> Void,
         onHoldEnd: @escaping @MainActor @Sendable () -> Void,
         onHoldCancel: @escaping @MainActor @Sendable () -> Void) {
        self.onTap = onTap
        self.onHoldStart = onHoldStart
        self.onHoldEnd = onHoldEnd
        self.onHoldCancel = onHoldCancel
    }

    var isActive: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        // An active tap can keep a function key or combination from also doing its usual job. Without the
        // permission for that, listen only: the key still opens the card.
        guard let tap = Self.makeTap(options: .defaultTap, mask: mask, owner: self)
                ?? Self.makeTap(options: .listenOnly, mask: mask, owner: self) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    private static func makeTap(options: CGEventTapOptions, mask: CGEventMask, owner: NextSentenceFnKey) -> CFMachPort? {
        CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: options, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<NextSentenceFnKey>.fromOpaque(context).takeUnretainedValue()
                return me.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(owner).toOpaque()
        )
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    /// Returns true to swallow the event: only a function key that is Write for Me's key, so it doesn't
    /// also do its usual job. Modifier keys always pass through.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue
        let input: NextSentenceKeyGesture.Input
        switch type {
        case .keyDown: input = .keyDown(keyCode: code, flags: flags)
        case .keyUp: input = .keyUp(keyCode: code, flags: flags)
        case .flagsChanged: input = .flagsChanged(keyCode: code, flags: flags)
        default: return false
        }
        let key = NextSentencePreferences.hotkey()
        // Only a press of the key itself reads the dictation and meeting keys.
        let blocked = gesture.downAt == nil && code == key.keyCode && NextSentencePreferences.hotkeyClash(key) != nil
        let outcome = gesture.handle(input, key: key, blocked: blocked, now: Date())
        if let token = outcome.holdCheck {
            DispatchQueue.main.asyncAfter(deadline: .now() + NextSentencePolicy.fnTapLimit) { [self] in
                deliver(gesture.holdTimerFired(token))
            }
        }
        deliver(outcome.event)
        return outcome.swallow
    }

    /// The open card's key tap took a key, so this tap never saw it. True when it counts as a shortcut:
    /// Write for Me's key was down and this is another key.
    @discardableResult
    func otherKeyWentDown(keyCode: Int64) -> Bool {
        let key = NextSentencePreferences.hotkey()
        guard gesture.downAt != nil, keyCode != key.keyCode else { return false }
        deliver(gesture.otherKeyWentDown(keyCode: keyCode, key: key))
        return true
    }

    private func deliver(_ event: NextSentenceKeyGesture.Event?) {
        guard let event else { return }
        let callback: @MainActor @Sendable () -> Void
        switch event {
        case .tap: callback = onTap
        case .holdStart: callback = onHoldStart
        case .holdEnd: callback = onHoldEnd
        case .holdCancel: callback = onHoldCancel
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { callback() } }
    }
}

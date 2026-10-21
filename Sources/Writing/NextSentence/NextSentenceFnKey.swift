import CoreGraphics
import Foundation

/// Write for Me's key: fn (Globe) unless they pick another single key in Settings
/// (`NextSentencePreferences.hotkey()`, read on every press so a change applies at once). A quick tap opens
/// the card (or, with it open, starts and finishes listening). Holding it on its own is push-to-talk.
/// It works whether or not the card is open, so this tap is on whenever Next Sentence is.
///
/// The key used with another key (fn-arrows, ⌘-shortcuts) is left alone. A modifier key always passes
/// through; a function key that's Write for Me's key is kept from doing its usual job. With fn, set
/// "Press 🌐 key to" to "Do Nothing" in Keyboard settings if macOS also does something with it.
final class NextSentenceFnKey: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let onTap: @MainActor @Sendable () -> Void
    private let onHoldStart: @MainActor @Sendable () -> Void
    private let onHoldEnd: @MainActor @Sendable () -> Void
    private var downAt: Date?
    private var usedWithOtherKey = false
    private var holding = false
    private var press = 0

    init(onTap: @escaping @MainActor @Sendable () -> Void,
         onHoldStart: @escaping @MainActor @Sendable () -> Void,
         onHoldEnd: @escaping @MainActor @Sendable () -> Void) {
        self.onTap = onTap
        self.onHoldStart = onHoldStart
        self.onHoldEnd = onHoldEnd
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
        let key = NextSentencePreferences.hotkey()
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if !key.isModifier, code == key.keyCode, type == .keyDown || type == .keyUp {
            // Its modifiers held exactly (none for a function key on its own); anything else is another shortcut.
            // Letting go counts however the modifiers were released.
            let held = event.flags.rawValue & NextSentenceHotkey.chordMask
            guard downAt != nil || held == key.modifiers else { return false }
            if type == .keyUp {
                released()
            } else if downAt == nil {
                pressed()
            }
            return true
        }
        if type == .keyDown {
            if downAt != nil { usedWithOtherKey = true }
            return false
        }
        guard type == .flagsChanged else { return false }
        if key.isModifier, code == key.keyCode, let mask = key.downMask {
            if event.flags.rawValue & mask != 0 { pressed() } else { released() }
        } else if downAt != nil && !key.isCombination {
            // Another modifier pressed while the key is down: that's a combination, not a tap.
            usedWithOtherKey = true
        }
        return false
    }

    private func pressed() {
        downAt = Date()
        usedWithOtherKey = false
        // Still down, alone, past the tap limit: it's a hold.
        press += 1
        let this = press
        DispatchQueue.main.asyncAfter(deadline: .now() + NextSentencePolicy.fnTapLimit) { [self] in
            guard this == self.press, self.downAt != nil, !self.usedWithOtherKey else { return }
            self.holding = true
            MainActor.assumeIsolated { self.onHoldStart() }
        }
    }

    private func released() {
        guard let down = downAt else { return }
        downAt = nil
        press += 1
        if holding {
            holding = false
            let onHoldEnd = onHoldEnd
            DispatchQueue.main.async { MainActor.assumeIsolated { onHoldEnd() } }
            return
        }
        guard NextSentencePolicy.isFnTap(heldFor: Date().timeIntervalSince(down), withOtherKey: usedWithOtherKey) else { return }
        let onTap = onTap
        DispatchQueue.main.async { MainActor.assumeIsolated { onTap() } }
    }
}

import CoreGraphics
import Foundation

/// The fn (Globe) key is Next Sentence's key: a tap opens the card, the next starts listening, the next
/// finishes. It works whether or not the card is open, so this tap is on whenever Next Sentence is.
///
/// Only a tap counts: fn pressed and let go quickly with no other key in between. Holding fn with
/// another key (fn-arrows, fn-F keys) is left alone. The events always pass through; if macOS is set
/// to do something with the Globe key too, set "Press 🌐 key to" to "Do Nothing" in Keyboard settings.
final class NextSentenceFnKey: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let onTap: @MainActor @Sendable () -> Void
    private var downAt: Date?
    private var usedWithOtherKey = false

    init(onTap: @escaping @MainActor @Sendable () -> Void) {
        self.onTap = onTap
    }

    var isActive: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<NextSentenceFnKey>.fromOpaque(context).takeUnretainedValue()
                me.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if type == .keyDown {
            if downAt != nil { usedWithOtherKey = true }
            return
        }
        guard type == .flagsChanged else { return }
        let flags = event.flags
        if event.getIntegerValueField(.keyboardEventKeycode) == NextSentencePolicy.KeyCode.fn {
            if flags.contains(.maskSecondaryFn) {
                downAt = Date()
                usedWithOtherKey = false
            } else if let down = downAt {
                downAt = nil
                guard NextSentencePolicy.isFnTap(heldFor: Date().timeIntervalSince(down), withOtherKey: usedWithOtherKey) else { return }
                let onTap = onTap
                DispatchQueue.main.async { MainActor.assumeIsolated { onTap() } }
            }
        } else if downAt != nil {
            // Another modifier pressed while fn is down: that's a combination, not a tap.
            usedWithOtherKey = true
        }
    }
}

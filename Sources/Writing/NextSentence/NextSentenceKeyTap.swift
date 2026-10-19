import AppKit
import CoreGraphics

/// Catches Tab, the arrows, Return (down and up, for hold-to-send) and Esc while the card is open, so the card never has to take focus
/// from the app being typed in. Exists only while the card is showing; every other key passes through.
/// The callback runs on the tap's thread and only decides; the work hops to the main actor.
final class NextSentenceKeyTap: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// The action, plus the typed characters and key code for `.typeIntoCard`.
    private let onAction: @MainActor @Sendable (NextSentencePolicy.KeyAction, String, Int64) -> Void

    init(onAction: @escaping @MainActor @Sendable (NextSentencePolicy.KeyAction, String, Int64) -> Void) {
        self.onAction = onAction
    }

    var isActive: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<NextSentenceKeyTap>.fromOpaque(context).takeUnretainedValue()
                return me.handle(type: type, event: event)
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

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown || type == .keyUp else { return Unmanaged.passUnretained(event) }
        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let action = type == .keyUp
            ? NextSentencePolicy.releaseAction(keyCode: keyCode)
            : NextSentencePolicy.action(
                keyCode: keyCode,
                command: flags.contains(.maskCommand), control: flags.contains(.maskControl),
                option: flags.contains(.maskAlternate), shift: flags.contains(.maskShift),
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
        guard action != .passThrough else { return Unmanaged.passUnretained(event) }
        guard action != .ignore else { return nil }
        var length = 0
        var chars = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        let typed = String(utf16CodeUnits: chars, count: length)
        let onAction = onAction
        DispatchQueue.main.async { MainActor.assumeIsolated { onAction(action, typed, keyCode) } }
        return NextSentencePolicy.consumes(action) ? nil : Unmanaged.passUnretained(event)
    }
}

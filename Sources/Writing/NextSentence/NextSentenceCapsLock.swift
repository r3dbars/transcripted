import CoreGraphics
import Foundation
import IOKit
import IOKit.hidsystem

/// Caps Lock is Next Sentence's key: a press opens the card, the next starts listening, the next
/// finishes. It works whether or not the card is open, so this tap is on whenever Next Sentence is.
///
/// Caps Lock latches in the keyboard itself, so a press arrives as one flagsChanged event with the
/// lock turning on and no release. The tap acts on that, then turns the lock back off, so typing never
/// comes out in capitals. Turning it off sends its own event, with the lock off, which is ignored.
final class NextSentenceCapsLock: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let onPress: @MainActor @Sendable () -> Void

    init(onPress: @escaping @MainActor @Sendable () -> Void) {
        self.onPress = onPress
    }

    var isActive: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        Self.setLock(false)
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<NextSentenceCapsLock>.fromOpaque(context).takeUnretainedValue()
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
        guard type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == NextSentencePolicy.KeyCode.capsLock else {
            return Unmanaged.passUnretained(event)
        }
        // Lock turning off is our own reset (or a press while it was somehow on): swallow it quietly.
        guard event.flags.contains(.maskAlphaShift) else { return nil }
        DispatchQueue.main.async { Self.setLock(false) }
        let onPress = onPress
        DispatchQueue.main.async { MainActor.assumeIsolated { onPress() } }
        return nil
    }

    /// Sets the keyboard's Caps Lock state (and its light).
    static func setLock(_ on: Bool) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }
        IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), on)
    }
}

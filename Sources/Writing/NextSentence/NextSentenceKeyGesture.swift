import Foundation

/// What a press of Write for Me's key means, apart from the event tap: a quick tap, a hold to talk,
/// or a shortcut that isn't for Write for Me at all. `NextSentenceFnKey` feeds it real key events.
/// Pure, so tests pin it.
///
/// Write for Me's key is the only thing that opens it. Any other key that goes down while it's held
/// (fn-arrow, fn-Delete, ⌘-shortcuts) makes it a shortcut: a tap doesn't count, and a hold that already
/// began is cancelled so nothing it opened gets sent.
struct NextSentenceKeyGesture {
    enum Input: Equatable {
        case keyDown(keyCode: Int64, flags: UInt64)
        case keyUp(keyCode: Int64, flags: UInt64)
        case flagsChanged(keyCode: Int64, flags: UInt64)
    }

    enum Event: Equatable {
        /// A quick press on its own: open the card, or start or finish listening.
        case tap
        /// Still held, on its own, past `NextSentencePolicy.fnTapLimit`: push-to-talk begins.
        case holdStart
        /// Let go after a hold: push-to-talk ends and what was said is used.
        case holdEnd
        /// Another key went down during a hold: drop what the hold started.
        case holdCancel
    }

    struct Outcome: Equatable {
        /// Keep the event from the app: only a function key or combination that is the key itself.
        var swallow = false
        var event: Event?
        /// A new press: call `holdTimerFired` with this after `NextSentencePolicy.fnTapLimit`.
        var holdCheck: Int?
    }

    private(set) var downAt: Date?
    private(set) var holding = false
    private var usedWithOtherKey = false
    private var press = 0

    /// `blocked`: dictation or meetings use the same key (`NextSentencePreferences.hotkeyClash`), so a new
    /// press does nothing here and the event goes on to them.
    mutating func handle(_ input: Input, key: NextSentenceHotkey, blocked: Bool, now: Date) -> Outcome {
        switch input {
        case .keyDown(let code, let flags), .keyUp(let code, let flags):
            let isDown = input == .keyDown(keyCode: code, flags: flags)
            if !key.isModifier, code == key.keyCode {
                // Its modifiers held exactly (none for a function key on its own); anything else is another
                // shortcut. Letting go counts however the modifiers were released.
                guard downAt != nil || flags & NextSentenceHotkey.chordMask == key.modifiers else { return Outcome() }
                if !isDown { return Outcome(swallow: true, event: released(now)) }
                if downAt != nil { return Outcome(swallow: true) } // auto-repeat
                guard !blocked else { return Outcome() }
                return pressed(now, swallow: true)
            }
            return Outcome(event: isDown ? otherKeyWentDown(keyCode: code, key: key) : nil)
        case .flagsChanged(let code, let flags):
            if key.isModifier, code == key.keyCode, let mask = key.downMask {
                if flags & mask == 0 { return Outcome(event: released(now)) }
                guard downAt == nil, !blocked else { return Outcome() }
                return pressed(now, swallow: false)
            }
            // Another modifier pressed while the key is down: that's a combination, not a tap.
            guard downAt != nil, !key.isCombination else { return Outcome() }
            return Outcome(event: otherKeyWentDown(keyCode: code, key: key))
        }
    }

    /// The tap limit passed for press `token`: still down and on its own, it's a hold.
    mutating func holdTimerFired(_ token: Int) -> Event? {
        guard token == press, downAt != nil, !usedWithOtherKey, !holding else { return nil }
        holding = true
        return .holdStart
    }

    /// A key went down while this one is held, maybe one the event tap never saw (the open card's own key
    /// tap took it first). Write for Me's own key (its auto-repeat) never counts.
    mutating func otherKeyWentDown(keyCode: Int64, key: NextSentenceHotkey) -> Event? {
        guard downAt != nil, keyCode != key.keyCode else { return nil }
        usedWithOtherKey = true
        guard holding else { return nil }
        holding = false
        return .holdCancel
    }

    private mutating func pressed(_ now: Date, swallow: Bool) -> Outcome {
        downAt = now
        usedWithOtherKey = false
        holding = false
        press += 1
        return Outcome(swallow: swallow, holdCheck: press)
    }

    private mutating func released(_ now: Date) -> Event? {
        guard let down = downAt else { return nil }
        downAt = nil
        press += 1
        if holding {
            holding = false
            return .holdEnd
        }
        return NextSentencePolicy.isFnTap(heldFor: now.timeIntervalSince(down), withOtherKey: usedWithOtherKey) ? .tap : nil
    }
}

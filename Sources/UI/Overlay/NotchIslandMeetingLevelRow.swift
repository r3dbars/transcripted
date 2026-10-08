// NotchIslandMeetingLevelRow.swift
// The live meeting's one row of level bars, shared by you and the call.
// Your bars enter on the right and move left; the call's enter on the left
// and move right, so the two cross through each other. Core publishes each
// side's level only every 0.15 s, so readings never set the pace: they only
// decide what the next bar shows, and the view's timer steps the row at one
// even `stepInterval`. Once the row is at rest with no fresh reading the timer
// stops (`isAtRest`), so a hidden island never keeps it ticking. Foundation
// only, so the fast tests drive it directly.

import Foundation

struct NotchIslandMeetingLevelRow {
    /// What one slot of the row draws. A nil side draws nothing there.
    struct Slot: Equatable {
        /// The call's bar, drawn dim and behind.
        var call: Float?
        /// Your bar, drawn on top: bright while you're heard, dim at rest.
        var you: Float?
    }

    static let count = 14
    /// About 9 bars a second: calmer than the dictation waveform's 20.
    static let stepInterval: TimeInterval = 0.11
    /// With no new reading, a side holds this long, then falls to rest.
    static let holdTime: TimeInterval = 0.25
    /// A shaped level above this stands taller than the resting 3 pt dot at
    /// the 16 pt full height.
    static let audible: Float = 0.22

    /// Raw levels, newest first.
    private(set) var you: [Float]
    private(set) var call: [Float]
    private var pendingYou: Float?
    private var pendingCall: Float?
    private var lastReadingAt: TimeInterval?

    init(count: Int = Self.count) {
        you = Array(repeating: 0, count: max(2, count))
        call = you
    }

    /// One meeting reading. It changes nothing on screen until the next step;
    /// the loudest reading since the last step wins.
    mutating func receive(mic: Float, system: Float, at time: TimeInterval) {
        pendingYou = max(pendingYou ?? 0, Self.clamped(mic))
        pendingCall = max(pendingCall ?? 0, Self.clamped(system))
        lastReadingAt = time
    }

    /// One bar per side: both histories move one slot.
    mutating func step(at time: TimeInterval) {
        Self.push(pendingYou, lastAt: lastReadingAt, now: time, into: &you)
        Self.push(pendingCall, lastAt: lastReadingAt, now: time, into: &call)
        pendingYou = nil
        pendingCall = nil
    }

    /// Nothing left to move: no reading waits or is still held, and every bar
    /// has fallen to rest. Stepping now would only redraw the same dots.
    func isAtRest(at time: TimeInterval) -> Bool {
        guard pendingYou == nil, pendingCall == nil else { return false }
        if let lastReadingAt, time - lastReadingAt <= Self.holdTime { return false }
        return you.allSatisfy { $0 < Self.restLevel } && call.allSatisfy { $0 < Self.restLevel }
    }

    /// A raw level below this draws as the resting dot.
    static let restLevel: Float = 0.01

    /// The row left to right. The call's newest bar is slot 0, yours the last
    /// slot. Where both are quiet, the left half shows the call's resting dot
    /// and the right half yours; where one side is heard it shows through.
    var slots: [Slot] {
        let count = you.count
        return (0..<count).map { index in
            let call = Self.shaped(self.call[index])
            let you = Self.shaped(self.you[count - 1 - index])
            let callHeard = call > Self.audible
            let youHeard = you > Self.audible
            let leftHalf = index < count / 2
            return Slot(
                call: callHeard || (!youHeard && leftHalf) ? call : nil,
                you: youHeard || (!callHeard && !leftHalf) ? you : nil
            )
        }
    }

    /// Same curve as the dictation bars: quiet speech still shows.
    static func shaped(_ level: Float) -> Float {
        min(1, pow(max(0, level), 0.6) * 1.15)
    }

    /// The newest bar rises fast and falls gently, like the dictation bars.
    /// With no reading this step it holds briefly, then decays to rest.
    private static func push(_ reading: Float?, lastAt: TimeInterval?, now: TimeInterval, into levels: inout [Float]) {
        let current = levels.first ?? 0
        let newest: Float
        if let reading {
            let rate = reading > current ? NotchIslandLevelScroller.attack : NotchIslandLevelScroller.release
            newest = current + (reading - current) * rate
        } else if let lastAt, now - lastAt <= holdTime {
            newest = current
        } else {
            newest = current * (1 - NotchIslandLevelScroller.release)
        }
        levels.removeLast()
        levels.insert(newest, at: 0)
    }

    private static func clamped(_ value: Float) -> Float {
        value.isFinite ? max(0, min(1, value)) : 0
    }
}

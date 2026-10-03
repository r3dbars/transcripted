// DictationMuffleMachine.swift
// The dictation muffle's timeline as a pure state machine: inputs in,
// effects out, time passed in. No Core Audio, no logging, no clock, so every
// ordering promise that decides whether the start sounds seamless is
// fast-testable with a virtual clock (Tests/DictationMuffleMachineTests.swift).
//
// The take, start to finish:
//   1. The mic opens: open the route. The copy runs silent and dry; the
//      originals are untouched.
//   2. Wait for the tap to deliver real audio. If it never does (a paused
//      source, a revoked grant), stand down: nothing was ever muted.
//   3. If the copy lags the original by more than a few milliseconds (seen on
//      some routes), wait briefly for a quiet moment so the splice lands in a
//      pause.
//   4. Cut: open the copy's gate and mute the originals in the same step. The
//      copy is still dry, so the only seam is a few milliseconds of time, not
//      a jump in tone or level.
//   5. Shortly after, glide the cutoff down: the muffle fades in.
//   6. The mic closes: glide back to dry, then hand back (unmute the
//      originals, then fade the copy out over them; on lagging routes, in a
//      quiet moment if one comes quickly), then close the route.
//
// Re-opening the mic during the glide back just glides down again, with no
// Core Audio work. Losing the route (output changed, device gone, a failed
// mute) closes it from any phase; closing always unmutes first.

import Foundation

struct DictationMuffleTiming: Equatable {
    /// How often to look at the IO thread's signals while waiting.
    var pollNanos: UInt64 = 2_000_000
    /// How long the tap may stay silent after the route starts before the
    /// muffle stands down.
    var firstSoundWaitNanos: UInt64 = 400_000_000
    /// Bluetooth outputs start slower (~170 ms to first audio on AirPods).
    var firstSoundWaitBluetoothNanos: UInt64 = 900_000_000
    /// Above this copy delay, the cut waits for a quiet moment.
    var quietCutAboveDelayNanos: UInt64 = 15_000_000
    /// How long the cut may wait for a quiet moment before it goes anyway.
    var quietWaitNanos: UInt64 = 300_000_000
    /// Settle between the cut and the start of the glide, so the mute has
    /// surely landed before the tone starts to change.
    var glideAfterCutNanos: UInt64 = 15_000_000
    /// At the hand back, how long to wait for a quiet moment on routes where
    /// the copy lags (same rule as the cut), so the originals come back in a
    /// pause instead of skipping ahead by the copy delay. Short: the music
    /// is already dry by then.
    var handBackQuietWaitNanos: UInt64 = 120_000_000
    /// How long the glide back to dry takes (DictationMuffleFilter.releaseSeconds
    /// plus a margin) before the originals come back.
    var releaseGlideNanos: UInt64 = 240_000_000
    /// After the hand back, how long before the route closes (the gate fade
    /// plus a margin).
    var handBackSettleNanos: UInt64 = 15_000_000
}

enum DictationMufflePhase: Equatable {
    case idle
    case opening
    case awaitingSound(deadline: UInt64)
    case awaitingQuiet(deadline: UInt64)
    case cutting(glideAt: UInt64)
    case muffled
    case releasing(handBackAt: UInt64)
    case awaitingHandBackQuiet(deadline: UInt64)
    case handingBack(closeAt: UInt64)
}

/// What the IO thread has seen, sampled on each tick.
struct DictationMuffleSignals: Equatable {
    var soundFlowing: Bool
    var quiet: Bool
    /// How far the copy lags the original, once it's known.
    var copyDelayNanos: UInt64?

    static let none = DictationMuffleSignals(soundFlowing: false, quiet: false, copyDelayNanos: nil)
}

enum DictationMuffleInput: Equatable {
    case micOpened
    case micClosed
    case routeOpened(bluetooth: Bool)
    case routeFailed(reason: String)
    case routeLost(reason: String)
    case tick(DictationMuffleSignals)
}

enum DictationMuffleReport: Equatable {
    case engaged(soundWaitNanos: UInt64, quietWaitNanos: UInt64, cutInQuiet: Bool)
    case skipped(reason: String)
    case stopped(reason: String)
}

enum DictationMuffleEffect: Equatable {
    /// Build and start the route: the copy silent and dry, nothing muted.
    case openRoute
    /// Open the copy's gate and mute the originals, together.
    case cut
    /// Glide the cutoff toward muffled (true) or open (false).
    case setMuffled(Bool)
    /// Unmute the originals and close the copy's gate, together.
    case handBack
    /// Stop and destroy everything, unmuting first if still muted.
    case closeRoute
    /// Deliver a tick at (or after) this time.
    case wake(at: UInt64)
    case report(DictationMuffleReport)
}

struct DictationMuffleMachine {
    let timing: DictationMuffleTiming
    private(set) var phase: DictationMufflePhase = .idle
    private var soundWaitStartedAt: UInt64 = 0
    private var soundFlowedAt: UInt64 = 0

    init(timing: DictationMuffleTiming = DictationMuffleTiming()) {
        self.timing = timing
    }

    mutating func handle(_ input: DictationMuffleInput, now: UInt64) -> [DictationMuffleEffect] {
        switch (phase, input) {
        case (.idle, .micOpened):
            phase = .opening
            return [.openRoute]

        case (.opening, .routeOpened(let isBluetooth)):
            soundWaitStartedAt = now
            let wait = isBluetooth ? timing.firstSoundWaitBluetoothNanos : timing.firstSoundWaitNanos
            phase = .awaitingSound(deadline: now + wait)
            return [.wake(at: now + timing.pollNanos)]

        case (.opening, .routeFailed(let reason)):
            phase = .idle
            return [.closeRoute, .report(.skipped(reason: reason))]

        case (.awaitingSound(let deadline), .tick(let signals)):
            guard signals.soundFlowing else {
                if now >= deadline {
                    phase = .idle
                    return [.closeRoute, .report(.skipped(reason: "tap_silent"))]
                }
                return [.wake(at: now + timing.pollNanos)]
            }
            soundFlowedAt = now
            if let delay = signals.copyDelayNanos, delay > timing.quietCutAboveDelayNanos, !signals.quiet {
                phase = .awaitingQuiet(deadline: now + timing.quietWaitNanos)
                return [.wake(at: now + timing.pollNanos)]
            }
            return cut(now: now, inQuiet: signals.quiet)

        case (.awaitingQuiet(let deadline), .tick(let signals)):
            if signals.quiet || now >= deadline {
                return cut(now: now, inQuiet: signals.quiet)
            }
            return [.wake(at: now + timing.pollNanos)]

        case (.cutting(let glideAt), .tick):
            guard now >= glideAt else { return [.wake(at: glideAt)] }
            phase = .muffled
            return [.setMuffled(true)]

        case (.cutting, .micClosed):
            // Still dry: hand back at once, no glide to undo.
            let closeAt = now + timing.handBackSettleNanos
            phase = .handingBack(closeAt: closeAt)
            return [.handBack, .wake(at: closeAt)]

        case (.muffled, .micClosed):
            let handBackAt = now + timing.releaseGlideNanos
            phase = .releasing(handBackAt: handBackAt)
            return [.setMuffled(false), .wake(at: handBackAt)]

        case (.releasing, .micOpened):
            phase = .muffled
            return [.setMuffled(true)]

        case (.releasing(let handBackAt), .tick(let signals)):
            guard now >= handBackAt else { return [.wake(at: handBackAt)] }
            if let delay = signals.copyDelayNanos, delay > timing.quietCutAboveDelayNanos, !signals.quiet {
                phase = .awaitingHandBackQuiet(deadline: now + timing.handBackQuietWaitNanos)
                return [.wake(at: now + timing.pollNanos)]
            }
            return handBack(now: now)

        case (.awaitingHandBackQuiet(let deadline), .tick(let signals)):
            if signals.quiet || now >= deadline {
                return handBack(now: now)
            }
            return [.wake(at: now + timing.pollNanos)]

        case (.awaitingHandBackQuiet, .micOpened):
            phase = .muffled
            return [.setMuffled(true)]

        case (.handingBack, .micOpened):
            // The route is still open: cut again rather than rebuild.
            soundWaitStartedAt = now
            soundFlowedAt = now
            return cut(now: now, inQuiet: false)

        case (.handingBack(let closeAt), .tick):
            guard now >= closeAt else { return [.wake(at: closeAt)] }
            phase = .idle
            return [.closeRoute]

        case (.opening, .micClosed), (.awaitingSound, .micClosed), (.awaitingQuiet, .micClosed):
            // The originals were never muted; just close.
            phase = .idle
            return [.closeRoute]

        case (.opening, .routeLost(let reason)),
             (.awaitingSound, .routeLost(let reason)),
             (.awaitingQuiet, .routeLost(let reason)),
             (.cutting, .routeLost(let reason)),
             (.muffled, .routeLost(let reason)),
             (.releasing, .routeLost(let reason)),
             (.awaitingHandBackQuiet, .routeLost(let reason)),
             (.handingBack, .routeLost(let reason)):
            phase = .idle
            return [.closeRoute, .report(.stopped(reason: reason))]

        default:
            // Everything else is a no-op: a repeated open or close, a stale
            // tick, or a route event that arrives after the route closed.
            return []
        }
    }

    private mutating func handBack(now: UInt64) -> [DictationMuffleEffect] {
        let closeAt = now + timing.handBackSettleNanos
        phase = .handingBack(closeAt: closeAt)
        return [.handBack, .wake(at: closeAt)]
    }

    private mutating func cut(now: UInt64, inQuiet: Bool) -> [DictationMuffleEffect] {
        let glideAt = now + timing.glideAfterCutNanos
        phase = .cutting(glideAt: glideAt)
        let report = DictationMuffleReport.engaged(
            soundWaitNanos: soundFlowedAt - soundWaitStartedAt,
            quietWaitNanos: now - soundFlowedAt,
            cutInQuiet: inQuiet
        )
        return [.cut, .wake(at: glideAt), .report(report)]
    }
}

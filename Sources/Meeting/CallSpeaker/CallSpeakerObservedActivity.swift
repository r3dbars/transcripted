import CoreAudio
import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// HAL and AX use this same monotonic host clock. The poll cadence's
/// ContinuousClock is separate and never supplies a recording-file offset.
struct CallSpeakerHostClock: Sendable {
    var now: @Sendable () -> UInt64
    var ticksPerSecond: Double

    static let live = CallSpeakerHostClock(
        now: { AudioGetCurrentHostTime() },
        ticksPerSecond: AudioGetHostClockFrequency()
    )
}

struct CallSpeakerReadTiming: Sendable, Equatable {
    let startHostTime: UInt64
    let endHostTime: UInt64

    var midpoint: UInt64? {
        guard startHostTime > 0, endHostTime >= startHostTime else { return nil }
        return startHostTime + (endHostTime - startHostTime) / 2
    }

    /// Called on the reader's serial queue around the AX operations only.
    static func measure(clock: CallSpeakerHostClock, scan: () -> CallSpeakerReadResult) -> CallSpeakerReadResult {
        let start = clock.now()
        var result = scan()
        result.timing = .init(startHostTime: start, endHostTime: clock.now())
        return result
    }
}

/// Typed unaligned evidence: its relative times start at AX observation,
/// not frame zero of a recording. Only `aligned(to:)` produces pipeline data.
struct CallSpeakerObservedActivity: Sendable {
    let originHostTime: UInt64
    let ticksPerSecond: Double
    let relativeActivity: CallSpeakerActivity

    func aligned(to timeline: RecordedSystemAudioTimeline?) -> CallSpeakerActivity {
        var result = CallSpeakerActivity(
            rosterNames: relativeActivity.rosterNames,
            selfNames: relativeActivity.selfNames,
            sawSpeakingIndicator: relativeActivity.sawSpeakingIndicator
        )
        guard let timeline, originHostTime > 0,
              ticksPerSecond.isFinite, ticksPerSecond > 0 else { return result }
        func hostTime(_ seconds: Double) -> UInt64? {
            let ticks = seconds * ticksPerSecond
            guard ticks.isFinite, ticks >= 0, ticks < Double(UInt64.max) else { return nil }
            let (value, overflow) = originHostTime.addingReportingOverflow(UInt64(ticks.rounded(.down)))
            return overflow ? nil : value
        }
        func map(_ start: Double, _ end: Double) -> [RecordedSystemAudioTimeline.Span] {
            guard let start = hostTime(start), let end = hostTime(end) else { return [] }
            return timeline.map(startHostTime: start, endHostTime: end)
        }
        result.intervals = relativeActivity.intervals.flatMap { interval in
            map(interval.start, interval.end).map {
                CallSpeakerActivity.Interval(name: interval.name, start: $0.start, end: $0.end)
            }
        }
        result.coverage = relativeActivity.coverage.flatMap {
            map($0.start, $0.end).map { CallSpeakerActivity.Span(start: $0.start, end: $0.end) }
        }
        return result
    }
}

import Foundation

/// Live detector for issue #500's still-open case: a foreign app holds the
/// shared input device in macOS voice/communication mode, so the copy every
/// other reader gets is AEC-gated and stays quiet even with the software AGC
/// (`RealtimeAGC`) pinned at max gain.
///
/// Pure policy: consumes one interval summary per 0.2s recording-timer tick
/// and latches a single fire per instance. Allocation-free and main-thread-
/// only — `Audio` replaces the instance on the recording start path and the
/// timer is the only consumer.
public struct QuietMicAttenuationDetector {

    // Mirror of the app-side stop-time classification thresholds in
    // MeetingCaptureSupport.swift (quietMicRawPeakThreshold /
    // usableMicProcessedPeakThreshold). Duplicated across targets on purpose
    // (the app fast-test runner cannot link Core); pinned equal by tests on
    // both sides so live and post-hoc classification agree.
    public static let quietMicRawPeakThreshold: Float = 0.05
    public static let usableMicProcessedPeakThreshold: Float = 0.12
    public static let gainPinnedFraction: Float = 0.9
    public static let detectionWindow: TimeInterval = 30
    /// Requires voice-like energy so a silent room never prompts. Bounded on
    /// both sides: above RealtimeAGC.minPeak (0.0008 ambient/silence), and
    /// well below usableMicProcessedPeakThreshold / RealtimeAGC.maxGain
    /// (0.12 / 25 = 0.0048) — the live pipeline measures processedPeak after
    /// the AGC multiplies the same buffer, so an activity tick at the gain
    /// pin must still land under the usable bar or it would disqualify
    /// itself and the detector could never fire. 0.002 × 25 = 0.05 keeps a
    /// 2.4× margin; consistency is pinned by tests against RealtimeAGC.
    public static let activityRawPeakFloor: Float = 0.002
    public static let requiredActivityDuration: TimeInterval = 5

    private let requiredTicks: Int
    private let requiredActivityTicks: Int
    private var consecutiveAttenuatedTicks = 0
    private var activityTicksInStreak = 0
    private var hasFired = false

    /// Deriving tick counts from `TimeInterval` keeps the detection window
    /// correct if the recording-timer cadence ever changes.
    public init(tickInterval: TimeInterval = 0.2) {
        requiredTicks = max(1, Int((Self.detectionWindow / tickInterval).rounded()))
        requiredActivityTicks = max(1, Int((Self.requiredActivityDuration / tickInterval).rounded()))
    }

    /// Feed one timer tick's interval summary. Returns `true` exactly once —
    /// when the mic has stayed attenuated for the full detection window with
    /// real input activity — then always `false` until a fresh instance
    /// replaces this one.
    ///
    /// Any non-qualifying tick (no buffers during engine restarts, nil gain
    /// when VPIO is on / AGC absent, zero raw peak when muted, loud raw,
    /// usable processed, unpinned gain) resets the streak. A qualifying
    /// streak may extend past the detection window while waiting for enough
    /// activity ticks; it never resets while ticks keep qualifying.
    public mutating func consume(
        rawPeak: Float,
        processedPeak: Float,
        appliedGain: Float?,
        agcMaxGain: Float?,
        sawBuffer: Bool
    ) -> Bool {
        guard !hasFired else { return false }

        let gainPinnedAtMax: Bool
        if let appliedGain, let agcMaxGain {
            gainPinnedAtMax = appliedGain >= Self.gainPinnedFraction * agcMaxGain
        } else {
            gainPinnedAtMax = false
        }

        let qualifies = sawBuffer
            && gainPinnedAtMax
            && rawPeak > 0
            && rawPeak < Self.quietMicRawPeakThreshold
            && processedPeak < Self.usableMicProcessedPeakThreshold

        guard qualifies else {
            consecutiveAttenuatedTicks = 0
            activityTicksInStreak = 0
            return false
        }

        consecutiveAttenuatedTicks += 1
        if rawPeak >= Self.activityRawPeakFloor {
            activityTicksInStreak += 1
        }

        guard consecutiveAttenuatedTicks >= requiredTicks,
              activityTicksInStreak >= requiredActivityTicks else {
            return false
        }

        hasFired = true
        return true
    }
}

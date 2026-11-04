import Foundation

/// The source coordinate of a delivered, unconverted system buffer. Unknown
/// or converted PCM has no such coordinate. Created off the realtime thread.
public struct SystemAudioBufferTiming: Sendable, Equatable {
    public let firstSampleHostTime: UInt64?
    public let sampleTime: Double?
    public let sampleRate: Double?
    public let continuityID: UInt64

    public init(firstSampleHostTime: UInt64?, sampleTime: Double?, sampleRate: Double?, continuityID: UInt64) {
        self.firstSampleHostTime = firstSampleHostTime.flatMap { $0 > 0 ? $0 : nil }
        self.sampleTime = sampleTime.flatMap { $0.isFinite ? $0 : nil }
        self.sampleRate = sampleRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.continuityID = continuityID
    }

    public static let unavailable = SystemAudioBufferTiming(
        firstSampleHostTime: nil, sampleTime: nil, sampleRate: nil, continuityID: 0
    )
}

/// Immutable mapping from HAL host ticks to frames actually committed to one
/// system WAV. Nothing here reads a clock, file, audio device, or app state.
public struct RecordedSystemAudioTimeline: Sendable {
    public struct Identity: Sendable, Equatable {
        public let generation: UInt64
        public let captureAttempt: UUID
        public let writer: UUID

        public init(generation: UInt64, captureAttempt: UUID, writer: UUID) {
            self.generation = generation
            self.captureAttempt = captureAttempt
            self.writer = writer
        }
    }

    public struct Span: Sendable, Equatable {
        public let start: Double
        public let end: Double
    }

    fileprivate struct Segment: Sendable {
        let startHost: UInt64
        let endHost: UInt64
        let startFrame: Int64
        let endFrame: Int64
        let continuityID: UInt64
    }

    public let identity: Identity
    public let sampleRate: Double
    public let didReachCapacity: Bool
    public let unmappedFrameCount: Int64
    private let segments: [Segment]
    public var segmentCount: Int { segments.count }

    /// Splits at gaps/epochs. There is no extrapolation before the first
    /// proven anchor or after the last one, including the final pending buffer.
    public func map(startHostTime: UInt64, endHostTime: UInt64) -> [Span] {
        guard startHostTime > 0, endHostTime > startHostTime else { return [] }
        var result: [Span] = []
        var priorHostEnd: UInt64?
        var priorContinuity: UInt64?
        // The journal is bounded. Skip its prefix by binary search, then only
        // visit segments overlapping this observation.
        var lower = 0
        var upper = segments.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if segments[middle].endHost <= startHostTime { lower = middle + 1 }
            else { upper = middle }
        }
        for segment in segments[lower...] {
            guard segment.startHost < endHostTime else { break }
            let start = max(startHostTime, segment.startHost)
            let end = min(endHostTime, segment.endHost)
            guard end > start else { continue }
            func seconds(at host: UInt64) -> Double {
                if host == segment.startHost { return Double(segment.startFrame) / sampleRate }
                if host == segment.endHost { return Double(segment.endFrame) / sampleRate }
                let fraction = Double(host - segment.startHost) / Double(segment.endHost - segment.startHost)
                return (Double(segment.startFrame) + fraction * Double(segment.endFrame - segment.startFrame)) / sampleRate
            }
            let mapped = Span(start: seconds(at: start), end: seconds(at: end))
            guard mapped.start.isFinite, mapped.end.isFinite, mapped.end > mapped.start else { continue }
            if let previous = result.last, previous.end == mapped.start,
               priorHostEnd == start, priorContinuity == segment.continuityID {
                result[result.count - 1] = Span(start: previous.start, end: mapped.end)
            } else {
                result.append(mapped)
            }
            priorHostEnd = end
            priorContinuity = segment.continuityID
        }
        return result
    }

    /// Queue-confined write journal. Call only on the existing file-writer
    /// queue, never the IOProc. Each receipt uses AVAudioFile.framePosition
    /// before/after the write, not intended frames or an open WAV's length.
    public struct Journal: Sendable {
        private struct Pending: Sendable {
            let startFrame: Int64
            let endFrame: Int64
            let frameCount: Int64
            let timing: SystemAudioBufferTiming
        }

        private let identity: Identity
        private let sampleRate: Double
        private let maximumSegments: Int
        private var segments: [Segment] = []
        private var pending: Pending?
        private var position: Int64 = 0
        private var trustedFrames: Int64 = 0
        private var invalidated = false
        private var finalized = false
        private var reachedCapacity = false

        /// The cap is explicit: saturation withholds the suffix, never extends
        /// an old affine run across dropped receipts. Budget needs native
        /// long-recording qualification before release.
        public init?(identity: Identity, sampleRate: Double, maximumSegments: Int) {
            guard sampleRate.isFinite, sampleRate > 0,
                  maximumSegments > 0, maximumSegments <= 1_048_576 else { return nil }
            self.identity = identity
            self.sampleRate = sampleRate
            self.maximumSegments = maximumSegments
        }

        /// A failed/partial/unknown/converted write breaks the pending link.
        /// Its real file position still places a later successful anchor.
        public mutating func recordWrite(
            identity receiptIdentity: Identity,
            startFrame: Int64, endFrame: Int64, frameCount: Int64,
            succeeded: Bool, timing: SystemAudioBufferTiming
        ) {
            guard receiptIdentity == identity, !finalized else { return }
            guard startFrame >= position, endFrame >= startFrame else {
                // A seek/overwrite can invalidate earlier file contents.
                invalidated = true
                pending = nil
                segments.removeAll(keepingCapacity: false)
                trustedFrames = 0
                return
            }
            position = endFrame
            guard !invalidated, !reachedCapacity,
                  succeeded, frameCount > 0, endFrame - startFrame == frameCount,
                  timing.sampleRate == sampleRate,
                  let host = timing.firstSampleHostTime, let sourceTime = timing.sampleTime else {
                pending = nil
                return
            }

            if let previous = pending, previous.timing.continuityID == timing.continuityID,
               let previousHost = previous.timing.firstSampleHostTime,
               let previousTime = previous.timing.sampleTime,
               host <= previousHost || sourceTime <= previousTime {
                pending = nil
                return
            }

            if let previous = pending,
               previous.endFrame == startFrame,
               previous.timing.continuityID == timing.continuityID,
               let previousHost = previous.timing.firstSampleHostTime,
               let previousTime = previous.timing.sampleTime,
               sourceTime == previousTime + Double(previous.frameCount), host > previousHost,
               segments.last.map({ previousHost >= $0.endHost }) ?? true {
                append(Segment(startHost: previousHost, endHost: host,
                               startFrame: previous.startFrame, endFrame: previous.endFrame,
                               continuityID: timing.continuityID))
            }
            // A backward host stamp must not become the next trusted start.
            guard !reachedCapacity, segments.last.map({ host >= $0.endHost }) ?? true else {
                pending = nil
                return
            }
            pending = Pending(startFrame: startFrame, endFrame: endFrame,
                              frameCount: frameCount, timing: timing)
        }

        /// A delivered buffer that was not written cannot connect two anchors.
        public mutating func breakContinuity(identity receiptIdentity: Identity) {
            guard receiptIdentity == identity, !finalized else { return }
            pending = nil
        }

        public mutating func finish() -> RecordedSystemAudioTimeline {
            finalized = true
            pending = nil // No following source stamp proves this buffer's end.
            return RecordedSystemAudioTimeline(
                identity: identity, sampleRate: sampleRate,
                didReachCapacity: reachedCapacity,
                unmappedFrameCount: max(0, position - trustedFrames), segments: segments
            )
        }

        private mutating func append(_ segment: Segment) {
            if let previous = segments.last,
               previous.continuityID == segment.continuityID,
               previous.endHost == segment.startHost, previous.endFrame == segment.startFrame,
               sameSlope(previous, segment) {
                segments[segments.count - 1] = Segment(
                    startHost: previous.startHost, endHost: segment.endHost,
                    startFrame: previous.startFrame, endFrame: segment.endFrame,
                    continuityID: segment.continuityID
                )
            } else {
                guard segments.count < maximumSegments else {
                    reachedCapacity = true
                    return
                }
                segments.append(segment)
            }
            trustedFrames += segment.endFrame - segment.startFrame
        }

        /// Reduced rational tick/frame slopes: no tolerance and no overflowing
        /// cross-products, even on a long recording.
        private func sameSlope(_ lhs: Segment, _ rhs: Segment) -> Bool {
            func reduced(_ segment: Segment) -> (UInt64, UInt64) {
                let frames = UInt64(segment.endFrame - segment.startFrame)
                let ticks = segment.endHost - segment.startHost
                var a = frames
                var b = ticks
                while b != 0 { (a, b) = (b, a % b) }
                return (frames / a, ticks / a)
            }
            return reduced(lhs) == reduced(rhs)
        }
    }
}

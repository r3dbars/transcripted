// DictationMuffleFilter.swift
// The "outside the club" sound. A 4th-order low-pass (two cascaded TPT
// state-variable filters per channel) whose cutoff glides exponentially from
// wide open down to a few hundred hertz and back, like a door closing, with a
// gentle level dip. At rest it is an exact passthrough.
//
// Why a cutoff glide and not a dry/wet crossfade: the low-pass is -180° at its
// cutoff, so dry + wet cancels there mid-ramp (a deep notch you hear as a
// hollow sweep). A glide has no dry path to cancel against, and TPT filters
// stay clean while their cutoff moves.
//
// A separate output gate fades the whole output in and out over a few
// milliseconds. The muffler opens it as the originals are muted, and closes
// it just after they come back, so the copy fades out over them. On routes
// where the copy lags (AirPods), the gate holds shut for the lag first; see
// DictationMuffleSplice.
//
// Runs on the Core Audio IO thread: no allocation, locks or ObjC. All state is
// fixed-size stored properties; coefficients are recomputed per short control
// block only while the cutoff is moving.

import CoreAudio
import Foundation

struct DictationMuffleFilter {
    static let openCutoffHz: Double = 18_000
    static let closedCutoffHz: Double = 450
    static let closedLevel: Float = 0.7
    /// How long the cutoff takes to close when muffling starts.
    static let engageSeconds: Double = 0.32
    /// How long it takes to open again when muffling ends.
    static let releaseSeconds: Double = 0.22
    /// How long the output gate takes to fade the whole copy in or out.
    static let gateSeconds: Double = 0.004
    /// Frames between coefficient updates while the cutoff moves.
    static let controlBlockFrames = 16

    private static let damping: Float = 1.414_213_6 // 1/Q for Q = 0.7071

    private let sampleRate: Double
    private let openCutoff: Double
    private let amountStepPerBlockEngage: Float
    private let amountStepPerBlockRelease: Float
    private let gateStep: Float

    /// 0 is wide open (exact passthrough), 1 is fully muffled.
    private(set) var amount: Float = 0
    /// Output level gate, 0...1.
    private(set) var gate: Float

    // Smoothed control values for the current block.
    private var level: Float = 1
    private var blend: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0
    private var a3: Float = 0

    // TPT SVF integrator states: (stage 1, stage 2) x (left, right).
    private var l1s1: Float = 0, l1s2: Float = 0, l2s1: Float = 0, l2s2: Float = 0
    private var r1s1: Float = 0, r1s2: Float = 0, r2s1: Float = 0, r2s2: Float = 0

    init(sampleRate: Double, startGated: Bool = false) {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        self.sampleRate = rate
        openCutoff = min(Self.openCutoffHz, rate * 0.45)
        let block = Double(Self.controlBlockFrames)
        amountStepPerBlockEngage = Float(block / max(1, Self.engageSeconds * rate))
        amountStepPerBlockRelease = Float(block / max(1, Self.releaseSeconds * rate))
        gateStep = Float(1 / max(1, Self.gateSeconds * rate))
        gate = startGated ? 0 : 1
        updateCoefficients()
    }

    /// Reads the tap's audio from `input`, filters it at the current amount,
    /// and writes it to `output`. `muffleTarget` (0 or 1) is where the cutoff
    /// glides toward; `gateTarget` (0 or 1) is where the output gate fades.
    /// While opening, the gate stays shut for the cycle's first
    /// `gateHoldFrames` frames, then fades over `gateFadeFrames` (0 means
    /// `gateSeconds`).
    ///
    /// Handles interleaved or split Float32 buffers on either side: mono input
    /// feeds both sides, a mono output gets the average, and output channels
    /// past the second are silenced. A missing or short input renders as
    /// silence rather than stale memory.
    ///
    /// Returns the cycle's input peak (absolute), which the muffler uses to
    /// know the tap is really delivering audio and to find quiet moments.
    @discardableResult
    mutating func render(
        input: UnsafePointer<AudioBufferList>?,
        output: UnsafeMutablePointer<AudioBufferList>?,
        muffleTarget: Float,
        gateTarget: Float,
        gateHoldFrames: Int = 0,
        gateFadeFrames: Int = 0
    ) -> Float {
        guard let output else { return 0 }
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let outCount = outList.count
        guard outCount > 0 else { return 0 }

        // Resolve the layout once per cycle: UnsafeMutableAudioBufferListPointer's
        // collection methods don't inline across modules, so walking them per
        // frame costs several times the filter itself.
        var outL: UnsafeMutablePointer<Float>?
        var outR: UnsafeMutablePointer<Float>?
        var outLStride = 0
        var outRStride = 0
        var frames = Int.max
        var totalChannels = 0
        for index in 0..<outCount {
            let buffer = outList[index]
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let raw = buffer.mData else {
                totalChannels += channels
                continue
            }
            // Zero first so channels past the second, and frames the input
            // can't cover, are silence.
            memset(raw, 0, Int(buffer.mDataByteSize))
            let data = raw.assumingMemoryBound(to: Float.self)
            frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            if totalChannels == 0 {
                outL = data
                outLStride = channels
                if channels >= 2 {
                    outR = data + 1
                    outRStride = channels
                }
            } else if totalChannels == 1 {
                outR = data
                outRStride = channels
            }
            totalChannels += channels
        }
        guard let outL, frames != Int.max, frames > 0 else { return 0 }
        let monoOut = totalChannels == 1

        var inL: UnsafePointer<Float>?
        var inR: UnsafePointer<Float>?
        var inLStride = 0
        var inRStride = 0
        var inputFrames = 0
        if let input {
            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let inCount = inList.count
            var shortest = Int.max
            var usable = inCount > 0
            for index in 0..<inCount {
                let buffer = inList[index]
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, buffer.mData != nil else {
                    usable = false
                    break
                }
                shortest = min(shortest, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            }
            if usable, shortest != Int.max, let firstRaw = inList[0].mData {
                let firstChannels = Int(inList[0].mNumberChannels)
                let first = UnsafePointer(firstRaw.assumingMemoryBound(to: Float.self))
                inL = first
                inLStride = firstChannels
                if firstChannels >= 2 {
                    inR = first + 1
                    inRStride = firstChannels
                } else if inCount >= 2, let secondRaw = inList[1].mData, inList[1].mNumberChannels > 0 {
                    inR = UnsafePointer(secondRaw.assumingMemoryBound(to: Float.self))
                    inRStride = Int(inList[1].mNumberChannels)
                } else {
                    inR = first
                    inRStride = firstChannels
                }
                inputFrames = min(shortest, frames)
            }
        }

        let gateTarget = min(max(gateTarget, 0), 1)
        let muffleTarget = min(max(muffleTarget, 0), 1)
        let gateStep = gateFadeFrames > 0 ? 1 / Float(gateFadeFrames) : self.gateStep
        var peak: Float = 0
        var frame = 0
        while frame < frames {
            advanceAmount(toward: muffleTarget)
            let blockEnd = min(frames, frame + Self.controlBlockFrames)
            while frame < blockEnd {
                var left: Float = 0
                var right: Float = 0
                if frame < inputFrames, let inL, let inR {
                    left = inL[frame &* inLStride]
                    right = inR[frame &* inRStride]
                    // A non-finite sample from the tap would poison the filter
                    // and click; treat it as silence.
                    if !left.isFinite { left = 0 }
                    if !right.isFinite { right = 0 }
                    peak = max(peak, max(abs(left), abs(right)))
                }
                let target: Float = frame < gateHoldFrames ? 0 : gateTarget
                if gate < target {
                    gate = min(target, gate + gateStep)
                } else if gate > target {
                    gate = max(target, gate - gateStep)
                }
                var (outLeft, outRight) = process(left: left, right: right)
                outLeft *= gate
                outRight *= gate
                if monoOut {
                    outL[frame &* outLStride] = (outLeft + outRight) * 0.5
                } else {
                    outL[frame &* outLStride] = outLeft
                    outR?[frame &* outRStride] = outRight
                }
                frame &+= 1
            }
        }
        flushFilterState()
        return peak
    }

    /// One stereo frame through both TPT stages at the current coefficients,
    /// then the level and the open-end blend. Exact passthrough at rest.
    @inline(__always)
    private mutating func process(left: Float, right: Float) -> (Float, Float) {
        // Always run the filter so its state tracks the signal and the glide
        // starts without a transient.
        let lLow = Self.stage(left, &l1s1, &l1s2, a1, a2, a3)
        let lOut = Self.stage(lLow, &l2s1, &l2s2, a1, a2, a3)
        let rLow = Self.stage(right, &r1s1, &r1s2, a1, a2, a3)
        let rOut = Self.stage(rLow, &r2s1, &r2s2, a1, a2, a3)
        if blend == 0 {
            return (left, right)
        }
        let wetL = left + blend * (lOut - left)
        let wetR = right + blend * (rOut - right)
        return (wetL * level, wetR * level)
    }

    /// Zavalishin's TPT state-variable low-pass, one stage.
    @inline(__always)
    private static func stage(
        _ x: Float,
        _ s1: inout Float,
        _ s2: inout Float,
        _ a1: Float,
        _ a2: Float,
        _ a3: Float
    ) -> Float {
        let v3 = x - s2
        let v1 = a1 * s1 + a2 * v3
        let v2 = s2 + a2 * s1 + a3 * v3
        s1 = 2 * v1 - s1
        s2 = 2 * v2 - s2
        return v2
    }

    @inline(__always)
    private mutating func advanceAmount(toward target: Float) {
        guard amount != target else { return }
        if amount < target {
            amount = min(target, amount + amountStepPerBlockEngage)
        } else {
            amount = max(target, amount - amountStepPerBlockRelease)
        }
        updateCoefficients()
    }

    /// Maps `amount` to cutoff, level and blend. Smoothstep so the glide eases
    /// in and out; exponential in frequency so it sounds even.
    private mutating func updateCoefficients() {
        let u = Double(amount)
        let shaped = u * u * (3 - 2 * u)
        let cutoff = openCutoff * pow(Self.closedCutoffHz / openCutoff, shaped)
        let g = tan(Double.pi * cutoff / sampleRate)
        let k = Double(Self.damping)
        let c1 = 1 / (1 + g * (g + k))
        let c2 = g * c1
        a1 = Float(c1)
        a2 = Float(c2)
        a3 = Float(g * c2)
        level = 1 + (Self.closedLevel - 1) * Float(shaped)
        // Fade from the exact dry signal into the (nearly transparent) open
        // filter over the first few percent of the glide, so leaving and
        // reaching rest are both seamless.
        blend = Float(min(1, shaped / 0.02))
    }

    /// Once per cycle: zero filter state that has decayed below audibility (on
    /// silence it otherwise settles into denormals, which are slow on Apple
    /// Silicon) or gone non-finite (one NaN from the tap would otherwise
    /// silence the rest of the take).
    @inline(__always)
    private mutating func flushFilterState() {
        @inline(__always) func clean(_ value: inout Float) {
            let magnitude = abs(value)
            if !(magnitude >= 1e-15 && magnitude <= 1e6) { value = 0 }
        }
        clean(&l1s1); clean(&l1s2); clean(&l2s1); clean(&l2s2)
        clean(&r1s1); clean(&r1s2); clean(&r2s1); clean(&r2s2)
    }
}

/// How the copy comes in at the cut.
///
/// The copy trails the original by `copyDelayFrames`: ~7 ms on wired outputs,
/// ~171 ms on AirPods, where the tap delivers the mix one output latency late.
/// Opening the copy the moment the originals are muted replays that much
/// music, which on AirPods is a clear repeat (heard 2026-10-06). So on a
/// lagging route the gate stays shut until the copy reaches the moment the
/// originals stopped, then fades in: the music drops out briefly and comes
/// back muffled where it left off, with nothing repeated. Short lags (wired
/// and built-in) keep the plain few-millisecond fade.
struct DictationMuffleSplice: Equatable {
    /// Above this lag the cut holds the copy back (the same line where the
    /// machine used to wait for a quiet moment).
    static let holdAboveLagSeconds: Double = 0.015
    /// Tap B mutes the originals about this long after the cut (lab-measured).
    static let muteLatencySeconds: Double = 0.0045
    /// The longest hold, so a bad lag reading can't leave a long silence.
    static let maxHoldSeconds: Double = 0.4
    /// The fade-in after a hold: long enough to come back in smoothly.
    static let heldFadeSeconds: Double = 0.02

    /// Frames the gate stays shut after the cut.
    var holdFrames: Int
    /// Frames the gate takes to open after the hold (0 means `gateSeconds`).
    var fadeFrames: Int

    static let plain = DictationMuffleSplice(holdFrames: 0, fadeFrames: 0)

    static func atCut(copyDelayFrames: Int?, sampleRate: Double) -> DictationMuffleSplice {
        guard sampleRate.isFinite, sampleRate > 0, let copyDelayFrames,
              Double(copyDelayFrames) > holdAboveLagSeconds * sampleRate else {
            return .plain
        }
        let hold = min(
            Double(copyDelayFrames) + muteLatencySeconds * sampleRate,
            maxHoldSeconds * sampleRate
        )
        return DictationMuffleSplice(
            holdFrames: Int(hold.rounded()),
            fadeFrames: max(1, Int((heldFadeSeconds * sampleRate).rounded()))
        )
    }
}

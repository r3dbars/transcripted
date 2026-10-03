// DictationMuffleFilter.swift
// The "outside the club" sound: a 4th-order low-pass (two cascaded RBJ
// biquads) at a few hundred hertz with a little gain cut, cross-faded with the
// untouched signal so muffle eases in and out instead of snapping.
//
// Runs on the CoreAudio IO thread, so nothing here allocates, locks, or calls
// into ObjC. All state is fixed-size stored properties.

import CoreAudio
import Foundation

struct DictationMuffleFilter {
    static let cutoffHz: Double = 450
    static let wetGain: Float = 0.7
    static let rampSeconds: Double = 0.18
    /// How fast the muffled copy fades in over the still-playing original at
    /// start, before the original is muted. Short enough that the brief
    /// overlap of the two is inaudible.
    static let handoffFadeSeconds: Double = 0.012

    private var b0: Float = 1
    private var b1: Float = 0
    private var b2: Float = 0
    private var a1: Float = 0
    private var a2: Float = 0
    // Transposed direct form II state: [channel][stage] -> (z1, z2).
    private var l1z1: Float = 0, l1z2: Float = 0, l2z1: Float = 0, l2z2: Float = 0
    private var r1z1: Float = 0, r1z2: Float = 0, r2z1: Float = 0, r2z2: Float = 0

    /// 0 is the untouched signal, 1 is fully muffled.
    private(set) var mix: Float = 0
    private var mixStep: Float = 1
    /// Overall output level, 0...1. Starts at 1 unless built `startSilent`.
    private(set) var outputGain: Float = 1
    private var gainStep: Float = 1

    init(sampleRate: Double, cutoffHz: Double = DictationMuffleFilter.cutoffHz, startSilent: Bool = false) {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        let cutoff = min(cutoffHz, rate * 0.45)
        let omega = 2 * Double.pi * cutoff / rate
        let alpha = sin(omega) / (2 * 0.7071)
        let cosw = cos(omega)
        let a0 = 1 + alpha
        b0 = Float((1 - cosw) / 2 / a0)
        b1 = Float((1 - cosw) / a0)
        b2 = b0
        a1 = Float(-2 * cosw / a0)
        a2 = Float((1 - alpha) / a0)
        mixStep = Float(1 / max(1, Self.rampSeconds * rate))
        gainStep = Float(1 / max(1, Self.handoffFadeSeconds * rate))
        outputGain = startSilent ? 0 : 1
    }

    /// Processes one stereo frame, moving `mix` one step toward `target`.
    /// Transposed direct form II; the loop-carried path is two fused
    /// multiply-adds per stage.
    @inline(__always)
    mutating func process(left: Float, right: Float, target: Float) -> (Float, Float) {
        if mix < target {
            mix = min(target, mix + mixStep)
        } else if mix > target {
            mix = max(target, mix - mixStep)
        }

        var y = l1z1.addingProduct(b0, left)
        l1z1 = l1z2.addingProduct(b1, left).addingProduct(-a1, y)
        l1z2 = (b2 * left).addingProduct(-a2, y)
        let lIn = y
        y = l2z1.addingProduct(b0, lIn)
        l2z1 = l2z2.addingProduct(b1, lIn).addingProduct(-a1, y)
        l2z2 = (b2 * lIn).addingProduct(-a2, y)
        let lWet = y

        y = r1z1.addingProduct(b0, right)
        r1z1 = r1z2.addingProduct(b1, right).addingProduct(-a1, y)
        r1z2 = (b2 * right).addingProduct(-a2, y)
        let rIn = y
        y = r2z1.addingProduct(b0, rIn)
        r2z1 = r2z2.addingProduct(b1, rIn).addingProduct(-a1, y)
        r2z2 = (b2 * rIn).addingProduct(-a2, y)
        let rWet = y

        let dry = 1 - mix
        let wet = mix * Self.wetGain
        return (dry * left + wet * lWet, dry * right + wet * rWet)
    }

    /// Reads the tap's audio from `input`, muffles it, and writes it to
    /// `output`. Handles interleaved or split Float32 buffers on either side:
    /// mono input feeds both sides, a mono output gets the average, and
    /// output channels past the second are silenced. A missing or short input
    /// renders as silence rather than stale memory.
    ///
    /// `gainTarget` fades the whole output toward 0 or 1 over
    /// `handoffFadeSeconds`. Returns true when the input carried any nonzero
    /// sample, which is how the muffler knows the tap is really flowing.
    ///
    /// The buffer layout is resolved once per IO cycle, not per frame:
    /// UnsafeMutableAudioBufferListPointer's collection methods don't inline
    /// across modules, and walking them per frame cost about 3x the filter.
    @discardableResult
    mutating func render(
        input: UnsafePointer<AudioBufferList>?,
        output: UnsafeMutablePointer<AudioBufferList>?,
        target: Float,
        gainTarget: Float = 1
    ) -> Bool {
        guard let output else { return false }
        let outList = UnsafeMutableAudioBufferListPointer(output)
        let outCount = outList.count
        guard outCount > 0 else { return false }

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
            // Zero first so channels past the second, and any frames the
            // input can't cover, are silence.
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
        guard let outL, frames != Int.max, frames > 0 else { return false }
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

        var gain = outputGain
        let step = gainStep
        var sawSignal = false
        for frame in 0..<frames {
            var left: Float = 0
            var right: Float = 0
            if frame < inputFrames, let inL, let inR {
                left = inL[frame &* inLStride]
                right = inR[frame &* inRStride]
                if left != 0 || right != 0 { sawSignal = true }
            }
            if gain < gainTarget {
                gain = min(gainTarget, gain + step)
            } else if gain > gainTarget {
                gain = max(gainTarget, gain - step)
            }
            let (outLeft, outRight) = process(left: left, right: right, target: target)
            if monoOut {
                outL[frame &* outLStride] = (outLeft + outRight) * 0.5 * gain
            } else {
                outL[frame &* outLStride] = outLeft * gain
                outR?[frame &* outRStride] = outRight * gain
            }
        }
        outputGain = gain
        flushFilterState()
        return sawSignal
    }

    /// Once per cycle: zero filter state that has decayed below audibility
    /// (on silence it otherwise settles into denormals, which are slow on
    /// Apple Silicon) or gone non-finite (one NaN from the tap would
    /// otherwise silence the rest of the take).
    @inline(__always)
    private mutating func flushFilterState() {
        @inline(__always) func clean(_ value: inout Float) {
            let magnitude = abs(value)
            if !(magnitude >= 1e-15 && magnitude <= 1e6) { value = 0 }
        }
        clean(&l1z1); clean(&l1z2); clean(&l2z1); clean(&l2z2)
        clean(&r1z1); clean(&r1z2); clean(&r2z1); clean(&r2z2)
    }
}

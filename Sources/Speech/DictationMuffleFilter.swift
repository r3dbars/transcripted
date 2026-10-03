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

    init(sampleRate: Double, cutoffHz: Double = DictationMuffleFilter.cutoffHz) {
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
    }

    /// Processes one stereo frame, moving `mix` one step toward `target`.
    @inline(__always)
    mutating func process(left: Float, right: Float, target: Float) -> (Float, Float) {
        if mix < target {
            mix = min(target, mix + mixStep)
        } else if mix > target {
            mix = max(target, mix - mixStep)
        }

        var y = b0 * left + l1z1
        l1z1 = b1 * left - a1 * y + l1z2
        l1z2 = b2 * left - a2 * y
        let lIn = y
        y = b0 * lIn + l2z1
        l2z1 = b1 * lIn - a1 * y + l2z2
        l2z2 = b2 * lIn - a2 * y
        let lWet = y

        y = b0 * right + r1z1
        r1z1 = b1 * right - a1 * y + r1z2
        r1z2 = b2 * right - a2 * y
        let rIn = y
        y = b0 * rIn + r2z1
        r2z1 = b1 * rIn - a1 * y + r2z2
        r2z2 = b2 * rIn - a2 * y
        let rWet = y

        let dry = 1 - mix
        let wet = mix * Self.wetGain
        return (dry * left + wet * lWet, dry * right + wet * rWet)
    }

    /// Reads the tap's audio from `input`, muffles it, and writes it to every
    /// channel of `output`. Handles interleaved or split Float32 buffers on
    /// either side: mono input feeds both sides, a mono output gets the
    /// average, and output channels past the second are silenced. A missing
    /// or short input renders as silence rather than stale memory.
    mutating func render(
        input: UnsafePointer<AudioBufferList>?,
        output: UnsafeMutablePointer<AudioBufferList>?,
        target: Float
    ) {
        guard let output else { return }
        let outBuffers = UnsafeMutableAudioBufferListPointer(output)
        guard outBuffers.count > 0 else { return }
        let firstOut = outBuffers[0]
        let firstOutChannels = Int(max(1, firstOut.mNumberChannels))
        let frames = Int(firstOut.mDataByteSize) / (MemoryLayout<Float>.size * firstOutChannels)

        let inBuffers = input.map { UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: $0)) }
        let inputFrames = inBuffers.map(Self.frameCount(of:)) ?? 0
        let totalOutChannels = outBuffers.reduce(0) { $0 + Int($1.mNumberChannels) }

        for frame in 0..<frames {
            var left: Float = 0
            var right: Float = 0
            if frame < inputFrames, let inBuffers {
                (left, right) = Self.readStereo(inBuffers, frame: frame)
            }
            let (outL, outR) = process(left: left, right: right, target: target)

            var globalChannel = 0
            for buffer in outBuffers {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                    globalChannel += channels
                    continue
                }
                let bufferFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                guard frame < bufferFrames else {
                    globalChannel += channels
                    continue
                }
                for channel in 0..<channels {
                    let value: Float
                    if totalOutChannels == 1 {
                        value = (outL + outR) * 0.5
                    } else if globalChannel == 0 {
                        value = outL
                    } else if globalChannel == 1 {
                        value = outR
                    } else {
                        value = 0
                    }
                    data[frame * channels + channel] = value
                    globalChannel += 1
                }
            }
        }
    }

    @inline(__always)
    private static func frameCount(of buffers: UnsafeMutableAudioBufferListPointer) -> Int {
        guard buffers.count > 0 else { return 0 }
        var frames = Int.max
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, buffer.mData != nil else { return 0 }
            frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
        }
        return frames == Int.max ? 0 : frames
    }

    @inline(__always)
    private static func readStereo(_ buffers: UnsafeMutableAudioBufferListPointer, frame: Int) -> (Float, Float) {
        let first = buffers[0]
        let firstChannels = Int(first.mNumberChannels)
        guard let firstData = first.mData?.assumingMemoryBound(to: Float.self) else { return (0, 0) }
        if firstChannels >= 2 {
            let base = frame * firstChannels
            return (firstData[base], firstData[base + 1])
        }
        let left = firstData[frame]
        if buffers.count >= 2,
           Int(buffers[1].mNumberChannels) >= 1,
           let secondData = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
            return (left, secondData[frame * Int(buffers[1].mNumberChannels)])
        }
        return (left, left)
    }
}

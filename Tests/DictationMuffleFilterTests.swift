import CoreAudio
import Foundation

func testDictationMuffleFilter() {
    let sampleRate = 48_000.0
    let block = DictationMuffleFilter.controlBlockFrames

    runSuite("At rest the muffle filter is a bit-exact passthrough for interleaved stereo") {
        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        let mismatches = muffleCountPassthroughMismatches(&filter, inputLayout: [2], outputLayout: [2], cycles: 20, startFrame: 0)
        assertEqual(mismatches, 0, "interleaved stereo at rest should be untouched")
        assertEqual(filter.amount, 0, "amount should stay 0 at rest")
    }

    runSuite("At rest the muffle filter is a bit-exact passthrough for split stereo") {
        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        let mismatches = muffleCountPassthroughMismatches(&filter, inputLayout: [1, 1], outputLayout: [1, 1], cycles: 20, startFrame: 0)
        assertEqual(mismatches, 0, "split stereo at rest should be untouched")
    }

    runSuite("After a full release the muffle filter is a bit-exact passthrough again") {
        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        var frame = 0
        // Engage fully, then release well past releaseSeconds.
        for _ in 0..<50 { _ = muffleRenderSignal(&filter, startFrame: frame, frames: 512, muffle: 1, gate: 1); frame += 512 }
        assertTrue(filter.amount > 0.99, "should be fully muffled before the release, amount \(filter.amount)")
        let releaseCycles = Int(((DictationMuffleFilter.releaseSeconds + 0.2) * sampleRate) / 512) + 1
        for _ in 0..<releaseCycles { _ = muffleRenderSignal(&filter, startFrame: frame, frames: 512, muffle: 0, gate: 1); frame += 512 }
        assertEqual(filter.amount, 0, "amount should be back to 0 after the release")
        let interleaved = muffleCountPassthroughMismatches(&filter, inputLayout: [2], outputLayout: [2], cycles: 4, startFrame: frame)
        assertEqual(interleaved, 0, "released filter should pass interleaved stereo untouched")
        let split = muffleCountPassthroughMismatches(&filter, inputLayout: [1, 1], outputLayout: [1, 1], cycles: 4, startFrame: frame + 4 * 512)
        assertEqual(split, 0, "released filter should pass split stereo untouched")
    }

    runSuite("Fully muffled, 5 kHz drops more than 60 dB") {
        let level = muffleSettledLevelDB(frequencyHz: 5_000, sampleRate: sampleRate)
        assertTrue(level.left < -60, "5 kHz left should be below -60 dB, got \(level.left) dB")
        assertTrue(level.right < -60, "5 kHz right should be below -60 dB, got \(level.right) dB")
    }

    runSuite("Fully muffled, 1 kHz drops more than 20 dB") {
        let level = muffleSettledLevelDB(frequencyHz: 1_000, sampleRate: sampleRate)
        assertTrue(level.left < -20, "1 kHz left should be below -20 dB, got \(level.left) dB")
        assertTrue(level.right < -20, "1 kHz right should be below -20 dB, got \(level.right) dB")
    }

    runSuite("Fully muffled, 100 Hz keeps about the closed level") {
        let level = muffleSettledLevelDB(frequencyHz: 100, sampleRate: sampleRate)
        let expected = DictationMuffleFilter.closedLevel
        for (side, db) in [("left", level.left), ("right", level.right)] {
            let ratio = Float(pow(10, db / 20))
            assertTrue(abs(ratio - expected) <= 0.1, "100 Hz \(side) should sit at \(expected) +/- 0.1 of input RMS, got \(ratio)")
        }
    }

    runSuite("The muffle glides in over about engageSeconds instead of jumping") {
        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        let engageFrames = Int(DictationMuffleFilter.engageSeconds * sampleRate)
        let slack = 4 * block
        var frame = 0
        var reachedAt: Int?
        var amountAtHalf: Float = -1
        var amountAfterFirstBlock: Float = -1
        while frame < engageFrames * 2 {
            _ = muffleRenderSignal(&filter, startFrame: frame, frames: block, muffle: 1, gate: 1)
            frame += block
            if frame == block { amountAfterFirstBlock = filter.amount }
            if amountAtHalf < 0, frame >= engageFrames / 2 { amountAtHalf = filter.amount }
            if reachedAt == nil, filter.amount >= 0.999 { reachedAt = frame }
        }
        assertTrue(amountAfterFirstBlock >= 0 && amountAfterFirstBlock < 0.05, "amount should barely move after one block, got \(amountAfterFirstBlock)")
        assertTrue(amountAtHalf > 0.05 && amountAtHalf < 0.95, "amount should be mid-glide halfway through, got \(amountAtHalf)")
        guard let reachedAt else {
            assertTrue(false, "amount never reached 1 within twice engageSeconds, last \(filter.amount)")
            return
        }
        assertTrue(abs(reachedAt - engageFrames) <= slack, "amount should reach 1 after about \(engageFrames) frames, reached at \(reachedAt)")
    }

    runSuite("The muffle glides back out over about releaseSeconds") {
        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        let releaseFrames = Int(DictationMuffleFilter.releaseSeconds * sampleRate)
        let slack = 4 * block
        var frame = 0
        for _ in 0..<50 { _ = muffleRenderSignal(&filter, startFrame: frame, frames: 512, muffle: 1, gate: 1); frame += 512 }
        assertTrue(filter.amount > 0.999, "should start fully muffled, amount \(filter.amount)")
        var released = 0
        var reachedAt: Int?
        var amountAtHalf: Float = -1
        while released < releaseFrames * 2 {
            _ = muffleRenderSignal(&filter, startFrame: frame, frames: block, muffle: 0, gate: 1)
            frame += block
            released += block
            if amountAtHalf < 0, released >= releaseFrames / 2 { amountAtHalf = filter.amount }
            if reachedAt == nil, filter.amount <= 0.001 { reachedAt = released }
        }
        assertTrue(amountAtHalf > 0.05 && amountAtHalf < 0.95, "amount should be mid-glide halfway through the release, got \(amountAtHalf)")
        guard let reachedAt else {
            assertTrue(false, "amount never returned to 0 within twice releaseSeconds, last \(filter.amount)")
            return
        }
        assertTrue(abs(reachedAt - releaseFrames) <= slack, "amount should reach 0 after about \(releaseFrames) frames, reached at \(reachedAt)")
    }

    runSuite("The muffle glide never notches a tone below its final muffled level") {
        for frequency in [300.0, 450.0, 700.0] {
            var filter = DictationMuffleFilter(sampleRate: sampleRate)
            let window = 480  // 10 ms: whole periods of sin^2 for 300, 450 and 700 Hz
            var frame = 0
            for _ in 0..<10 {
                _ = muffleRenderSine(&filter, frequencyHz: frequency, sampleRate: sampleRate, startFrame: frame, frames: window, muffle: 0)
                frame += window
            }
            var glideLevels: [Double] = []
            var guardCycles = 0
            while filter.amount < 0.999, guardCycles < 200 {
                let level = muffleRenderSine(&filter, frequencyHz: frequency, sampleRate: sampleRate, startFrame: frame, frames: window, muffle: 1)
                glideLevels.append(level.left)
                frame += window
                guardCycles += 1
            }
            for _ in 0..<30 {
                _ = muffleRenderSine(&filter, frequencyHz: frequency, sampleRate: sampleRate, startFrame: frame, frames: window, muffle: 1)
                frame += window
            }
            var finalSum = 0.0
            for _ in 0..<20 {
                finalSum += muffleRenderSine(&filter, frequencyHz: frequency, sampleRate: sampleRate, startFrame: frame, frames: window, muffle: 1).left
                frame += window
            }
            let finalLevel = finalSum / 20
            let lowest = glideLevels.min() ?? 0
            assertTrue(glideLevels.count > 5, "\(frequency) Hz glide should span several windows, got \(glideLevels.count)")
            assertTrue(
                lowest >= finalLevel - 1,
                "\(frequency) Hz dipped to \(lowest) dB mid-glide, more than 1 dB under its final \(finalLevel) dB"
            )
        }
    }

    runSuite("A gated start fades the copy in within gateSeconds plus one control block, and out the same way") {
        var filter = DictationMuffleFilter(sampleRate: sampleRate, startGated: true)
        let budget = Int(DictationMuffleFilter.gateSeconds * sampleRate) + block
        let level: Float = 0.5
        let frames = 1_024
        let constant = [Float](repeating: level, count: frames)
        let fadeIn = muffleRender(&filter, input: [constant, constant], inputLayout: [2], outputLayout: [2], muffle: 0, gate: 1)
        let firstOut = fadeIn.out[0][0]
        assertTrue(abs(firstOut) <= 0.1 * level, "first gated sample should be about 0, got \(firstOut)")
        let fullAt = fadeIn.out[0].firstIndex { abs($0 - level) <= 5e-5 }
        assertNotNil(fullAt, "gate should reach full level within the cycle")
        if let fullAt {
            assertTrue(fullAt <= budget, "gate should reach full level within \(budget) frames, reached at \(fullAt)")
            let tail = fadeIn.out[0][fullAt...].allSatisfy { abs($0 - level) <= 5e-5 }
            assertTrue(tail, "gate should stay fully open once it gets there")
        }
        let intermediate = fadeIn.out[0].contains { $0 > 0.05 * level && $0 < 0.95 * level }
        assertTrue(intermediate, "gate should fade, not step")

        let fadeOut = muffleRender(&filter, input: [constant, constant], inputLayout: [2], outputLayout: [2], muffle: 0, gate: 0)
        let silentAt = fadeOut.out[0].firstIndex { abs($0) <= 5e-5 }
        assertNotNil(silentAt, "gate should close within the cycle")
        if let silentAt {
            assertTrue(silentAt <= budget, "gate should close within \(budget) frames, closed at \(silentAt)")
            let tail = fadeOut.out[0][silentAt...].allSatisfy { abs($0) <= 5e-5 } && fadeOut.out[1][silentAt...].allSatisfy { abs($0) <= 5e-5 }
            assertTrue(tail, "gate should stay closed once shut")
        }
        assertTrue(fadeOut.out[0][0] > 0.5 * level, "gate should fade out from open, not drop at once, got \(fadeOut.out[0][0])")
    }

    runSuite("Handback cannot pair an open snapshot with cleared splice parameters") {
        let gate = DictationMuffleGate()
        let splice = DictationMuffleSplice(holdFrames: 4_096, fadeFrames: 4_096)
        gate.cut(splice)
        let admitted = gate.snapshot()
        gate.handBack() // controlled queue/IO interleaving after callback admission
        var filter = DictationMuffleFilter(sampleRate: sampleRate, startGated: true)
        let samples = [Float](repeating: 0.5, count: 128)
        let out = muffleRender(&filter, input: [samples, samples], inputLayout: [2], outputLayout: [2], muffle: admitted.isMuffled ? 1 : 0, gate: admitted.isOpen ? 1 : 0, gateHoldFrames: admitted.holdFrames, gateFadeFrames: admitted.fadeFrames).out[0]
        assertTrue(out.allSatisfy { $0 == 0 }, "the already admitted held callback stays silent after handback")
        gate.consume(admitted, frames: 128)
        assertEqual(gate.snapshot().isOpen, false, "old callback cannot reopen a handed-back command")
        assertEqual(gate.snapshot().holdFrames, 0, "closed callbacks have no hold")
        assertEqual(gate.snapshot().fadeFrames, 0, "closed callbacks keep the short closing fade")
        assertEqual(admitted.holdFrames, splice.holdFrames, "admitted hold survives later publication")
        assertEqual(admitted.fadeFrames, splice.fadeFrames, "admitted fade survives later publication")
    }

    runSuite("An old callback cannot count down an identical re-cut") {
        let gate = DictationMuffleGate()
        let splice = DictationMuffleSplice(holdFrames: 4_096, fadeFrames: 4_096)
        gate.cut(splice)
        let previous = gate.snapshot()
        gate.handBack()
        gate.cut(splice)
        gate.consume(previous, frames: 512)
        assertEqual(gate.snapshot().holdFrames, 4_096, "new cut keeps its complete hold despite identical parameters")
        gate.consume(gate.snapshot(), frames: 512)
        assertEqual(gate.snapshot().holdFrames, 3_584, "current callback consumes exactly its rendered frames")
        gate.setMuffled(false)
        assertEqual(gate.snapshot().holdFrames, 3_584, "muffle updates preserve the IO countdown")
        assertEqual(gate.snapshot().isMuffled, false, "muffle updates change the target")
        gate.consume(gate.snapshot(), frames: 10_000)
        assertEqual(gate.snapshot().holdFrames, 0, "the countdown stops at zero")
        assertEqual(gate.snapshot().fadeFrames, 4_096, "countdown leaves the swell duration unchanged")
        gate.cut(.plain)
        assertEqual(gate.snapshot().isMuffled, false, "plain cuts retain the dry glide")
        assertEqual(gate.snapshot().holdFrames, 0, "plain cuts have no hold")
        assertEqual(gate.snapshot().fadeFrames, 0, "plain cuts use the ordinary fade")
    }

    runSuite("A held re-cut closes the stale copy with the short gate step") {
        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        let samples = [Float](repeating: 0.5, count: 512)
        _ = muffleRender(&filter, input: [samples, samples], inputLayout: [2], outputLayout: [2], muffle: 0, gate: 0, frames: 32)
        let out = muffleRender(&filter, input: [samples, samples], inputLayout: [2], outputLayout: [2], muffle: 1, gate: 1, gateHoldFrames: 4_096, gateFadeFrames: 4_096).out[0]
        let closeFrames = Int((DictationMuffleFilter.gateSeconds * sampleRate).rounded()) + block
        assertTrue(out.dropFirst(closeFrames).allSatisfy { $0 == 0 }, "re-cut shuts stale audio within the ordinary closing fade")
        assertEqual(filter.gate, 0, "held re-cut ends the cycle shut")
    }

    runSuite("A short copy lag cuts with the plain gate fade; an AirPods-size lag holds the copy back by the lag first") {
        let wired = DictationMuffleSplice.atCut(copyDelayFrames: 346, sampleRate: sampleRate)
        assertEqual(wired, .plain, "a 7 ms wired lag keeps the plain fade")
        assertEqual(DictationMuffleSplice.atCut(copyDelayFrames: nil, sampleRate: sampleRate), .plain, "an unknown lag keeps the plain fade")
        let airPods = DictationMuffleSplice.atCut(copyDelayFrames: 8_198, sampleRate: sampleRate)
        let extraFrames = Int(((DictationMuffleSplice.muteLatencySeconds + DictationMuffleSplice.skipSideMarginSeconds) * sampleRate).rounded())
        let catchUp = 8_198 + extraFrames
        assertEqual(airPods.holdFrames + airPods.fadeFrames, catchUp, "the fade-in ends exactly where the originals stopped, so nothing plays twice at full level")
        assertTrue(airPods.holdFrames > 0 && airPods.holdFrames < catchUp, "part silence, part swell, hold \(airPods.holdFrames)")
        assertTrue(airPods.fadeFrames >= Int((DictationMuffleSplice.heldFadeSeconds * sampleRate).rounded()), "the swell is never shorter than the plain held fade")
        let capped = DictationMuffleSplice.atCut(copyDelayFrames: 1_000_000, sampleRate: sampleRate)
        assertEqual(capped.holdFrames + capped.fadeFrames, Int((DictationMuffleSplice.maxHoldSeconds * sampleRate).rounded()), "a wild lag reading can't leave a long silence")
        assertEqual(DictationMuffleSplice.atCut(copyDelayFrames: 8_198, sampleRate: 0), .plain, "no sample rate, no hold")
    }

    runSuite("A held copy near the lag threshold reaches its muffle target before any audible swell") {
        for lag in [15.1, 16.0, 17.5, 18.0, 171.0] {
            let splice = DictationMuffleSplice.atCut(
                copyDelayFrames: Int((lag * sampleRate / 1_000).rounded()), sampleRate: sampleRate
            )
            var filter = DictationMuffleFilter(sampleRate: sampleRate, startGated: true)
            let samples = [Float](repeating: 0.5, count: splice.holdFrames + 128)
            let output = muffleRender(
                &filter, input: [samples, samples], inputLayout: [2], outputLayout: [2],
                muffle: splice.startsMuffled ? 1 : 0, gate: 1,
                gateHoldFrames: splice.holdFrames, gateFadeFrames: splice.fadeFrames
            ).out[0]
            assertTrue(output.prefix(splice.holdFrames).allSatisfy { $0 == 0 }, "held copy stays silent")
            assertTrue(output.dropFirst(splice.holdFrames).contains { $0 != 0 }, "the swell is audible after the hold")
            assertEqual(filter.amount, 1, "held copy is already muffled at \(lag) ms without waiting for a machine tick")
        }
        assertEqual(DictationMuffleSplice.plain.startsMuffled, false, "wired/plain cuts retain their delayed glide")
    }

    runSuite("A held gate stays silent for the hold, then fades in over the fade length") {
        let holdFrames = 300
        let fadeFrames = 200
        var filter = DictationMuffleFilter(sampleRate: sampleRate, startGated: true)
        let level: Float = 0.5
        let constant = [Float](repeating: level, count: 1_024)
        let out = muffleRender(
            &filter, input: [constant, constant], inputLayout: [2], outputLayout: [2],
            muffle: 0, gate: 1, gateHoldFrames: holdFrames, gateFadeFrames: fadeFrames
        ).out
        assertTrue(out[0][..<holdFrames].allSatisfy { $0 == 0 } && out[1][..<holdFrames].allSatisfy { $0 == 0 }, "silent through the hold")
        let halfway = out[0][holdFrames + fadeFrames / 2]
        assertTrue(halfway > 0.4 * level && halfway < 0.6 * level, "half level halfway through the fade, got \(halfway)")
        let fullAt = out[0].firstIndex { abs($0 - level) <= 5e-5 }
        assertNotNil(fullAt, "gate should reach full level within the cycle")
        if let fullAt {
            assertTrue(abs(fullAt - (holdFrames + fadeFrames)) <= 2, "full level at the end of the fade, reached at \(fullAt)")
        }
    }

    runSuite("Across many IO cycles a held copy opens exactly when the hold runs out") {
        let cycle = 128
        let splice = DictationMuffleSplice.atCut(copyDelayFrames: 8_198, sampleRate: sampleRate)
        var filter = DictationMuffleFilter(sampleRate: sampleRate, startGated: true)
        let constant = [Float](repeating: 0.5, count: cycle)
        var hold = splice.holdFrames
        var firstSoundAt: Int?
        var rendered = 0
        while rendered < splice.holdFrames + 4 * cycle, firstSoundAt == nil {
            let out = muffleRender(
                &filter, input: [constant, constant], inputLayout: [2], outputLayout: [2],
                muffle: 0, gate: 1, gateHoldFrames: hold, gateFadeFrames: splice.fadeFrames
            ).out[0]
            if let index = out.firstIndex(where: { $0 != 0 }) { firstSoundAt = rendered + index }
            hold = DictationMuffleSplice.remainingHold(hold, afterFrames: cycle)
            rendered += cycle
        }
        assertEqual(firstSoundAt, splice.holdFrames, "the copy should open on the first frame after the hold")
        assertEqual(DictationMuffleSplice.remainingHold(100, afterFrames: 512), 0, "a hold never goes negative")
        assertEqual(DictationMuffleSplice.remainingHold(600, afterFrames: 512), 88, "a hold counts down by the frames rendered")
    }

    runSuite("While the gate is held shut the filter jumps to its muffle target, so the copy comes back fully muffled") {
        var filter = DictationMuffleFilter(sampleRate: sampleRate, startGated: true)
        let constant = [Float](repeating: 0.5, count: 512)
        _ = muffleRender(
            &filter, input: [constant, constant], inputLayout: [2], outputLayout: [2],
            muffle: 1, gate: 1, gateHoldFrames: 4_096, gateFadeFrames: 960
        )
        assertEqual(filter.amount, 1, "fully muffled before the gate opens")
        var gliding = DictationMuffleFilter(sampleRate: sampleRate, startGated: false)
        _ = muffleRender(&gliding, input: [constant, constant], inputLayout: [2], outputLayout: [2], muffle: 1, gate: 1)
        assertTrue(gliding.amount < 1, "an open gate still glides, got \(gliding.amount)")
    }

    runSuite("render returns the cycle's input peak, and 0 for silence or no input") {
        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        var left = [Float](repeating: 0.1, count: 256)
        var right = [Float](repeating: -0.2, count: 256)
        left[40] = 0.7
        right[100] = -0.9
        let peak = muffleRender(&filter, input: [left, right], inputLayout: [2], outputLayout: [2], muffle: 0, gate: 1).peak
        assertEqual(peak, 0.9, "peak should be the max absolute sample across both channels")
        let splitPeak = muffleRender(&filter, input: [left, right], inputLayout: [1, 1], outputLayout: [2], muffle: 1, gate: 1).peak
        assertEqual(splitPeak, 0.9, "peak should not depend on layout or muffle")
        let silence = [Float](repeating: 0, count: 256)
        assertEqual(muffleRender(&filter, input: [silence, silence], inputLayout: [2], outputLayout: [2], muffle: 0, gate: 1).peak, 0, "silence peak")
        assertEqual(muffleRender(&filter, input: nil, inputLayout: [], outputLayout: [2], muffle: 0, gate: 1, frames: 256).peak, 0, "nil input peak")
    }

    runSuite("A mono output gets the average of left and right") {
        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        let left = muffleTestSignal(seed: 1, startFrame: 0, frames: 512)
        let right = muffleTestSignal(seed: 2, startFrame: 0, frames: 512)
        let result = muffleRender(&filter, input: [left, right], inputLayout: [2], outputLayout: [1], muffle: 0, gate: 1, prefill: 0.25)
        var maxError: Float = 0
        for i in 0..<512 { maxError = max(maxError, abs(result.out[0][i] - (left[i] + right[i]) * 0.5)) }
        assertTrue(maxError <= 1e-6, "mono output should be (L+R)/2, max error \(maxError)")
    }

    runSuite("Output channels past the second are silent") {
        for layout in [[1, 1, 1, 1], [4]] {
            var filter = DictationMuffleFilter(sampleRate: sampleRate)
            let left = muffleTestSignal(seed: 1, startFrame: 0, frames: 256)
            let right = muffleTestSignal(seed: 2, startFrame: 0, frames: 256)
            let result = muffleRender(&filter, input: [left, right], inputLayout: [2], outputLayout: layout, muffle: 0, gate: 1, prefill: 0.25)
            assertEqual(result.out[0], left, "layout \(layout): channel 0 should carry left")
            assertEqual(result.out[1], right, "layout \(layout): channel 1 should carry right")
            assertTrue(result.out[2].allSatisfy { $0 == 0 }, "layout \(layout): channel 2 should be zero")
            assertTrue(result.out[3].allSatisfy { $0 == 0 }, "layout \(layout): channel 3 should be zero")
        }
    }

    runSuite("A nil input renders zeros") {
        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        let result = muffleRender(&filter, input: nil, inputLayout: [], outputLayout: [2], muffle: 0, gate: 1, prefill: 0.25, frames: 256)
        assertTrue(result.out[0].allSatisfy { $0 == 0 } && result.out[1].allSatisfy { $0 == 0 }, "nil input should render silence over a prefilled buffer")
        let split = muffleRender(&filter, input: nil, inputLayout: [], outputLayout: [1, 1], muffle: 1, gate: 1, prefill: 0.25, frames: 256)
        assertTrue(split.out[0].allSatisfy { $0 == 0 } && split.out[1].allSatisfy { $0 == 0 }, "nil input should render silence while muffled too")
    }

    runSuite("Two mono input buffers are read as left and right") {
        var filter = DictationMuffleFilter(sampleRate: sampleRate)
        let left = muffleTestSignal(seed: 3, startFrame: 0, frames: 512)
        let right = muffleTestSignal(seed: 4, startFrame: 0, frames: 512)
        let result = muffleRender(&filter, input: [left, right], inputLayout: [1, 1], outputLayout: [2], muffle: 0, gate: 1, prefill: 0.25)
        assertEqual(result.out[0], left, "first mono buffer should be left")
        assertEqual(result.out[1], right, "second mono buffer should be right")
    }

    runSuite("A NaN or Inf input never makes non-finite output and doesn't silence later cycles") {
        for muffle: Float in [0, 1] {
            var filter = DictationMuffleFilter(sampleRate: sampleRate)
            var frame = 0
            for _ in 0..<50 {
                _ = muffleRenderSine(&filter, frequencyHz: 100, sampleRate: sampleRate, startFrame: frame, frames: 480, muffle: muffle)
                frame += 480
            }
            var left = muffleSine(frequencyHz: 100, sampleRate: sampleRate, startFrame: frame, frames: 480)
            var right = left
            left[10] = .nan
            right[20] = .infinity
            left[30] = -.infinity
            let poisoned = muffleRender(&filter, input: [left, right], inputLayout: [2], outputLayout: [2], muffle: muffle, gate: 1)
            frame += 480
            let poisonedFinite = poisoned.out.allSatisfy { $0.allSatisfy { $0.isFinite } }
            assertTrue(poisonedFinite, "muffle \(muffle): a NaN/Inf cycle should still render finite samples")
            var laterFinite = true
            var lastLevel = -200.0
            for _ in 0..<10 {
                let signal = muffleSine(frequencyHz: 100, sampleRate: sampleRate, startFrame: frame, frames: 480)
                let result = muffleRender(&filter, input: [signal, signal], inputLayout: [2], outputLayout: [2], muffle: muffle, gate: 1)
                laterFinite = laterFinite && result.out.allSatisfy { $0.allSatisfy { $0.isFinite } }
                lastLevel = muffleLevelDB(output: result.out[0], input: signal)
                frame += 480
            }
            assertTrue(laterFinite, "muffle \(muffle): later cycles should stay finite")
            assertTrue(lastLevel > -6, "muffle \(muffle): later cycles should carry the tone again, got \(lastLevel) dB")
        }
    }
}

// MARK: - Helpers

private struct MuffleRenderResult {
    var peak: Float
    var out: [[Float]]
}

/// Owns an AudioBufferList whose buffers carry `layout[i]` interleaved
/// channels each; channels are addressed in order across buffers.
private final class MuffleBufferList {
    let list: UnsafeMutableAudioBufferListPointer
    let layout: [Int]
    let frames: Int
    private let storage: [UnsafeMutablePointer<Float>]

    init(layout: [Int], frames: Int, fill: Float) {
        self.layout = layout
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: max(1, layout.count))
        var buffers: [UnsafeMutablePointer<Float>] = []
        for (index, channels) in layout.enumerated() {
            let count = max(1, channels * frames)
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            pointer.initialize(repeating: fill, count: count)
            buffers.append(pointer)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(channels * frames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(pointer)
            )
        }
        storage = buffers
    }

    deinit {
        for pointer in storage { pointer.deallocate() }
        free(list.unsafeMutablePointer)
    }

    var channelCount: Int { layout.reduce(0, +) }

    private func locate(_ channel: Int) -> (buffer: Int, offset: Int, stride: Int) {
        var remaining = channel
        for (index, channels) in layout.enumerated() {
            if remaining < channels { return (index, remaining, channels) }
            remaining -= channels
        }
        preconditionFailure("channel \(channel) out of range for layout \(layout)")
    }

    subscript(channel: Int, frame: Int) -> Float {
        get {
            let spot = locate(channel)
            return storage[spot.buffer][frame * spot.stride + spot.offset]
        }
        set {
            let spot = locate(channel)
            storage[spot.buffer][frame * spot.stride + spot.offset] = newValue
        }
    }
}

private func muffleRender(
    _ filter: inout DictationMuffleFilter,
    input: [[Float]]?,
    inputLayout: [Int],
    outputLayout: [Int],
    muffle: Float,
    gate: Float,
    prefill: Float = 0,
    frames explicitFrames: Int? = nil,
    gateHoldFrames: Int = 0,
    gateFadeFrames: Int = 0
) -> MuffleRenderResult {
    let frames = explicitFrames ?? input?.first?.count ?? 0
    let outList = MuffleBufferList(layout: outputLayout, frames: frames, fill: prefill)
    var peak: Float = 0
    if let input {
        let inList = MuffleBufferList(layout: inputLayout, frames: frames, fill: 0)
        for channel in 0..<min(inList.channelCount, input.count) {
            for frame in 0..<frames { inList[channel, frame] = input[channel][frame] }
        }
        peak = filter.render(input: UnsafePointer(inList.list.unsafeMutablePointer), output: outList.list.unsafeMutablePointer, muffleTarget: muffle, gateTarget: gate, gateHoldFrames: gateHoldFrames, gateFadeFrames: gateFadeFrames)
    } else {
        peak = filter.render(input: nil, output: outList.list.unsafeMutablePointer, muffleTarget: muffle, gateTarget: gate, gateHoldFrames: gateHoldFrames, gateFadeFrames: gateFadeFrames)
    }
    var out: [[Float]] = []
    for channel in 0..<outList.channelCount {
        out.append((0..<frames).map { outList[channel, $0] })
    }
    return MuffleRenderResult(peak: peak, out: out)
}

/// A deterministic, broadband test signal (no exact zeros).
private func muffleTestSignal(seed: Int, startFrame: Int, frames: Int) -> [Float] {
    (0..<frames).map { offset in
        let n = Double(startFrame + offset)
        let s = Double(seed)
        return Float(0.45 * sin(0.37 * n + s) + 0.3 * sin(1.91 * n + 2 * s) + 0.1 * sin(2.83 * n + 0.5) + 0.001)
    }
}

private func muffleRenderSignal(_ filter: inout DictationMuffleFilter, startFrame: Int, frames: Int, muffle: Float, gate: Float) -> MuffleRenderResult {
    let left = muffleTestSignal(seed: 1, startFrame: startFrame, frames: frames)
    let right = muffleTestSignal(seed: 2, startFrame: startFrame, frames: frames)
    return muffleRender(&filter, input: [left, right], inputLayout: [2], outputLayout: [2], muffle: muffle, gate: gate)
}

private func muffleCountPassthroughMismatches(
    _ filter: inout DictationMuffleFilter,
    inputLayout: [Int],
    outputLayout: [Int],
    cycles: Int,
    startFrame: Int
) -> Int {
    var mismatches = 0
    var frame = startFrame
    for _ in 0..<cycles {
        let left = muffleTestSignal(seed: 1, startFrame: frame, frames: 512)
        let right = muffleTestSignal(seed: 2, startFrame: frame, frames: 512)
        let result = muffleRender(&filter, input: [left, right], inputLayout: inputLayout, outputLayout: outputLayout, muffle: 0, gate: 1)
        for i in 0..<512 {
            if result.out[0][i].bitPattern != left[i].bitPattern { mismatches += 1 }
            if result.out[1][i].bitPattern != right[i].bitPattern { mismatches += 1 }
        }
        frame += 512
    }
    return mismatches
}

private func muffleSine(frequencyHz: Double, sampleRate: Double, startFrame: Int, frames: Int, amplitude: Double = 0.5) -> [Float] {
    (0..<frames).map { offset in
        Float(amplitude * sin(2 * Double.pi * frequencyHz * Double(startFrame + offset) / sampleRate))
    }
}

private func muffleRMS(_ samples: [Float]) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    return (sum / Double(samples.count)).squareRoot()
}

private func muffleLevelDB(output: [Float], input: [Float]) -> Double {
    let outRMS = max(muffleRMS(output), 1e-12)
    let inRMS = max(muffleRMS(input), 1e-12)
    return 20 * log10(outRMS / inRMS)
}

/// Renders one cycle of a stereo sine and returns each channel's level in dB re input.
private func muffleRenderSine(
    _ filter: inout DictationMuffleFilter,
    frequencyHz: Double,
    sampleRate: Double,
    startFrame: Int,
    frames: Int,
    muffle: Float
) -> (left: Double, right: Double) {
    let signal = muffleSine(frequencyHz: frequencyHz, sampleRate: sampleRate, startFrame: startFrame, frames: frames)
    let result = muffleRender(&filter, input: [signal, signal], inputLayout: [2], outputLayout: [2], muffle: muffle, gate: 1)
    return (muffleLevelDB(output: result.out[0], input: signal), muffleLevelDB(output: result.out[1], input: signal))
}

/// Settles fully muffled for a second, then measures half a second.
private func muffleSettledLevelDB(frequencyHz: Double, sampleRate: Double) -> (left: Double, right: Double) {
    var filter = DictationMuffleFilter(sampleRate: sampleRate)
    let cycle = 480
    var frame = 0
    for _ in 0..<100 {
        _ = muffleRenderSine(&filter, frequencyHz: frequencyHz, sampleRate: sampleRate, startFrame: frame, frames: cycle, muffle: 1)
        frame += cycle
    }
    var inputs: [Float] = []
    var lefts: [Float] = []
    var rights: [Float] = []
    for _ in 0..<50 {
        let signal = muffleSine(frequencyHz: frequencyHz, sampleRate: sampleRate, startFrame: frame, frames: cycle)
        let result = muffleRender(&filter, input: [signal, signal], inputLayout: [2], outputLayout: [2], muffle: 1, gate: 1)
        inputs += signal
        lefts += result.out[0]
        rights += result.out[1]
        frame += cycle
    }
    return (muffleLevelDB(output: lefts, input: inputs), muffleLevelDB(output: rights, input: inputs))
}

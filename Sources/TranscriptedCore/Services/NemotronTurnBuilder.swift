// NemotronTurnBuilder.swift
// Turns Nemotron 3 Diarization's per-frame speaker probabilities into exclusive
// speaker turns the meeting pipeline can consume.
//
// Nemotron emits, for every 10 ms frame, an independent activity probability for
// each of its 8 arrival-ordered speaker slots. Several slots can be "on" at once
// (overlapped speech). The meeting pipeline transcribes each diarized segment on
// its own, so overlapping segments would transcribe the same audio twice. This
// builder therefore picks at most ONE speaker per frame and returns turns that
// never overlap.
//
// Pure and FluidAudio-free on purpose so it can be unit-tested without models.

import Foundation

/// One exclusive speaker turn built from Nemotron frame probabilities.
public struct NemotronSpeakerTurn: Equatable, Sendable {
    /// Speaker index remapped to `0..<n` in order of first appearance.
    public let speakerIndex: Int
    /// First frame of the turn (inclusive).
    public let startFrame: Int
    /// One past the last frame of the turn (exclusive).
    public let endFrame: Int
    /// `startFrame * frameSeconds`.
    public let startTime: Double
    /// `endFrame * frameSeconds`.
    public let endTime: Double
    /// Mean winning probability over the frames where this speaker actually won
    /// the frame. Bridged silence is excluded, so for well-formed input this is in
    /// `[threshold, 1]`. Used as the segment quality score: it is the model's own
    /// confidence that this turn belongs to this speaker.
    public let meanActiveProbability: Float

    public var duration: Double { endTime - startTime }

    public init(
        speakerIndex: Int,
        startFrame: Int,
        endFrame: Int,
        startTime: Double,
        endTime: Double,
        meanActiveProbability: Float
    ) {
        self.speakerIndex = speakerIndex
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.startTime = startTime
        self.endTime = endTime
        self.meanActiveProbability = meanActiveProbability
    }
}

public enum NemotronTurnBuilder {
    /// A speaker slot counts as active in a frame at or above this probability.
    /// 0.5 is the operating point FluidAudio and NeMo use for Sortformer output.
    public static let defaultThreshold: Float = 0.5

    /// Same-speaker turns separated by pure silence shorter than this are joined.
    /// Mirrors the pyannote backend's tuned `minGapDuration` (0.2874 s) so both
    /// backends fragment a single speaker's pauses the same way.
    public static let defaultMaxBridgeGapSeconds: Double = 0.2874

    /// Turns shorter than this are dropped (after gap bridging). 0.25 s removes
    /// single-slot flicker at speaker changes (a few 10 ms frames where the
    /// argmax briefly flips) without touching anything the pipeline could use:
    /// downstream already skips segments under 1 s for transcription and for
    /// voiceprints (`TranscriptionPipeline`), so a higher floor here would not
    /// change the transcript. Keeping 0.25–1 s turns still matters because they
    /// split neighbouring turns and keep speaker counts honest. It is also the
    /// same order as FluidAudio's own `Nemotron3Diarizer.segments` default (0.2 s).
    public static let defaultMinTurnSeconds: Double = 0.25

    /// Build exclusive speaker turns from flattened `[frameCount * numSpeakers]`
    /// probabilities (frame-major: frame 0's speakers first).
    ///
    /// 1. Each frame goes to the speaker with the highest probability among those
    ///    `>= threshold` (lowest index on ties), or to silence when none qualifies.
    /// 2. Consecutive frames with the same speaker form a run.
    /// 3. Same-speaker runs separated only by silence shorter than
    ///    `maxBridgeGapSeconds` are joined.
    /// 4. Runs shorter than `minTurnSeconds` are dropped.
    /// 5. Step 3 runs again, so a speaker whose turn was split by a dropped blip
    ///    from someone else is rejoined when the resulting gap is short.
    /// 6. Speaker slots are renumbered `0..<n` in order of first appearance.
    ///
    /// When `probabilities.count` disagrees with `frameCount * numSpeakers`, only
    /// the frames both agree on are used (`min(frameCount, count / numSpeakers)`),
    /// so a malformed model output can never index out of bounds. Non-finite
    /// probabilities are treated as inactive.
    public static func turns(
        probabilities: [Float],
        frameCount: Int,
        numSpeakers: Int,
        frameSeconds: Double,
        threshold: Float = defaultThreshold,
        maxBridgeGapSeconds: Double = defaultMaxBridgeGapSeconds,
        minTurnSeconds: Double = defaultMinTurnSeconds
    ) -> [NemotronSpeakerTurn] {
        guard numSpeakers > 0, frameCount > 0, frameSeconds > 0, frameSeconds.isFinite else { return [] }
        let usableFrames = min(frameCount, probabilities.count / numSpeakers)
        guard usableFrames > 0 else { return [] }

        let runs = frameRuns(
            probabilities: probabilities,
            usableFrames: usableFrames,
            numSpeakers: numSpeakers,
            threshold: threshold
        )
        guard !runs.isEmpty else { return [] }

        let maxGapFrames = maxBridgeGapFrames(seconds: maxBridgeGapSeconds, frameSeconds: frameSeconds)
        let minFrames = minTurnFrames(seconds: minTurnSeconds, frameSeconds: frameSeconds)

        var merged = bridge(runs, maxGapFrames: maxGapFrames)
        merged = merged.filter { $0.end - $0.start >= minFrames }
        merged = bridge(merged, maxGapFrames: maxGapFrames)

        var remap: [Int: Int] = [:]
        return merged.map { run in
            let index: Int
            if let existing = remap[run.speaker] {
                index = existing
            } else {
                index = remap.count
                remap[run.speaker] = index
            }
            let mean = run.activeFrames > 0 ? Float(run.probabilitySum / Double(run.activeFrames)) : 0
            return NemotronSpeakerTurn(
                speakerIndex: index,
                startFrame: run.start,
                endFrame: run.end,
                startTime: Double(run.start) * frameSeconds,
                endTime: Double(run.end) * frameSeconds,
                meanActiveProbability: mean
            )
        }
    }

    // MARK: - Internals

    struct Run: Equatable {
        var speaker: Int
        var start: Int
        var end: Int
        var probabilitySum: Double
        var activeFrames: Int
    }

    /// Largest silence gap, in frames, that still counts as "shorter than"
    /// `seconds`. The epsilon keeps exact multiples (0.30 s at 10 ms) exclusive.
    static func maxBridgeGapFrames(seconds: Double, frameSeconds: Double) -> Int {
        guard seconds > 0, seconds.isFinite else { return 0 }
        return max(0, Int((seconds / frameSeconds - 1e-9).rounded(.up)) - 1)
    }

    /// Smallest turn length, in frames, that is at least `seconds` long.
    static func minTurnFrames(seconds: Double, frameSeconds: Double) -> Int {
        guard seconds > 0, seconds.isFinite else { return 0 }
        return max(0, Int((seconds / frameSeconds - 1e-9).rounded(.up)))
    }

    /// Per-frame argmax-above-threshold labelling, collapsed into runs.
    static func frameRuns(
        probabilities: [Float],
        usableFrames: Int,
        numSpeakers: Int,
        threshold: Float
    ) -> [Run] {
        var runs: [Run] = []
        var current: Run?
        for frame in 0..<usableFrames {
            let base = frame * numSpeakers
            var winner = -1
            var winnerProbability: Float = 0
            for speaker in 0..<numSpeakers {
                let probability = probabilities[base + speaker]
                guard probability.isFinite, probability >= threshold else { continue }
                if winner < 0 || probability > winnerProbability {
                    winner = speaker
                    winnerProbability = probability
                }
            }

            if winner < 0 {
                if let open = current {
                    runs.append(open)
                    current = nil
                }
                continue
            }

            if var open = current, open.speaker == winner {
                open.end = frame + 1
                open.probabilitySum += Double(winnerProbability)
                open.activeFrames += 1
                current = open
            } else {
                if let open = current { runs.append(open) }
                current = Run(
                    speaker: winner,
                    start: frame,
                    end: frame + 1,
                    probabilitySum: Double(winnerProbability),
                    activeFrames: 1
                )
            }
        }
        if let open = current { runs.append(open) }
        return runs
    }

    /// Join adjacent same-speaker runs whose gap is at most `maxGapFrames`.
    /// Runs are ordered and non-overlapping, so the gap between a run and the
    /// previous kept run holds no other kept speaker; joining keeps exclusivity.
    static func bridge(_ runs: [Run], maxGapFrames: Int) -> [Run] {
        var out: [Run] = []
        out.reserveCapacity(runs.count)
        for run in runs {
            if var last = out.last, last.speaker == run.speaker, run.start - last.end <= maxGapFrames {
                last.end = run.end
                last.probabilitySum += run.probabilitySum
                last.activeFrames += run.activeFrames
                out[out.count - 1] = last
            } else {
                out.append(run)
            }
        }
        return out
    }
}

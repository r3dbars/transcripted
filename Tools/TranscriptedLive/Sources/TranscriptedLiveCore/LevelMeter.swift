import Foundation

/// How loud one speaker's audio is, in steps of `stepSeconds` of audio: a short
/// history the Claude Code mod draws as a meter. Loudness only, no audio and no
/// text, so nothing about what was said is in it.
public struct LevelMeter: Equatable {
    public let stepSeconds: Double
    public let capacity: Int
    /// Newest last, each 0 (silence, -60 dBFS and below) to 1 (full scale).
    public private(set) var levels: [Double] = []

    private var sumOfSquares: Double = 0
    private var count = 0

    public init(stepSeconds: Double = 0.1, capacity: Int = 48) {
        self.stepSeconds = stepSeconds
        self.capacity = capacity
    }

    public mutating func add(_ samples: [Float], sampleRate: Double) {
        let perStep = max(1, Int(sampleRate * stepSeconds))
        for sample in samples {
            sumOfSquares += Double(sample) * Double(sample)
            count += 1
            if count >= perStep {
                push(Self.level(rms: (sumOfSquares / Double(count)).squareRoot()))
                sumOfSquares = 0
                count = 0
            }
        }
    }

    /// RMS to 0...1 on a 60 dB scale, so speech fills the meter and room noise barely shows.
    static func level(rms: Double) -> Double {
        guard rms > 0 else { return 0 }
        let dbfs = 20 * log10(rms)
        return min(1, max(0, (dbfs + 60) / 60))
    }

    private mutating func push(_ level: Double) {
        levels.append((level * 100).rounded() / 100)
        if levels.count > capacity { levels.removeFirst(levels.count - capacity) }
    }
}

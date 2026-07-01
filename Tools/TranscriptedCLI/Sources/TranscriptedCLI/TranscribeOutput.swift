import ArgumentParser
import Foundation

/// CLI-local token timing so output formatting stays compilable and testable
/// without linking the FluidAudio dependency bundle. The gated transcribe
/// command maps FluidAudio `TokenTiming` values into this shape.
struct TranscribeToken: Equatable {
    let text: String
    let startSeconds: Double
    let endSeconds: Double
}

struct TranscribeSegment: Equatable, Encodable {
    let text: String
    let startSeconds: Double
    let endSeconds: Double
}

struct TranscribeFileOutput: Encodable {
    let file: String
    let text: String
    let durationSeconds: Double
    let processingSeconds: Double
    let realTimeFactor: Double
    let confidence: Double
    let segments: [TranscribeSegment]
}

enum TranscribeOutputFormat: Equatable {
    case text
    case json
    case srt

    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .json: return "json"
        case .srt: return "srt"
        }
    }

    static func resolve(json: Bool, srt: Bool) throws -> TranscribeOutputFormat {
        switch (json, srt) {
        case (true, true):
            throw ValidationError("Choose either --json or --srt, not both.")
        case (true, false):
            return .json
        case (false, true):
            return .srt
        case (false, false):
            return .text
        }
    }
}

enum TranscribeOutputBuilder {
    /// Caption-sized grouping defaults. Segments break on silence gaps,
    /// sentence-ending punctuation, and caption length/duration ceilings.
    static let defaultMaxSegmentSeconds: Double = 6.0
    static let defaultMaxSegmentCharacters = 84
    static let defaultGapSeconds: Double = 0.8
    static let sentenceBreakMinimumSeconds: Double = 2.0

    /// Minimum caption duration so SRT entries never collapse to zero length.
    static let minimumCaptionSeconds: Double = 0.1

    static func segments(
        from tokens: [TranscribeToken],
        maxDurationSeconds: Double = defaultMaxSegmentSeconds,
        maxCharacters: Int = defaultMaxSegmentCharacters,
        gapSeconds: Double = defaultGapSeconds
    ) -> [TranscribeSegment] {
        var segments: [TranscribeSegment] = []
        var currentTokens: [TranscribeToken] = []
        var currentCharacterCount = 0

        func flush() {
            defer {
                currentTokens.removeAll(keepingCapacity: true)
                currentCharacterCount = 0
            }
            guard let first = currentTokens.first, let last = currentTokens.last else { return }
            let text = currentTokens.map(\.text).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            segments.append(TranscribeSegment(
                text: text,
                startSeconds: first.startSeconds,
                endSeconds: last.endSeconds
            ))
        }

        for token in tokens {
            if let first = currentTokens.first, let last = currentTokens.last {
                let gap = token.startSeconds - last.endSeconds
                let duration = token.endSeconds - first.startSeconds
                let endsSentence = last.text.hasSuffix(".")
                    || last.text.hasSuffix("?")
                    || last.text.hasSuffix("!")
                let sentenceBreak = endsSentence
                    && (last.endSeconds - first.startSeconds) >= sentenceBreakMinimumSeconds
                if gap >= gapSeconds
                    || duration > maxDurationSeconds
                    || currentCharacterCount + token.text.count > maxCharacters
                    || sentenceBreak {
                    flush()
                }
            }
            currentTokens.append(token)
            currentCharacterCount += token.text.count
        }
        flush()
        return segments
    }

    static func srt(from segments: [TranscribeSegment]) -> String {
        segments.enumerated().map { index, segment in
            let end = max(segment.endSeconds, segment.startSeconds + minimumCaptionSeconds)
            return "\(index + 1)\n"
                + "\(srtTimestamp(segment.startSeconds)) --> \(srtTimestamp(end))\n"
                + "\(segment.text)\n"
        }
        .joined(separator: "\n")
    }

    static func srtTimestamp(_ seconds: Double) -> String {
        let totalMilliseconds = Int((max(0, seconds) * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let secondsPart = totalSeconds % 60
        let minutesPart = (totalSeconds / 60) % 60
        let hoursPart = totalSeconds / 3600
        return String(format: "%02d:%02d:%02d,%03d", hoursPart, minutesPart, secondsPart, milliseconds)
    }

    static func outputURL(
        for input: URL,
        outputDirectory: URL,
        format: TranscribeOutputFormat
    ) -> URL {
        outputDirectory
            .appendingPathComponent(input.deletingPathExtension().lastPathComponent, isDirectory: false)
            .appendingPathExtension(format.fileExtension)
    }

    static func encodeJSON(_ outputs: [TranscribeFileOutput]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if outputs.count == 1, let only = outputs.first {
            return try encoder.encode(only)
        }
        return try encoder.encode(outputs)
    }
}

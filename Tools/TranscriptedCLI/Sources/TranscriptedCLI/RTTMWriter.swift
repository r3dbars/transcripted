import Foundation

enum RTTMText {
    /// Standard RTTM line: SPEAKER <file_id> 1 <start> <duration> <NA> <NA> <speaker> <NA> <NA>
    static func render(fileId: String, segments: [(speakerId: String, start: Double, end: Double)]) -> String {
        let safeFileId = fileId.replacingOccurrences(of: " ", with: "_")
        return segments.map { segment in
            let start = String(format: "%.3f", segment.start)
            let duration = String(format: "%.3f", segment.end - segment.start)
            return "SPEAKER \(safeFileId) 1 \(start) \(duration) <NA> <NA> \(segment.speakerId) <NA> <NA>"
        }.joined(separator: "\n")
    }

    static func output(fileId: String, segments: [(speakerId: String, start: Double, end: Double)], to path: String?) throws {
        let rttm = render(fileId: fileId, segments: segments)
        if let path {
            try rttm.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            print(rttm)
        }
    }
}

#if TRANSCRIPTEDCLI_WITH_DIARIZATION && canImport(FluidAudio)
import FluidAudio

enum RTTMWriter {
    static func write(segments: [TimedSpeakerSegment], fileId: String) -> String {
        RTTMText.render(
            fileId: fileId,
            segments: segments.map {
                (speakerId: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
            }
        )
    }

    static func output(segments: [TimedSpeakerSegment], fileId: String, to path: String?) throws {
        try RTTMText.output(
            fileId: fileId,
            segments: segments.map {
                (speakerId: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
            },
            to: path
        )
    }
}
#endif

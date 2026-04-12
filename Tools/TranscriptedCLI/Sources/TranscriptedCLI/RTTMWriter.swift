import Foundation

#if TRANSCRIPTEDCLI_WITH_DIARIZATION
import FluidAudio

enum RTTMWriter {
    /// Convert diarization segments to standard RTTM format.
    /// Format: SPEAKER <file_id> 1 <start> <duration> <NA> <NA> <speaker> <NA> <NA>
    static func write(segments: [TimedSpeakerSegment], fileId: String) -> String {
        // RTTM is space-delimited, so sanitize file ID
        let safeFileId = fileId.replacingOccurrences(of: " ", with: "_")
        return segments.map { segment in
            let start = String(format: "%.3f", segment.startTimeSeconds)
            let duration = String(format: "%.3f", segment.endTimeSeconds - segment.startTimeSeconds)
            return "SPEAKER \(safeFileId) 1 \(start) \(duration) <NA> <NA> \(segment.speakerId) <NA> <NA>"
        }.joined(separator: "\n")
    }

    /// Write RTTM to file, or print to stdout if no path given.
    static func output(segments: [TimedSpeakerSegment], fileId: String, to path: String?) throws {
        let rttm = write(segments: segments, fileId: fileId)
        if let path = path {
            try rttm.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            print(rttm)
        }
    }
}
#endif

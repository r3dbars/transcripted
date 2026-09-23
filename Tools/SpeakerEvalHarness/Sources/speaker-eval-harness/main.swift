// speaker-eval-harness
//
// Headless eval harness for Transcripted's speaker-naming pipeline, run against
// REAL labeled audio (AMI Meeting Corpus). Two stages, split so the expensive
// diarization runs once and the cheap threshold sweep replays the cache:
//
//   dump    — run the APP'S diarizer (TranscriptedCore.DiarizationService; backend
//             pyannote or nemotron, embedder native WeSpeaker or ERes2Net) on one
//             audio file and write every segment + its embedding to JSON.
//             Expensive; cache once per variant. See Dump.swift.
//
//   replay  — load cached dumps for a session series IN ORDER, run them through the
//             real EmbeddingClusterer.postProcess (within-meeting consolidation) and
//             the real SpeakerDatabase match/learn/merge path (cross-meeting re-ID),
//             then emit per-segment hypothesis assignments. Cheap; sweep thresholds.
//             See Replay.swift.
//
// The DB is replayed in session order so profiles accumulate across meetings exactly
// like real usage. Scoring (DER, fragmentation, false-merge, re-ID curve) is done by
// scripts/score_speaker_eval.py; the side-by-side diarizer bake-off (raw + pipeline
// DER, speaker-count error, returning-speaker recognition) by scripts/score_speaker_lab.py,
// driven end to end by scripts/run_speaker_lab.sh.

import Foundation
import TranscriptedCore

// MARK: - Wire JSON models

struct SegmentDump: Codable {
    let speakerId: Int
    let start: Double
    let end: Double
    let quality: Float
    let embedding: [Float]?
}

struct RawDump: Codable {
    let meeting: String
    let audioPath: String
    let durationSeconds: Double          // end of the last diarized segment (pre-lab field)
    let diarizerSpeakerCount: Int
    let segments: [SegmentDump]
    // Speaker-lab fields. Optional so dumps written before the lab still decode
    // (those are pyannote + WeSpeaker dumps).
    let backend: String?                 // "pyannote" | "nemotron"
    let embedder: String?                // effective fingerprint model: "wespeaker" | "eres2net"
    let embeddingDimension: Int?
    let diarizeSeconds: Double?          // wall time of diarizeOffline (decode + diarize + embed)
    let audioSeconds: Double?            // audio file duration
    let initSeconds: Double?             // model load / warmup wall time
    let nemotronPreset: String?          // TRANSCRIPTED_NEMOTRON_PRESET at dump time (nemotron only)
}

struct AssignmentOut: Codable {
    let start: Double
    let end: Double
    let diarizerCluster: Int     // cluster id AFTER EmbeddingClusterer consolidation
    let dbProfile: String        // persistent DB profile UUID (the "person" the app would name)
}

struct MeetingResult: Codable {
    let meeting: String
    let diarizerClustersAfterConsolidation: Int
    let clusterToProfile: [String: String]   // consolidated cluster id -> DB UUID
    let assignments: [AssignmentOut]
    let rawDiarizerClusters: Int             // clusters straight out of the diarizer
    let clusterStatus: [String: String]      // cluster id -> "matched" (profile existed before this meeting) | "new"
    let profilesAfterMeeting: Int
}

struct ReplayResult: Codable {
    let consolidationThreshold: String   // pairwise merge: "none" or a float as string
    let matchThreshold: Double           // the fixed floor, or thresholds.matchManySegments when adaptive
    let writePathFixes: Bool             // #6 write-gate + #8 link-decouple applied?
    let profilesAtEnd: Int
    let meetings: [MeetingResult]
    let matchMode: String                // "fixed" | "adaptive"
    let sameVoiceThreshold: Double?      // same-voice consolidation (nil = off)
    let thresholdProfile: String         // "weSpeaker" | "eRes2Net"
    let dedupThreshold: Double           // mergeDuplicates threshold after each meeting
    let writeBack: WriteBackPolicy       // fingerprint update policy
    let backend: String
    let embedder: String
}

// MARK: - Helpers

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

/// Value following `name`, or nil when the flag is absent. A flag given with no value
/// (last token, or directly followed by another `--flag`) is a hard error, so a
/// truncated optimizer command never silently runs the default.
func argValue(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { die("\(name) needs a value") }
    return args[i + 1]
}

/// Embedding dimension of a dump: the recorded value, else the first embedded
/// segment's. nil when the dump carries no embeddings.
func dumpEmbeddingDimension(_ dump: RawDump) -> Int? {
    if let dim = dump.embeddingDimension, dim > 0 { return dim }
    return dump.segments.compactMap { $0.embedding?.count }.first { $0 > 0 }
}

/// Quality-filtered, L2-normalized mean embedding for a cluster — same filter as
/// EmbeddingClusterer.computeMeanEmbeddingsPerSpeaker (qual >= 0.3, dur >= 1.0),
/// with a fallback to all embedded segments when none pass the filter, delegating
/// the mean/normalize math to the production Transcription.computeMeanEmbedding.
/// `count` is how many segment embeddings backed the mean — what the app's adaptive
/// match floor keys on (`SpeakerEmbeddingThresholds.adaptiveMatch(forSegmentCount:)`).
func clusterMeanEmbedding(_ segs: [SegmentDump]) -> (embedding: [Float], count: Int)? {
    let filtered = segs.filter { $0.quality >= 0.3 && ($0.end - $0.start) >= 1.0 }
        .compactMap { $0.embedding }.filter { !$0.isEmpty }
    let chosen = filtered.isEmpty ? segs.compactMap { $0.embedding }.filter { !$0.isEmpty } : filtered
    guard !chosen.isEmpty else { return nil }
    let mean = Transcription.computeMeanEmbedding(chosen)
    guard !mean.isEmpty else { return nil }
    return (embedding: mean, count: chosen.count)
}

// MARK: - entry

@main
struct Main {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard #available(macOS 14.0, *) else { die("requires macOS 14+") }
        guard let cmd = args.first else {
            die("usage: speaker-eval-harness <dump|replay|autoeval|autoeval-self-test> ...")
        }
        switch cmd {
        case "dump": await runDump(Array(args.dropFirst()))
        case "replay": await runReplay(Array(args.dropFirst()))
        case "autoeval": runAutoResearch(Array(args.dropFirst()))
        case "autoeval-self-test": runAutoResearchSelfTests()
        default: die("unknown command \(cmd)")
        }
    }
}

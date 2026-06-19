// ladder-fingerprints — Stage 2 of the multi-meeting confidence-ladder eval.
//
// Consumes the cached `dump` JSONs (real diarizer segments + 256-dim WeSpeaker embeddings)
// and the ground-truth RTTMs, and produces a POLICY-INDEPENDENT per-(speaker, meeting)
// "fingerprint" cache that the cheap ladder sweep replays many times.
//
// For each meeting, in chronological (sorted) order:
//   1. Rebuild [SpeakerSegment] from the dump.
//   2. Run the REAL within-meeting consolidation: EmbeddingClusterer.postProcess(
//        segments, existingProfiles: [], pairwiseMergeThreshold: nil)  — this is the
//        production OFFLINE path (TranscriptionPipeline passes pairwiseMergeThreshold:nil;
//        consolidationThreshold defaults to 0.88). existingProfiles:[] keeps the fingerprint
//        independent of any ladder policy so it can be cached once. [FLAG: production also
//        passes the accumulated DB profiles to enable dbInformedSplit across meetings; we
//        omit that here on purpose — the cross-meeting promotion ladder is exactly what the
//        sweep studies, and a policy-independent fingerprint must not depend on the evolving
//        DB. dbInformedSplit with [] profiles is a no-op, so only the cross-meeting split is
//        skipped; within-meeting merge/absorb/consolidate run identically to production.]
//   3. Attribute each consolidated cluster to the ground-truth speaker it overlaps most
//      (the same max-overlap attribution scripts/score_speaker_eval.py uses).
//   4. The per-(speaker, meeting) fingerprint = REAL Transcription.computeMeanEmbedding over
//      that speaker's quality-filtered segments (qual>=0.3, dur>=1.0; fallback to all), i.e.
//      the exact vector the app stores/matches. Within-meeting over-segmentation is folded
//      into the one per-speaker fingerprint (the ladder studies cross-meeting re-ID, not
//      intra-meeting clustering, which the existing replay/score already covers).

import Foundation
import TranscriptedCore

struct FpSpeaker: Codable {
    let gtSpeaker: String
    let embedding: [Float]
    let durationSeconds: Double
    let segmentCount: Int
    let clusterCount: Int        // # diarizer clusters that mapped to this gt speaker (over-seg)
    let purity: Double           // overlap-to-assigned / total cluster duration (weighted)
}

struct FpMeeting: Codable {
    let meeting: String
    let order: Int
    let speakers: [FpSpeaker]
}

struct FpCache: Codable {
    let corpus: String
    let consolidation: String
    let meetings: [FpMeeting]
    let speakerAppearances: [String: Int]
    let note: String
}

// (start, end) ground-truth intervals per speaker, parsed from an RTTM.
func parseRTTM(_ path: String) -> [String: [(Double, Double)]] {
    var out: [String: [(Double, Double)]] = [:]
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return out }
    for line in text.split(separator: "\n") {
        let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard f.count >= 8, f[0] == "SPEAKER",
              let start = Double(f[3]), let dur = Double(f[4]) else { continue }
        out[f[7], default: []].append((start, start + dur))
    }
    return out
}

func overlap(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
    max(0, min(a.1, b.1) - max(a.0, b.0))
}

// REAL fingerprint reducer: quality filter (qual>=0.3 & dur>=1.0, fallback to all) then the
// production Transcription.computeMeanEmbedding (L2-normalized mean). Mirrors the app's
// EmbeddingClusterer.computeMeanEmbeddingsPerSpeaker used to build a stored profile vector.
func meanFingerprint(_ segs: [SpeakerSegment]) -> [Float]? {
    func embsOf(_ s: [SpeakerSegment]) -> [[Float]] {
        s.compactMap { $0.embedding }.filter { !$0.isEmpty }
    }
    let filtered = segs.filter { $0.qualityScore >= 0.3 && ($0.endTime - $0.startTime) >= 1.0 }
    let embs = embsOf(filtered).isEmpty ? embsOf(segs) : embsOf(filtered)
    guard !embs.isEmpty else { return nil }
    let m = Transcription.computeMeanEmbedding(embs)
    return m.isEmpty ? nil : m
}

@available(macOS 14.0, *)
func runLadderFingerprints(_ args: [String]) async {
    guard let dumpsDir = argValue("--dumps", in: args),
          let rttmDir = argValue("--rttm", in: args),
          let out = argValue("--out", in: args) else {
        die("ladder-fingerprints requires --dumps <dir> --rttm <dir> --out <fingerprints.json> [--corpus name]")
    }
    let corpus = argValue("--corpus", in: args) ?? "unknown"
    // VoxConverse (and any corpus with per-file local speaker labels) must namespace gt
    // speakers by meeting so spk00 in file A != spk00 in file B (no false cross-file recurrence).
    let namespaceSpeakers = args.contains("--namespace-speakers")
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: dumpsDir) else { die("cannot list \(dumpsDir)") }
    let dumpFiles = entries.filter { $0.hasSuffix(".json") }.sorted()
    guard !dumpFiles.isEmpty else { die("no dump JSONs in \(dumpsDir)") }

    func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    let dec = JSONDecoder()
    var meetings: [FpMeeting] = []
    var appearances: [String: Int] = [:]
    var order = 0
    var skippedNoRTTM = 0

    for file in dumpFiles {
        let meeting = (file as NSString).deletingPathExtension
        guard let data = fm.contents(atPath: "\(dumpsDir)/\(file)"),
              let dump = try? dec.decode(RawDump.self, from: data) else {
            log("[fp] bad dump \(file), skipping"); continue
        }
        let rttmPath = "\(rttmDir)/\(meeting).rttm"
        var gt = parseRTTM(rttmPath)
        if namespaceSpeakers {
            gt = Dictionary(uniqueKeysWithValues: gt.map { ("\(meeting)/\($0.key)", $0.value) })
        }
        if gt.isEmpty { skippedNoRTTM += 1; log("[fp] no/empty RTTM for \(meeting), skipping"); continue }

        let segs = dump.segments.map {
            SpeakerSegment(speakerId: $0.speakerId, startTime: $0.start, endTime: $0.end,
                           embedding: $0.embedding, qualityScore: $0.quality)
        }
        let consolidated = await MainActor.run {
            EmbeddingClusterer.postProcess(segments: segs, existingProfiles: [], pairwiseMergeThreshold: nil)
        }

        // group consolidated segments by post-consolidation cluster id
        var byCluster: [Int: [SpeakerSegment]] = [:]
        for s in consolidated { byCluster[s.speakerId, default: []].append(s) }

        // attribute each cluster to its max-overlap gt speaker
        struct ClusterAttr { let gt: String; let dur: Double; let overlapToGt: Double; let segs: [SpeakerSegment] }
        var attrs: [ClusterAttr] = []
        for (_, cs) in byCluster {
            let clusterDur = cs.reduce(0.0) { $0 + ($1.endTime - $1.startTime) }
            var best = ""; var bestOv = -1.0
            for (spk, ivals) in gt {
                var ov = 0.0
                for s in cs { for iv in ivals { ov += overlap((s.startTime, s.endTime), iv) } }
                if ov > bestOv { bestOv = ov; best = spk }
            }
            guard !best.isEmpty, bestOv > 0 else { continue }   // unmatched cluster (no gt overlap)
            attrs.append(ClusterAttr(gt: best, dur: clusterDur, overlapToGt: bestOv, segs: cs))
        }

        // fold clusters of the same gt speaker into one per-(speaker, meeting) fingerprint
        var bySpeaker: [String: [ClusterAttr]] = [:]
        for a in attrs { bySpeaker[a.gt, default: []].append(a) }

        var fpSpeakers: [FpSpeaker] = []
        for (spk, cas) in bySpeaker {
            let allSegs = cas.flatMap { $0.segs }
            guard let fp = meanFingerprint(allSegs) else { continue }
            let totalDur = cas.reduce(0.0) { $0 + $1.dur }
            let totalOv = cas.reduce(0.0) { $0 + $1.overlapToGt }
            let purity = totalDur > 0 ? min(1.0, totalOv / totalDur) : 0
            fpSpeakers.append(FpSpeaker(
                gtSpeaker: spk, embedding: fp, durationSeconds: totalDur,
                segmentCount: allSegs.count, clusterCount: cas.count, purity: purity))
            appearances[spk, default: 0] += 1
        }
        fpSpeakers.sort { $0.durationSeconds > $1.durationSeconds }
        meetings.append(FpMeeting(meeting: meeting, order: order, speakers: fpSpeakers))
        order += 1
    }

    let cache = FpCache(
        corpus: corpus, consolidation: "offline(pairwise=nil,consolidation=0.88)",
        meetings: meetings, speakerAppearances: appearances,
        note: "fingerprint = real EmbeddingClusterer.postProcess + Transcription.computeMeanEmbedding; "
            + "clusters attributed to gt by max RTTM overlap; per-(speaker,meeting) folds over-segmentation.")
    let enc = JSONEncoder()
    do { try enc.encode(cache).write(to: URL(fileURLWithPath: out)) }
    catch { die("failed to write \(out): \(error.localizedDescription)") }

    let multiAppear = appearances.values.filter { $0 >= 2 }.count
    log("[fp] \(corpus): \(meetings.count) meetings, \(appearances.count) distinct gt speakers, "
        + "\(multiAppear) recurring (>=2 appearances), \(skippedNoRTTM) meetings skipped (no RTTM) -> \(out)")
}

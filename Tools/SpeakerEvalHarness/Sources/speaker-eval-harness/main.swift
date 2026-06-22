// speaker-eval-harness
//
// Headless eval harness for Transcripted's speaker-naming pipeline, run against
// REAL labeled audio (AMI Meeting Corpus). Two stages, split so the expensive
// diarization runs once and the cheap threshold sweep replays the cache:
//
//   dump    — run the APP'S diarizer (FluidAudio PyAnnote + 256-dim WeSpeaker
//             embeddings, via TranscriptedCore.DiarizationService) on one WAV and
//             write every segment + its embedding to JSON. Expensive; cache once.
//
//   replay  — load cached dumps for a session series IN ORDER, run them through the
//             real EmbeddingClusterer.postProcess (within-meeting consolidation) and
//             the real SpeakerDatabase match/learn/merge path (cross-meeting re-ID),
//             then emit per-segment hypothesis assignments. Cheap; sweep thresholds.
//
// The DB is replayed in session order so profiles accumulate across meetings exactly
// like real usage. Scoring (DER, fragmentation, false-merge, re-ID curve) is done by
// scripts/score_speaker_eval.py against the AMI ground-truth RTTMs.

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
    let durationSeconds: Double
    let diarizerSpeakerCount: Int
    let segments: [SegmentDump]
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
}

struct ReplayResult: Codable {
    let consolidationThreshold: String   // "none" or a float as string
    let matchThreshold: Double
    let writePathFixes: Bool             // #6 write-gate + #8 link-decouple applied?
    let profilesAtEnd: Int
    let meetings: [MeetingResult]
}

// MARK: - Helpers

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

func argValue(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

/// Quality-filtered, L2-normalized mean embedding for a cluster — mirrors
/// EmbeddingClusterer.computeMeanEmbeddingsPerSpeaker (qual >= 0.3, dur >= 1.0),
/// with a fallback to all embedded segments when none pass the filter. This is the
/// vector the app stores/matches per speaker cluster.
func clusterMeanEmbedding(_ segs: [SegmentDump]) -> [Float]? {
    func mean(_ embs: [[Float]]) -> [Float]? {
        guard let dim = embs.first?.count, dim > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dim)
        for e in embs where e.count == dim { for i in 0..<dim { sum[i] += e[i] } }
        let n = Float(embs.count)
        for i in 0..<dim { sum[i] /= n }
        var norm: Float = 0
        for v in sum { norm += v * v }
        norm = norm.squareRoot()
        guard norm > 0 else { return sum }
        for i in 0..<dim { sum[i] /= norm }
        return sum
    }
    let filtered = segs.filter { $0.quality >= 0.3 && ($0.end - $0.start) >= 1.0 }
        .compactMap { $0.embedding }.filter { !$0.isEmpty }
    if !filtered.isEmpty { return mean(filtered) }
    let all = segs.compactMap { $0.embedding }.filter { !$0.isEmpty }
    return all.isEmpty ? nil : mean(all)
}

/// Cosine similarity between two equal-length vectors (eval-local mirror of the app's helper).
func cosineSim(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    let denom = (na.squareRoot()) * (nb.squareRoot())
    return denom > 0 ? Double(dot / denom) : 0
}

/// Best + second-best profile (above `threshold`) for an embedding against a frozen snapshot.
/// Returns the matched profile id, its similarity, and the runner-up similarity (-1 if none) so the
/// eval can feed `SpeakerWritePathPolicy.voiceprintBlendAlpha`'s margin guard exactly like the app.
func bestAndSecond(_ emb: [Float], profiles: [SpeakerProfile], threshold: Double)
    -> (id: UUID, similarity: Double, second: Double)? {
    var bestId: UUID?
    var best = -1.0, second = -1.0
    for p in profiles {
        guard p.disputeCount == 0, p.embedding.count == emb.count else { continue }
        let s = cosineSim(emb, p.embedding)
        guard s >= threshold else { continue }
        if s > best { second = best; best = s; bestId = p.id }
        else if s > second { second = s }
    }
    guard let id = bestId else { return nil }
    return (id, best, second)
}

// MARK: - dump

@available(macOS 14.0, *)
func runDump(_ args: [String]) async {
    guard let audio = argValue("--audio", in: args), let out = argValue("--out", in: args) else {
        die("dump requires --audio <wav> --out <raw.json>")
    }
    let audioURL = URL(fileURLWithPath: audio)
    guard FileManager.default.fileExists(atPath: audioURL.path) else { die("audio not found: \(audio)") }
    let meeting = argValue("--meeting", in: args) ?? audioURL.deletingPathExtension().lastPathComponent

    let service = await DiarizationService()   // defaultModelBundleProvider -> downloads CoreML models from HF if not cached
    FileHandle.standardError.write(Data("[dump] \(meeting): initializing diarizer (may download models on first run)...\n".utf8))
    await service.initialize()
    let ready = await MainActor.run { service.isReady }
    guard ready else { die("diarizer failed to initialize (see logs)") }

    FileHandle.standardError.write(Data("[dump] \(meeting): diarizing...\n".utf8))
    let t0 = Date()
    let segments: [SpeakerSegment]
    do {
        segments = try await service.diarizeOffline(audioURL: audioURL)
    } catch {
        die("diarization failed: \(error.localizedDescription)")
    }
    let elapsed = Date().timeIntervalSince(t0)

    let dumped = segments.map {
        SegmentDump(speakerId: $0.speakerId, start: $0.startTime, end: $0.endTime,
                    quality: $0.qualityScore, embedding: $0.embedding)
    }
    let withEmb = dumped.filter { ($0.embedding?.isEmpty == false) }.count
    let dim = dumped.compactMap { $0.embedding?.count }.first ?? 0
    let dur = segments.map { $0.endTime }.max() ?? 0
    let raw = RawDump(meeting: meeting, audioPath: audioURL.path, durationSeconds: dur,
                      diarizerSpeakerCount: Set(segments.map { $0.speakerId }).count, segments: dumped)

    let enc = JSONEncoder()
    do { try enc.encode(raw).write(to: URL(fileURLWithPath: out)) }
    catch { die("failed to write \(out): \(error.localizedDescription)") }

    FileHandle.standardError.write(Data((
        "[dump] \(meeting): \(segments.count) segments, \(raw.diarizerSpeakerCount) raw clusters, "
        + "\(withEmb)/\(segments.count) embedded (dim=\(dim)), \(String(format: "%.1f", elapsed))s -> \(out)\n").utf8))
    await service.cleanup()
}

// MARK: - replay

@available(macOS 14.0, *)
func runReplay(_ args: [String]) async {
    guard let inputsCSV = argValue("--inputs", in: args), let out = argValue("--out", in: args) else {
        die("replay requires --inputs <a.json,b.json,...> (session order) --match <float> [--consolidation none|float] --out <result.json>")
    }
    let matchThreshold = Double(argValue("--match", in: args) ?? "0.6") ?? 0.6
    let consolidationArg = (argValue("--consolidation", in: args) ?? "none").lowercased()
    let consolidation: Float? = consolidationArg == "none" ? nil : Float(consolidationArg)

    // Write-path fixes (#6 write-time contamination gate + #8 cross-cluster link/merge decouple).
    // "off" (default) = legacy behavior: every match blends at the full EMA rate and any clusters
    // matching the same profile collapse together. "on" = apply the SpeakerWritePathPolicy gates,
    // mirroring TranscriptionPipeline. Use the flag to A/B before/after on the same dumps.
    let writePathFixes = (argValue("--write-path-fixes", in: args) ?? "off").lowercased() == "on"

    let inputs = inputsCSV.split(separator: ",").map(String.init)
    let dec = JSONDecoder()
    var dumps: [RawDump] = []
    for path in inputs {
        guard let data = FileManager.default.contents(atPath: path) else { die("cannot read \(path)") }
        do { dumps.append(try dec.decode(RawDump.self, from: data)) }
        catch { die("bad dump \(path): \(error.localizedDescription)") }
    }

    // Fresh DB per replay so each threshold combo starts from an empty profile store,
    // exactly like a user who has never run the app before.
    let dbPath = NSTemporaryDirectory() + "speaker-eval-\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: dbPath) }
    let db = await SpeakerDatabase(path: dbPath)

    var meetingResults: [MeetingResult] = []

    for dump in dumps {
        // Build SpeakerSegments from the cached embeddings.
        let segs = dump.segments.map {
            SpeakerSegment(speakerId: $0.speakerId, startTime: $0.start, endTime: $0.end,
                           embedding: $0.embedding, qualityScore: $0.quality)
        }

        // 1) Within-meeting consolidation — the real clusterer, DB-informed split uses
        //    profiles learned from prior sessions (cross-meeting context), exactly as in app.
        let existing = await MainActor.run { db.allSpeakers() }
        let consolidated = await MainActor.run {
            EmbeddingClusterer.postProcess(segments: segs, existingProfiles: existing,
                                           pairwiseMergeThreshold: consolidation)
        }

        // Group consolidated segments by (post-consolidation) cluster id.
        var byCluster: [Int: [SegmentDump]] = [:]
        for s in consolidated {
            byCluster[s.speakerId, default: []].append(
                SegmentDump(speakerId: s.speakerId, start: s.startTime, end: s.endTime,
                            quality: s.qualityScore, embedding: s.embedding))
        }

        // 2) Cross-meeting match / learn: for each cluster, match its mean embedding
        //    against the DB (threshold sweep target); reuse or create a profile, then
        //    learn (EMA blend) — the real cross-meeting re-ID path.
        var clusterEmb: [Int: [Float]] = [:]
        for (cid, segs) in byCluster {
            if let e = clusterMeanEmbedding(segs) { clusterEmb[cid] = e }
        }
        // Deterministic order so larger (longer-speaking) clusters claim identities first.
        let clusterOrder = clusterEmb.keys.sorted {
            let a = byCluster[$0]!.reduce(0.0) { $0 + ($1.end - $1.start) }
            let b = byCluster[$1]!.reduce(0.0) { $0 + ($1.end - $1.start) }
            return a > b
        }
        var spunOffProfileIds: Set<UUID> = []
        var memberToRep: [Int: Int] = [:]   // (fixes mode) fused member cluster -> representative
        if !writePathFixes {
            // Legacy: match against the live DB, blend every match at the full EMA rate.
            for cid in clusterOrder {
                let emb = clusterEmb[cid]!
                let matched = await MainActor.run { db.matchSpeaker(embedding: emb, threshold: matchThreshold) }
                _ = await MainActor.run { db.addOrUpdateSpeaker(embedding: emb, existingId: matched?.profile.id) }
            }
            // 3) Dedup pass — the app runs mergeDuplicates after each transcript.
            await MainActor.run { db.mergeDuplicates(threshold: matchThreshold) }
        } else {
            // Production mirror of TranscriptionPipeline's write path: match-all vs the pre-meeting
            // snapshot → cross-cluster link/merge (#8) via the SAME planner the app uses → gated
            // write-back (#6) → mergeDuplicates protecting spun-off distinct voices.
            var matchedProfile: [Int: UUID] = [:]
            var matchSim: [Int: Double] = [:]
            var matchSecond: [Int: Double] = [:]
            for cid in clusterOrder {
                if let m = bestAndSecond(clusterEmb[cid]!, profiles: existing, threshold: matchThreshold) {
                    matchedProfile[cid] = m.id; matchSim[cid] = m.similarity; matchSecond[cid] = m.second
                }
            }
            let plan = Transcription.planCrossClusterLinks(
                matchedProfileBySpeaker: matchedProfile,
                matchSimilarityBySpeaker: matchSim,
                meanBySpeaker: clusterEmb,
                segmentCountBySpeaker: byCluster.mapValues { $0.count }
            )
            memberToRep = plan.remaps
            let spinOffReps = Set(plan.spinOffs)
            // Write-back for representatives + uncontended clusters only; fused members inherit their
            // representative (they don't write back, mirroring the pipeline).
            for cid in clusterOrder where memberToRep[cid] == nil {
                let emb = clusterEmb[cid]!
                if spinOffReps.contains(cid) {
                    let p = await MainActor.run { db.addOrUpdateSpeaker(embedding: emb, existingId: nil) }
                    spunOffProfileIds.insert(p.id)
                } else if let pid = matchedProfile[cid] {
                    let alpha = SpeakerWritePathPolicy.voiceprintBlendAlpha(
                        similarity: matchSim[cid] ?? 0, secondBestSimilarity: matchSecond[cid])
                    _ = await MainActor.run {
                        db.addOrUpdateSpeaker(embedding: emb, existingId: pid, blendAlpha: alpha)
                    }
                } else {
                    _ = await MainActor.run { db.addOrUpdateSpeaker(embedding: emb, existingId: nil) }
                }
            }
            await MainActor.run { db.mergeDuplicates(threshold: matchThreshold, protecting: spunOffProfileIds) }
        }

        // Resolve each cluster to its FINAL surviving profile. Representatives + uncontended clusters
        // re-match their mean against the post-merge DB; fused members inherit their representative's
        // profile (matchSpeaker alone could wrongly route a spun-off member back to the profile it
        // merely resembled).
        var resolved: [Int: String] = [:]
        for cid in clusterOrder where memberToRep[cid] == nil {
            let emb = clusterEmb[cid]!
            let m: SpeakerMatchResult? = await MainActor.run { db.matchSpeaker(embedding: emb, threshold: matchThreshold) }
            if let m { resolved[cid] = m.profile.id.uuidString }
        }
        for (member, rep) in memberToRep where resolved[rep] != nil {
            resolved[member] = resolved[rep]
        }
        let surviving = Set(await MainActor.run { db.allSpeakers() }.map { $0.id.uuidString })

        let assignments: [AssignmentOut] = consolidated.compactMap { s in
            guard let pid = resolved[s.speakerId] else { return nil }
            return AssignmentOut(start: s.startTime, end: s.endTime,
                                 diarizerCluster: s.speakerId, dbProfile: pid)
        }

        meetingResults.append(MeetingResult(
            meeting: dump.meeting,
            diarizerClustersAfterConsolidation: byCluster.count,
            clusterToProfile: Dictionary(uniqueKeysWithValues: resolved.map { (String($0.key), $0.value) }),
            assignments: assignments))

        FileHandle.standardError.write(Data((
            "[replay] \(dump.meeting): clusters=\(byCluster.count) "
            + "profilesNow=\(surviving.count) (match=\(matchThreshold) consolidation=\(consolidationArg) "
            + "fixes=\(writePathFixes ? "on" : "off") spunOff=\(spunOffProfileIds.count))\n").utf8))
    }

    let profilesAtEnd = await MainActor.run { db.allSpeakers().count }
    let result = ReplayResult(
        consolidationThreshold: consolidationArg,
        matchThreshold: matchThreshold,
        writePathFixes: writePathFixes,
        profilesAtEnd: profilesAtEnd,
        meetings: meetingResults)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted]
    do { try enc.encode(result).write(to: URL(fileURLWithPath: out)) }
    catch { die("failed to write \(out): \(error.localizedDescription)") }
    FileHandle.standardError.write(Data("[replay] wrote \(out) (profilesAtEnd=\(profilesAtEnd))\n".utf8))
}

// MARK: - entry

@main
struct Main {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard #available(macOS 14.0, *) else { die("requires macOS 14+") }
        guard let cmd = args.first else {
            die("usage: speaker-eval-harness <dump|replay> ...")
        }
        switch cmd {
        case "dump": await runDump(Array(args.dropFirst()))
        case "replay": await runReplay(Array(args.dropFirst()))
        default: die("unknown command \(cmd)")
        }
    }
}

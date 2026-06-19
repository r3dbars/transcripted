// ladder-parity — proves the simulator's reused math is faithful to production.
//
// 1. EMA blend: ported emaBlend(...) must agree (≤1e-5) with the REAL public
//    SpeakerDatabase.addOrUpdateSpeaker update branch on identical inputs.
// 2. Matcher: the simulator's parameterized gate, at the PRODUCTION parameters
//    (floor 0.60, maturity bonus ON, separation 0.05), must reduce EXACTLY to the REAL
//    public Transcription.matchAgainstProfiles on the same profile snapshot + queries.
//
// Exits non-zero on any mismatch, so it can gate CI / the sweep.

import Foundation
import TranscriptedCore

// deterministic LCG so the parity vectors are reproducible (no Date/random dependence)
struct LCG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }

func randVec(_ dim: Int, _ rng: inout LCG) -> [Float] {
    (0..<dim).map { _ in Float(rng.next() * 2 - 1) }
}

/// Standalone replica of LadderSweep.gateMatch over [SpeakerProfile] at given params —
/// the EXACT logic the sweep uses; compared head-to-head against matchAgainstProfiles.
func paramMatch(_ query: [Float], _ profiles: [SpeakerProfile],
                floor: Double, maturityBonus: Bool, separationCheck: Bool, separationGap: Double = 0.05) -> (UUID?, Double) {
    var bestIdx = -1; var best = -2.0; var second = -2.0; var bestCall = 0
    for i in 0..<profiles.count where profiles[i].disputeCount == 0 {
        guard profiles[i].embedding.count == query.count else { continue }
        let s = Transcription.cosineSimilarityStatic(query, profiles[i].embedding)
        if s > best { second = best; best = s; bestIdx = i; bestCall = profiles[i].callCount }
        else if s > second { second = s }
    }
    if bestIdx < 0 { return (nil, best) }
    var eff = floor
    if maturityBonus { eff += (bestCall <= 2 ? 0.08 : (bestCall <= 4 ? 0.04 : 0.0)) }
    if best < eff { return (nil, best) }
    if separationCheck && second >= floor && (best - second) < separationGap { return (nil, best) }
    return (profiles[bestIdx].id, best)
}

@available(macOS 14.0, *)
func runLadderParity(_ args: [String]) async {
    func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    var fail = 0
    let dim = 256

    // ---- 1. EMA parity vs real SpeakerDatabase.addOrUpdateSpeaker ----
    var rng = LCG(s: 0xC0FFEE)
    let dbPath = NSTemporaryDirectory() + "ladder-parity-\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: dbPath) }
    let db = await SpeakerDatabase(path: dbPath)
    var emaMax = 0.0
    for _ in 0..<200 {
        let v0 = randVec(dim, &rng)
        let v1 = randVec(dim, &rng)
        let p0 = await MainActor.run { db.addOrUpdateSpeaker(embedding: v0) }       // create (normalizes v0)
        let p1 = await MainActor.run { db.addOrUpdateSpeaker(embedding: v1, existingId: p0.id) }  // EMA blend (alpha 0.15)
        let mine = emaBlend(existing: p0.embedding, incoming: v1, alpha: 0.15)
        for i in 0..<dim { emaMax = max(emaMax, abs(Double(p1.embedding[i] - mine[i]))) }
        // delete so the DB stays small / matcher unaffected
        _ = await MainActor.run { db.deleteSpeaker(id: p0.id) }
    }
    let emaPass = emaMax < 1e-5
    log("[parity] EMA blend vs SpeakerDatabase.addOrUpdateSpeaker: maxAbsDiff=\(String(format: "%.2e", emaMax)) -> \(emaPass ? "PASS" : "FAIL")")
    if !emaPass { fail += 1 }

    // ---- 2. Matcher parity vs real Transcription.matchAgainstProfiles ----
    var rng2 = LCG(s: 0xBADF00D)
    var mismatches = 0, simMax = 0.0, cases = 0
    for trial in 0..<400 {
        // build 2–6 profiles with varied callCount/disputeCount, some embeddings deliberately close
        let nProf = 2 + (trial % 5)
        var profiles: [SpeakerProfile] = []
        let anchor = l2norm(randVec(dim, &rng2))
        for j in 0..<nProf {
            // half the profiles near the anchor (exercise separation), half random
            let base = j % 2 == 0 ? anchor : l2norm(randVec(dim, &rng2))
            let jitter = randVec(dim, &rng2).map { $0 * 0.08 }
            let emb = l2norm(zip(base, jitter).map { $0 + $1 })
            profiles.append(SpeakerProfile(id: UUID(), displayName: "p\(j)", nameSource: nil,
                embedding: emb, firstSeen: Date(), lastSeen: Date(),
                callCount: [1, 2, 3, 5, 9][j % 5], confidence: 0.5,
                disputeCount: (j == nProf - 1 && trial % 7 == 0) ? 1 : 0))
        }
        // queries: near anchor + random, across a similarity range
        for _ in 0..<4 {
            let mix = randVec(dim, &rng2).map { $0 * 0.2 }
            let q = l2norm(zip(anchor, mix).map { $0 + $1 })
            cases += 1
            let real = Transcription.matchAgainstProfiles(q, profiles: profiles, threshold: 0.60)
            let mine = paramMatch(q, profiles, floor: 0.60, maturityBonus: true, separationCheck: true)
            let realId = real?.profileId, mineId = mine.0
            if realId != mineId { mismatches += 1; continue }
            if let r = real { simMax = max(simMax, abs(r.similarity - mine.1)) }
        }
    }
    let matchPass = mismatches == 0 && simMax < 1e-9
    log("[parity] matcher vs Transcription.matchAgainstProfiles: \(cases) cases, \(mismatches) decision mismatches, simMaxDiff=\(String(format: "%.2e", simMax)) -> \(matchPass ? "PASS" : "FAIL")")
    if !matchPass { fail += 1 }

    if fail == 0 { log("[parity] ALL PASS — simulator math is faithful to production") }
    else { die("\(fail) parity check(s) FAILED") }
}

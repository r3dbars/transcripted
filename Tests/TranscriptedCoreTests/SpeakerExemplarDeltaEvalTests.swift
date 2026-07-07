import XCTest
@testable import TranscriptedCore

/// Corpus-gated A/B eval that measures the accuracy delta of the two speaker-identity features that
/// merged into `main` in 2026-07 — multi-exemplar voiceprints (#1488) and negative exemplars
/// (#1487) — on **real** per-quality speaker embeddings (AMI + VoxCeleb, re-encoded through the
/// audio-degradation matrix and re-dumped by the real diarizer).
///
/// It is a measurement harness, not a pass/fail regression: it enrolls mature profiles through the
/// real `SpeakerDatabase` (real EMA blend + real `SpeakerExemplarPolicy` exemplar maintenance) and
/// then scores held-out, cross-condition trials two ways using the *same production functions*:
///   - **WITH**   — `SpeakerVectorMath.bestSimilarity` (average + stored exemplars) and the real
///                  `SpeakerNegativeExemplarPolicy` veto (both features live).
///   - **WITHOUT** — `SpeakerVectorMath.cosineSimilarity` against the blended average only, no veto
///                  (the legacy single-average matcher, i.e. the pre-#1487/#1488 behavior).
/// The auto-name decision in both arms is the real `SpeakerNamingPolicy.shouldAutoAccept`
/// (0.92 similarity bar + 0.12 best-vs-second margin), so the numbers are read at the certified
/// operating point.
///
/// The corpus (11 GB of cached fingerprints) is not in-tree, so the whole test XCTSkip's unless
/// `SPEAKER_EVAL_QMATRIX_DIR` points at a directory of `<corpus>_<quality>/fingerprints.json`
/// caches (produced by `Tools/SpeakerEvalHarness` `ladder-fingerprints`). Results are written as
/// JSON to `SPEAKER_EVAL_OUT` (default: a temp file, path printed) for the report to fold in.
@available(macOS 14.0, *)
final class SpeakerExemplarDeltaEvalTests: XCTestCase {

    // MARK: Fingerprint cache schema (mirror of Tools/SpeakerEvalHarness/Fingerprints.swift)
    private struct FpSpeaker: Codable {
        let gtSpeaker: String
        let embedding: [Float]
        let segmentCount: Int
    }
    private struct FpMeeting: Codable {
        let meeting: String
        let order: Int
        let speakers: [FpSpeaker]
    }
    private struct FpCache: Codable {
        let corpus: String
        let meetings: [FpMeeting]
    }

    private struct Appearance {
        let quality: String
        let meeting: String
        let embedding: [Float]
        let segmentCount: Int
    }

    private struct Profile {
        let gt: String
        let id: UUID
        let average: [Float]
        let exemplars: [[Float]]
        let callCount: Int
    }

    // Operating point (matches production SpeakerNamingPolicy / SpeakerEmbeddingThresholds.weSpeaker).
    private let matchFloor = 0.70          // matchManySegments — mature profile DB-match floor
    private let autoBar = SpeakerNamingPolicy.autoAcceptSimilarityThreshold   // 0.92
    private let marginMin = SpeakerNamingPolicy.autoAcceptMarginMin           // 0.12
    private let emaAlpha: Float = 0.15     // production profile EMA (SpeakerDatabase blend)

    // Held-out degraded conditions the returning voice arrives in (VoIP / telephone / noise / room).
    private let testQualities = ["opus_8k", "tel_g711", "noisy_snr5", "reverb", "mp3_16"]

    func testExemplarDeltaOnRealQmatrixFingerprints() throws {
        guard let root = ProcessInfo.processInfo.environment["SPEAKER_EVAL_QMATRIX_DIR"] else {
            throw XCTSkip("Set SPEAKER_EVAL_QMATRIX_DIR to a dir of <corpus>_<quality>/fingerprints.json caches to run.")
        }
        var report: [String: Any] = [
            "operatingPoint": ["autoBar": autoBar, "marginMin": marginMin, "matchFloor": matchFloor],
            "note": "WITH = multi-exemplar bestSimilarity + negative veto (main). WITHOUT = single-average cosine, no veto (legacy).",
        ]
        var corpora: [[String: Any]] = []

        for (corpus, qualities) in [
            ("ami", ["orig", "mp3_32", "opus_8k", "tel_g711", "noisy_snr5", "reverb"]),
            ("voxceleb", ["orig", "mp3_64", "mp3_32", "mp3_16", "opus_16k", "opus_8k", "tel_g711", "noisy_snr5", "noisy_snr10", "reverb"]),
        ] {
            guard let bySpeaker = try loadCorpus(root: root, corpus: corpus, qualities: qualities), !bySpeaker.isEmpty else {
                continue
            }
            let result = try runCorpus(corpus: corpus, bySpeaker: bySpeaker)
            corpora.append(result)
        }

        guard !corpora.isEmpty else {
            throw XCTSkip("No corpora found under \(root) (expected e.g. ami_orig/fingerprints.json).")
        }
        report["corpora"] = corpora

        // Emit artifact.
        let outPath = ProcessInfo.processInfo.environment["SPEAKER_EVAL_OUT"]
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("exemplar-delta-\(UUID().uuidString).json").path
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outPath))
        print("SPEAKER_EVAL_OUT_WRITTEN \(outPath)")
        FileHandle.standardOutput.write(("\n" + (String(data: data, encoding: .utf8) ?? "") + "\n").data(using: .utf8)!)

        // Sanity gates: the eval actually exercised the features and produced monotone genuine sims.
        for c in corpora {
            let name = c["corpus"] as? String ?? "?"
            let with = c["with"] as? [String: Any] ?? [:]
            let without = c["without"] as? [String: Any] ?? [:]
            let mWith = with["meanGenuineSim"] as? Double ?? 0
            let mWithout = without["meanGenuineSim"] as? Double ?? 0
            XCTAssertGreaterThanOrEqual(mWith, mWithout - 1e-9,
                "\(name): multi-exemplar must be monotone non-decreasing on genuine similarity")
            XCTAssertGreaterThan(c["profiles"] as? Int ?? 0, 0, "\(name): no profiles enrolled")
        }
    }

    // MARK: Load

    private func loadCorpus(root: String, corpus: String, qualities: [String]) throws -> [String: [Appearance]]? {
        var bySpeaker: [String: [Appearance]] = [:]
        var found = false
        let dec = JSONDecoder()
        for q in qualities {
            let path = "\(root)/\(corpus)_\(q)/fingerprints.json"
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            found = true
            let cache = try dec.decode(FpCache.self, from: data)
            for m in cache.meetings {
                for s in m.speakers {
                    bySpeaker[s.gtSpeaker, default: []].append(
                        Appearance(quality: q, meeting: m.meeting, embedding: s.embedding, segmentCount: s.segmentCount))
                }
            }
        }
        return found ? bySpeaker : nil
    }

    // MARK: Enroll + score one corpus

    private func runCorpus(corpus: String, bySpeaker: [String: [Appearance]]) throws -> [String: Any] {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("exemplar-eval-\(corpus)-\(UUID().uuidString).sqlite").path
        let db = SpeakerDatabase(path: dbPath)
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        var profiles: [Profile] = []
        var testTrials: [(gt: String, emb: [Float])] = []          // held-out degraded, all speakers
        // held-out utterances per speaker, keyed for the veto experiment (test conditions only)
        var testBySpeaker: [String: [(quality: String, emb: [Float])]] = [:]

        // Deterministic order: sort speakers and, within a speaker, sort by (meeting, quality).
        for gt in bySpeaker.keys.sorted() {
            let apps = bySpeaker[gt]!.sorted { ($0.meeting, $0.quality) < ($1.meeting, $1.quality) }
            let meetings = Array(Set(apps.map { $0.meeting })).sorted()
            guard meetings.count >= 3 else { continue }
            let k = max(1, Int((Double(meetings.count) * 0.6).rounded()))
            let enrollMeetings = Set(meetings.prefix(k))
            let testMeetings = Set(meetings.suffix(meetings.count - k))

            // Enroll: every quality within the enroll meetings → a mature, multi-condition profile.
            let enrollMeans = apps.filter { enrollMeetings.contains($0.meeting) }.map { $0.embedding }
            guard enrollMeans.count >= 2 else { continue }
            var id: UUID? = nil
            var last: SpeakerProfile? = nil
            for mean in enrollMeans {
                let p = db.addOrUpdateSpeaker(embedding: mean, existingId: id, blendAlpha: emaAlpha)
                id = p.id
                last = p
            }
            guard let pid = id, let lp = last else { continue }
            profiles.append(Profile(gt: gt, id: pid, average: lp.embedding, exemplars: lp.exemplars, callCount: lp.callCount))

            // Held-out degraded trials.
            for a in apps where testMeetings.contains(a.meeting) && testQualities.contains(a.quality) {
                testTrials.append((gt: gt, emb: a.embedding))
                testBySpeaker[gt, default: []].append((quality: a.quality, emb: a.embedding))
            }
        }

        // Cross-check that the DB attached exemplars for at least some profiles (feature is live).
        let profilesWithExemplars = profiles.filter { !$0.exemplars.isEmpty }.count

        // ---- Experiment 1: identification at the operating point, WITH vs WITHOUT ----
        let with = scoreArm(profiles: profiles, trials: testTrials, useExemplars: true)
        let without = scoreArm(profiles: profiles, trials: testTrials, useExemplars: false)

        // ---- Experiment 2: negative-exemplar veto after a correction ----
        let veto = vetoExperiment(profiles: profiles, testBySpeaker: testBySpeaker, db: db)

        return [
            "corpus": corpus,
            "profiles": profiles.count,
            "profilesWithExemplars": profilesWithExemplars,
            "trials": testTrials.count,
            "testQualities": testQualities,
            "with": with,
            "without": without,
            "veto": veto,
        ]
    }

    /// Identification metrics for one arm at the certified operating point.
    private func scoreArm(profiles: [Profile], trials: [(gt: String, emb: [Float])], useExemplars: Bool) -> [String: Any] {
        var recallAtFloor = 0
        var autoCorrect = 0          // genuine, silently + correctly recognized
        var falseAuto = 0            // WRONG identity silently auto-named (the dangerous case)
        var impostorFAatFloor = 0    // any non-self profile clears the match floor
        var genuineSimSum = 0.0
        var genuineSimN = 0

        for trial in trials {
            // Score against every gallery profile (best rep for WITH, average for WITHOUT).
            var best = (sim: -2.0, gt: "", cc: 0, ex: [[Float]]())
            var second = -2.0
            var bestImpostor = -2.0
            for p in profiles {
                let sim = useExemplars
                    ? SpeakerVectorMath.bestSimilarity(candidate: trial.emb, average: p.average, exemplars: p.exemplars)
                    : SpeakerVectorMath.cosineSimilarity(trial.emb, p.average)
                if p.gt != trial.gt { bestImpostor = max(bestImpostor, sim) }
                if sim > best.sim {
                    second = best.sim
                    best = (sim, p.gt, p.callCount, p.exemplars)
                } else if sim > second {
                    second = sim
                }
            }
            if bestImpostor >= matchFloor { impostorFAatFloor += 1 }

            // Real auto-accept decision on the argmax profile (named + mature so eligibility holds
            // exactly when callCount > 4; margin/similarity gates come from production).
            let named = namedMatureProfile(gt: best.gt, callCount: best.cc, average: [], exemplars: best.ex)
            let autoAccept = SpeakerNamingPolicy.shouldAutoAccept(
                profile: named, similarity: best.sim, secondBestSimilarity: second)

            if best.gt == trial.gt {
                genuineSimSum += best.sim; genuineSimN += 1
                if best.sim >= matchFloor { recallAtFloor += 1 }
                if autoAccept { autoCorrect += 1 }
            } else if autoAccept {
                falseAuto += 1
            }
        }
        let n = max(1, trials.count)
        return [
            "recallAtFloor": Double(recallAtFloor) / Double(n),
            "autoCorrect": Double(autoCorrect) / Double(n),
            "falseAuto": Double(falseAuto) / Double(n),
            "falseAutoCount": falseAuto,
            "impostorFAatFloor": Double(impostorFAatFloor) / Double(n),
            "meanGenuineSim": genuineSimN > 0 ? genuineSimSum / Double(genuineSimN) : 0,
        ]
    }

    /// Failure mode (b): after a wrong match B→A is corrected (B's session mean stored as a negative
    /// exemplar on A), does a *later* B utterance still re-match A (legacy) or get vetoed (WITH)?
    ///
    /// For every confusable ordered pair (A, B) — a B utterance `u1` that wrongly clears A's match
    /// floor — `u1` is recorded as A's negative exemplar and every *other* held-out B utterance `u2`
    /// is replayed. We report, over those replays:
    ///   - reMatchRateLegacy — u2 still clears A's floor (the repeat wrong match the veto must fix).
    ///   - vetoedRate / vetoedAmongReMatch — how often the veto fires, and specifically how much of
    ///     the legacy wrong re-match it removes (the actual fix rate).
    ///   - vetoableShare — u2 resembles the rejected sample ≥ the 0.80 veto floor (the precondition).
    ///   - sameCondition* — the veto's designed case: u2 arrives in the SAME audio quality as u1.
    ///   - ownerCollateralRate — A's own voice wrongly vetoed by B's negative (must stay ~0).
    private func vetoExperiment(profiles: [Profile], testBySpeaker: [String: [(quality: String, emb: [Float])]], db: SpeakerDatabase) -> [String: Any] {
        var confusablePairs = 0
        var replays = 0, reMatch = 0, vetoed = 0, vetoedAndReMatch = 0, vetoable = 0
        var sameCondReplays = 0, sameCondReMatch = 0, sameCondVetoed = 0
        var ownerCollateral = 0, ownerChecks = 0

        // DB round-trip sanity: the store persists + reads a negative exemplar (real write path).
        if let a = profiles.first, let bEmb = testBySpeaker[profiles.dropFirst().first?.gt ?? ""]?.first?.emb {
            db.recordNegativeExemplar(profileId: a.id, embedding: bEmb)
            XCTAssertFalse((db.negativeExemplarsByProfile()[a.id] ?? []).isEmpty, "negative exemplar store failed to persist")
        }

        for a in profiles {
            let ownUtterances = testBySpeaker[a.gt] ?? []
            for b in profiles where b.gt != a.gt {
                guard let bUtterances = testBySpeaker[b.gt], bUtterances.count >= 2 else { continue }
                let u1 = bUtterances[0]
                let pos1 = SpeakerVectorMath.bestSimilarity(candidate: u1.emb, average: a.average, exemplars: a.exemplars)
                guard pos1 >= matchFloor else { continue }   // B's first utterance is confusable with A
                confusablePairs += 1
                let negatives = [SpeakerVectorMath.l2Normalize(u1.emb)]

                for u2 in bUtterances.dropFirst() {
                    replays += 1
                    let pos2 = SpeakerVectorMath.bestSimilarity(candidate: u2.emb, average: a.average, exemplars: a.exemplars)
                    let didReMatch = pos2 >= matchFloor
                    let didVeto = SpeakerNegativeExemplarPolicy.shouldVeto(
                        candidate: u2.emb, positiveSimilarity: pos2, negativeExemplars: negatives)
                    let negSim = SpeakerVectorMath.cosineSimilarity(u2.emb, negatives[0])
                    if didReMatch { reMatch += 1 }
                    if didVeto { vetoed += 1 }
                    if didReMatch && didVeto { vetoedAndReMatch += 1 }
                    if negSim >= SpeakerNegativeExemplarPolicy.vetoFloor { vetoable += 1 }
                    if u2.quality == u1.quality {
                        sameCondReplays += 1
                        if didReMatch { sameCondReMatch += 1 }
                        if didVeto { sameCondVetoed += 1 }
                    }
                }
                // Collateral: A's own held-out utterances must not be vetoed by B's negative.
                for own in ownUtterances {
                    ownerChecks += 1
                    let posOwn = SpeakerVectorMath.bestSimilarity(candidate: own.emb, average: a.average, exemplars: a.exemplars)
                    if SpeakerNegativeExemplarPolicy.shouldVeto(candidate: own.emb, positiveSimilarity: posOwn, negativeExemplars: negatives) {
                        ownerCollateral += 1
                    }
                }
            }
        }
        func rate(_ x: Int, _ y: Int) -> Double { y > 0 ? Double(x) / Double(y) : 0 }
        return [
            "confusablePairs": confusablePairs,
            "replays": replays,
            "reMatchRateLegacy": rate(reMatch, replays),
            "vetoedRate": rate(vetoed, replays),
            "vetoedAmongReMatch": rate(vetoedAndReMatch, reMatch),   // fraction of wrong re-matches the veto removes
            "vetoableShare": rate(vetoable, replays),               // u2 resembles rejected sample >= 0.80
            "reMatchCount": reMatch, "vetoedCount": vetoed, "vetoedAndReMatchCount": vetoedAndReMatch,
            "sameCondition": [
                "replays": sameCondReplays,
                "reMatchRateLegacy": rate(sameCondReMatch, sameCondReplays),
                "vetoedRate": rate(sameCondVetoed, sameCondReplays),
            ],
            "ownerCollateralRate": rate(ownerCollateral, ownerChecks),
            "ownerChecks": ownerChecks,
        ]
    }

    private func namedMatureProfile(gt: String, callCount: Int, average: [Float], exemplars: [[Float]]) -> SpeakerProfile {
        SpeakerProfile(
            id: UUID(),
            displayName: gt.isEmpty ? "spk" : gt,
            nameSource: "userManual",
            embedding: average,
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: callCount,
            confidence: 0.9,
            disputeCount: 0,
            exemplars: exemplars)
    }
}

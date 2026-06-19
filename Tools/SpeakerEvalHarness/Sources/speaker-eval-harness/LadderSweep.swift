// ladder-sweep — Stage 3 of the multi-meeting confidence-ladder eval.
//
// Replays the policy-independent fingerprint cache (Stage 2) through a parameterized
// AUTO / SUGGEST / UNKNOWN promotion ladder, for every policy in a swept grid, and
// measures how few times a user must TYPE or TAP before a returning speaker is
// recognized at near-zero false-positive (false-AUTO) rate.
//
// REUSE OF PRODUCTION CODE (so results transfer):
//   - Matching similarity: REAL Transcription.cosineSimilarityStatic (public).
//   - The production matcher's maturity bonus (+0.08 ≤2 calls, +0.04 for 3–4) and 0.05
//     separation/ambiguity rejection are replicated here as toggleable gate options; the
//     `ladder-parity` subcommand asserts this generalized matcher reduces EXACTLY to the
//     real Transcription.matchAgainstProfiles at the production parameters.
//   - Enrollment EMA blend is ported VERBATIM from SpeakerDatabase.addOrUpdateSpeakerImpl
//     (alpha·new + (1-alpha)·old, then L2-normalize; confidence += 0.1; callCount += 1) and
//     `ladder-parity` asserts byte-for-byte agreement (≤1e-5) with the real public
//     SpeakerDatabase.addOrUpdateSpeaker on the same inputs.
//   - Fingerprints come from the REAL diarizer + EmbeddingClusterer.postProcess +
//     Transcription.computeMeanEmbedding (Stage 1/2).
//
// NOTHING in production behavior is changed — the only production diff in this PR is making
// three already-pure `nonisolated static` functions `public` so the harness can call them.

import Foundation
import TranscriptedCore

// MARK: - Vector helpers (EMA port)

func l2norm(_ v: [Float]) -> [Float] {
    var n: Float = 0
    for x in v { n += x * x }
    n = n.squareRoot()
    guard n > 0 else { return v }
    return v.map { $0 / n }
}

/// VERBATIM port of SpeakerDatabase.addOrUpdateSpeakerImpl update branch (alpha=0.15 there;
/// parameterized here): blended[i] = old[i]*(1-alpha) + new[i]*alpha, then L2-normalize.
func emaBlend(existing: [Float], incoming: [Float], alpha: Float) -> [Float] {
    let blended = zip(existing, incoming).map { old, new in old * (1 - alpha) + new * alpha }
    return l2norm(blended)
}

func vadd(_ a: inout [Float], _ b: [Float]) { for i in 0..<min(a.count, b.count) { a[i] += b[i] } }

// MARK: - Policy

enum PromotionRule: Equatable {
    case fixedCount(Int)     // AUTO requires callCount > N (production: N=4)
    case evidence(Double)    // AUTO requires accumulated evidence score >= target

    var ruleName: String { switch self { case .fixedCount: return "fixed"; case .evidence: return "evidence" } }
    var param: Double { switch self { case .fixedCount(let n): return Double(n); case .evidence(let t): return t } }
}

enum DemoteMode: String { case off, demote, demoteUnblend }

struct Policy {
    var id: Int
    var isBaseline: Bool = false
    var suggestFloor: Double
    var autoBar: Double
    var marginMin: Double
    var promotion: PromotionRule
    var emaAlpha: Float
    var demote: DemoteMode
    var maturityBonus: Bool
    var separationCheck: Bool
    var separationGap: Double = 0.05
}

// MARK: - Simulated profile

struct SimProfile {
    let label: String          // ground-truth identity the user typed (== displayName)
    var embedding: [Float]
    var callCount: Int
    var disputeCount: Int
    var confidence: Double
    var evidence: Double
    var named: Bool
    // contamination tracking
    var cleanSum: [Float]      // running sum of CORRECTLY-attributed fingerprints
    var cleanCount: Int
    var poisoned: Bool         // ever received a false-AUTO blend
    var prePoison: [Float]?    // snapshot before first poison (for un-blend rollback)
}

// MARK: - Per-policy result

struct PolicyResult {
    var p: Policy
    var nPeople = 0
    var appearances = 0
    var types = 0
    var taps = 0
    var corrections = 0
    var unknowns = 0
    var falseUnknowns = 0      // UNKNOWN/type that merged into an existing (missed recurrence)
    var suggests = 0
    var suggestWrong = 0
    var autos = 0
    var autoWrong = 0          // FALSE-AUTO (the metric driven toward zero)
    var reachedAuto = 0
    var meetingsToAuto: [Int] = []
    var contamDrift: [Double] = []
    var poisonedProfiles = 0
    // re-ID by appearance ordinal: correct-resolution fraction (not mislabeled) at ordinal k
    var apprCorrect: [Int: Int] = [:]
    var apprTotal: [Int: Int] = [:]

    var prompts: Int { types + taps }
    var falseAutoRate: Double { autos > 0 ? Double(autoWrong) / Double(autos) : 0 }
    var suggestPrecision: Double { suggests > 0 ? Double(suggests - suggestWrong) / Double(suggests) : 0 }
    var promptsPerPerson: Double { nPeople > 0 ? Double(prompts) / Double(nPeople) : 0 }
    var typesPerPerson: Double { nPeople > 0 ? Double(types) / Double(nPeople) : 0 }
    var tapsPerPerson: Double { nPeople > 0 ? Double(taps) / Double(nPeople) : 0 }
    var pctReachedAuto: Double { nPeople > 0 ? Double(reachedAuto) / Double(nPeople) : 0 }
    var medMeetingsToAuto: Double { median(meetingsToAuto.map(Double.init)) }
    var meanContamDrift: Double { contamDrift.isEmpty ? 0 : contamDrift.reduce(0,+) / Double(contamDrift.count) }
    func apprAcc(_ k: Int) -> Double {
        guard let t = apprTotal[k], t > 0 else { return -1 }
        return Double(apprCorrect[k] ?? 0) / Double(t)
    }
}

func median(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return -1 }
    let s = xs.sorted()
    let n = s.count
    return n % 2 == 1 ? s[n/2] : (s[n/2 - 1] + s[n/2]) / 2
}

// MARK: - Simulation core

func evidenceIncrement(sim: Double, floor: Double, marginGate: Double) -> Double {
    let above = max(0.0, sim - floor)
    let m = marginGate.isFinite ? min(max(0.0, marginGate), 0.2) : 0.2
    return above + 0.25 * m
}

func promotionMet(_ p: SimProfile, _ policy: Policy) -> Bool {
    switch policy.promotion {
    case .fixedCount(let n): return p.callCount > n
    case .evidence(let t):   return p.evidence >= t
    }
}

func simulate(_ policy: Policy, _ cache: FpCache,
              tracePath: String? = nil) -> PolicyResult {
    var r = PolicyResult(p: policy)
    var profiles: [SimProfile] = []
    var byLabel: [String: Int] = [:]
    var apprOrdinal: [String: Int] = [:]              // per-person appearance counter
    var perPerson: [String: (types: Int, taps: Int, corrections: Int, firstAuto: Int)] = [:]

    var trace: [String] = []
    let doTrace = tracePath != nil
    if doTrace { trace.append("meeting,order,gtSpeaker,apprOrdinal,tier,correct,bestSim,secondSim,marginGate,candLabel,callCount") }

    func ensurePerson(_ lbl: String) {
        if perPerson[lbl] == nil { perPerson[lbl] = (0, 0, 0, -1) }
    }

    // Match: returns gate candidate index (post floor/maturity/separation) + raw best/second.
    func gateMatch(_ query: [Float]) -> (cand: Int?, best: Double, second: Double) {
        var bestIdx = -1; var best = -2.0; var second = -2.0; var bestCall = 0
        for i in 0..<profiles.count where profiles[i].disputeCount == 0 {
            let s = Transcription.cosineSimilarityStatic(query, profiles[i].embedding)
            if s > best { second = best; best = s; bestIdx = i; bestCall = profiles[i].callCount }
            else if s > second { second = s }
        }
        if bestIdx < 0 { return (nil, best, second) }
        var eff = policy.suggestFloor
        if policy.maturityBonus { eff += (bestCall <= 2 ? 0.08 : (bestCall <= 4 ? 0.04 : 0.0)) }
        if best < eff { return (nil, best, second) }
        if policy.separationCheck && second >= policy.suggestFloor && (best - second) < policy.separationGap {
            return (nil, best, second)
        }
        return (bestIdx, best, second)
    }

    func enroll(_ idx: Int, _ query: [Float], correct: Bool, sim: Double, marginGate: Double) {
        profiles[idx].embedding = emaBlend(existing: profiles[idx].embedding, incoming: query, alpha: policy.emaAlpha)
        profiles[idx].callCount += 1
        profiles[idx].confidence = min(1.0, profiles[idx].confidence + 0.1)
        profiles[idx].evidence += evidenceIncrement(sim: sim, floor: policy.suggestFloor, marginGate: marginGate)
        if correct {
            vadd(&profiles[idx].cleanSum, query)
            profiles[idx].cleanCount += 1
        } else {
            if !profiles[idx].poisoned { profiles[idx].prePoison = profiles[idx].embedding; profiles[idx].poisoned = true }
        }
    }

    func createProfile(_ lbl: String, _ query: [Float]) {
        let n = l2norm(query)
        profiles.append(SimProfile(label: lbl, embedding: n, callCount: 1, disputeCount: 0,
                                   confidence: 0.5, evidence: 0, named: true,
                                   cleanSum: n, cleanCount: 1, poisoned: false, prePoison: nil))
        byLabel[lbl] = profiles.count - 1
    }

    // route a fingerprint to its correct profile (create or merge-by-name); returns whether new
    @discardableResult
    func routeToCorrect(_ gt: String, _ query: [Float], sim: Double, marginGate: Double) -> Bool {
        if let idx = byLabel[gt] {
            // repair a disputed profile when the user names it correctly
            if profiles[idx].disputeCount > 0 { profiles[idx].disputeCount = 0 }
            enroll(idx, query, correct: true, sim: sim, marginGate: marginGate)
            return false
        } else {
            createProfile(gt, query)
            return true
        }
    }

    for m in cache.meetings {
        for sp in m.speakers {
            let gt = sp.gtSpeaker
            let query = sp.embedding
            ensurePerson(gt)
            let ord = (apprOrdinal[gt] ?? 0) + 1
            apprOrdinal[gt] = ord
            r.appearances += 1
            r.apprTotal[min(ord, 8), default: 0] += 1

            let (cand, best, second) = gateMatch(query)
            let marginGate = (second >= policy.suggestFloor) ? (best - second) : Double.infinity

            var tier = "unknown"
            var correct = false
            var candLabel = ""
            var candCall = 0

            if cand == nil {
                tier = "unknown"
                r.unknowns += 1
                perPerson[gt]!.types += 1
                r.types += 1
                let existedBefore = byLabel[gt] != nil
                routeToCorrect(gt, query, sim: best, marginGate: marginGate)
                if existedBefore { r.falseUnknowns += 1 }   // missed recurrence
                correct = true   // user typed the right name -> transcript correct
            } else {
                let i = cand!
                candLabel = profiles[i].label
                candCall = profiles[i].callCount
                let promoted = promotionMet(profiles[i], policy)
                let autoOK = profiles[i].named && profiles[i].disputeCount == 0
                    && best > policy.autoBar && promoted && (marginGate >= policy.marginMin)
                if autoOK {
                    tier = "auto"
                    r.autos += 1
                    if candLabel == gt {
                        correct = true
                        enroll(i, query, correct: true, sim: best, marginGate: marginGate)
                        if perPerson[gt]!.firstAuto < 0 { perPerson[gt]!.firstAuto = ord }
                    } else {
                        correct = false
                        r.autoWrong += 1                       // FALSE-AUTO
                        enroll(i, query, correct: false, sim: best, marginGate: marginGate)  // silent poison
                        // true person NOT enrolled this meeting (their evidence eaten); not caught (worst case)
                    }
                } else {
                    tier = "suggest"
                    r.suggests += 1
                    if candLabel == gt {
                        correct = true
                        perPerson[gt]!.taps += 1
                        r.taps += 1                            // confirm tap
                        enroll(i, query, correct: true, sim: best, marginGate: marginGate)
                    } else {
                        correct = false
                        r.suggestWrong += 1
                        perPerson[gt]!.taps += 1
                        r.taps += 1                            // reject tap
                        perPerson[gt]!.corrections += 1
                        r.corrections += 1
                        if policy.demote != .off {
                            profiles[i].disputeCount += 1      // demote: exclude from future matching
                            if policy.demote == .demoteUnblend, let pre = profiles[i].prePoison {
                                profiles[i].embedding = pre     // un-blend any prior poison
                            }
                        }
                        // user then names the correct person: new type, or tap-select existing
                        let isNew = (byLabel[gt] == nil)
                        routeToCorrect(gt, query, sim: best, marginGate: marginGate)
                        if isNew { perPerson[gt]!.types += 1; r.types += 1 }
                        else { perPerson[gt]!.taps += 1; r.taps += 1 }
                    }
                }
            }

            if correct { r.apprCorrect[min(ord, 8), default: 0] += 1 }
            if doTrace {
                let marginStr = marginGate.isFinite ? fmt(marginGate) : "inf"
                trace.append("\(m.meeting),\(m.order),\(gt),\(ord),\(tier),\(correct),"
                    + "\(fmt(best)),\(fmt(second)),\(marginStr),\(candLabel),\(candCall)")
            }
        }
    }

    // finalize per-person + contamination
    r.nPeople = perPerson.count
    for (_, pp) in perPerson {
        if pp.firstAuto > 0 { r.reachedAuto += 1; r.meetingsToAuto.append(pp.firstAuto) }
    }
    for p in profiles {
        if p.poisoned { r.poisonedProfiles += 1 }
        if p.cleanCount > 0 {
            let clean = l2norm(p.cleanSum)
            let drift = 1.0 - Transcription.cosineSimilarityStatic(p.embedding, clean)
            r.contamDrift.append(drift)
        }
    }

    if let tp = tracePath {
        try? trace.joined(separator: "\n").write(toFile: tp, atomically: true, encoding: .utf8)
    }
    return r
}

func fmt(_ x: Double) -> String { String(format: "%.4f", x) }

// MARK: - Grid

func buildGrid() -> [Policy] {
    let floors = [0.40, 0.45, 0.50, 0.55, 0.60]
    let autoBars = [0.80, 0.83, 0.85, 0.88, 0.90, 0.92, 0.95]
    let margins = [0.00, 0.03, 0.05, 0.08, 0.12]
    let promotions: [PromotionRule] = [.fixedCount(2), .fixedCount(3), .fixedCount(4), .fixedCount(5),
                                       .evidence(0.25), .evidence(0.40), .evidence(0.60)]
    let alphas: [Float] = [0.10, 0.15, 0.25]
    let demotes: [DemoteMode] = [.off, .demote, .demoteUnblend]

    var grid: [Policy] = []
    var id = 0
    // Production baseline (explicit, plotted as the single baseline point)
    grid.append(Policy(id: id, isBaseline: true, suggestFloor: 0.60, autoBar: 0.88, marginMin: 0.0,
                       promotion: .fixedCount(4), emaAlpha: 0.15, demote: .demote,
                       maturityBonus: true, separationCheck: true)); id += 1

    // Main grid: maturity + separation ON (production safeguards); sweep the rest.
    for f in floors { for a in autoBars { for mg in margins {
        for promo in promotions { for al in alphas { for dm in demotes {
            grid.append(Policy(id: id, suggestFloor: f, autoBar: a, marginMin: mg,
                               promotion: promo, emaAlpha: al, demote: dm,
                               maturityBonus: true, separationCheck: true)); id += 1
        }}}
    }}}
    return grid
}

// Small ablation grid: toggle the production maturity bonus / separation check OFF.
func buildAblationGrid(startId: Int) -> [Policy] {
    var grid: [Policy] = []
    var id = startId
    let floors = [0.50, 0.55, 0.60]
    let autoBars = [0.85, 0.88, 0.92]
    for f in floors { for a in autoBars {
        for mb in [true, false] { for sc in [true, false] {
            if mb && sc { continue }   // already covered by main grid
            grid.append(Policy(id: id, suggestFloor: f, autoBar: a, marginMin: 0.0,
                               promotion: .fixedCount(4), emaAlpha: 0.15, demote: .demote,
                               maturityBonus: mb, separationCheck: sc)); id += 1
        }}
    }}
    return grid
}

// MARK: - CSV

func policyCSVHeader() -> String {
    "policyId,isBaseline,suggestFloor,autoBar,marginMin,promoRule,promoParam,emaAlpha,demote,"
    + "maturityBonus,separationCheck,nPeople,appearances,types,taps,corrections,prompts,"
    + "promptsPerPerson,typesPerPerson,tapsPerPerson,unknowns,falseUnknowns,suggests,suggestWrong,"
    + "suggestPrecision,autos,autoWrong,falseAutoRate,reachedAuto,pctReachedAuto,medMeetingsToAuto,"
    + "meanContamDrift,poisonedProfiles,acc1,acc2,acc3,acc4,acc5,acc6,acc7,acc8plus"
}

func policyCSVRow(_ r: PolicyResult) -> String {
    let p = r.p
    func a(_ k: Int) -> String { let v = r.apprAcc(k); return v < 0 ? "" : fmt(v) }
    return [
        "\(p.id)", p.isBaseline ? "1" : "0", fmt(p.suggestFloor), fmt(p.autoBar), fmt(p.marginMin),
        p.promotion.ruleName, fmt(p.promotion.param), String(format: "%.2f", p.emaAlpha), p.demote.rawValue,
        p.maturityBonus ? "1" : "0", p.separationCheck ? "1" : "0",
        "\(r.nPeople)", "\(r.appearances)", "\(r.types)", "\(r.taps)", "\(r.corrections)", "\(r.prompts)",
        fmt(r.promptsPerPerson), fmt(r.typesPerPerson), fmt(r.tapsPerPerson),
        "\(r.unknowns)", "\(r.falseUnknowns)", "\(r.suggests)", "\(r.suggestWrong)",
        fmt(r.suggestPrecision), "\(r.autos)", "\(r.autoWrong)", fmt(r.falseAutoRate),
        "\(r.reachedAuto)", fmt(r.pctReachedAuto), fmt(r.medMeetingsToAuto),
        fmt(r.meanContamDrift), "\(r.poisonedProfiles)",
        a(1), a(2), a(3), a(4), a(5), a(6), a(7), a(8),
    ].joined(separator: ",")
}

// MARK: - entry

@available(macOS 14.0, *)
func runLadderSweep(_ args: [String]) async {
    guard let fp = argValue("--fingerprints", in: args), let outDir = argValue("--out-dir", in: args) else {
        die("ladder-sweep requires --fingerprints <fingerprints.json> --out-dir <dir> [--corpus name]")
    }
    let fm = FileManager.default
    guard let data = fm.contents(atPath: fp),
          let cache = try? JSONDecoder().decode(FpCache.self, from: data) else { die("cannot read fingerprints \(fp)") }
    let corpus = argValue("--corpus", in: args) ?? cache.corpus
    try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let traceDir = "\(outDir)/traces"; try? fm.createDirectory(atPath: traceDir, withIntermediateDirectories: true)

    func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    var grid = buildGrid()
    grid.append(contentsOf: buildAblationGrid(startId: grid.count))
    log("[sweep] \(corpus): \(cache.meetings.count) meetings, \(cache.speakerAppearances.count) speakers, "
        + "\(grid.count) policies (\(grid.count - 1 - 0) swept + 1 baseline + ablation)")

    let policiesCSV = "\(outDir)/ladder_policies_\(corpus).csv"
    // checkpoint: write header, then append each policy row (so a long run is never lost)
    try? policyCSVHeader().write(toFile: policiesCSV, atomically: true, encoding: .utf8)
    guard let fh = FileHandle(forWritingAtPath: policiesCSV) else { die("cannot open \(policiesCSV)") }
    fh.seekToEndOfFile()
    fh.write(Data("\n".utf8))

    let t0 = Date()
    for (i, policy) in grid.enumerated() {
        // trace only the baseline (bounded output, no silent truncation: documented)
        let tp = policy.isBaseline ? "\(traceDir)/baseline_\(corpus).csv" : nil
        let r = simulate(policy, cache, tracePath: tp)
        fh.write(Data((policyCSVRow(r) + "\n").utf8))
        if (i + 1) % 500 == 0 || i + 1 == grid.count {
            try? fh.synchronize()
            let rate = Date().timeIntervalSince(t0) / Double(i + 1)
            log("[sweep] \(i + 1)/\(grid.count) policies (\(String(format: "%.1f", rate * 1000))ms/policy)")
        }
    }
    try? fh.close()
    log("[sweep] DONE \(corpus): \(grid.count) policies -> \(policiesCSV) "
        + "(\(String(format: "%.1f", Date().timeIntervalSince(t0)))s). Baseline trace -> \(traceDir)/baseline_\(corpus).csv")
}

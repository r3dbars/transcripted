#!/usr/bin/env python3
"""Recompute CLEANER speaker-matching metrics from replay results + RTTM.

Builds the full mass-based confusion matrix global_overlap[true_id][profile]
(seconds of reference/hypothesis co-occurrence) the same way score_speaker_eval.py
does internally, then derives:

  (a) identities correctly isolated (clean 1:1): true speakers whose speech is
      >=COVER captured by a single profile that is itself >=DOMINANCE that speaker.
  (b) profile purity: fraction of profiles >=PURITY dominated by one true speaker.
  (c) over-merge vs over-split decomposition of (profiles_end - 32).

Also reports mass-weighted total false-positive (merge) and false-negative (split)
fractions that are robust to mega-profile collapse, plus the matcher-controllable
"effective identity recovery" (sum of best 1:1 coverage, capped at 32).
"""
import argparse, json, glob, os, sys
from collections import defaultdict

def parse_rttm(path):
    out = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if not p or p[0] != "SPEAKER":
                continue
            start, dur, spk = float(p[3]), float(p[4]), p[7]
            out.append((start, start + dur, spk))
    return out

def overlap(a0, a1, b0, b1):
    return max(0.0, min(a1, b1) - max(a0, b0))

def build_overlap_matrix(ref, hyp):
    m = defaultdict(lambda: defaultdict(float))
    hyp = sorted(hyp, key=lambda x: x[0])
    for (rs, re, tid) in ref:
        for (hs, he, pid) in hyp:
            if hs >= re:
                break
            ov = overlap(rs, re, hs, he)
            if ov > 0:
                m[tid][pid] += ov
    return m

def load_global_overlap(result_path, rttm_dir):
    result = json.load(open(result_path))
    global_overlap = defaultdict(lambda: defaultdict(float))   # tid -> pid -> sec
    global_ref_time = defaultdict(float)                       # tid -> total ref sec
    for mr in result["meetings"]:
        meeting = mr["meeting"]
        ref = parse_rttm(f"{rttm_dir}/{meeting}.rttm")
        hyp = [(a["start"], a["end"], a["dbProfile"]) for a in mr["assignments"]]
        om = build_overlap_matrix(ref, hyp)
        # ref time per tid (count each tid's total reference duration once per meeting)
        ref_by_tid = defaultdict(float)
        for s, e, t in ref:
            ref_by_tid[t] += (e - s)
        for tid in om:
            global_ref_time[tid] += ref_by_tid[tid]
        for tid, secs in om.items():
            for pid, ov in secs.items():
                global_overlap[tid][pid] += ov
    return global_overlap, global_ref_time, result.get("profilesAtEnd")

def analyze(result_path, rttm_dir, COVER=0.50, DOMINANCE=0.50, PURITY=0.80, FRAC=0.10):
    go, ref_time, profiles_end = load_global_overlap(result_path, rttm_dir)

    # profile mass = total overlapped ref seconds attributed to that profile
    profile_mass = defaultdict(float)
    profile_to_true = defaultdict(lambda: defaultdict(float))
    for tid, profs in go.items():
        for pid, ov in profs.items():
            profile_mass[pid] += ov
            profile_to_true[pid][tid] += ov

    n_true = len(ref_time)            # should be 32 for AMI
    n_profiles = len(profile_mass)

    # ---- (a) identities correctly isolated: clean 1:1 ----
    isolated = []
    for tid, profs in go.items():
        tot_t = ref_time[tid] or 1.0
        ok = False
        for pid, ov in profs.items():
            cover = ov / tot_t
            dom = ov / (profile_mass[pid] or 1.0)
            if cover >= COVER and dom >= DOMINANCE:
                ok = True
                break
        if ok:
            isolated.append(tid)
    n_isolated = len(isolated)

    # ---- (b) profile purity: fraction of profiles >=PURITY one true speaker ----
    pure_profiles = 0
    for pid, mass in profile_mass.items():
        top = max(profile_to_true[pid].values()) if profile_to_true[pid] else 0.0
        if (top / (mass or 1.0)) >= PURITY:
            pure_profiles += 1
    purity_frac = pure_profiles / (n_profiles or 1)

    # ---- (c) over-split / over-merge decomposition ----
    # over-split: extra profiles created per identity (profiles >=FRAC of a person, minus 1)
    over_split = 0
    for tid, profs in go.items():
        tot_t = ref_time[tid] or 1.0
        k = sum(1 for pid, ov in profs.items() if ov / tot_t >= FRAC)
        over_split += max(0, k - 1)
    # over-merge: extra identities collapsed per profile (true speakers >=FRAC of mass, minus 1)
    over_merge = 0
    for pid, mass in profile_mass.items():
        k = sum(1 for tid, ov in profile_to_true[pid].items() if ov / (mass or 1.0) >= FRAC)
        over_merge += max(0, k - 1)

    # ---- mass-weighted FP / FN (collapse-robust) ----
    # FN mass = fraction of each person's speech NOT in their dominant profile (split loss)
    fn_mass_num = 0.0; fn_mass_den = 0.0
    for tid, profs in go.items():
        ov_total = sum(profs.values())
        best = max(profs.values()) if profs else 0.0
        fn_mass_num += ov_total - best  # this person's speech that landed in non-dominant profiles
        fn_mass_den += ov_total
    fn_mass = fn_mass_num / (fn_mass_den or 1.0)
    # FP mass = fraction of profile mass that is NOT the profile's dominant speaker (merge contamination)
    fp_mass_num = 0.0; fp_mass_den = 0.0
    for pid, mass in profile_mass.items():
        top = max(profile_to_true[pid].values()) if profile_to_true[pid] else 0.0
        fp_mass_num += (mass - top)
        fp_mass_den += mass
    fp_mass = fp_mass_num / (fp_mass_den or 1.0)

    # ---- effective identity recovery (matcher-controllable upper view) ----
    # sum over true speakers of best single-profile coverage (B-cubed-ish recall)
    recall_sum = 0.0
    for tid, profs in go.items():
        tot_t = ref_time[tid] or 1.0
        best = max(profs.values()) if profs else 0.0
        recall_sum += best / tot_t
    mean_recall = recall_sum / (n_true or 1)

    return {
        "profiles_end": profiles_end,
        "n_profiles_obs": n_profiles,
        "n_true": n_true,
        "isolated_1to1": n_isolated,
        "pure_profiles": pure_profiles,
        "purity_frac": round(purity_frac, 3),
        "over_split": over_split,
        "over_merge": over_merge,
        "gap_from_32": (profiles_end - 32) if profiles_end is not None else None,
        "fp_mass": round(fp_mass, 4),     # merge contamination (false positive)
        "fn_mass": round(fn_mass, 4),     # split loss (false negative)
        "mean_recall": round(mean_recall, 4),
    }

def find_result(arm_dir, match):
    for name in (f"cons_none_match_{match:.2f}.json", f"match_{match:.2f}.json"):
        p = os.path.join(arm_dir, "results", name)
        if os.path.exists(p):
            return p
    return None

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--eval-dir", default="data/eval")
    ap.add_argument("--rttm-dir", default="data/ami/rttm")
    ap.add_argument("--arms", default="clean,opus12k,opus8k,g711u")
    ap.add_argument("--modes", default="baseline,global")
    ap.add_argument("--matches", default="0.50,0.60,0.70")
    args = ap.parse_args()

    arms = args.arms.split(",")
    modes = args.modes.split(",")
    matches = [float(x) for x in args.matches.split(",")]

    rows = []
    for arm in arms:
        for mode in modes:
            arm_dir = os.path.join(args.eval_dir, f"ami_{arm}" if mode == "baseline" else f"ami_{arm}_{mode}")
            for match in matches:
                rp = find_result(arm_dir, match)
                if not rp:
                    print(f"MISSING {arm_dir} match={match}", file=sys.stderr)
                    continue
                r = analyze(rp, args.rttm_dir)
                r.update({"arm": arm, "mode": mode, "match": match})
                rows.append(r)
    print(json.dumps(rows, indent=2))

if __name__ == "__main__":
    main()

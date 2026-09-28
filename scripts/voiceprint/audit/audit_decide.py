#!/usr/bin/env python3
"""Answer-key audit: turn the evidence into drop lists.

Only overwhelming evidence becomes a drop:
  leak      shared audio across sessions (landmark fingerprints, hundreds of aligned hashes).
            vox1o: videos that are re-uploads / excerpts of each other are linked into one
            recording; per linked group the video with the most clips stays, the rest go. Videos
            that only share one intro utterance lose just the clips cut from that utterance.
  session   every panel model (4+ architecture families) puts the whole session closer to other
            speakers than to its own speaker's other sessions, each by a centered-cosine margin of
            at least 0.05: the session is somebody else.
  clip      every panel model puts the clip closer to another speaker (each normalized margin
            <= -0.10) AND every panel model finds it an outlier within its own speaker (robust z <= -3).
  annot     the corpus's own word alignment has another participant speaking inside the clip
            (ICSI NXT words; AMI manual words).
Everything else is reported, not dropped.

Writes VP/results/audit/drop_<set>.txt (seg_ids, one per line), drop_reasons.csv,
merge_vox1o_sessions.json (the alternative to dropping duplicate videos), decide.json.
"""
from __future__ import annotations

import collections
import csv
import json
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[3]
VP = REPO / "data" / "eval" / "voiceprint"
A = VP / "results" / "audit"
SETS = ("vox1o", "libri", "ami", "icsi", "yodas")
MIN_PANEL = 4


def rows_of(s):
    return [json.loads(l) for l in open(VP / "sets" / s / "segments.jsonl") if l.strip()]


def read_csv(p):
    if not Path(p).exists():
        return []
    with open(p) as f:
        return list(csv.DictReader(f))


def vox1o_leaks(rows, reasons):
    vp = read_csv(A / "leaks" / "vox1o_video_pairs.csv")
    clips_by_vid = collections.Counter(r["session"].split(":", 1)[1] for r in rows)
    par = {}

    def find(x):
        par.setdefault(x, x)
        while par[x] != x:
            par[x] = par[par[x]]
            x = par[x]
        return x
    dup, snip = [], []
    for p in vp:
        m, small = int(p["matched_utt_pairs"]), min(int(p["utts_a"]), int(p["utts_b"]))
        (dup if (m >= 2 or small <= 3) else snip).append(p)
    for p in dup:
        par[find(p["video_a"])] = find(p["video_b"])
    comp = collections.defaultdict(set)
    for p in dup:
        for v in (p["video_a"], p["video_b"]):
            comp[find(v)].add(v)
    keep_of = {}
    merge = {}
    for c in comp.values():
        keep = max(sorted(c), key=lambda v: clips_by_vid[v])
        for v in c:
            keep_of[v] = keep
            merge[f"vox1o:{v}"] = f"vox1o:{keep}"
    drop_vid = {v for v, k in keep_of.items() if v != k}
    for r in rows:
        v = r["session"].split(":", 1)[1]
        if v in drop_vid:
            reasons[r["seg_id"]].append(f"leak: video {v} is a re-upload/excerpt of {keep_of[v]} (kept)")
    # snippet pairs: only clips cut from the shared utterance(s); keep one side
    shared_utts = collections.defaultdict(set)   # video -> utt names
    for p in snip:
        for ex in p["examples"].split():
            ua, ub = ex.split(":")[0].split("~")
            shared_utts[p["video_a"]].add(ua)
            shared_utts[p["video_b"]].add(ub)
    snip_vids = sorted(shared_utts, key=lambda v: (-clips_by_vid[v], v))
    keeper = next((v for v in snip_vids if v not in drop_vid), None)
    for r in rows:
        v = r["session"].split(":", 1)[1]
        if v in shared_utts and v != keeper and r["src"]["file"].split("/")[-1] in shared_utts[v]:
            reasons[r["seg_id"]].append(f"leak: cut from utterance shared with another video ({r['src']['file'].split('/')[-1]})")
    # trial impact
    fp = read_csv(A / "leaks" / "clips_shared_audio.csv")
    shared = {frozenset((x["a"], x["b"])) for x in fp if x["a"].startswith("vox1o") and x["same_session"] == "False" and int(x["match"]) >= 15}
    impact = {}
    tt = tl = ta = 0
    for b in (2, 4, 8):
        p = VP / "results" / "trials" / f"vox1o__b{b}.npz"
        if not p.exists():
            continue
        z = np.load(p)
        ids = z["seg_ids"]
        vid = np.asarray([i.split(":")[2] for i in ids])
        mv = np.asarray([keep_of.get(v, v) for v in vid])
        lab = z["label"] == 1
        e, t = z["enroll"][lab], z["test"][lab]
        leak = int((mv[e] == mv[t]).sum())
        aud = int(sum(frozenset((ids[a], ids[c])) in shared for a, c in zip(e, t)))
        impact[f"b{b}"] = {"targets": int(lab.sum()), "same_recording": leak, "shared_audio": aud}
        tt += int(lab.sum())
        tl += leak
        ta += aud
    impact["total"] = {"targets": tt, "same_recording": tl, "shared_audio": ta,
                       "same_recording_pct": round(100 * tl / max(tt, 1), 2)}
    # anything shared across sessions that survives the drops?
    dropped = {k for k, v in reasons.items() if v}
    left = [x for x in fp if x["a"].startswith("vox1o") and x["same_session"] == "False" and int(x["match"]) >= 25
            and x["a"] not in dropped and x["b"] not in dropped]
    return {"dup_video_pairs": len(dup), "snippet_video_pairs": len(snip), "linked_groups": len(comp),
            "videos_in_groups": sum(len(c) for c in comp.values()), "videos_dropped": len(drop_vid),
            "trial_impact": impact, "shared_audio_pairs_left_after_drop": len(left)}, merge


def label_drops(s, reasons, summary):
    info = summary.get(s, {})
    panel = info.get("panel", [])
    fams = set()
    for m in panel:
        fams.add(m.split("-")[0] if not m.startswith(("app-wespeaker", "wespeaker")) else "resnet")
    out = {"panel": panel, "session_drops": [], "clip_drops": []}
    if len(panel) < MIN_PANEL:
        out["note"] = f"panel has {len(panel)} models (< {MIN_PANEL}); no label drops"
        return out
    sess = read_csv(A / "labels" / f"{s}_sessions.csv")
    bad_sessions = set()
    for r in sess:
        margins = [float(r[f"margin_{m}"]) for m in panel if f"margin_{m}" in r]
        if len(margins) == len(panel) and max(margins) <= -0.05:
            bad_sessions.add((r["speaker"], r["session"]))
            out["session_drops"].append({"speaker": r["speaker"], "session": r["session"], "clips": r["clips"],
                                         "margins": [round(x, 3) for x in margins], "closest_other": r["closest_other"]})
    outl = {r["seg_id"]: float(r["z_least_extreme"]) for r in read_csv(A / "labels" / f"{s}_outliers.csv")}
    for r in read_csv(A / "labels" / f"{s}_clips.csv"):
        if int(r["n_models_closer_to_other"]) != len(panel) or int(r["panel"]) != len(panel):
            continue
        if float(r["max_norm_margin"]) > -0.10 or outl.get(r["seg_id"], 0) > -3:
            continue
        out["clip_drops"].append({"seg_id": r["seg_id"], "max_norm_margin": float(r["max_norm_margin"]),
                                  "z": outl[r["seg_id"]], "closest_other": r["closest_other_speaker"]})
    for rr in rows_of(s):
        if (rr["speaker"], rr["session"]) in bad_sessions:
            reasons[rr["seg_id"]].append(f"label: whole session {rr['session']} matches none of {rr['speaker']}'s other sessions (all {len(panel)} panel models)")
    for c in out["clip_drops"]:
        reasons[c["seg_id"]].append(f"label: all {len(panel)} panel models put the clip nearer {c['closest_other']} (max norm margin {c['max_norm_margin']:+.2f}) and flag it as an outlier (z {c['z']:+.1f})")
    return out


def annot_drops(s, reasons):
    rows = read_csv(A / f"overlap_{s}.csv")
    n = 0
    for r in rows:
        w = float(r.get("nxtword_in_clip_s") or 0) if s == "icsi" else float(r.get("word_in_clip_s") or 0)
        v = float(r.get("nxtvocal_in_clip_s") or 0) if s == "icsi" else float(r.get("vocal_in_clip_s") or 0)
        if w > 0:
            reasons[r["seg_id"]].append(f"annot: another participant's aligned words inside the clip ({w:.2f} s)")
            n += 1
        elif v > 0:
            reasons[r["seg_id"]].append(f"annot-vocal: another participant's annotated vocal sound (laugh/cough) inside the clip ({v:.2f} s)")
            n += 1
    return n


def main() -> int:
    summary = json.loads((A / "labels" / "summary.json").read_text()) if (A / "labels" / "summary.json").exists() else {}
    decide = {}
    all_reasons = []
    for s in SETS:
        rows = rows_of(s)
        ids = {r["seg_id"] for r in rows}
        reasons = collections.defaultdict(list)
        d = {}
        if s == "vox1o":
            d["leaks"], merge = vox1o_leaks(rows, reasons)
            (A / "merge_vox1o_sessions.json").write_text(json.dumps(merge, indent=1, sort_keys=True))
        d["labels"] = label_drops(s, reasons, summary)
        if s in ("ami", "icsi"):
            d["annot_drops"] = annot_drops(s, reasons)
        drop = sorted(k for k, v in reasons.items() if v and k in ids)
        (A / f"drop_{s}.txt").write_text("".join(f"{k}\n" for k in drop))
        by_kind = collections.Counter(v[0].split(":")[0] for k, v in reasons.items() if v and k in ids)
        # the second-voice (vocal sound) drops also go to their own file, so they can be taken or left as a block
        sv = sorted(k for k, v in reasons.items() if k in ids and any(x.startswith("annot-vocal") for x in v))
        if sv:
            (A / f"drop_{s}_second_voice.txt").write_text("".join(f"{k}\n" for k in sv))
        d["dropped"] = len(drop)
        d["dropped_by_reason"] = dict(by_kind)
        d["clips"] = len(rows)
        decide[s] = d
        for k in drop:
            all_reasons.append({"set": s, "seg_id": k, "reason": " | ".join(reasons[k])})
        print(f"{s}: drop {len(drop)} / {len(rows)} {dict(by_kind)}")
    with open(A / "drop_reasons.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["set", "seg_id", "reason"])
        w.writeheader()
        w.writerows(all_reasons)
    (A / "decide.json").write_text(json.dumps(decide, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())

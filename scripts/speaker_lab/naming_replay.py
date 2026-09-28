#!/usr/bin/env python3
"""Replay naming policies over a shared-DB series (family F) in seconds.

The lab runner saves every diarized speaker's session voice fingerprint per
meeting (lab_result.json "speakers"). This replays the whole series against a
simple speaker DB model under different naming policies, with a simulated user
who always knows who is who, and counts user work and wrong names.

The DB model is deliberately simple (a profile = mean of the fingerprints the
user confirmed), so absolute numbers differ from the app's matcher. It exists
to rank policies; winners get built into TranscriptedCore and re-checked end
to end with `speaker-eval-harness meeting-series`.

Row outcomes per voice, per meeting:
  auto      named silently (no work)           AUTO WRONG = worst outcome
  suggest   "Was this Taylor?" (confirm = 1)   wrong suggestion = type the name (3)
  ask       type a name (3), or pick an existing person (2)
  hidden    tiny voice folded away (0 work; counted if it was a real person)

  data/eval/yodas3/venv/bin/python scripts/speaker_lab/naming_replay.py --set p0-F
"""
from __future__ import annotations

import argparse
import json
import os
import re
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from scipy.optimize import linear_sum_assignment

REPO_ROOT = Path(__file__).resolve().parents[2]
ROOT = Path(os.environ.get("YODAS_ROOT", REPO_ROOT / "data" / "eval" / "yodas3"))
NICK = {"bob": "robert", "will": "william", "kate": "katherine", "alex": "alexander", "liz": "elizabeth",
        "mike": "michael", "dan": "daniel", "sam": None}  # "Sam" is ambiguous on purpose


def unit(v: np.ndarray) -> np.ndarray:
    return v / (np.linalg.norm(v) + 1e-9)


def name_keys(name: str | None, email: str | None) -> set[str]:
    """Normalised full-name keys for an invitee, including nickname and email forms."""
    keys = set()
    for raw in filter(None, [name, re.sub(r"[._]", " ", (email or "").split("@")[0])]):
        parts = raw.lower().split()
        if len(parts) < 2:
            continue
        first, last = parts[0], parts[-1]
        keys.add(f"{first} {last}")
        if NICK.get(first):
            keys.add(f"{NICK[first]} {last}")
    return keys


def profile_key(name: str) -> str:
    parts = name.lower().split()
    return f"{parts[0]} {parts[-1]}" if len(parts) >= 2 else name.lower()


@dataclass
class Profile:
    pid: int
    name: str
    identity: str
    embs: list = field(default_factory=list)
    confirmations: int = 0
    meetings_confirmed: set = field(default_factory=set)
    last_seen: int = -1

    @property
    def centroid(self) -> np.ndarray:
        return unit(np.mean(self.embs, axis=0))


@dataclass
class Policy:
    name: str
    auto_confirmations: int = 5         # confirmed meetings before silent naming
    auto_sim: float = 0.92
    auto_margin: float = 0.12
    suggest_sim: float = 0.70
    lineup: bool = False                # compare only against invitees (when an invite exists)
    lineup_auto_confirmations: int = 5
    lineup_auto_sim: float = 0.92
    lineup_auto_margin: float = 0.12
    assign: bool = False                # one person per voice, solved jointly
    eliminate: bool = False             # last unknown voice <- last unmatched invitee (suggest)
    min_talk_s: float = 0.0             # voices under this are hidden, not rows
    use_invite: bool = True             # False: pretend no meeting had a calendar invite
    recent_lineup: int = 0              # >0: people seen in the last N meetings act as the lineup
    recent_top: int = 0                 # >0: the N most recently heard named people act as the lineup (app version)


POLICIES = [
    Policy("today (5 confirms, 0.92/0.12)"),
    Policy("3 confirms", auto_confirmations=3),
    Policy("2 confirms", auto_confirmations=2),
    Policy("1 confirm", auto_confirmations=1),
    Policy("hide <5 s voices", min_talk_s=5.0),
    Policy("calendar lineup, 2 confirms @0.80", lineup=True, lineup_auto_confirmations=2,
           lineup_auto_sim=0.80, lineup_auto_margin=0.10),
    Policy("calendar lineup + assign, 1 confirm @0.75", lineup=True, assign=True, lineup_auto_confirmations=1,
           lineup_auto_sim=0.75, lineup_auto_margin=0.08),
    Policy("lineup + assign + eliminate + hide <5 s", lineup=True, assign=True, eliminate=True, min_talk_s=5.0,
           lineup_auto_confirmations=1, lineup_auto_sim=0.75, lineup_auto_margin=0.08),
    Policy("APP v2: invite bars 2 confirms @0.80/0.10", lineup=True, lineup_auto_confirmations=2,
           lineup_auto_sim=0.80, lineup_auto_margin=0.10),
    # ---- no calendar at all (random Zooms)
    Policy("NO INVITE: today", use_invite=False),
    Policy("NO INVITE: 3 confirms @0.92/0.12", use_invite=False, auto_confirmations=3),
    Policy("NO INVITE: 2 confirms @0.92/0.12", use_invite=False, auto_confirmations=2),
    Policy("NO INVITE: recent-8 lineup, 2 confirms @0.85/0.12", use_invite=False, lineup=True, recent_lineup=8,
           lineup_auto_confirmations=2, lineup_auto_sim=0.85, lineup_auto_margin=0.12),
    Policy("NO INVITE: recent-8 lineup, 2 confirms @0.80/0.10", use_invite=False, lineup=True, recent_lineup=8,
           lineup_auto_confirmations=2, lineup_auto_sim=0.80, lineup_auto_margin=0.10),
    Policy("NO INVITE: recent-8 + 2 confirms + hide <5 s", use_invite=False, lineup=True, recent_lineup=8,
           lineup_auto_confirmations=2, lineup_auto_sim=0.85, lineup_auto_margin=0.12, min_talk_s=5.0),
    Policy("NO INVITE: APP top-12 recent, 2 confirms @0.80/0.10", use_invite=False, lineup=True, recent_top=12,
           lineup_auto_confirmations=2, lineup_auto_sim=0.80, lineup_auto_margin=0.10),
    Policy("NO INVITE: APP top-8 recent, 2 confirms @0.80/0.10", use_invite=False, lineup=True, recent_top=8,
           lineup_auto_confirmations=2, lineup_auto_sim=0.80, lineup_auto_margin=0.10),
    Policy("APP v2 full: invite, else top-12 recent", lineup=True, recent_top=12,
           lineup_auto_confirmations=2, lineup_auto_sim=0.80, lineup_auto_margin=0.10),
]
COST = {"auto": 0, "suggest_ok": 1, "suggest_wrong": 3, "ask_new": 3, "ask_existing": 2, "hidden": 0}


def replay(meetings: list[dict], pol: Policy) -> dict:
    profiles: list[Profile] = []
    work = 0
    counts = defaultdict(int)
    first_suggest: dict[str, int] = {}
    first_auto: dict[str, int] = {}
    appear: dict[str, int] = defaultdict(int)
    hidden_real_seconds = 0.0
    wrong_autos = []
    for mi, m in enumerate(meetings):
        voices = [v for v in m["speakers"] if v["channel"] == "system" and v.get("sessionEmbedding")]
        invite = m["calendar"]["invitees"] if pol.use_invite else []
        invite_keys = [name_keys(i.get("name"), i.get("email")) for i in invite if i["is_person"]]
        if pol.recent_lineup:
            # No invite: the people you've met with in your last N meetings stand in for it.
            recent = [p for p in profiles if p.last_seen >= mi - pol.recent_lineup]
            invite_keys = [{profile_key(p.name)} for p in recent]
        if pol.recent_top and not invite_keys:
            # App version: the N named people heard most recently (by last-seen time).
            recent = sorted((p for p in profiles if p.last_seen >= 0), key=lambda p: -p.last_seen)[: pol.recent_top]
            invite_keys = [{profile_key(p.name)} for p in recent]
        in_lineup = lambda p: any(profile_key(p.name) in ks for ks in invite_keys)  # noqa: E731
        people_here = {v["truthIdentity"] for v in voices if v.get("truthIdentity")}
        for ident in people_here:
            appear[ident] += 1
        decisions = {}
        shown = []
        for v in voices:
            if v["talkSeconds"] < pol.min_talk_s:
                decisions[v["diarizerSpeakerId"]] = ("hidden", None)
                if v.get("truthIdentity"):
                    hidden_real_seconds += v["talkSeconds"]
            else:
                shown.append(v)
        E = np.array([unit(np.array(v["sessionEmbedding"], dtype=np.float32)) for v in shown]) if shown else None
        C = np.array([p.centroid for p in profiles]) if profiles else None
        S = E @ C.T if (E is not None and C is not None) else None
        lineup_idx = [k for k, p in enumerate(profiles) if pol.lineup and invite_keys and in_lineup(p)]
        use_lineup = pol.lineup and bool(invite_keys)
        # candidate best profile per voice
        best: dict[int, tuple[int, float, float]] = {}
        if S is not None:
            if use_lineup and pol.assign and lineup_idx:
                sub = S[:, lineup_idx]
                r, c = linear_sum_assignment(-sub)
                for i, j in zip(r, c):
                    others = np.delete(S[i], lineup_idx[j])
                    second = float(others.max()) if len(others) else -1.0
                    best[i] = (lineup_idx[j], float(sub[i, j]), second)
            else:
                for i in range(len(shown)):
                    row = S[i]
                    cands = lineup_idx if use_lineup and lineup_idx else list(range(len(profiles)))
                    if not cands:
                        continue
                    j = max(cands, key=lambda k: row[k])
                    others = np.delete(row, j)
                    best[i] = (j, float(row[j]), float(others.max()) if len(others) else -1.0)
        taken_invites = set()
        unknown = []
        for i, v in enumerate(shown):
            sid = v["diarizerSpeakerId"]
            if i not in best:
                unknown.append(i)
                continue
            j, sim, second = best[i]
            p = profiles[j]
            if use_lineup and j in lineup_idx:
                auto = (len(p.meetings_confirmed) >= pol.lineup_auto_confirmations and sim >= pol.lineup_auto_sim
                        and sim - second >= pol.lineup_auto_margin)
            else:
                auto = (len(p.meetings_confirmed) >= pol.auto_confirmations and sim >= pol.auto_sim
                        and sim - second >= pol.auto_margin)
            if auto:
                decisions[sid] = ("auto", j)
            elif sim >= pol.suggest_sim:
                decisions[sid] = ("suggest", j)
            else:
                unknown.append(i)
                continue
            taken_invites.add(profile_key(p.name))
        # process of elimination: one unknown voice, one invitee nobody claimed -> suggest them
        elim_name = None
        if pol.eliminate and len(unknown) == 1:
            free = [i for i in invite if i["is_person"] and not (name_keys(i.get("name"), i.get("email")) & taken_invites)]
            if len(free) == 1:
                elim_name = free[0].get("name") or " ".join(
                    w.capitalize() for w in re.sub(r"[._]", " ", free[0]["email"].split("@")[0]).split())
        for i in unknown:
            decisions[shown[i]["diarizerSpeakerId"]] = ("elim", elim_name) if elim_name else ("ask", None)

        # simulated user + DB learning
        for v in voices:
            sid = v["diarizerSpeakerId"]
            kind, arg = decisions[sid]
            ident = v.get("truthIdentity")
            truth_name = next((x["name"] for x in m["truth"]["participants"] if x["identity"] == ident), None)
            emb = unit(np.array(v["sessionEmbedding"], dtype=np.float32))
            target = next((p for p in profiles if p.identity == ident), None) if ident else None
            if kind == "hidden":
                counts["hidden"] += 1
                continue
            if kind == "auto":
                p = profiles[arg]
                if p.identity != ident:
                    counts["auto_wrong"] += 1
                    wrong_autos.append((m["id"], p.name, truth_name))
                    work += 10
                    if target:
                        target.embs.append(emb)
                    continue
                counts["auto"] += 1
                first_auto.setdefault(ident, appear[ident])
                p.embs.append(emb)
                p.last_seen = mi
                continue
            if kind in ("suggest", "elim"):
                if kind == "suggest":
                    ok = profiles[arg].identity == ident
                else:  # elimination suggests an invite name, e.g. "Bob Chen" for Robert Chen
                    ok = bool(truth_name) and profile_key(truth_name) in (name_keys(arg, None) | {profile_key(arg)})
                if ok:
                    counts["suggest_ok"] += 1
                    work += COST["suggest_ok"]
                    first_suggest.setdefault(ident, appear[ident])
                else:
                    counts["suggest_wrong"] += 1
                    work += COST["suggest_wrong"]
            else:
                if target:
                    counts["ask_existing"] += 1
                    work += COST["ask_existing"]
                else:
                    counts["ask_new"] += 1
                    work += COST["ask_new"]
            if not ident:
                continue  # a voice with no real person behind it: user discards it
            if target is None:
                target = Profile(len(profiles), truth_name, ident)
                profiles.append(target)
            target.embs.append(emb)
            target.meetings_confirmed.add(m["id"])
            target.last_seen = mi
    recurring = [i for i, n in appear.items() if n >= 4]
    fs = [first_suggest.get(i) for i in recurring]
    fa = [first_auto.get(i) for i in recurring]
    return {"policy": pol.name, "work": work, "counts": dict(counts), "wrong_autos": wrong_autos,
            "recurring": len(recurring),
            "median_first_suggest": float(np.median([x for x in fs if x])) if any(fs) else None,
            "never_suggested": sum(1 for x in fs if not x),
            "median_first_auto": float(np.median([x for x in fa if x])) if any(fa) else None,
            "never_auto": sum(1 for x in fa if not x),
            "hidden_real_seconds": round(hidden_real_seconds, 1)}


def load(set_dir: Path) -> list[dict]:
    series = json.load(open(set_dir / "series.json"))
    out = []
    for m in series["meetings"]:
        d = set_dir / m["id"]
        if not (d / "lab_result.json").exists():
            continue
        lab = json.load(open(d / "lab_result.json"))
        if not lab.get("speakers"):
            raise SystemExit(f"{d}: lab_result.json has no speakers block; rerun with the current harness")
        out.append({"id": m["id"], "speakers": lab["speakers"], "truth": json.load(open(d / "truth.json")),
                    "calendar": json.load(open(d / "calendar.json"))})
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--set", required=True)
    args = ap.parse_args()
    set_dir = ROOT / "sim" / args.set
    meetings = load(set_dir)
    # How well does the fingerprint separate people at all? (genuine vs impostor)
    per_ident = defaultdict(list)
    for m in meetings:
        for v in m["speakers"]:
            if v["channel"] == "system" and v.get("sessionEmbedding") and v.get("truthIdentity") and v["truthShare"] >= 0.8:
                per_ident[v["truthIdentity"]].append(unit(np.array(v["sessionEmbedding"], dtype=np.float32)))
    gen, imp = [], []
    ids = list(per_ident)
    for a in range(len(ids)):
        ea = np.array(per_ident[ids[a]])
        s = ea @ ea.T
        gen += list(s[np.triu_indices(len(ea), 1)])
        for b in range(a + 1, len(ids)):
            imp += list((ea @ np.array(per_ident[ids[b]]).T).ravel())
    lines = [f"# Naming replay: {args.set}", "",
             f"{len(meetings)} meetings. Session fingerprints (app WeSpeaker): same person median "
             f"{np.median(gen):.3f} (p5 {np.percentile(gen, 5):.3f}); different people median {np.median(imp):.3f} "
             f"(p99 {np.percentile(imp, 99):.3f}, max {np.max(imp):.3f}).", "",
             "| policy | user work | auto | AUTO WRONG | suggested ok | suggested wrong | typed | picked | hidden | "
             "recurring people: first suggested (appearance #, median) | first auto (median) | never auto |",
             "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    results = []
    for pol in POLICIES:
        r = replay(meetings, pol)
        results.append(r)
        c = r["counts"]
        lines.append(f"| {pol.name} | {r['work']} | {c.get('auto', 0)} | {c.get('auto_wrong', 0)} | {c.get('suggest_ok', 0)} "
                     f"| {c.get('suggest_wrong', 0)} | {c.get('ask_new', 0)} | {c.get('ask_existing', 0)} | {c.get('hidden', 0)} "
                     f"| {r['median_first_suggest']} | {r['median_first_auto']} | {r['never_auto']}/{r['recurring']} |")
    text = "\n".join(lines) + "\n"
    (set_dir / "naming_replay.md").write_text(text)
    json.dump(results, open(set_dir / "naming_replay.json", "w"), indent=1)
    print(text)


if __name__ == "__main__":
    main()

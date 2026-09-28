#!/usr/bin/env python3
"""Score speaker-lab runs: did we split people right, and how much work was left?

Reads <set>/<meeting>/{truth.json, lab_result.json} written by meeting_sim.py and
`speaker-eval-harness meeting-series`, and writes <set>/report.md + report.json.

Per channel (system = people on the call, mic = your room when local split is on):

  people      true speakers on that channel (you excluded on the mic)
  found       distinct speakers the pipeline produced
  rows        naming rows shown (review sheet), plus voices named silently
  fragments   extra rows for a person who already has one (the "11 boxes" bug)
  blends      rows where a second real person holds >= 20% of the talk time;
              one name can never be right for all of it
  ghosts      rows with no real speaker behind them (noise, echo)
  missed      real people who got no row and no silent name
  who-said-what  share of speech time whose row belongs to the person talking
              (many-to-one: fragments still count as right; blends don't)
  1:1 accuracy   same, but each person may own only their single best row, so
              fragments count as wrong (close to 1 - DER confusion)

Silent names are checked against the answer key; a wrong one is the worst
outcome the lab measures.

  data/eval/yodas3/venv/bin/python scripts/speaker_lab/score.py --set p0-A
"""
from __future__ import annotations

import argparse
import json
import os
from collections import defaultdict
from pathlib import Path

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[2]
ROOT = Path(os.environ.get("YODAS_ROOT", REPO_ROOT / "data" / "eval" / "yodas3"))
BLEND_SHARE = 0.20


def overlap(a0: float, a1: float, b0: float, b1: float) -> float:
    return max(0.0, min(a1, b1) - max(a0, b0))


def score_meeting(truth: dict, lab: dict) -> dict:
    pid_info = {p["pid"]: p for p in truth["participants"]}
    out = {"meeting": truth["meeting"], "family": truth["family"], "minutes": truth["duration_s"] / 60,
           "outcome": lab.get("outcome", "missing"), "channels": {}}
    if lab.get("outcome") != "ok":
        return out
    channels = ["system"] + (["mic"] if truth["split_local_speakers"] else [])
    rows = lab["rows"]
    silent = lab["silentNames"]
    utts = lab["utterances"]
    for ch in channels:
        people = [p["pid"] for p in truth["participants"] if p["channel"] == ch and p["role"] != "you"]
        segs = [s for s in truth["segments"] if pid_info[s["pid"]]["channel"] == ch]
        ch_utts = [u for u in utts if u["channel"] == ch]
        spk_ids = sorted({u["speakerId"] for u in ch_utts})

        # time each diarizer speaker overlaps each true person
        ov: dict[int, dict[str, float]] = defaultdict(lambda: defaultdict(float))
        for u in ch_utts:
            for s in segs:
                o = overlap(u["start"], u["end"], s["start"], s["end"])
                if o > 0:
                    ov[u["speakerId"]][s["pid"]] += o
        owner = {}
        for sid in spk_ids:
            byp = ov.get(sid, {})
            owner[sid] = max(byp, key=byp.get) if byp else None

        ch_rows = [r for r in rows if r["channel"] == ch]
        ch_silent = [s for s in silent if s["channel"] == ch]
        shown = [(r["diarizerSpeakerId"], r.get("truthPid"), r.get("truthShare", 0), r.get("secondShare", 0))
                 for r in ch_rows]
        shown += [(s["diarizerSpeakerId"], s.get("truthPid"), s.get("truthShare", 0), 0.0) for s in ch_silent]
        # on the mic, a row that is really you is not a naming task ("Keep as You")
        you_pids = {p["pid"] for p in truth["participants"] if p["role"] == "you"}
        task_rows = [x for x in shown if x[1] not in you_pids]

        per_person = defaultdict(int)
        ghosts = blends = 0
        for _, pid, share, second in task_rows:
            if pid is None:
                ghosts += 1
                continue
            per_person[pid] += 1
            if second >= BLEND_SHARE:
                blends += 1
        fragments = sum(max(0, n - 1) for n in per_person.values())
        missed = [p for p in people if per_person.get(p, 0) == 0]

        # who-said-what (many-to-one) and 1:1 accuracy over true speech time
        total = right_many = 0.0
        best_row_for: dict[str, int] = {}
        for pid in people + list(you_pids & {p["pid"] for p in truth["participants"] if p["channel"] == ch}):
            cands = [(ov[sid].get(pid, 0.0), sid) for sid in spk_ids]
            if cands and max(cands)[0] > 0:
                best_row_for[pid] = max(cands)[1]
        right_one = 0.0
        # Word level when the answer key has word times (ASR-caption voices):
        # each spoken word counts once, at its midpoint. Turn spans include the
        # pauses inside someone's speech, which the pipeline rightly drops, so
        # time overlap undercounts; words are what the transcript shows.
        ch_pids = {p["pid"] for p in truth["participants"] if p["channel"] == ch}
        words = [w for w in truth.get("words", []) if w["pid"] in ch_pids]
        missed_words = 0
        if words:
            starts = np.array([u["start"] for u in ch_utts]) if ch_utts else np.zeros(0)
            order = np.argsort(starts)
            sorted_utts = [ch_utts[i] for i in order]
            sorted_starts = starts[order] if len(starts) else starts
            for w in words:
                mid = (w["start"] + w["end"]) / 2
                total += 1
                k = int(np.searchsorted(sorted_starts, mid, side="right")) - 1
                hit = None
                for j in (k, k - 1):
                    if 0 <= j < len(sorted_utts) and sorted_utts[j]["start"] - 0.3 <= mid <= sorted_utts[j]["end"] + 0.3:
                        hit = sorted_utts[j]
                        break
                if hit is None:
                    missed_words += 1
                    continue
                if owner.get(hit["speakerId"]) == w["pid"]:
                    right_many += 1
                if best_row_for.get(w["pid"]) == hit["speakerId"]:
                    right_one += 1
        else:
            for s in segs:
                total += s["end"] - s["start"]
                for u in ch_utts:
                    o = overlap(u["start"], u["end"], s["start"], s["end"])
                    if o <= 0:
                        continue
                    if owner.get(u["speakerId"]) == s["pid"]:
                        right_many += o
                    if best_row_for.get(s["pid"]) == u["speakerId"]:
                        right_one += o
        out["channels"][ch] = {
            "people": len(people),
            "found": len([sid for sid in spk_ids if owner.get(sid) not in you_pids]) if ch == "mic" else len(spk_ids),
            "rows": len(task_rows),
            "review_rows": len([r for r in ch_rows if r.get("truthPid") not in you_pids]),
            "silent": len(ch_silent),
            "silent_wrong": sum(1 for s in ch_silent if not s.get("correct")),
            "fragments": fragments,
            "blends": blends,
            "ghosts": ghosts,
            "missed": len(missed),
            "extra_rows": len(task_rows) - len(people),
            "exact": len(task_rows) == len(people) and fragments == 0 and blends == 0 and not missed,
            "who_said_what": right_many / total if total else None,
            "one_to_one": right_one / total if total else None,
            "attribution_unit": "words" if words else "seconds",
            "words_dropped": missed_words / total if words and total else None,
            "small_rows": sum(1 for r in ch_rows if r.get("truthPid") not in you_pids
                              and sum(u["end"] - u["start"] for u in ch_utts
                                      if str(u["speakerId"]) == r["diarizerSpeakerId"]) < 10.0),
        }
    return out


def e2e_as_lab(truth: dict, dump: dict) -> dict:
    """Turn a `dump-e2e` result into the lab_result shape: every model speaker on
    the call channel becomes one naming row, attributed by overlap like the
    Swift runner does. Only the call (system) channel is diarized."""
    segs = [s for s in truth["segments"]
            if next(p for p in truth["participants"] if p["pid"] == s["pid"])["channel"] == "system"]
    utts = [{"channel": "system", "speakerId": s["speaker"], "start": s["start"], "end": s["end"]}
            for s in dump["segments"]]
    rows = []
    for spk in sorted({u["speakerId"] for u in utts}):
        byp: dict[str, float] = defaultdict(float)
        for u in (u for u in utts if u["speakerId"] == spk):
            for s in segs:
                o = overlap(u["start"], u["end"], s["start"], s["end"])
                if o > 0:
                    byp[s["pid"]] += o
        tot = sum(byp.values())
        ranked = sorted(byp.items(), key=lambda kv: -kv[1])
        rows.append({"channel": "system", "diarizerSpeakerId": str(spk),
                     "truthPid": ranked[0][0] if ranked else None,
                     "truthShare": ranked[0][1] / tot if tot else 0.0,
                     "secondShare": ranked[1][1] / tot if len(ranked) > 1 and tot else 0.0,
                     "needsConfirmation": False, "userAction": "type_new"})
    return {"outcome": "ok", "rows": rows, "silentNames": [], "utterances": utts}


WORK = {"type_new": 3, "pick_existing": 2, "correct": 3, "confirm": 1, "discard": 1, "keep_as_you": 1}


def score_series(set_dir: Path, series: dict) -> dict | None:
    """Learning speed and trust across a shared-DB series (family F).

    Tracks each recurring person by voice identity (pids change per meeting):
    the meeting where we first SUGGEST them (a confirm row with their right
    name), where we first name them SILENTLY, and every wrong name, silent or
    suggested. Also the user's work per meeting over time.
    """
    shared = [m for m in series["meetings"] if not m.get("fresh_db", True)]
    if not shared:
        return None
    people: dict[str, dict] = {}
    timeline = []
    for idx, m in enumerate(shared, start=1):
        d = set_dir / m["id"]
        if not (d / "lab_result.json").exists():
            continue
        truth = json.load(open(d / "truth.json"))
        lab = json.load(open(d / "lab_result.json"))
        pid_to = {p["pid"]: p for p in truth["participants"]}
        work = 0
        counts = defaultdict(int)
        seen_this = set()
        for r in lab.get("rows", []):
            p = pid_to.get(r.get("truthPid") or "")
            counts[r["userAction"]] += 1
            work += WORK.get(r["userAction"], 0)
            if not p or p["role"] == "you":
                continue
            st = people.setdefault(p["identity"], {"name": p["name"], "appearances": 0, "first_suggested": None,
                                                   "first_silent": None, "wrong_suggestions": 0, "wrong_silent": 0,
                                                   "rows": 0})
            st["rows"] += 1
            if r["needsConfirmation"]:
                if r.get("currentName") == p["name"]:
                    st["first_suggested"] = st["first_suggested"] or idx
                else:
                    st["wrong_suggestions"] += 1
        for s in lab.get("silentNames", []):
            p = pid_to.get(s.get("truthPid") or "")
            counts["silent"] += 1
            if not p:
                continue
            st = people.setdefault(p["identity"], {"name": p["name"], "appearances": 0, "first_suggested": None,
                                                   "first_silent": None, "wrong_suggestions": 0, "wrong_silent": 0,
                                                   "rows": 0})
            if s.get("correct"):
                st["first_silent"] = st["first_silent"] or idx
            else:
                st["wrong_silent"] += 1
                work += 10
        for p in truth["participants"]:
            if p["role"] == "you":
                continue
            st = people.setdefault(p["identity"], {"name": p["name"], "appearances": 0, "first_suggested": None,
                                                   "first_silent": None, "wrong_suggestions": 0, "wrong_silent": 0,
                                                   "rows": 0})
            st["appearances"] += 1
            st.setdefault("meetings", []).append(idx)
            seen_this.add(p["identity"])
        timeline.append({"index": idx, "meeting": m["id"], "title": m.get("title", ""),
                         "people": len(seen_this), "work": work, **counts})
    for st in people.values():
        mts = st.get("meetings", [])
        st["appearance_of_first_suggestion"] = (mts.index(st["first_suggested"]) + 1
                                               if st["first_suggested"] in mts else None)
        st["appearance_of_first_silent"] = (mts.index(st["first_silent"]) + 1
                                           if st["first_silent"] in mts else None)
    return {"people": people, "timeline": timeline}


def series_report(res: dict) -> str:
    lines = ["", "## Learning across meetings (shared speaker DB)", "",
             "Appearance # = how many meetings with that person it took. Work: typed name 3, "
             "pick existing 2, confirm 1, wrong silent name 10.", "",
             "| person | appearances | rows shown | first suggested (appearance #) | first silent (appearance #) "
             "| wrong suggestions | WRONG SILENT |", "|---|---|---|---|---|---|---|"]
    for ident, st in sorted(res["people"].items(), key=lambda kv: -kv[1]["appearances"]):
        lines.append(f"| {st['name']} | {st['appearances']} | {st['rows']} | {st['appearance_of_first_suggestion'] or '-'} "
                     f"| {st['appearance_of_first_silent'] or '-'} | {st['wrong_suggestions']} | {st['wrong_silent']} |")
    lines += ["", "| # | meeting | people | work | rows typed | picked | confirmed | silent |",
              "|---|---|---|---|---|---|---|---|"]
    for t in res["timeline"]:
        lines.append(f"| {t['index']} | {t['meeting']} | {t['people']} | {t['work']} | {t.get('type_new', 0) + t.get('correct', 0)} "
                     f"| {t.get('pick_existing', 0)} | {t.get('confirm', 0)} | {t.get('silent', 0)} |")
    return "\n".join(lines) + "\n"


def summarize(scored: list[dict]) -> dict:
    fam = defaultdict(list)
    for m in scored:
        fam[m["family"]].append(m)
    summary = {}
    for f, ms in sorted(fam.items()):
        ok = [m for m in ms if m["outcome"] == "ok"]
        s = {"meetings": len(ms), "ok": len(ok)}
        for ch in ("system", "mic"):
            cs = [m["channels"][ch] for m in ok if ch in m["channels"]]
            if not cs:
                continue
            arr = lambda k: np.array([c[k] for c in cs], dtype=float)  # noqa: E731
            wsw = [c["who_said_what"] for c in cs if c["who_said_what"] is not None]
            one = [c["one_to_one"] for c in cs if c["one_to_one"] is not None]
            s[ch] = {
                "people_mean": float(arr("people").mean()),
                "rows_mean": float(arr("rows").mean()),
                "rows_max": int(arr("rows").max()),
                "extra_rows_mean": float(arr("extra_rows").mean()),
                "exact_pct": float(100 * np.mean([c["exact"] for c in cs])),
                "any_fragment_pct": float(100 * np.mean(arr("fragments") > 0)),
                "fragments_mean": float(arr("fragments").mean()),
                "any_blend_pct": float(100 * np.mean(arr("blends") > 0)),
                "blends_total": int(arr("blends").sum()),
                "ghosts_total": int(arr("ghosts").sum()),
                "missed_total": int(arr("missed").sum()),
                "silent_total": int(arr("silent").sum()),
                "silent_wrong_total": int(arr("silent_wrong").sum()),
                "who_said_what_mean": float(np.mean(wsw)) if wsw else None,
                "one_to_one_mean": float(np.mean(one)) if one else None,
            }
        summary[f] = s
    return summary


def report(set_name: str, scored: list[dict], summary: dict) -> str:
    lines = [f"# Speaker lab report: {set_name}", "",
             "Rows are naming tasks you'd see after the call (you excluded). "
             "Perfect is rows = people, no fragments, no blends.", ""]
    lines += ["| family | ch | meetings | people | rows (mean / max) | exact | any fragment | fragments/mtg | "
              "any blend | ghosts | missed | who-said-what | 1:1 |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for f, s in summary.items():
        for ch in ("system", "mic"):
            if ch not in s:
                continue
            c = s[ch]
            lines.append(
                f"| {f} | {ch} | {s['ok']}/{s['meetings']} | {c['people_mean']:.1f} | {c['rows_mean']:.1f} / {c['rows_max']} "
                f"| {c['exact_pct']:.0f}% | {c['any_fragment_pct']:.0f}% | {c['fragments_mean']:.2f} | {c['any_blend_pct']:.0f}% "
                f"| {c['ghosts_total']} | {c['missed_total']} | {100 * (c['who_said_what_mean'] or 0):.1f}% "
                f"| {100 * (c['one_to_one_mean'] or 0):.1f}% |")
    lines += ["", "## Per meeting", "",
              "| meeting | min | ch | people | rows | fragments | blends | ghosts | missed | who-said-what | 1:1 |",
              "|---|---|---|---|---|---|---|---|---|---|---|"]
    for m in scored:
        if m["outcome"] != "ok":
            lines.append(f"| {m['meeting']} | {m['minutes']:.0f} | - | - | {m['outcome']} | | | | | | |")
            continue
        for ch, c in m["channels"].items():
            lines.append(f"| {m['meeting']} | {m['minutes']:.0f} | {ch} | {c['people']} | {c['rows']} | {c['fragments']} "
                         f"| {c['blends']} | {c['ghosts']} | {c['missed']} | {100 * (c['who_said_what'] or 0):.1f}% "
                         f"| {100 * (c['one_to_one'] or 0):.1f}% |")
    return "\n".join(lines) + "\n"


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--set", required=True)
    ap.add_argument("--e2e", help="score dump-e2e output for this model instead of the pipeline run")
    args = ap.parse_args()
    set_dir = ROOT / "sim" / args.set
    series = json.load(open(set_dir / "series.json"))
    scored = []
    for m in series["meetings"]:
        d = set_dir / m["id"]
        truth = json.load(open(d / "truth.json"))
        if args.e2e:
            f = d / f"e2e_{args.e2e}.json"
            if f.exists():
                scored.append(score_meeting(truth, e2e_as_lab(truth, json.load(open(f)))))
        elif (d / "lab_result.json").exists():
            scored.append(score_meeting(truth, json.load(open(d / "lab_result.json"))))
    summary = summarize(scored)
    tag = f"{args.set} [{args.e2e}]" if args.e2e else args.set
    stem = f"report_e2e_{args.e2e}" if args.e2e else "report"
    series_res = None if args.e2e else score_series(set_dir, series)
    json.dump({"set": tag, "summary": summary, "meetings": scored, "series": series_res},
              open(set_dir / f"{stem}.json", "w"), indent=1)
    text = report(tag, scored, summary)
    if series_res:
        text += series_report(series_res)
    (set_dir / f"{stem}.md").write_text(text)
    print(text)


if __name__ == "__main__":
    main()

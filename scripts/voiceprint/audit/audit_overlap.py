#!/usr/bin/env python3
"""Answer-key audit, part 3: are the ami and icsi clips really one talker?

Re-derives every clip's neighbourhood from annotations the builders did NOT use:
  ami   AMI manual word annotations (ami_public_manual_1.6.2 words/<meeting>.<agent>.words.xml):
        other participants' words AND vocal sounds (laughs, coughs), which the pyannote
        only_words RTTM the builder used leaves out.
  icsi  the original MRT transcripts (<meeting>.mrt): other participants' segments, plus the
        off-mike segments with no participant (CloseMic="false") that hold speech or vocal sounds
        (background coughs, "Mm-hmm" not audible on close mikes, several speakers off mike). The
        builder used the per-channel NXT segments, which have no off-mike rows.
For each clip: seconds of another person's words / vocal sounds inside the clip, and inside the
0.3 s guard around it. Reported for all clips and for a seeded random 50.

Writes VP/results/audit/overlap_<set>.csv and overlap_summary.json.
"""
from __future__ import annotations

import collections
import json
import random
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
VP = REPO / "data" / "eval" / "voiceprint"
OUT = VP / "results" / "audit"
AMI = REPO / "data" / "ami"
ICSI = VP / "raw" / "icsi"
NS = "{http://nite.sourceforge.net/}"
GUARD = 0.3


def load_rows(s):
    return [json.loads(l) for l in open(VP / "sets" / s / "segments.jsonl") if l.strip()]


def ov(a0, a1, b0, b1):
    return max(0.0, min(a1, b1) - max(a0, b0))


def ami_events():
    """meeting -> list of (start, end, global_id, kind) where kind in word / vocal / nonvocal."""
    root = ET.parse(AMI / "meta" / "corpusResources" / "meetings.xml").getroot()
    agent = {}
    for m in root.iter("meeting"):
        agent[m.get("observation")] = {s.get("nxt_agent"): s.get("global_name") for s in m.iter("speaker")}
    zf = zipfile.ZipFile(AMI / "meta" / "ami_public_manual_1.6.2.zip")
    ev = collections.defaultdict(list)
    for n in zf.namelist():
        mm = re.match(r"words/(\w+)\.([A-Z])\.words\.xml$", n)
        if not mm:
            continue
        mid, ag = mm.group(1), mm.group(2)
        gid = agent.get(mid, {}).get(ag)
        if gid is None:
            continue
        r = ET.fromstring(zf.read(n))
        for el in r:
            tag = el.tag.split("}")[-1]
            s, e = el.get("starttime"), el.get("endtime")
            if not s or not e:
                continue
            s, e = float(s), float(e)
            if tag == "w":
                if el.get("punc") == "true" or e <= s:
                    continue
                ev[mid].append((s, e, gid, "word"))
            elif tag == "vocalsound":
                ev[mid].append((s, max(e, s + 0.05), gid, "vocal:" + (el.get("type") or "")))
            elif tag == "nonvocalsound":
                ev[mid].append((s, max(e, s + 0.05), gid, "nonvocal:" + (el.get("type") or "")))
    return ev


def icsi_events():
    """meeting -> list of (start, end, participant or '?offmic', kind)."""
    ev = collections.defaultdict(list)
    for f in sorted((ICSI / "annot" / "mrt" / "transcripts").glob("B*.mrt")):
        mid = f.stem
        t = f.read_text(encoding="latin-1")
        for m in re.finditer(r"<Segment([^>]*)>(.*?)</Segment>", t, flags=re.S):
            attrs, body = m.group(1), m.group(2)
            st = re.search(r'StartTime="([\d.]+)"', attrs)
            en = re.search(r'EndTime="([\d.]+)"', attrs)
            if not st or not en:
                continue
            s, e = float(st.group(1)), float(en.group(1))
            p = re.search(r'Participant="(\w+)"', attrs)
            text = re.sub(r"<[^>]*>", " ", body)
            has_words = bool(re.search(r"[A-Za-z@]", text))
            vocal = "<VocalSound" in body
            if p:
                kind = "word" if has_words else ("vocal" if vocal else "other")
                ev[mid].append((s, e, p.group(1), kind))
            else:
                if has_words:
                    ev[mid].append((s, e, "?offmic", "offmic_word"))
                elif vocal:
                    ev[mid].append((s, e, "?offmic", "offmic_vocal"))
    return ev


def icsi_nxt_words(ev):
    """Add NXT forced-aligned word / vocal-sound times per participant (kinds nxtword, nxtvocal)."""
    nxt = ICSI / "annot" / "nxt" / "ICSI"
    for seg in sorted(nxt.glob("Segments/*.segs.xml")):
        mid, ch = seg.name.split(".")[0], seg.name.split(".")[1]
        ps = {x.get("participant") for x in ET.parse(seg).getroot().iter("segment")} - {None}
        if len(ps) != 1:
            continue
        p = ps.pop()
        wf = nxt / "Words" / f"{mid}.{ch}.words.xml"
        if not wf.exists():
            continue
        for el in ET.parse(wf).getroot():
            tag = el.tag.split("}")[-1]
            st, en = el.get("starttime"), el.get("endtime")
            if tag not in ("w", "vocalsound") or not st or not en:
                continue
            a, b = float(st), float(en)
            if b > a:
                ev[mid].append((a, b, p, "nxtword" if tag == "w" else "nxtvocal"))
    return ev


def check(rows, ev, meeting_of, own_of):
    out = []
    for r in rows:
        mid = meeting_of(r)
        own = own_of(r)
        a, b = r["src"]["start"], r["src"]["end"]
        d = collections.Counter()
        near = 99.0
        for s, e, who, kind in ev.get(mid, []):
            if who == own:
                if kind == "word":
                    d["own_word_s"] += ov(a, b, s, e)
                continue
            k = kind.split(":")[0]
            if k == "nonvocal":
                d["nonvocal_in_clip_s"] += ov(a, b, s, e)
                continue
            inside = ov(a, b, s, e)
            guard = ov(a - GUARD, b + GUARD, s, e)
            if k in ("word", "offmic_word", "nxtword"):
                d[f"{k}_in_clip_s"] += inside
                d[f"{k}_in_guard_s"] += guard
            else:
                d[f"{k}_in_clip_s"] += inside
                d[f"{k}_in_guard_s"] += guard
            if k in ("word", "vocal", "nxtword", "nxtvocal"):
                gap = max(0.0, max(a, s) - min(b, e)) if inside == 0 else 0.0
                near = min(near, gap)
        row = {"seg_id": r["seg_id"], "bucket": r["bucket"], "nearest_other_voice_s": round(near, 3)}
        for k, v in d.items():
            row[k] = round(v, 3)
        out.append(row)
    return out


def summarize(res, rng_ids):
    keys = sorted({k for r in res for k in r if k.endswith("_s") and k not in ("own_word_s", "nearest_other_voice_s")})
    def summ(rs):
        o = {"clips": len(rs)}
        for k in keys:
            o[f"n_{k}>0"] = sum(1 for r in rs if r.get(k, 0) > 0)
        o["n_other_voice_in_clip"] = sum(1 for r in rs if any(r.get(k, 0) > 0 for k in keys if k.endswith("in_clip_s") and not k.startswith(("nonvocal", "other"))))
        o["n_other_voice_in_guard"] = sum(1 for r in rs if any(r.get(k, 0) > 0 for k in keys if k.endswith("in_guard_s") and not k.startswith(("nonvocal", "other"))))
        own = [r.get("own_word_s", 0) / r["bucket"] for r in rs]
        o["own_word_cover_median"] = round(sorted(own)[len(own) // 2], 3) if own else None
        o["own_word_cover_lt_0.5"] = sum(1 for x in own if x < 0.5)
        return o
    sample = [r for r in res if r["seg_id"] in rng_ids]
    return {"all": summ(res), "random50": summ(sample),
            "random50_ids_with_other_voice": [r["seg_id"] for r in sample if any(r.get(k, 0) > 0 for k in keys if k.endswith("in_clip_s") and not k.startswith(("nonvocal", "other")))]}


def write_csv(path, rows):
    import csv
    keys = []
    for r in rows:
        for k in r:
            if k not in keys:
                keys.append(k)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys, restval=0)
        w.writeheader()
        w.writerows(rows)


def main():
    summary = {}
    for s in ("ami", "icsi"):
        rows = load_rows(s)
        rng = random.Random(f"audit-overlap-{s}")
        rnd = {r["seg_id"] for r in rng.sample(rows, 50)}
        if s == "ami":
            ev = ami_events()
            res = check(rows, ev, lambda r: r["session"].split(":")[1], lambda r: r["speaker"].split(":")[1])
        else:
            ev = icsi_nxt_words(icsi_events())
            res = check(rows, ev, lambda r: r["session"].split(":")[1], lambda r: r["speaker"].split(":")[1])
        write_csv(OUT / f"overlap_{s}.csv", res)
        summary[s] = summarize(res, rnd)
        summary[s]["random50_ids"] = sorted(rnd)
        print(s, json.dumps({k: v for k, v in summary[s].items() if k != "random50_ids"}, indent=1))
    (OUT / "overlap_summary.json").write_text(json.dumps(summary, indent=1))


if __name__ == "__main__":
    sys.exit(main())

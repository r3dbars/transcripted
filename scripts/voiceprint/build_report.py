#!/usr/bin/env python3
"""Voiceprint bake-off report builder.

One script regenerates the whole honest write-up from whatever results exist. Rerun it any time;
it takes seconds and never invents a number: a missing input becomes a "pending" cell.

Contract: Tools/SpeakerEvalHarness/VOICEPRINT_BAKEOFF.md. VP = data/eval/voiceprint (or $VP_ROOT).

Reads (all optional except that an empty report is pretty boring):
  VP/results/verify_summary.csv (+ .md for the trial table)   pairwise verification (score_verify.py)
  VP/results/naming/*.json, naming_clean/*.json                naming simulator (naming_sim.py); the
                                                               clean-only run is the like-for-like one
  VP/results/lineup_summary.md, lineup/*.json                  334-person lineup      (may not exist yet)
  VP/results/fusion_summary.md, latency.md, e2e_summary.md     (may not exist yet)
  VP/results/audit/{audit.md,bias.csv,decide.json,drop_*.txt,overlap_summary.json}
  VP/models/licenses.json, VP/models/*/model.json              license verdicts, reference_only, params
  VP/coreml/summary.json                                       Core ML build parity and size
  VP/emb/*/*.json                                              embed daemon timings (latency fallback)
  VP/sets/*/segments.jsonl, VP/clips/*/<cond>/READY            dataset counts

Writes:
  Tools/SpeakerEvalHarness/VOICEPRINT_RESULTS.md    the repo write-up
  VP/results/report/ranking.png                     headline ranking with 95% CI whiskers
  VP/results/report/clean_vs_call.png               clean vs call-audio slope chart
  VP/results/report/accuracy_vs_latency.png         accuracy against latency
  VP/results/report/data.json                       the same tables, machine-readable

Units in data.json: tar_*, eer_*, auc and naming shares are percentages (0-100); deltas are
percentage points; min_dcf is the normalized 0-1 number the scorer prints; latency is milliseconds.

Usage:
  VP/venv/bin/python scripts/voiceprint/build_report.py [--vp DIR] [--out FILE] [--no-charts]

How the parts that other agents write are read (their formats were not fixed when this was
written, so these readers are tolerant and everything they find also lands in data.json):
  latency.md, lineup_summary.md, fusion_summary.md, e2e_summary.md are parsed as Markdown tables.
  The first column names a model id (backticks, bold and "(baseline)" are ignored). Latency uses
  the first column whose header matches p50/median + 4 s, else any "ms" column; if a model has
  several rows (devices) the fastest wins. Lineup uses a "top-1"/accuracy column, and
  lineup/<model>.json is searched for keys like top1, top5, accuracy (clean and call variants).
  Whatever the parser cannot place is shown as "see file", never guessed.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import re
import statistics
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEFAULT_VP = Path(os.environ.get("VP_ROOT", str(REPO / "data" / "eval" / "voiceprint")))
DEFAULT_OUT = REPO / "Tools" / "SpeakerEvalHarness" / "VOICEPRINT_RESULTS.md"

HUMAN_SETS = ("vox1o", "libri", "ami", "icsi")
BIASED_SETS = ("yodas",)
ALL_SETS = HUMAN_SETS + BIASED_SETS
DEGRADED = ("opus12", "phone", "noisy")
CONDS = ("clean",) + DEGRADED
CROSS = tuple(f"clean>{c}" for c in DEGRADED)
BUCKETS = (2, 4, 8)

# Two validated categorical hues (blue, orange) plus neutral grays; run through the dataviz palette validator.
C_SHIP = "#2a78d6"
C_BASE = "#eb6834"
C_NOSHIP = "#8c8b85"
C_NOSHIP_FILL = "#d6d5cf"
C_SURFACE = "#fcfcfb"
C_TEXT = "#0b0b0b"
C_TEXT2 = "#52514e"
C_GRID = "#e4e3de"

PENDING = "pending"
DASH = "–"

SET_BLURB = {
    "vox1o": "VoxCeleb1 test: 40 celebrities, each in many different YouTube videos. Human-checked. Old-school interviews.",
    "libri": "LibriSpeech: 146 readers, several chapters each. Read speech, clean, easy.",
    "ami": "AMI meetings: 96 people in 24 groups who meet four times. Closest public thing to the product.",
    "icsi": "ICSI meetings: 52 researchers who meet week after week. Noisier headset mix, real weekly regulars.",
    "yodas": "YouTube speech (YODAS3). Labels made by two models agreeing, not by people. Reported on its own, never ranked.",
}


# --------------------------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------------------------

def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def fnum(x):
    try:
        if x is None or x == "":
            return None
        v = float(x)
        return None if math.isnan(v) or math.isinf(v) else v
    except (TypeError, ValueError):
        return None


def first_float(s):
    if s is None:
        return None
    m = re.search(r"-?\d+(?:\.\d+)?", str(s).replace(",", ""))
    return float(m.group(0)) if m else None


def read_json(path: Path):
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def read_text(path: Path) -> str | None:
    try:
        return path.read_text()
    except Exception:
        return None


def pct(v, nd=1):
    """Fraction to percent string."""
    return PENDING if v is None else f"{100 * v:.{nd}f}"


def pp(v, nd=1):
    """Fraction difference to signed percentage-points string."""
    return DASH if v is None else f"{100 * v:+.{nd}f}"


def ci_txt(e, nd=1, unit=""):
    """'74.6 [72.3, 77.5]' from an entry {v, lo, hi} in fractions (unit '%' puts it after the point value)."""
    if not e or e.get("v") is None:
        return PENDING
    s = pct(e["v"], nd) + unit
    if e.get("lo") is not None and e.get("hi") is not None:
        s += f" [{pct(e['lo'], nd)}, {pct(e['hi'], nd)}]"
    return s


def delta_txt(d, nd=1):
    if not d or d.get("v") is None:
        return DASH
    s = pp(d["v"], nd)
    star = ""
    if d.get("lo") is not None and d.get("hi") is not None:
        s += f" [{pp(d['lo'], nd)}, {pp(d['hi'], nd)}]"
        if d["lo"] > 0 or d["hi"] < 0:
            star = "*"
    return s + star


def r3(v, nd=3):
    return None if v is None else round(v, nd)


def pct_num(v, nd=2):
    """Fraction to a rounded percentage number for data.json."""
    return None if v is None else round(100 * v, nd)


def clean_json(o):
    """Make an object JSON-safe: NaN/inf to None, tuples to lists."""
    if isinstance(o, dict):
        return {str(k): clean_json(v) for k, v in o.items()}
    if isinstance(o, (list, tuple, set)):
        return [clean_json(v) for v in o]
    if isinstance(o, float):
        return None if math.isnan(o) or math.isinf(o) else o
    return o


def mtime_iso(p: Path) -> str | None:
    try:
        return time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(p.stat().st_mtime))
    except Exception:
        return None


def md_tables(text: str) -> list[dict]:
    """Every Markdown table in text: {title, header, rows} (title = nearest heading above)."""
    tables, cur, title = [], None, None
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("#"):
            title = s.lstrip("#").strip()
        if s.startswith("|"):
            cells = [c.strip() for c in s.strip("|").split("|")]
            if cur is None:
                cur = {"title": title, "header": cells, "rows": []}
                tables.append(cur)
            elif all(re.fullmatch(r":?-{2,}:?", c) or c == "" for c in cells):
                continue
            else:
                cur["rows"].append(cells)
        else:
            cur = None
    return tables


def cell_model_id(cell: str, known: set[str]) -> str | None:
    """The model id a table cell names, if any."""
    txt = re.sub(r"[`*_]", "", cell or "").strip()
    if not txt:
        return None
    if txt in known:
        return txt
    tok = txt.split()[0] if txt.split() else ""
    if tok in known:
        return tok
    base = re.sub(r"-(ane|gpu|cpu|coreml)$", "", tok)
    return base if base in known else None


def md_section(text: str, heading_re: str) -> str | None:
    """Body of the first heading matching heading_re, up to the next heading of the same or higher level."""
    lines = text.splitlines()
    start, level = None, None
    for i, line in enumerate(lines):
        m = re.match(r"^(#+)\s+(.*)$", line)
        if not m:
            continue
        if start is None:
            if re.search(heading_re, m.group(2), re.I):
                start, level = i + 1, len(m.group(1))
        elif len(m.group(1)) <= level:
            return "\n".join(lines[start:i]).strip()
    return "\n".join(lines[start:]).strip() if start is not None else None


def md_intro(text: str) -> str:
    """Paragraphs between the first heading and the second heading."""
    out, seen = [], False
    for line in text.splitlines():
        if line.startswith("#"):
            if seen:
                break
            seen = True
            continue
        out.append(line)
    return "\n".join(out).strip()


def upto_first_table(body: str) -> str:
    """Text up to and including the first table (drops the tables and paragraphs after it)."""
    out, in_table = [], False
    for line in body.splitlines():
        if line.strip().startswith("|"):
            in_table = True
        elif in_table:
            break
        out.append(line)
    return "\n".join(out).strip()


def trunc(s: str, n: int) -> str:
    s = (s or "").strip()
    if len(s) <= n:
        return s
    return s[:n].rsplit(" ", 1)[0].rstrip(",;:( ") + "…"


def excerpt(text: str, max_lines: int = 60) -> str:
    """Markdown excerpt for embedding: headings demoted, cut at a blank line."""
    out = []
    for line in text.splitlines():
        m = re.match(r"^(#+)\s+(.*)$", line)
        out.append(f"#### {m.group(2)}" if m else line)
    if len(out) <= max_lines:
        return "\n".join(out).strip()
    cut = max_lines
    while cut > 10 and out[cut].strip():
        cut -= 1
    return "\n".join(out[:cut]).strip() + "\n\n_(cut here; the rest is in the file)_"


# --------------------------------------------------------------------------------------------
# loaders
# --------------------------------------------------------------------------------------------

class Inputs:
    """Tracks which inputs exist so the report can say what is pending."""

    def __init__(self, vp: Path):
        self.vp = vp
        self.seen: dict[str, dict] = {}

    def note(self, label: str, path: Path, required: bool = False):
        exists = path.exists()
        self.seen[label] = {"path": rel_to_repo(path), "found": exists, "modified": mtime_iso(path) if exists else None,
                            "required": required}
        return exists


def rel_to_repo(p: Path) -> str:
    try:
        return str(Path(p).resolve().relative_to(REPO.resolve()))
    except Exception:
        try:
            return os.path.relpath(p, REPO)
        except Exception:
            return str(p)


def load_verify(vp: Path, inp: Inputs):
    """CSV index: idx[(model, scope, group, mode, metric)] -> row; also headline mode / baseline flag."""
    path = vp / "results" / "verify_summary.csv"
    inp.note("verify_summary.csv", path)
    idx: dict[tuple, dict] = {}
    headline_mode: dict[str, str] = {}
    baseline: str | None = None
    delta_idx: dict[tuple, dict] = {}
    if not path.exists():
        return idx, headline_mode, baseline, delta_idx
    with path.open(newline="") as f:
        for r in csv.DictReader(f):
            m = r["model_id"]
            if r.get("headline_mode"):
                headline_mode[m] = r["headline_mode"]
            if r.get("baseline") == "1":
                baseline = m
            if r["scope"] == "human+headline_vs_baseline":
                delta_idx[(m, r["group"], r["metric"])] = r
            else:
                idx[(m, r["scope"], r["group"], r["mode"], r["metric"])] = r
    return idx, headline_mode, baseline, delta_idx


def load_trials_table(vp: Path) -> list[dict]:
    text = read_text(vp / "results" / "verify_summary.md")
    if not text:
        return []
    out = []
    for t in md_tables(text):
        if t["header"][:2] == ["set", "bucket"]:
            for row in t["rows"]:
                if len(row) >= 7:
                    out.append({"set": re.sub(r"\s*\(separate\)", "", row[0]), "bucket": first_float(row[1]),
                                "speakers": first_float(row[2]), "clips": first_float(row[3]),
                                "targets": row[4], "nontargets": row[5], "fa_allowed": row[6]})
    return out


def load_naming(vp: Path, inp: Inputs):
    docs = {"all": {}, "clean": {}}
    for key, sub in (("all", "naming"), ("clean", "naming_clean")):
        d = vp / "results" / sub
        inp.note(f"{sub}/*.json", d)
        if d.is_dir():
            for p in sorted(d.glob("*.json")):
                doc = read_json(p)
                if isinstance(doc, dict) and doc.get("model_id"):
                    docs[key][doc["model_id"]] = doc
    for sub in ("naming_summary.md", "naming_summary_clean.md"):
        inp.note(sub, vp / "results" / sub)
    return docs


NAMING_KEYS = ("wrong_silent_names", "auto_share_from_meeting3", "first_auto_median", "first_auto_p90",
               "never_auto_share", "work_per_meeting", "wrong_suggestions", "wrong_suggestion_rate",
               "strangers_wrongly_named", "appearances", "regulars", "meetings")


def slim_naming(p):
    return None if not p else {k: p.get(k) for k in NAMING_KEYS}


def naming_view(doc_all: dict | None, doc_clean: dict | None) -> dict | None:
    """One model's naming numbers. `clean_only` = bars calibrated on clean audio only (same footing for
    every model); `with_call` = bars calibrated on every condition the model has (like the app)."""
    if not doc_all and not doc_clean:
        return None

    def test(doc, key):
        return slim_naming((((doc or {}).get("pooled") or {}).get("test") or {}).get(key))

    def calib_wrong(doc):
        return ((((doc or {}).get("pooled") or {}).get("calib") or {}).get("all") or {}).get("wrong_silent_names")

    clean_only = None
    if doc_clean:
        clean_only = test(doc_clean, "all")
    elif doc_all and not test(doc_all, "call"):
        clean_only = test(doc_all, "clean")
    with_call = test(doc_all, "call") and {
        "clean": test(doc_all, "clean"), "call": test(doc_all, "call"), "all": test(doc_all, "all")}
    ref = doc_all or doc_clean
    folds = ref.get("folds") or []
    look_over = sum(f.get("test_lookalike_pairs_over_bar", 0) or 0 for f in folds)
    look_n = sum(f.get("test_lookalike_pairs_checked", 0) or 0 for f in folds)
    wrong = 0
    for doc in (doc_all, doc_clean):
        if doc:
            wrong += (test(doc, "all") or {}).get("wrong_silent_names") or 0
            wrong += calib_wrong(doc) or 0
    fixed = None
    fv = (doc_all or {}).get("fixed_margin_variant")
    if isinstance(fv, dict):
        ft = (fv.get("pooled") or {}).get("test") or {}
        fixed = {"clean": slim_naming(ft.get("clean")), "call": slim_naming(ft.get("call")), "all": slim_naming(ft.get("all"))}
    app_bars = None
    ab = (ref.get("pooled") or {}).get("app_bars")
    if ab:
        app_bars = {"clean": slim_naming(ab.get("clean")), "call": slim_naming(ab.get("call")), "all": slim_naming(ab.get("all"))}
    bars = [{k: (f.get("bars") or {}).get(k) for k in ("floor", "auto_lineup", "auto_global")} for f in folds]
    return {
        "clean_only": clean_only,
        "with_call": with_call or None,
        "all_conditions_view": test(doc_all, "all") if doc_all else None,
        "wrong_silent_total": wrong,
        "lookalike_over": look_over, "lookalike_checked": look_n,
        "bars": bars, "fixed_margins": fixed, "app_bars": app_bars,
        "sets": sorted((ref.get("sets") or {}).keys()),
        "set_conds": sum(len(v) for v in (ref.get("sets") or {}).values()),
        "have_clean_run": bool(doc_clean), "have_all_run": bool(doc_all),
    }


def load_licenses(vp: Path, inp: Inputs):
    path = vp / "models" / "licenses.json"
    inp.note("models/licenses.json", path)
    d = read_json(path) or {}
    by_id, alias = {}, {}
    for m in d.get("models") or []:
        by_id[m["model_id"]] = m
        for a in m.get("aliases") or []:
            alias[a] = m["model_id"]
    return d, by_id, alias


def load_model_meta(vp: Path) -> dict[str, dict]:
    out = {}
    for p in sorted((vp / "models").glob("*/model.json")):
        j = read_json(p)
        if isinstance(j, dict):
            out[p.parent.name] = j
    return out


def load_coreml(vp: Path) -> dict[str, dict]:
    d = read_json(vp / "coreml" / "summary.json")
    out = {}
    if isinstance(d, list):
        for e in d:
            if isinstance(e, dict) and e.get("model_id"):
                out[e.get("registered_as") or e["model_id"] + "-coreml"] = e
    return out


def load_sets(vp: Path, inp: Inputs) -> dict[str, dict]:
    sets = {}
    for name in ALL_SETS:
        seg = vp / "sets" / name / "segments.jsonl"
        inp.note(f"sets/{name}/segments.jsonl", seg)
        if not seg.exists():
            continue
        clips = 0
        speakers, sessions, strangers = set(), set(), set()
        by_bucket = Counter()
        label_source = Counter()
        try:
            with seg.open() as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    r = json.loads(line)
                    clips += 1
                    speakers.add(r.get("speaker"))
                    sessions.add(r.get("session"))
                    by_bucket[int(r.get("bucket", 0))] += 1
                    if r.get("stranger_only"):
                        strangers.add(r.get("speaker"))
                    label_source[r.get("label_source", "human")] += 1
        except Exception as e:  # noqa: BLE001
            log(f"warning: could not read {seg}: {e}")
            continue
        drops = 0
        dp = vp / "results" / "audit" / f"drop_{name}.txt"
        if dp.exists():
            drops = len([x for x in dp.read_text().splitlines() if x.strip()])
        conds = ["clean"] + [c for c in DEGRADED if (vp / "clips" / name / c / "READY").exists()]
        sets[name] = {
            "set": name, "human_labeled": name in HUMAN_SETS, "in_ranking": name in HUMAN_SETS,
            "blurb": SET_BLURB.get(name, ""),
            "speakers": len(speakers), "sessions": len(sessions), "clips": clips,
            "by_bucket": {str(b): by_bucket.get(b, 0) for b in BUCKETS},
            "stranger_only_speakers": len(strangers), "multi_session_speakers": len(speakers) - len(strangers),
            "dropped_by_audit": drops, "clips_after_drops": clips - drops,
            "conditions": conds, "label_source": dict(label_source),
            "ready": (vp / "sets" / name / "READY").exists(),
        }
    return sets


def load_audit(vp: Path, inp: Inputs) -> dict:
    a = vp / "results" / "audit"
    inp.note("audit/audit.md", a / "audit.md")
    out = {"found": (a / "audit.md").exists(), "decide": read_json(a / "decide.json") or {},
           "overlap": read_json(a / "overlap_summary.json") or {}, "bias": []}
    bp = a / "bias.csv"
    if bp.exists():
        with bp.open(newline="") as f:
            for r in csv.DictReader(f):
                out["bias"].append({
                    "model_id": r.get("model"), "labeler": str(r.get("labeler")).lower() == "true",
                    "yodas_eer": fnum(r.get("eer_yodas")),
                    "eer_x": fnum(r.get("eer_yodas_multiplier_vs_expected")),
                    "miss_x": fnum(r.get("miss@1e-3_yodas_multiplier_vs_expected")),
                })
    return out


def load_daemon_ms(vp: Path) -> dict[str, float]:
    """Median embed ms per clip across every emb json of a model (busy machine, mixed devices)."""
    out = {}
    for d in sorted((vp / "emb").glob("*")):
        if not d.is_dir():
            continue
        vals = []
        for p in d.glob("*.json"):
            j = read_json(p)
            v = fnum((j or {}).get("ms_per_clip"))
            if v is not None:
                vals.append(v)
        if vals:
            out[d.name] = statistics.median(vals)
    return out


def load_daemon_status(vp: Path) -> dict | None:
    return read_json(vp / "logs" / "daemon.status.json")


def emb_coverage(vp: Path) -> dict[str, list[str]]:
    out = {}
    for d in sorted((vp / "emb").glob("*")):
        if d.is_dir():
            out[d.name] = sorted(p.stem for p in d.glob("*.npz"))
    return out


# ---- tolerant readers for the files other agents write -------------------------------------

def parse_table_file(path: Path, known: set[str]) -> dict:
    """{model: [ {header: cell} rows ]} plus the tables, for a Markdown file with model-keyed tables."""
    text = read_text(path)
    out = {"text": text, "tables": [], "by_model": defaultdict(list)}
    if not text:
        return out
    for t in md_tables(text):
        if not t["header"]:
            continue
        if "model" not in t["header"][0].lower() and not any(cell_model_id(r[0], known) for r in t["rows"] if r):
            continue
        out["tables"].append(t)
        for row in t["rows"]:
            if not row:
                continue
            mid = cell_model_id(row[0], known)
            if mid:
                d = dict(zip(t["header"], row))
                d["__title__"] = t.get("title") or ""
                out["by_model"][mid].append(d)
    return out


LAT_PREFS = [r"^4\s*s$", r"p50.*4|4.*p50", r"median.*4|4.*median", r"4\s*s.*ms|ms.*4\s*s", r"p50|median", r"\bms\b|latency|ms/"]


def pick_latency(rows: list[dict]) -> dict | None:
    """Fastest 4 s (or best-guess ms) figure among a model's latency rows (several devices -> the fastest)."""
    titled = [r for r in rows if re.search(r"time per window|latency|warm", r.get("__title__", ""), re.I)]
    rows = titled or rows
    if not rows:
        return None
    headers = [h for h in rows[0] if not h.startswith("__")]
    for pref in LAT_PREFS:
        cols = [h for h in headers[1:] if re.search(pref, h, re.I) and not re.search(r"p95|p99|max|cold|load|ratio|stream", h, re.I)]
        if not cols:
            continue
        col = cols[0]
        best = None
        for r in rows:
            v = first_float(r.get(col))
            if v is None:
                continue
            dev = next((r[h] for h in r if re.search(r"device|compute|unit|backend", h, re.I)), None)
            if best is None or v < best["ms"]:
                best = {"ms": v, "column": col, "device": dev, "row": {k: v2 for k, v2 in r.items() if not k.startswith("__")}}
        if best:
            return best
    return None


def _num_keys(d: dict, want: str, avoid: str) -> tuple[str | None, float | None]:
    for k, v in d.items():
        if re.search(want, k, re.I) and not re.search(avoid, k, re.I) and isinstance(v, (int, float)) and not isinstance(v, bool):
            return k, float(v)
    return None, None


LINEUP_CALL_RE = r"opus|call|cross|degrad|noisy|phone"


def lineup_from_json(doc: dict) -> dict:
    """The lineup scorer's headline (DIR at zero wrong names) from lineup/<model>.json.

    Expected shape: headline.mode, headline.by_mode[mode] with keys like dir0_clean_cond, dir0_opus12 and
    *_sd. If the shape changes, any top-1 / accuracy style number is used instead and its key is recorded.
    """
    out: dict = {"coverage_full": (doc.get("coverage") or {}).get("full")}
    hl = doc.get("headline") or {}
    bm = hl.get("by_mode") or {}
    e = bm.get(hl.get("mode")) or (next(iter(bm.values())) if bm else None)
    if isinstance(e, dict):
        ck, cv = _num_keys(e, r"clean", r"_sd$|sd$")
        kk, kv = _num_keys(e, LINEUP_CALL_RE, r"_sd$|sd$|clean")
        out.update({"mode": hl.get("mode"), "clean_key": ck, "clean": cv, "call_key": kk, "call": kv,
                    "clean_sd": (e.get(ck + "_sd") if ck else None), "call_sd": (e.get(kk + "_sd") if kk else None)})
        if cv is not None or kv is not None:
            return out
    flat = dict(flatten(doc))
    ck, cv = _num_keys(flat, r"top.?1|rank.?1|accuracy|\bdir", r"_sd$|" + LINEUP_CALL_RE)
    kk, kv = _num_keys(flat, r"(top.?1|rank.?1|accuracy|\bdir).*(" + LINEUP_CALL_RE + r")|(" + LINEUP_CALL_RE + r").*(top.?1|rank.?1|accuracy|\bdir)", r"_sd$")
    out.update({"clean_key": ck, "clean": cv, "call_key": kk, "call": kv, "guessed": True})
    return out


def flatten(o, prefix=""):
    if isinstance(o, dict):
        for k, v in o.items():
            yield from flatten(v, f"{prefix}.{k}" if prefix else str(k))
    elif isinstance(o, (int, float)) and not isinstance(o, bool):
        yield prefix, float(o)


def load_lineup(vp: Path, inp: Inputs, known: set[str]) -> dict:
    inp.note("lineup_summary.md", vp / "results" / "lineup_summary.md")
    inp.note("lineup/*.json", vp / "results" / "lineup")
    tab = parse_table_file(vp / "results" / "lineup_summary.md", known)
    per: dict[str, dict] = {}
    # markdown fallback: a "DIR @ 0 wrong" (else top-1) column; the table title says clean or call
    for mid, rows in tab["by_model"].items():
        rec: dict = per.setdefault(mid, {})
        for r in rows:
            title = r.get("__title__", "")
            hdr = [h for h in r if not h.startswith("__")]
            col = next((h for h in hdr[1:] if re.search(r"dir.*0 wrong", re.sub(r"[*`]", "", h), re.I)), None) \
                or next((h for h in hdr[1:] if re.search(r"top.?1|rank.?1|accuracy", h, re.I)), None)
            if not col:
                continue
            key = "call_txt" if re.search(r"call", title, re.I) else "clean_txt" if re.search(r"clean", title, re.I) else None
            v = first_float(re.sub(r"[*`]", "", r[col]))
            if key and v is not None:
                rec[key] = v / 100.0
    d = vp / "results" / "lineup"
    if d.is_dir():
        for p in sorted(d.glob("*.json")):
            doc = read_json(p)
            if isinstance(doc, dict):
                mid = doc.get("model_id") or p.stem
                per.setdefault(mid, {})["json"] = lineup_from_json(doc)
    return {"text": tab["text"], "per_model": per, "tables": tab["tables"]}


def lineup_numbers(lu: dict | None) -> dict:
    """{clean, call, clean_sd, call_sd} as fractions, from the JSON headline, else the Markdown tables."""
    if not lu:
        return {}
    js = lu.get("json") or {}
    clean = js.get("clean") if js.get("clean") is not None else lu.get("clean_txt")
    call = js.get("call") if js.get("call") is not None else lu.get("call_txt")
    return {"clean": clean, "call": call, "clean_sd": js.get("clean_sd"), "call_sd": js.get("call_sd"), "mode": js.get("mode")}


def net_of_latency_id(mid: str) -> str:
    return re.sub(r"-(ane|gpu|cpu|coreml)$", "", mid)


def load_latency(vp: Path, inp: Inputs, known: set[str]) -> dict:
    """latency.md rows are Core ML builds named by their source model id. Returns per-network fastest 4 s ms."""
    inp.note("latency.md", vp / "results" / "latency.md")
    tab = parse_table_file(vp / "results" / "latency.md", known)
    per: dict[str, dict] = {}
    for mid, rows in tab["by_model"].items():
        pl = pick_latency(rows)
        if not pl:
            continue
        net = net_of_latency_id(mid)
        if net not in per or pl["ms"] < per[net]["ms"]:
            per[net] = {**pl, "row_id": mid}
    return {"text": tab["text"], "per_model": per}


# --------------------------------------------------------------------------------------------
# assemble one record per model
# --------------------------------------------------------------------------------------------

def ship_status(lic: dict | None, meta: dict) -> tuple[str, str]:
    """(status, label). status: yes / no / unclear / unknown."""
    if meta.get("reference_only"):
        return "no", "no (reference only)"
    if not lic:
        return "unknown", "unknown"
    v = lic.get("verdict")
    risk = lic.get("risk")
    if v == "eligible":
        return "yes", "yes" + (f" ({risk} risk)" if risk and risk != "low" else "")
    if v == "eligible-attribution":
        return "yes", "yes, credit" + (f" ({risk} risk)" if risk and risk != "low" else "")
    if v == "ineligible":
        return "no", "no"
    if v == "unclear":
        return "unclear", "unclear"
    return "unknown", "unknown"


def network_of(mid: str, meta: dict, known_dirs: set[str]) -> str:
    src = meta.get("source_model_id")
    if src:
        return src
    if mid.endswith("-coreml") and mid[:-7] in known_dirs:
        return mid[:-7]
    return mid


class Verify:
    def __init__(self, idx, headline_mode, delta_idx):
        self.idx, self.hm, self.delta_idx = idx, headline_mode, delta_idx

    def get(self, model, scope, group, metric, mode=None):
        mode = mode or self.hm.get(model)
        if not mode:
            return None
        r = self.idx.get((model, scope, group, mode, metric))
        if r is None:
            return None
        return {"v": fnum(r["value"]), "lo": fnum(r["ci_lo"]), "hi": fnum(r["ci_hi"]),
                "n_cells": int(fnum(r["n_cells"]) or 0), "n_expected": int(fnum(r["n_cells_expected"]) or 0),
                "delta": {"v": fnum(r["delta_vs_baseline"]), "lo": fnum(r["delta_lo"]), "hi": fnum(r["delta_hi"])}
                if fnum(r["delta_vs_baseline"]) is not None else None}

    def delta(self, model, group, metric="tar@1e-3"):
        r = self.delta_idx.get((model, group, metric))
        if not r:
            return None
        v = fnum(r["delta_vs_baseline"])
        if v is None:
            return None
        return {"v": v, "lo": fnum(r["delta_lo"]), "hi": fnum(r["delta_hi"]), "n_cells": int(fnum(r["n_cells"]) or 0)}

    def one_threshold(self, model, group, metric):
        mode = self.hm.get(model)
        r = self.idx.get((model, "human+one_threshold", group, mode, metric)) if mode else None
        return fnum(r["value"]) if r else None

    def view(self, model, baseline):
        mode = self.hm.get(model)
        if not mode:
            return None
        clean = self.get(model, "human", "clean", "tar@1e-3")
        cross = self.get(model, "human", "cross", "tar@1e-3")
        overall = self.get(model, "human", "overall", "tar@1e-3") or self.get(model, "human", "overall", "auc")
        if clean is None and cross is None:
            return None
        group = "cross" if cross and cross["v"] is not None else "clean"
        head = cross if group == "cross" else clean
        n_have = (overall or head or {}).get("n_cells", 0)
        n_exp = (overall or head or {}).get("n_expected", 0)
        v = {
            "variant": mode, "headline_group": group,
            "tar_clean": clean, "tar_call": cross, "headline": head,
            "eer_clean": self.get(model, "human", "clean", "eer"),
            "eer_call": self.get(model, "human", "cross", "eer"),
            "min_dcf": (self.get(model, "human", "overall", "mindcf") or {}).get("v"),
            "auc": (self.get(model, "human", "overall", "auc") or {}).get("v"),
            "tar4_call_one_threshold": self.one_threshold(model, "cross", "tar@1e-4"),
            "yodas_tar_call": (self.get(model, "yodas", "cross", "tar@1e-3") or {}).get("v"),
            "yodas_tar_clean": (self.get(model, "yodas", "clean", "tar@1e-3") or {}).get("v"),
            "conds": {}, "buckets": {},
            "delta": None if model == baseline else self.delta(model, group),
            "cells_have": n_have, "cells_expected": n_exp,
            "cells_have_cross": (cross or {}).get("n_cells", 0), "cells_expected_cross": (cross or {}).get("n_expected", 0),
            "complete": bool(n_exp) and n_have >= n_exp,
        }
        for g in CONDS + CROSS:
            t = self.get(model, "human", g, "tar@1e-3")
            e = self.get(model, "human", g, "eer")
            if t or e:
                v["conds"][g] = {"tar": (t or {}).get("v"), "eer": (e or {}).get("v")}
        for b in BUCKETS:
            t = self.get(model, f"human@b{b}", "cross", "tar@1e-3")
            e = self.get(model, f"human@b{b}", "cross", "eer")
            if t or e:
                v["buckets"][str(b)] = {"tar": (t or {}).get("v"), "eer": (e or {}).get("v")}
        return v


def build_models(vp, verify, baseline, naming_docs, licenses, meta_all, coreml, lineup, latency, daemon_ms, inp):
    lic_by_id, alias = licenses[1], licenses[2]
    known_dirs = set(meta_all)
    scored = set(verify.hm) | set(naming_docs["all"]) | set(naming_docs["clean"]) | set(lineup["per_model"])
    ids = sorted(scored | set(meta_all))
    models = {}
    for mid in ids:
        meta = meta_all.get(mid, {})
        lic = None
        for key in (mid, meta.get("source_model_id"), alias.get(mid)):
            if key and key in lic_by_id:
                lic = lic_by_id[key]
                break
        if lic is None and mid.endswith("-coreml") and mid[:-7] in lic_by_id:
            lic = lic_by_id[mid[:-7]]
        ship, ship_label = ship_status(lic, meta)
        net = network_of(mid, meta, known_dirs)
        vv = verify.view(mid, baseline)
        nv = naming_view(naming_docs["all"].get(mid), naming_docs["clean"].get(mid))
        params = meta.get("params_m")
        if params is None and lic:
            params = lic.get("params_m")
        rec = {
            "model_id": mid, "network": net, "is_coreml_build": mid != net,
            "family": meta.get("family") or (lic or {}).get("family"),
            "runtime": meta.get("runtime"), "dim": meta.get("dim"),
            "params_m": params, "baseline": mid == baseline,
            "status": meta.get("status"), "reference_only": bool(meta.get("reference_only")),
            "train_data": meta.get("train_data") or (lic or {}).get("train_data"),
            "license": {"verdict": (lic or {}).get("verdict"), "risk": (lic or {}).get("risk"),
                        "reason": (lic or {}).get("reason"), "ship": ship, "ship_label": ship_label},
            "verify": vv, "naming": nv, "scored": bool(vv or nv),
        }
        # lineup
        lu = lineup["per_model"].get(mid)
        rec["lineup"] = lu
        rec["lineup_n"] = lineup_numbers(lu)
        # latency: latency.md (a Core ML benchmark, keyed by network) wins; else the embed daemon's median for this build
        lat = latency["per_model"].get(net)
        if lat and lat.get("ms") is not None:
            rec["latency"] = {"ms": lat["ms"], "source": "latency.md", "device": lat.get("device"), "column": lat.get("column")}
        elif mid in daemon_ms:
            rec["latency"] = {"ms": daemon_ms[mid], "source": "embed daemon", "device": meta.get("device"), "column": "median ms per clip"}
        else:
            rec["latency"] = None
        cm = coreml.get(mid)
        if cm:
            rec["coreml"] = {k: cm.get(k) for k in ("precision", "shapes", "parity_ALL_min", "parity_CPU_min", "ms4_ALL", "ms4_CPU",
                                                    "size_mb", "ALL_runs_on", "error", "converted")}
        models[mid] = rec
    return models


def pick_representatives(models: dict) -> dict[str, dict]:
    """One record per network: the build with the best coverage, plain build before its Core ML twin."""
    groups: dict[str, list[dict]] = defaultdict(list)
    for m in models.values():
        if m["scored"] and m["verify"]:
            groups[m["network"]].append(m)
    reps = {}
    for net, ms in groups.items():
        ms.sort(key=lambda m: (
            0 if (m["verify"]["tar_call"] and m["verify"]["complete"]) else 1 if m["verify"]["tar_call"] else 2,
            -(m["verify"]["cells_have"] or 0), 1 if m["is_coreml_build"] else 0, m["model_id"]))
        rep = dict(ms[0])
        rep["builds"] = [m["model_id"] for m in ms]
        for key in ("naming", "lineup", "lineup_n"):
            if not rep.get(key) or (key == "lineup_n" and not any(v is not None for v in rep[key].values())):
                rep[key] = next((m[key] for m in ms if m.get(key) and (key != "lineup_n" or any(v is not None for v in m[key].values()))), rep.get(key))
        # fastest known latency among builds (latency.md beats daemon)
        lats = [m["latency"] for m in ms if m.get("latency")]
        lats.sort(key=lambda l: (0 if l["source"] == "latency.md" else 1, l["ms"]))
        rep["latency_best"] = lats[0] if lats else None
        reps[net] = rep
    return reps


def head_value(m: dict):
    v = m.get("verify") or {}
    return (v.get("headline") or {}).get("v")


def naming_ok(m: dict) -> bool | None:
    """True: naming ran and zero wrong silent names. False: wrong names seen. None: pending."""
    n = m.get("naming")
    if not n or not n.get("clean_only"):
        return None
    return n["wrong_silent_total"] == 0 and n["lookalike_over"] == 0


def decide(reps: dict[str, dict], baseline_id: str | None) -> dict:
    """Winner rule: shippable license, fully scored, zero wrong silent names in the naming simulation, then the highest
    call-audio TAR@1e-3. No winner is crowned while a candidate that looks better on the cells it has is still being scored."""
    base = next((m for m in reps.values() if m["model_id"] == baseline_id), None)
    cands = [m for m in reps.values() if m["license"]["ship"] == "yes" and not m["baseline"]
             and m["verify"] and m["verify"]["tar_call"] and m["verify"]["tar_call"]["v"] is not None]
    complete = sorted([m for m in cands if m["verify"]["complete"]], key=lambda m: -m["verify"]["tar_call"]["v"])
    gated = [m for m in complete if naming_ok(m) is True]
    partial = sorted([m for m in cands if not m["verify"]["complete"]],
                     key=lambda m: -((m["verify"]["delta"] or {}).get("v") or -9))

    def dv(m):
        return ((m["verify"] or {}).get("delta") or {}).get("v")
    winner = gated[0] if gated else None
    held_back = None
    if winner is not None and partial and dv(partial[0]) is not None and dv(partial[0]) > (dv(winner) if dv(winner) is not None else -9):
        held_back = partial[0]["model_id"]
        winner = None
    top_noship = sorted([m for m in reps.values() if m["license"]["ship"] != "yes" and m["verify"] and m["verify"]["tar_call"]
                         and m["verify"]["tar_call"]["v"] is not None], key=lambda m: -m["verify"]["tar_call"]["v"])
    runner = None
    if winner is not None and len(gated) > 1:
        runner = gated[1]
    return {"winner": winner["model_id"] if winner else None,
            "runner_up": runner["model_id"] if runner else None,
            "best_complete_shippable": complete[0]["model_id"] if complete else None,
            "held_back_by": held_back,
            "blocked_by_naming": [m["model_id"] for m in complete if naming_ok(m) is not True],
            "still_filling": [m["model_id"] for m in partial],
            "provisional_leader": partial[0]["model_id"] if partial else None,
            "best_not_shippable": top_noship[0]["model_id"] if top_noship else None,
            "baseline": base["model_id"] if base else baseline_id}


def find_rep(reps: dict, model_id: str | None):
    if not model_id:
        return None
    return next((m for m in reps.values() if m["model_id"] == model_id), None)


# --------------------------------------------------------------------------------------------
# charts
# --------------------------------------------------------------------------------------------

def setup_mpl():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({
        "figure.facecolor": C_SURFACE, "axes.facecolor": C_SURFACE, "savefig.facecolor": C_SURFACE,
        "font.family": "sans-serif", "font.size": 10, "text.color": C_TEXT,
        "axes.edgecolor": C_GRID, "axes.labelcolor": C_TEXT2, "xtick.color": C_TEXT2, "ytick.color": C_TEXT2,
        "axes.spines.top": False, "axes.spines.right": False, "axes.linewidth": 1.0,
        "grid.color": C_GRID, "grid.linewidth": 0.8, "grid.linestyle": "-", "hatch.linewidth": 1.0,
    })
    return plt


def category(m: dict) -> str:
    if m["baseline"]:
        return "baseline"
    return "ship" if m["license"]["ship"] == "yes" else "noship"


def placeholder(plt, path: Path, title: str, msg: str):
    fig, ax = plt.subplots(figsize=(9, 3))
    ax.axis("off")
    ax.text(0.5, 0.62, title, ha="center", fontsize=13, weight="bold")
    ax.text(0.5, 0.35, msg, ha="center", fontsize=11, color=C_TEXT2)
    fig.savefig(path, dpi=160)
    plt.close(fig)


def legend_handles(cats=("ship", "baseline", "noship"), kind="bar"):
    from matplotlib.lines import Line2D
    from matplotlib.patches import Patch
    lab = {"ship": "Shippable license", "baseline": "Baseline (today's app model)", "noship": "Not shippable (license)"}
    col = {"ship": C_SHIP, "baseline": C_BASE, "noship": C_NOSHIP}
    hs = []
    for c in cats:
        if kind == "bar":
            hs.append(Patch(facecolor=C_NOSHIP_FILL, hatch="////", edgecolor=C_NOSHIP, linewidth=0, label=lab[c]) if c == "noship"
                      else Patch(facecolor=col[c], linewidth=0, label=lab[c]))
        else:
            hs.append(Line2D([0], [0], marker="o", ls="", ms=8, mfc=col[c], mec=col[c], label=lab[c]))
    return hs


def new_fig(plt, w, plot_h, left, right=0.6, top=1.25, bottom=0.9):
    """A figure laid out in inches so headers, footnotes and labels never collide."""
    H = plot_h + top + bottom
    fig = plt.figure(figsize=(w, H))
    ax = fig.add_axes([left / w, bottom / H, (w - left - right) / w, plot_h / H])
    return fig, ax, H


def header(fig, H, title, sub, handles=None):
    fig.text(0.012, 1 - 0.32 / H, title, ha="left", va="center", fontsize=13, weight="bold", color=C_TEXT)
    fig.text(0.012, 1 - 0.62 / H, sub, ha="left", va="center", fontsize=9, color=C_TEXT2)
    if handles:
        fig.legend(handles=handles, loc="center left", bbox_to_anchor=(0.006, 1 - 0.95 / H), ncol=len(handles), frameon=False,
                   fontsize=9, handletextpad=0.5, columnspacing=1.6)


def chart_ranking(plt, reps: dict, path: Path, meta: dict) -> dict:
    import textwrap
    rows = [m for m in reps.values() if m["verify"] and m["verify"]["tar_call"] and m["verify"]["tar_call"]["v"] is not None]
    missing = sorted(m["model_id"] for m in reps.values() if m["verify"] and not (m["verify"]["tar_call"] and m["verify"]["tar_call"]["v"] is not None))
    if not rows:
        placeholder(plt, path, "Ranking", "pending: no call-audio results yet")
        return {"path": path.name, "models": [], "pending": True}
    rows.sort(key=lambda m: (-m["verify"]["tar_call"]["v"], m["model_id"]))
    n = len(rows)
    labels = []
    for m in rows:
        v = m["verify"]
        labels.append(m["model_id"] + ("" if v["complete"] else f"  [{v['cells_have']}/{v['cells_expected']} cells]"))
    foot = []
    if any(not m["verify"]["complete"] for m in rows):
        foot.append("[a/b cells] = not every set, clip length and condition is scored yet, so that bar averages a different mix. Compare with care; "
                    "the paired difference to the baseline in the tables uses only shared cells.")
    if missing:
        foot.append(f"{len(missing)} more models have no call-audio result yet and are not drawn (they are in the table).")
    wrapped = [w for ln in foot for w in (textwrap.wrap(ln, 165) or [""])]
    left = max(len(x) for x in labels) * 0.072 + 0.35
    bottom = 0.85 + 0.17 * len(wrapped)
    cats = [c for c in ("ship", "baseline", "noship") if any(category(m) == c for m in rows)]
    fig, ax, H = new_fig(plt, 10.5, 0.34 * n + 0.2, left=left, bottom=bottom)
    ys = list(range(n))[::-1]
    for y, m in zip(ys, rows):
        e = m["verify"]["tar_call"]
        cat = category(m)
        v = 100 * e["v"]
        if cat == "ship":
            ax.barh(y, v, height=0.56, color=C_SHIP, linewidth=0, zorder=2)
        elif cat == "baseline":
            ax.barh(y, v, height=0.56, color=C_BASE, linewidth=0, zorder=2)
        else:
            ax.barh(y, v, height=0.56, facecolor=C_NOSHIP_FILL, edgecolor=C_NOSHIP, hatch="////", linewidth=0, zorder=2)
        if e.get("lo") is not None and e.get("hi") is not None:
            ax.errorbar(v, y, xerr=[[v - 100 * e["lo"]], [100 * e["hi"] - v]], fmt="none", ecolor=C_TEXT, elinewidth=1.2,
                        capsize=3, capthick=1.2, zorder=3)
        hi = 100 * (e.get("hi") if e.get("hi") is not None else e["v"])
        ax.text(hi + 1.0, y, f"{v:.1f}", va="center", ha="left", fontsize=9, color=C_TEXT, zorder=4)
    ax.set_yticks(ys)
    ax.set_yticklabels(labels, fontsize=9)
    ax.set_xlim(0, 100)
    ax.set_ylim(-0.7, n - 0.3)
    ax.set_xlabel("True accepts at 1 in 1,000 false accepts (%), call audio. Higher is better.")
    ax.grid(axis="x", zorder=0)
    ax.set_axisbelow(True)
    ax.tick_params(axis="y", length=0)
    header(fig, H, "Who do we still recognize on call audio?",
           "Enroll on clean audio, test on Opus 12 kbps / phone / noisy-room copies. Pooled over the human-labeled sets. Whiskers: 95% CI over speakers.",
           legend_handles(cats))
    for i, ln in enumerate(wrapped):
        fig.text(0.012, (0.12 + 0.17 * (len(wrapped) - 1 - i)) / H, ln, ha="left", va="bottom", fontsize=8, color=C_TEXT2)
    fig.savefig(path, dpi=160)
    plt.close(fig)
    return {"path": path.name, "models": [m["model_id"] for m in rows], "pending": False, "missing": missing}


def spread(vals: list[float], gap: float) -> list[float]:
    """Push label positions apart so neighbors are at least `gap` apart, keeping order."""
    order = sorted(range(len(vals)), key=lambda i: vals[i])
    pos = [vals[i] for i in order]
    for _ in range(80):
        moved = False
        for j in range(1, len(pos)):
            if pos[j] - pos[j - 1] < gap - 1e-9:
                mid = (pos[j] + pos[j - 1]) / 2
                pos[j - 1], pos[j] = mid - gap / 2, mid + gap / 2
                moved = True
        if not moved:
            break
    out = [0.0] * len(vals)
    for k, i in enumerate(order):
        out[i] = pos[k]
    return out


def chart_slope(plt, reps: dict, path: Path) -> dict:
    ok = [m for m in reps.values() if m["verify"] and m["verify"]["tar_call"] and m["verify"]["tar_call"]["v"] is not None
          and m["verify"]["tar_clean"] and m["verify"]["tar_clean"]["v"] is not None]
    ships = sorted([m for m in ok if category(m) == "ship"], key=lambda m: -m["verify"]["tar_call"]["v"])[:8]
    base = [m for m in ok if m["baseline"]]
    noship = sorted([m for m in ok if category(m) == "noship"], key=lambda m: -m["verify"]["tar_call"]["v"])[:1]
    sel = ships + base + noship
    if not sel:
        placeholder(plt, path, "Clean vs call audio", "pending: no model has both clean and call-audio results yet")
        return {"path": path.name, "models": [], "pending": True}
    lo = min(min(100 * m["verify"]["tar_call"]["v"], 100 * m["verify"]["tar_clean"]["v"]) for m in sel)
    hi = max(max(100 * m["verify"]["tar_call"]["v"], 100 * m["verify"]["tar_clean"]["v"]) for m in sel)
    pad = max(3.0, 0.08 * (hi - lo))
    ymin, ymax = lo - pad, min(100.0, hi + pad)
    plot_h = 5.6
    fig, ax, H = new_fig(plt, 11, plot_h, left=0.85, right=0.3, top=1.25, bottom=0.95)
    gap = (ymax - ymin) / plot_h * 0.235  # 0.235 in between label centers
    left = spread([100 * m["verify"]["tar_clean"]["v"] for m in sel], gap)
    right = spread([100 * m["verify"]["tar_call"]["v"] for m in sel], gap)
    for m, ly, ry in zip(sel, left, right):
        v = m["verify"]
        yc, yk = 100 * v["tar_clean"]["v"], 100 * v["tar_call"]["v"]
        cat = category(m)
        col = {"ship": C_SHIP, "baseline": C_BASE, "noship": C_NOSHIP}[cat]
        ls = "-" if v["complete"] else (0, (4, 2))
        lw = 2.4 if cat == "baseline" else 2.0
        ax.plot([0, 1], [yc, yk], color=col, lw=lw, ls=ls, solid_capstyle="round", zorder=3 if cat != "noship" else 2)
        ax.plot([0, 1], [yc, yk], "o", color=col, ms=7, mec=C_SURFACE, mew=2, zorder=4)
        name = m["model_id"]
        ax.annotate(f"{name}  {yc:.1f}", (0, yc), xytext=(-0.05, ly), textcoords="data", ha="right", va="center",
                    fontsize=8.5, color=C_TEXT, arrowprops=dict(arrowstyle="-", color=C_GRID, lw=0.8, shrinkA=0, shrinkB=2))
        ax.annotate(f"{yk:.1f}  {name}", (1, yk), xytext=(1.05, ry), textcoords="data", ha="left", va="center",
                    fontsize=8.5, color=C_TEXT, arrowprops=dict(arrowstyle="-", color=C_GRID, lw=0.8, shrinkA=0, shrinkB=2))
    ax.set_xlim(-1.35, 2.35)
    ax.set_ylim(ymin, ymax)
    ax.set_xticks([0, 1])
    ax.set_xticklabels(["Clean audio\n(enroll clean, test clean)", "Call audio\n(enroll clean, test Opus / phone / noisy)"], fontsize=9.5)
    ax.set_ylabel("True accepts at 1 in 1,000 false accepts (%)")
    ax.yaxis.grid(True, zorder=0)
    ax.set_axisbelow(True)
    ax.spines["left"].set_visible(False)
    ax.tick_params(axis="x", length=0)
    cats = [c for c in ("ship", "baseline", "noship") if any(category(m) == c for m in sel)]
    sub = "Top 8 shippable models, the baseline, and the best model we cannot ship."
    if any(not m["verify"]["complete"] for m in sel):
        sub += "  Dashed = not every cell scored yet."
    header(fig, H, "How much does each model lose on call audio?", sub, legend_handles(cats, kind="line"))
    fig.savefig(path, dpi=160)
    plt.close(fig)
    return {"path": path.name, "models": [m["model_id"] for m in sel], "pending": False}


def chart_latency(plt, reps: dict, path: Path) -> dict:
    from matplotlib.lines import Line2D
    pts = []
    for m in reps.values():
        v = m["verify"]
        lat = m.get("latency_best")
        if not v or not v["tar_call"] or v["tar_call"]["v"] is None or not lat or not lat.get("ms") or lat["ms"] <= 0:
            continue
        pts.append((m, lat))
    if not pts:
        placeholder(plt, path, "Accuracy vs latency", "pending: no latency numbers yet")
        return {"path": path.name, "models": [], "pending": True}
    have_fallback = any(l["source"] != "latency.md" for _, l in pts)
    have_real = any(l["source"] == "latency.md" for _, l in pts)
    cats = [c for c in ("ship", "baseline", "noship") if any(category(m) == c for m, _ in pts)]
    fig, ax, H = new_fig(plt, 10.5, 5.6, left=0.95, right=0.5, top=1.25, bottom=1.05)
    for m, lat in pts:
        cat = category(m)
        col = {"ship": C_SHIP, "baseline": C_BASE, "noship": C_NOSHIP}[cat]
        hollow = lat["source"] != "latency.md"
        x, y = lat["ms"], 100 * m["verify"]["tar_call"]["v"]
        e = m["verify"]["tar_call"]
        if e.get("lo") is not None and e.get("hi") is not None:
            ax.plot([x, x], [100 * e["lo"], 100 * e["hi"]], color=col, lw=1.0, alpha=0.45, zorder=2)
        ax.plot([x], [y], "o", ms=9, mfc=C_SURFACE if hollow else col, mec=col, mew=2, zorder=4)
    ax.set_xscale("log")
    xs = [l["ms"] for _, l in pts]
    lo_x, hi_x = min(xs) / 1.6, max(xs) * 1.6
    ticks = [t for t in (1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000) if lo_x <= t <= hi_x]
    ax.set_xlim(lo_x, hi_x)
    ax.set_xticks(ticks)
    ax.set_xticklabels([str(t) for t in ticks])
    ax.minorticks_off()
    ys_ = [100 * m["verify"]["tar_call"]["v"] for m, _ in pts]
    los = [100 * m["verify"]["tar_call"]["lo"] for m, _ in pts if m["verify"]["tar_call"].get("lo") is not None] or ys_
    his = [100 * m["verify"]["tar_call"]["hi"] for m, _ in pts if m["verify"]["tar_call"].get("hi") is not None] or ys_
    ax.set_ylim(min(los) - 2, max(his) + 2)
    from matplotlib.ticker import MaxNLocator
    ax.yaxis.set_major_locator(MaxNLocator(integer=True))
    xl = "Milliseconds to embed one clip (log scale). Lower is better."
    if have_fallback:
        xl += "  Hollow dot = rough timing from the embedding job on a busy machine."
    ax.set_xlabel(xl)
    ax.set_ylabel("True accepts at 1 in 1,000 false accepts (%), call audio")
    ax.grid(True, zorder=0)
    ax.set_axisbelow(True)
    frontier_pts = sorted([(lat["ms"], 100 * m["verify"]["tar_call"]["v"], m) for m, lat in pts if category(m) != "noship"])
    front, best = [], -1.0
    for x, y, m in frontier_pts:
        if y > best:
            front.append((x, y, m))
            best = y
    if len(front) >= 2:
        ax.step([p[0] for p in front], [p[1] for p in front], where="post", color=C_TEXT2, lw=1.0, alpha=0.6, zorder=1)
    if len(pts) <= 14:
        to_label = {m["model_id"] for m, _ in pts}
    else:
        to_label = {m["model_id"] for _, _, m in front} | {m["model_id"] for m, _ in pts if m["baseline"]}
        to_label |= {m["model_id"] for m, _ in sorted(pts, key=lambda p: -p[0]["verify"]["tar_call"]["v"])[:4]}
    fig.canvas.draw()
    rend = fig.canvas.get_renderer()
    placed = []
    for m, lat in pts:
        px, py = ax.transData.transform((lat["ms"], 100 * m["verify"]["tar_call"]["v"]))
        placed.append(type("B", (), {"x0": px - 9, "x1": px + 9, "y0": py - 9, "y1": py + 9})())
    axbb = ax.get_window_extent(rend)

    def overlaps(a, b):
        return not (a.x1 < b.x0 or b.x1 < a.x0 or a.y1 < b.y0 or b.y1 < a.y0)

    cands = [(10, 6, "left", "bottom"), (10, -6, "left", "top"), (-10, 6, "right", "bottom"), (-10, -6, "right", "top"),
             (0, 13, "center", "bottom"), (0, -13, "center", "top"), (14, 0, "left", "center"), (-14, 0, "right", "center"),
             (24, 18, "left", "bottom"), (24, -18, "left", "top"), (-24, 18, "right", "bottom"), (-24, -18, "right", "top")]
    for m, lat in sorted(pts, key=lambda p: (0 if p[0]["baseline"] else 1, -p[0]["verify"]["tar_call"]["v"])):
        if m["model_id"] not in to_label:
            continue
        x, y = lat["ms"], 100 * m["verify"]["tar_call"]["v"]
        chosen = None
        for dx, dy, ha, va in cands:
            t = ax.annotate(m["model_id"], (x, y), xytext=(dx, dy), textcoords="offset points", ha=ha, va=va, fontsize=8.5, color=C_TEXT)
            bb = t.get_window_extent(rend)
            inside = bb.x0 >= axbb.x0 and bb.x1 <= axbb.x1 and bb.y0 >= axbb.y0 and bb.y1 <= axbb.y1
            if inside and not any(overlaps(bb, p) for p in placed):
                chosen = bb
                break
            t.remove()
        if chosen is None:
            t = ax.annotate(m["model_id"], (x, y), xytext=(10, 6), textcoords="offset points", ha="left", va="bottom", fontsize=8.5, color=C_TEXT)
            chosen = t.get_window_extent(rend)
        placed.append(chosen)
    hs = legend_handles(cats, kind="dot")
    if len(front) >= 2:
        hs.append(Line2D([0], [0], color=C_TEXT2, lw=1.0, label="Best so far as you go slower"))
    header(fig, H, "What does more accuracy cost in time?",
           "One dot per network at its fastest measured build. Vertical line: 95% CI of accuracy." + ("" if have_real else " Latency benchmark pending."), hs)
    fig.savefig(path, dpi=160)
    plt.close(fig)
    return {"path": path.name, "models": [m["model_id"] for m, _ in pts], "pending": False,
            "latency_sources": sorted({l["source"] for _, l in pts})}


# --------------------------------------------------------------------------------------------
# markdown
# --------------------------------------------------------------------------------------------

def mdrow(cells):
    return "| " + " | ".join(str(c) for c in cells) + " |"


def pct_s(v):
    """Share as a short percent string: whole numbers from 10% up, one decimal below (like naming_sim)."""
    if v is None:
        return PENDING
    return f"{100 * v:.0f}%" if v >= 0.1 or v == 0 else f"{100 * v:.1f}%"


def naming_cell(n):
    """'71% / 60%' auto-named from meeting 3+: clean-only bars / with call audio in the calibration."""
    if not n:
        return PENDING
    co = n.get("clean_only")
    wc = n.get("with_call")
    a = pct_s(co.get("auto_share_from_meeting3")) if co else PENDING
    b = pct_s((wc["call"] or {}).get("auto_share_from_meeting3")) if wc and wc.get("call") else PENDING
    return f"{a} / {b}"


def wrong_cell(n):
    if not n or not n.get("clean_only"):
        return PENDING
    t = n["wrong_silent_total"]
    look = n["lookalike_over"]
    s = "0" if t == 0 else f"**{t}**"
    if look:
        s += f", {look} look-alike"
    return s


def lineup_cell(m):
    """Lineup DIR at zero wrong names, clean / opus12 probes."""
    ln = m.get("lineup_n") or {}
    if not ln or (ln.get("clean") is None and ln.get("call") is None):
        return PENDING
    return f"{pct_s(ln.get('clean'))} / {pct_s(ln.get('call'))}"


def latency_cell(m):
    lat = m.get("latency")
    if not lat or not lat.get("ms"):
        return PENDING
    ms = lat["ms"]
    s = f"{ms:.0f}" if ms >= 10 else f"{ms:.1f}"
    return s if lat["source"] == "latency.md" else "~" + s


def model_cell(m):
    s = f"`{m['model_id']}`"
    if m["baseline"]:
        s += " **(baseline)**"
    if m["is_coreml_build"]:
        s += " _(Core ML)_"
    if m.get("status") not in (None, "ready"):
        s += f" _({m['status']})_"
    return s


def sort_key_ranking(m):
    v = m.get("verify")
    if v and v["tar_call"] and v["tar_call"]["v"] is not None:
        return (0 if v["complete"] else 1, -v["tar_call"]["v"], m["model_id"])
    if v and v["tar_clean"] and v["tar_clean"]["v"] is not None:
        return (2, -v["tar_clean"]["v"], m["model_id"])
    return (3, 0, m["model_id"])


def build_markdown(ctx: dict) -> str:
    models, reps, datasets = ctx["models"], ctx["reps"], ctx["datasets"]
    dec, baseline_id = ctx["decision"], ctx["baseline_id"]
    inp, vp = ctx["inputs"], ctx["vp"]
    charts_rel = ctx["charts_rel"]
    L: list[str] = []
    A = L.append
    scored = [m for m in models.values() if m["scored"]]
    scored_v = [m for m in scored if m["verify"]]
    nets_scored = {m["network"] for m in scored}
    ship_nets = {m["network"] for m in scored if m["license"]["ship"] == "yes"}
    base = models.get(baseline_id) if baseline_id else None
    now = ctx["now"]

    A("# Voiceprint bake-off: results")
    A("")
    A(f"_Generated {now} by `scripts/voiceprint/build_report.py` from `data/eval/voiceprint/results`. "
      "Rerun it any time; numbers that haven't landed show as pending. The charts and raw tables live under "
      "`data/eval/voiceprint/results/report/` (gitignored with the rest of `data/`)._")
    A("")
    ds = ctx["daemon_status"]
    if ds and ds.get("pending"):
        A(f"> **Not final.** The embedding daemon still had {ds['pending']} jobs queued at {ds.get('time', 'the last check')}, "
          "so some models are missing conditions. Rows say how many cells they have.")
        A("")

    # ---- short version
    A("## The short version")
    A("")
    human_n = sum(datasets[s]["clips"] for s in HUMAN_SETS if s in datasets)
    people = sum(datasets[s]["speakers"] for s in HUMAN_SETS if s in datasets)
    A(f"- We scored **{len(nets_scored)} voiceprint networks** ({len(scored)} builds, {len(ship_nets)} networks we could legally ship) "
      f"on {human_n:,} clips of {people} real people in four human-labeled sets"
      + (f", plus a fifth set with model-made labels that we keep out of the ranking." if "yodas" in datasets else "."))
    w, r_up = find_rep(reps, dec["winner"]), find_rep(reps, dec["runner_up"])
    b_rep = find_rep(reps, baseline_id) or base
    if b_rep and b_rep["verify"] and b_rep["verify"]["tar_call"]:
        A(f"- Today's model (`{b_rep['model_id']}`) accepts {ci_txt(b_rep['verify']['tar_call'], unit='%')} of same-person pairs on call audio "
          "at 1 false accept in 1,000.")
    if w:
        wv = w["verify"]
        kind = verdict_kind(w)
        d = wv["delta"]
        if kind == "win":
            A(f"- **Winner: `{w['model_id']}`.** {ci_txt(wv['tar_call'], unit='%')} on call audio, {delta_txt(d)} points vs today's model. "
              "That's a clear win: the paired interval excludes zero.")
        elif kind == "lead":
            A(f"- **Best shippable: `{w['model_id']}`**, {ci_txt(wv['tar_call'], unit='%')} on call audio, {delta_txt(d)} points vs today's model. "
              "Ahead, but the interval includes zero, so it isn't proven.")
        else:
            A(f"- **Nothing complete beats today's model.** Best shippable so far is `{w['model_id']}` at {ci_txt(wv['tar_call'], unit='%')} "
              f"({delta_txt(d)} points).")
        if r_up:
            rv = r_up["verify"]
            ov = overlap(wv["tar_call"], rv["tar_call"])
            A(f"- Runner-up: `{r_up['model_id']}` at {ci_txt(rv['tar_call'], unit='%')}. "
              + ("The intervals overlap, so this metric alone can't separate them." if ov else "The intervals don't overlap."))
    else:
        why = []
        pl = find_rep(reps, dec["held_back_by"] or dec["provisional_leader"])
        if pl:
            why.append(f"`{pl['model_id']}` leads so far ({delta_txt(pl['verify']['delta'])} points vs today's model on the cells it has: "
                       f"{pl['verify']['cells_have']} of {pl['verify']['cells_expected']}) but isn't fully scored")
        if dec["blocked_by_naming"]:
            why.append("naming results are missing or not clean for " + ", ".join(f"`{x}`" for x in dec["blocked_by_naming"][:4]))
        A("- **No winner yet.** " + ("; ".join(why) + "." if why else "Not enough shippable models with full results."))
    bn = find_rep(reps, dec["best_not_shippable"])
    if bn:
        A(f"- Most accurate overall is `{bn['model_id']}` ({ci_txt(bn['verify']['tar_call'], unit='%')}), but its license blocks shipping "
          f"({(bn['license']['reason'] or 'see license table')[:110].rstrip('.')}).")
    wrongs = [m for m in reps.values() if m.get("naming") and m["naming"]["wrong_silent_total"] > 0]
    named = [m for m in reps.values() if m.get("naming") and m["naming"].get("clean_only")]
    if named:
        if wrongs:
            A("- **Wrong silent names above zero:** " + ", ".join(f"`{m['model_id']}` ({m['naming']['wrong_silent_total']})" for m in wrongs)
              + ". Those can't ship.")
        else:
            A(f"- Wrong silent names: **0 for all {len(named)} models simulated.** That was the hard gate.")
    pend = ctx["pending"]
    if pend:
        A("- Still pending: " + "; ".join(pend[:6]) + ("; and more (see the last section)." if len(pend) > 6 else "."))
    A("")

    # ---- what and why
    A("## What we tested and why")
    A("")
    A("Nemotron now separates the speakers in a meeting (PR #1887). So the voiceprint model only has to answer one thing: "
      "is this the same person we heard before? Today that model is the WeSpeaker ResNet34-LM embedding inside FluidAudio. "
      "We wanted to know if anything we can legally ship does that better.")
    A("")
    A("Four kinds of test, because one number lies:")
    A("")
    A("1. **Pairwise verification.** Take two clips. Same person or not? We report *TAR at FAR 1e-3*: of all same-person pairs, "
      "the share we accept when the bar is set so only 1 in 1,000 different-person pairs sneaks through (higher is better). "
      "EER is where misses equal false accepts (lower is better). Clips are 2, 4 and 8 seconds. Same person always means "
      "a *different* session, never the same recording.")
    A("2. **Call audio.** The headline is *cross-condition*: enroll a person on clean audio, then test on a weak Opus 12 kbps "
      "link, a phone line (8 kHz, μ-law), or a reverberant room with music or babble at 5 to 15 dB SNR. That's what a meeting app hears.")
    A("3. **Naming simulation.** A Python mirror of the app's naming replays whole runs of meetings with each model, with the bars "
      "calibrated per model. It counts what a user feels: how many meetings until a regular is named automatically, how often we "
      "suggest the wrong name, and wrong *silent* names, which must be zero.")
    A("4. **Lineup, speed, and the real pipeline.** A lineup of everyone at once (334 people), how long one clip takes, and finally the "
      "winner run through the actual app pipeline against today's model.")
    A("")
    A("The gate for shipping: the license has to allow it, and wrong silent names have to be zero. Accuracy only ranks what passes.")
    A("")

    # ---- datasets
    A("## Datasets")
    A("")
    A("All audio is 16 kHz mono. We use local copies for evaluation only; nothing is committed or uploaded.")
    A("")
    if datasets:
        A(mdrow(["set", "what it is", "people", "sessions", "clips (2 / 4 / 8 s)", "dropped by audit", "used for", "conditions"]))
        A(mdrow(["---"] * 8))
        for s in ALL_SETS:
            d = datasets.get(s)
            if not d:
                A(mdrow([f"`{s}`", SET_BLURB.get(s, ""), PENDING, PENDING, PENDING, PENDING, "", PENDING]))
                continue
            bk = " / ".join(f"{d['by_bucket'][str(b)]:,}" for b in BUCKETS)
            strangers = f" ({d['stranger_only_speakers']} single-session)" if d["stranger_only_speakers"] else ""
            A(mdrow([f"`{s}`", d["blurb"], f"{d['speakers']}{strangers}", f"{d['sessions']:,}", f"{d['clips']:,} ({bk})",
                     f"{d['dropped_by_audit']:,}", "ranking" if d["in_ranking"] else "reported separately",
                     ", ".join(d["conditions"])]))
        A("")
        A(f"The four ranked sets hold {people} people. "
          "Single-session people can only be strangers (impostors), never the person you're trying to recognize.")
    else:
        A(f"{PENDING}: no `sets/*/segments.jsonl` found.")
    A("")
    A("Call-audio copies, made by `scripts/voiceprint/degrade.py`, one deterministic copy per clip and condition:")
    A("")
    A("- `opus12`: Opus at 12 kbps, like a weak Zoom or Meet link.")
    A("- `phone`: 8 kHz, 300 to 3400 Hz, G.711 μ-law.")
    A("- `noisy`: room reverb (RT60 0.3 to 0.7 s) plus music or babble at 5 to 15 dB SNR. The noise comes from a separate bank, never from an eval set.")
    A("")
    trials = ctx["trials"]
    if trials:
        A("Trials are sampled once per set and clip length (up to 30,000 of each kind) and reused for every model and condition, so every model faces the same pairs.")
        A("")
        A(mdrow(["set", "clip length", "people", "clips", "same-person pairs", "different-person pairs (same session)", "false accepts allowed at 1e-3 / 1e-4"]))
        A(mdrow(["---"] * 7))
        for t in trials:
            A(mdrow([f"`{t['set']}`", f"{int(t['bucket'])} s" if t["bucket"] else DASH, int(t["speakers"] or 0), int(t["clips"] or 0),
                     t["targets"], t["nontargets"], t["fa_allowed"]]))
        A("")
    a = ctx["audit"]
    if a["found"]:
        A("**We audited the answer key before trusting any ranking.** Details in `results/audit/audit.md`.")
        A("")
        dropped = {s: d["dropped_by_audit"] for s, d in datasets.items() if d["dropped_by_audit"]}
        if dropped:
            A("- Clips dropped before scoring: " + ", ".join(f"{s} {n}" for s, n in dropped.items()) + ". Reasons: re-uploaded videos in vox1o "
              "(same recording under two session ids), a chapter read by someone else in libri, mislabeled clips, and AMI clips with "
              "another person's laugh or cough inside.")
        ov = (a["overlap"].get("ami") or {}).get("all") or {}
        if ov.get("n_other_voice_in_clip"):
            A(f"- AMI: {ov['n_other_voice_in_clip']} of {ov.get('clips', 3000):,} clips have another participant's laugh or cough inside. "
              "Models misplace those about 4 to 6 times as often. They're dropped.")
        A("- None of the drops reorders the models on any set; they shift everyone together.")
        A("")

    # ---- results
    A("## Results")
    A("")
    A("Headline metric: **true accepts at 1 in 1,000 false accepts on call audio**, pooled over the four human sets (mean over sets of "
      "the mean over clip lengths and conditions). Brackets are 95% bootstrap intervals over speakers. **Δ** is the paired difference "
      "to today's model on the cells both have, in percentage points; `*` means the interval excludes zero. "
      "Each model uses the better of raw cosine, centered cosine and AS-norm (the scorer picks it); that selection flatters every "
      "model a little and the Δ interval doesn't include it.")
    A("")
    if charts_rel.get("ranking"):
        A(f"![Ranking of call-audio accuracy with 95% intervals]({charts_rel['ranking']})")
        A("")
    A("### Every model")
    A("")
    A("`Ship?` is the license verdict (engineering triage, not legal advice). `clean` and `call` are the headline metric on clean and call audio. "
      "`lineup` is clean / call in the 334-person lineup. `auto from mtg 3+` is the share of a regular's appearances named silently "
      "from their third meeting on, with bars calibrated on clean audio only (the same footing for every model) / with call audio in the calibration. "
      "`wrong names` is wrong silent names in the simulation (must be 0). `ms/clip` is embed time for one clip; `~` means a rough timing from the "
      "embedding job on a busy machine, not a benchmark. `cells` is scored (set, clip length, condition) cells out of the most any model has.")
    A("")
    hdr = ["#", "model", "ship?", "params (M)", "clean", "call [95% CI]", "Δ vs baseline", "EER call", "lineup", "auto from mtg 3+", "wrong names", "ms/clip", "cells"]
    A(mdrow(hdr))
    A(mdrow(["---"] * len(hdr)))
    rows = sorted(scored, key=sort_key_ranking)
    for i, m in enumerate(rows, 1):
        v = m["verify"]
        if v:
            clean = pct(v["tar_clean"]["v"]) if v["tar_clean"] else PENDING
            call = ci_txt(v["tar_call"]) if v["tar_call"] else PENDING
            dcell = "ref" if m["baseline"] else (delta_txt(v["delta"]) if v["delta"] else DASH)
            eer = pct(v["eer_call"]["v"], 2) if v["eer_call"] else PENDING
            cells = f"{v['cells_have']}/{v['cells_expected']}" + ("" if v["complete"] else " partial")
        else:
            clean = call = eer = PENDING
            dcell = DASH
            cells = "0"
        params = f"{m['params_m']:.1f}" if m.get("params_m") else DASH
        A(mdrow([i, model_cell(m), m["license"]["ship_label"], params, clean, call, dcell, eer, lineup_cell(m),
                 naming_cell(m["naming"]), wrong_cell(m["naming"]), latency_cell(m), cells]))
    A("")
    unscored = [m for m in models.values() if not m["scored"]]
    if unscored:
        A("**Set up but not scored yet** (no embeddings scored): "
          + ", ".join(f"`{m['model_id']}` ({m['license']['ship_label']}{', ' + m['status'] if m.get('status') not in (None, 'ready') else ''})" for m in unscored) + ".")
        A("")

    # by condition and length
    cond_rows = [m for m in rows if m["verify"] and m["verify"]["conds"] and any(k in m["verify"]["conds"] for k in CROSS)]
    if cond_rows:
        A("### By condition and clip length")
        A("")
        A("TAR at FAR 1e-3 / EER, both in %. The clean>x columns enroll clean and test on the degraded copy; the last three are call audio by clip length.")
        A("")
        hdr = ["model", "clean", "clean>opus12", "clean>phone", "clean>noisy", "2 s", "4 s", "8 s"]
        A(mdrow(hdr))
        A(mdrow(["---"] * len(hdr)))

        def te(d):
            if not d or d.get("tar") is None:
                return PENDING
            return f"{100 * d['tar']:.1f} / {100 * d['eer']:.2f}" if d.get("eer") is not None else f"{100 * d['tar']:.1f}"
        for m in cond_rows:
            v = m["verify"]
            A(mdrow([model_cell(m)] + [te(v["conds"].get(g)) for g in ("clean",) + CROSS] + [te(v["buckets"].get(str(b))) for b in BUCKETS]))
        A("")
    if charts_rel.get("slope"):
        A(f"![Clean vs call-audio accuracy for the top models]({charts_rel['slope']})")
        A("")

    # winner
    A("## Winner and runner-up")
    A("")
    A("The rule: a shippable license, every cell scored, zero wrong silent names in the naming simulation. Then the highest call-audio "
      "accuracy. We don't crown anyone while a candidate that looks better on the cells it has is still being scored.")
    A("")
    if w:
        kind = verdict_kind(w)
        A(winner_block(w, {"win": "Winner", "lead": "Best shippable (not proven)", "behind": "Best shippable (does not beat today's model)"}[kind],
                       b_rep, models))
        if r_up:
            A("")
            A(winner_block(r_up, "Runner-up", b_rep, models, vs=w))
    else:
        A("**No winner yet.**")
        A("")
        pl = find_rep(reps, dec["held_back_by"] or dec["provisional_leader"])
        if pl:
            A(winner_block(pl, "Leading so far (not final, cells missing)", b_rep, models))
        bc = find_rep(reps, dec["best_complete_shippable"])
        if bc and (not pl or bc["model_id"] != pl["model_id"]):
            A("")
            A(winner_block(bc, "Best fully scored shippable model so far", b_rep, models))
    if dec["still_filling"] and w:
        fl = [find_rep(reps, x) for x in dec["still_filling"]]
        fl = [x for x in fl if x]
        if fl:
            A("")
            A("Still filling in: " + "; ".join(f"`{x['model_id']}` has {x['verify']['cells_have']} of {x['verify']['cells_expected']} cells, "
                                              f"so far {delta_txt(x['verify']['delta'])} points vs baseline" for x in fl) + ".")
    if bn:
        A("")
        A(f"**Best model we can't ship:** `{bn['model_id']}`, {ci_txt(bn['verify']['tar_call'], unit='%')} on call audio. {bn['license']['reason'] or ''}")
    A("")

    # naming
    A("## Naming simulation")
    A("")
    A("This is what a user feels. For each model we replay realistic runs of meetings (AMI and ICSI as they happened, LibriSpeech and VoxCeleb "
      "as invented recurring groups), with the app's naming rules mirrored in Python: match against the profiles from before each meeting, "
      "name silently only when confirmations, similarity bar and margin all agree, otherwise suggest or ask. A simulated user always knows "
      "who is who and corrects mistakes. Bars are calibrated on half the speakers and scored on the other half, both ways.")
    A("")
    A("Work per meeting: type a name 3, pick a known person 2, confirm a suggestion 1, fix a wrong suggestion 3, fix a wrong silent name 10.")
    A("")
    nrows = [m for m in reps.values() if m.get("naming") and m["naming"].get("clean_only")]
    nrows.sort(key=lambda m: (m["naming"]["wrong_silent_total"] > 0, m["naming"]["lookalike_over"] > 0,
                              -(m["naming"]["clean_only"].get("auto_share_from_meeting3") or 0)))
    if nrows:
        hdr = ["model", "ship?", "wrong silent names (all runs)", "look-alike pairs over bar", "strangers wrongly named", "wrong suggestions",
               "auto from mtg 3+ (clean bars)", "first auto: median / p90 meeting", "work per meeting", "with call audio: auto from mtg 3+ / wrong / work"]
        A(mdrow(hdr))
        A(mdrow(["---"] * len(hdr)))
        for m in nrows:
            n = m["naming"]
            co = n["clean_only"]
            wc = n.get("with_call")
            med, p90 = co.get("first_auto_median"), co.get("first_auto_p90")
            first = f"{med if med is not None else 'never'} / {p90 if p90 is not None else 'never'}"
            callc = PENDING
            if wc and wc.get("call"):
                c = wc["call"]
                callc = f"{pct_s(c.get('auto_share_from_meeting3'))} / {c.get('wrong_silent_names')} / {c.get('work_per_meeting'):.2f}"
            A(mdrow([model_cell(m), m["license"]["ship_label"], "0" if n["wrong_silent_total"] == 0 else f"**{n['wrong_silent_total']}**",
                     f"{n['lookalike_over']} / {n['lookalike_checked']:,}" if n["lookalike_checked"] else DASH,
                     co.get("strangers_wrongly_named"), f"{co.get('wrong_suggestions')} ({pct(co.get('wrong_suggestion_rate'), 1)}%)",
                     pct_s(co.get('auto_share_from_meeting3')), first, f"{co.get('work_per_meeting'):.2f}", callc]))
        A("")
        bm = next((m for m in models.values() if m["baseline"] and m.get("naming")), None)
        ab = (bm or {}).get("naming", {}).get("app_bars") if bm else None
        if ab and ab.get("clean"):
            wc = bm["naming"].get("with_call") or {}
            co = bm["naming"].get("clean_only") or {}
            txt = (f"For scale, today's model with the app's shipped bars (0.70 / 0.80 / 0.92, no calibration) names "
                   f"{pct_s(ab['clean'].get('auto_share_from_meeting3'))} of regulars' appearances from meeting 3 on clean audio and "
                   f"{pct_s((ab.get('call') or {}).get('auto_share_from_meeting3'))} on call audio, with "
                   f"{ab['all'].get('wrong_silent_names') if ab.get('all') else 'no data on'} wrong silent names. "
                   f"Our calibration (zero wrong names plus a safety margin, same recipe for every model) gives the same model "
                   f"{pct_s(co.get('auto_share_from_meeting3'))} with clean-only bars")
            if wc.get("clean") and wc.get("call"):
                txt += (f", and {pct_s(wc['clean'].get('auto_share_from_meeting3'))} clean / {pct_s(wc['call'].get('auto_share_from_meeting3'))} call "
                        "once call audio is in the calibration")
            txt += ". Absolute rates move a lot with how strict the bars are, so read the table as models against each other, not against the live app."
            A(txt)
            A("")
    else:
        A(f"{PENDING}: no naming results yet.")
        A("")
    A("Notes on reading it:")
    A("")
    A("- **Clean-only bars** are calibrated on clean audio for every model, so they compare fairly. **With call audio** bars are calibrated on every "
      "condition a model has, like the app, which makes them stricter; compare those columns only between models that have the same coverage.")
    A("- No confidence intervals here: the simulation is point estimates over many seeded runs (48 per model in the last check), not a bootstrap.")
    A("- A model shows a look-alike pair when two different held-out people clear the lineup bar against each other. It over-counts on purpose.")
    A("")

    # lineup, fusion, latency, e2e
    A("## Lineup (334 people)")
    A("")
    A("Everyone at once: all labeled people share one database and each probe has to pick the right name, or none for a stranger. "
      "The number in the model table is **DIR at zero wrong names**: the share of known people shown with the right name at the lowest bar "
      "where nobody, known or stranger, gets a wrong name. Higher is better; the table shows clean / opus12 probes, one bar per model.")
    A("")
    lu = ctx["lineup"]
    if lu["text"]:
        intro = md_intro(lu["text"])
        if intro:
            A(intro)
            A("")
        for heading, label in (("Call audio", "Call audio, models with full coverage (opus12 probes)"),
                               ("Clean audio", "Clean audio, every model")):
            sec = md_section(lu["text"], heading)
            if sec:
                A(f"**{label}**")
                A("")
                A(upto_first_table(sec))
                A("")
        A("The variants (yodas strangers, opus12 enrollment, 2-session enrollment, one clip vs three), per-dataset numbers, and who gets "
          "confused with whom are in `results/lineup_summary.md`.")
    else:
        A(f"{PENDING}: `results/lineup_summary.md` hasn't been written yet.")
    A("")
    A("## Score fusion")
    A("")
    fu = ctx["fusion_text"]
    if fu:
        intro = md_intro(fu)
        if intro:
            A(intro)
            A("")
        ver = md_section(fu, "Verdict")
        A(ver if ver else excerpt(fu, 40))
        A("")
        A("Full tables (by condition, per set, weight sweep, method notes) are in the fusion summary file under `results/`.")
    else:
        A(f"{PENDING}: `results/fusion_summary.md` hasn't been written yet.")
    A("")
    A("## Latency")
    A("")
    la = ctx["latency"]
    if la["text"]:
        A(excerpt(la["text"], 70))
    else:
        A(f"{PENDING}: `results/latency.md` hasn't been written yet. The `ms/clip` column above uses the embedding job's own timings "
          "(median per clip on a busy machine, mixed devices), which are only good for spotting order of magnitude.")
    A("")
    if charts_rel.get("latency"):
        A(f"![Accuracy against latency]({charts_rel['latency']})")
        A("")
    cm = [(m["model_id"], m["coreml"]) for m in models.values() if m.get("coreml") and m["coreml"].get("converted")]
    if cm:
        A("Core ML builds converted so far (fused front end, raw audio in). Parity is the worst cosine against the reference runtime on 60 clips.")
        A("")
        A(mdrow(["build", "precision", "shapes", "worst parity (all units / CPU)", "ms per 4 s clip (all units / CPU)", "runs on", "size MB"]))
        A(mdrow(["---"] * 7))
        for mid, c in sorted(cm):
            A(mdrow([f"`{mid}`", c.get("precision"), c.get("shapes"),
                     f"{c.get('parity_ALL_min')} / {c.get('parity_CPU_min')}", f"{c.get('ms4_ALL')} / {c.get('ms4_CPU')}", c.get("ALL_runs_on"), c.get("size_mb")]))
        A("")
        A("Those ms numbers were taken on a machine running other jobs. Use them for order of magnitude only.")
        A("")
    A("## End to end")
    A("")
    e2e = ctx["e2e_text"]
    A(excerpt(e2e, 70) if e2e else f"{PENDING}: `results/e2e_summary.md` hasn't been written yet (the winner has to be wired into the app first).")
    A("")

    # what didn't work
    A("## What didn't work")
    A("")
    for para in ctx["didnt_work"]:
        A(para)
        A("")

    # caveats
    A("## Caveats")
    A("")
    for c in ctx["caveats"]:
        A(f"- {c}")
    A("")

    # rerun
    A("## How to rerun")
    A("")
    A("From the repo root, with the shared venv (`data/eval/voiceprint/venv`). Each step only redoes what changed.")
    A("")
    A("```bash")
    A("VP=data/eval/voiceprint")
    A("$VP/venv/bin/python scripts/voiceprint/embed_daemon.py          # embeddings for every model x set x condition")
    A("$VP/venv/bin/python scripts/voiceprint/score_verify.py          # pairwise verification -> results/verify_summary.*")
    A("$VP/venv/bin/python scripts/voiceprint/naming_sim.py            # naming simulation -> results/naming/, naming_summary.md")
    A("$VP/venv/bin/python scripts/voiceprint/naming_sim.py --conds clean --tag clean   # clean-only bars, the like-for-like table")
    A("$VP/venv/bin/python scripts/voiceprint/score_lineup.py          # 334-person lineup -> results/lineup_summary.md")
    A("$VP/venv/bin/python scripts/voiceprint/score_fusion.py          # does fusing two models help -> results/fusion_summary.md")
    A("$VP/venv/bin/python scripts/voiceprint/bench_latency.py run && $VP/venv/bin/python scripts/voiceprint/bench_latency.py report   # -> results/latency.md")
    A("$VP/venv/bin/python scripts/voiceprint/build_report.py          # this file, the charts, and report/data.json")
    A("```")
    A("")
    A("`build_report.py` reads the files listed in its docstring. It's safe to run at any point: a missing file becomes a pending row, "
      "and it never touches the app's real speaker database, prefs or capture library.")
    A("")
    found = [k for k, v in inp.seen.items() if v["found"]]
    miss = [k for k, v in inp.seen.items() if not v["found"]]
    A(f"Inputs found this run: {len(found)}. Missing: {', '.join(f'`{k}`' for k in miss) if miss else 'none'}.")
    A("")
    if pend:
        A("### Pending this run")
        A("")
        for p in pend:
            A(f"- {p}")
        A("")
    return "\n".join(L).rstrip() + "\n"


def overlap(a, b) -> bool:
    if not a or not b or None in (a.get("lo"), a.get("hi"), b.get("lo"), b.get("hi")):
        return True
    return a["lo"] <= b["hi"] and b["lo"] <= a["hi"]


def verdict_kind(m: dict) -> str:
    d = (m.get("verify") or {}).get("delta")
    if d and d.get("lo") is not None and d["lo"] > 0:
        return "win"
    if d and d.get("v") is not None and d["v"] > 0:
        return "lead"
    return "behind"


def winner_block(m: dict, title: str, base: dict | None, models: dict, vs: dict | None = None) -> str:
    v = m["verify"]
    lic = m["license"]
    out = [f"### {title}: `{m['model_id']}`", ""]
    bits = []
    bits.append(f"- **Call audio:** {ci_txt(v['tar_call'], unit='%')} at 1 in 1,000 false accepts; EER {pct(v['eer_call']['v'], 2) if v['eer_call'] else PENDING}%."
                + (f" Clean: {ci_txt(v['tar_clean'], unit='%')}." if v["tar_clean"] else "")
                + (f" Scored on {v['cells_have']} of {v['cells_expected']} cells." if not v["complete"] else ""))
    if base and base["verify"] and base["verify"]["tar_call"]:
        d = v["delta"]
        if d:
            tail = ("clearly better" if d["lo"] is not None and d["lo"] > 0 else
                    "better, but the interval includes zero" if d["v"] > 0 else "not better")
            bits.append(f"- **Against today's model** ({ci_txt(base['verify']['tar_call'], unit='%')}): {delta_txt(d)} points, paired on {d.get('n_cells')} shared call-audio cells. That's {tail}.")
    if vs and vs["verify"]["tar_call"]:
        bits.append("- **Against the winner:** " + ("intervals overlap, no separation on this metric." if overlap(v["tar_call"], vs["verify"]["tar_call"])
                                                     else "intervals don't overlap."))
    n = m.get("naming")
    if n and n.get("clean_only"):
        co = n["clean_only"]
        med = co.get("first_auto_median")
        s = (f"- **Naming:** names {pct_s(co.get('auto_share_from_meeting3'))} of a regular's appearances from meeting 3 on (clean bars), "
             f"median first automatic name at meeting {med if med is not None else 'never'}; wrong silent names {n['wrong_silent_total']}; "
             f"{co.get('wrong_suggestions')} wrong suggestions ({pct(co.get('wrong_suggestion_rate'), 1)}%).")
        wc = n.get("with_call")
        if wc and wc.get("call"):
            s += f" With call audio in the calibration: {pct_s(wc['call'].get('auto_share_from_meeting3'))}."
        bits.append(s)
    else:
        bits.append(f"- **Naming:** {PENDING}.")
    ln = m.get("lineup_n") or {}
    if ln.get("clean") is not None or ln.get("call") is not None:
        bits.append(f"- **Lineup (DIR at zero wrong names):** {pct_s(ln.get('clean'))} clean, {pct_s(ln.get('call'))} on opus12 probes.")
    lat = m.get("latency")
    size = f"{m['params_m']:.1f}M parameters" if m.get("params_m") else "size unknown"
    if lat and lat.get("ms"):
        src = "measured in latency.md" if lat["source"] == "latency.md" else "rough embed-job timing on a busy machine"
        bits.append(f"- **Size and speed:** {size}; about {lat['ms']:.0f} ms per clip ({src}).")
    else:
        bits.append(f"- **Size and speed:** {size}; latency {PENDING}.")
    cmb = [b for b in m.get("builds", []) if b != m["model_id"]] or ([m["model_id"]] if m["is_coreml_build"] else [])
    for b in cmb:
        c = (models.get(b) or {}).get("coreml")
        if c:
            bits.append(f"- **Core ML build** (`{b}`): {c.get('precision')}, worst parity {c.get('parity_ALL_min')}, {c.get('size_mb')} MB, runs on {c.get('ALL_runs_on')}.")
    bits.append(f"- **License:** {lic['reason'] or lic['ship_label']} ({lic['verdict']}, {lic['risk'] or 'risk unknown'} risk)."
                + (" Trained on: " + m["train_data"] + "." if m.get("train_data") else ""))
    return "\n".join(out + bits)


# --------------------------------------------------------------------------------------------
# prose that depends on the data
# --------------------------------------------------------------------------------------------

def frontend_facts(meta_all: dict) -> dict:
    """Numbers behind the WeSpeaker front-end finding, read from the model.json notes and sanity blocks."""
    m = meta_all.get("wespeaker-resnet34-lm") or {}
    n = m.get("notes") or ""
    out: dict = {}
    m1 = re.search(r"EER ([\d.]+)% with the front end this runtime uses \(sherpa's front end gave ([\d.]+)%", n)
    if m1:
        out["eer_good"], out["eer_bad"] = m1.group(1), m1.group(2)
    try:
        out["diff_bad"] = m["sanity_before_sherpa_frontend"]["setA"]["diff"]
        out["diff_good"] = m["sanity"]["setA"]["diff"]
    except Exception:  # noqa: BLE001
        pass
    app = (meta_all.get("app-wespeaker-coreml") or {}).get("notes") or ""
    m2 = re.search(r"per-clip cosine app\(tiled\) vs sherpa-onnx is only ([\d.]+) mean", app)
    if m2:
        out["parity"] = m2.group(1)
    m3 = re.search(r"isolated 2 s EER ([\d.]+)%.*?tiled 2 s ([\d.]+)%", app)
    if m3:
        out["iso"], out["tiled"] = m3.group(1), m3.group(2)
    return out


def build_didnt_work(ctx) -> list[str]:
    meta_all, models, reps, audit = ctx["meta_all"], ctx["models"], ctx["reps"], ctx["audit"]
    out = []
    f = frontend_facts(meta_all)
    s = ("**The WeSpeaker front end.** Our first WeSpeaker numbers were wrong, and it was our harness, not the model. sherpa-onnx runs the WeSpeaker ONNX "
         "files with a different front end than the one they were trained with: no per-clip mean normalization, a povey window, mel up to 7,600 Hz. "
         "We caught it when we compared against the app's own Core ML model")
    if f.get("parity"):
        s += f": the network gives cosine 1.0000 when both sides get the same features, but only {f['parity']} on average when each computes its own"
    s += "."
    if f.get("diff_bad") is not None and f.get("diff_good") is not None:
        s += (f" Through sherpa, different people looked far too alike (mean different-speaker cosine {f['diff_bad']:.2f} vs {f['diff_good']:.2f} "
              "with the right front end on the same AMI clips)")
        if f.get("eer_bad"):
            s += f", and cross-session EER on 130 four-second clips was {f['eer_bad']}% vs {f['eer_good']}%"
        s += "."
    s += (" Every WeSpeaker-family model now runs through `wespeaker_onnx` with WeSpeaker's own front end. The 3D-Speaker and NeMo ONNX files "
          "still go through sherpa-onnx's front end, and we have not audited theirs.")
    out.append(s)
    s = ("**Scoring today's model the app's way took care.** The app embeds a 10-second window around a turn, not a bare clip. "
         "A short clip at the start of a zero-padded window shifts the mean the front end subtracts, and every short clip tilts the same way")
    if f.get("iso") and f.get("tiled"):
        s += f" (2 s AMI EER {f['iso']}% padded vs {f['tiled']}% when the clip fills the window)"
    s += ". The baseline is scored the tiled way, which matches the app's real meeting path."
    out.append(s)
    bias = [b for b in audit["bias"] if b["eer_x"] is not None]
    lab = [b for b in bias if b["labeler"]]
    s = ("**yodas is biased, so it doesn't rank.** Its labels came from TitaNet-large and CAM++ agreeing, and every clip was re-checked against those two, "
         "so scores there flatter them")
    if lab:
        top = min(lab, key=lambda b: b["eer_x"])
        s += f": `{top['model_id']}` gets {top['eer_x']:.2f}x the EER its human-set standing predicts"
        if top.get("miss_x") is not None:
            s += f" and {top['miss_x']:.2f}x the misses at FAR 1e-3"
    nonlab = [b for b in bias if not b["labeler"] and b["eer_x"] < 0.5]
    if nonlab:
        s += "; " + ", ".join(f"`{b['model_id']}`" for b in nonlab) + " gets a similar lift without labeling anything, most likely because it was trained on YouTube too"
    s += ". Under 1.0x below means yodas flatters that model. We report yodas on its own and leave it out of every ranking."
    out.append(s)
    if bias:
        rows = ["| model | labeler? | yodas EER (%) | EER vs. what human sets predict | misses at 1e-3 vs. prediction |", "|---|---|---|---|---|"]
        for b in sorted(bias, key=lambda b: b["eer_x"]):
            rows.append(mdrow([f"`{b['model_id']}`", "yes" if b["labeler"] else "no", f"{b['yodas_eer']:.2f}" if b["yodas_eer"] is not None else DASH,
                               f"{b['eer_x']:.2f}x", f"{b['miss_x']:.2f}x" if b["miss_x"] is not None else DASH]))
        out.append("\n".join(rows))
    ns = sorted([m for m in reps.values() if m["license"]["ship"] != "yes" and m["verify"] and (m["verify"]["headline"] or {}).get("v") is not None],
                key=lambda m: -m["verify"]["headline"]["v"])
    if ns:
        parts = []
        for m in ns:
            group = "call" if m["verify"]["headline_group"] == "cross" else "clean"
            why = (m["license"]["reason"] or "license blocks shipping").rstrip(".")
            parts.append(f"`{m['model_id']}` ({pct(m['verify']['headline']['v'])}% {group}): {why}")
        out.append("**The most accurate models can't ship.** We ran them anyway as a reference for how much headroom exists, never as candidates. "
                   + "; ".join(parts[:5]) + ".")
    unscored_ns = [m for m in models.values() if not m["scored"] and m["license"]["ship"] == "no"]
    if unscored_ns:
        out.append("Also blocked and not scored (yet): " + ", ".join(f"`{m['model_id']}`" for m in unscored_ns)
                   + ". ECAPA2 is CC BY-NC; anything trained on VoxBlink2 or CN-Celeb is out whatever the repo's MIT label says.")
    weak = sorted([m for m in reps.values() if m["verify"] and (m["verify"]["headline"] or {}).get("v") is not None and m["license"]["ship"] == "yes"],
                  key=lambda m: m["verify"]["headline"]["v"])[:3]
    if weak:
        bits = []
        for m in weak:
            grp = "call" if m["verify"]["headline_group"] == "cross" else "clean"
            td = trunc((m.get("train_data") or "").split(";")[0], 48)
            bits.append(f"`{m['model_id']}` ({pct(m['verify']['headline']['v'])}% {grp}" + (f"; {td}" if td else "") + ")")
        gaps = []
        for m in weak:
            b = ctx["reps"].get(ctx["baseline_id"]) if ctx.get("baseline_id") else None
            bv = (b or {}).get("verify") or {}
            same = bv.get("tar_call") if m["verify"]["headline_group"] == "cross" else bv.get("tar_clean")
            if same and same.get("v") is not None:
                gaps.append(100 * (same["v"] - m["verify"]["headline"]["v"]))
        tail = f" That's {min(gaps):.0f} to {max(gaps):.0f} points below today's model on the same measure." if gaps else ""
        out.append("**Weak models.** " + ", ".join(bits) + "." + tail + " Older designs and models trained for other languages don't earn a spot.")
    pend_cml = [m for m in models.values() if m.get("status") == "pending" and m["is_coreml_build"]]
    if pend_cml:
        out.append("**Core ML builds with mixed clip lengths.** An enumerated-shape build re-plans the graph whenever the input length changes "
                   "(0.3 to 0.8 s per clip with mixed 2 / 4 / 8 s clips). We rebuild as one static-shape function per length: "
                   + ", ".join(f"`{m['model_id']}`" for m in pend_cml) + " (marked pending in `model.json` when this ran).")
    cm16 = [(mid, c) for mid, c in ((m["model_id"], (ctx["coreml_raw"].get(m["model_id"]) or {})) for m in models.values() if m["is_coreml_build"])
            if isinstance(c.get("fp16_trial_cpu"), dict) and c["fp16_trial_cpu"].get("fp16") is not None and c["fp16_trial_cpu"]["fp16"] < 0.99]
    if cm16:
        out.append("**fp16 Core ML.** Half precision broke some networks on CPU (worst parity "
                   + ", ".join(f"`{mid}` {c['fp16_trial_cpu']['fp16']:.2f}" for mid, c in cm16)
                   + "), so those builds are fp32.")
    return out


def build_caveats(ctx) -> list[str]:
    reps = ctx["reps"]
    c = [
        "**Read speech and meetings, not your users.** The sets are VoxCeleb interviews, audiobooks, and two research-meeting corpora with headset mixes. "
        "AMI and ICSI are the closest to the product, and even they're English, scripted or research-group meetings.",
        "**Call audio is simulated.** Opus, phone and noisy-room copies are deterministic degradations, not recordings of real Zoom calls. "
        "The end-to-end stage is where real pipeline audio finally shows up.",
        "**Labels aren't perfect.** The audit found and dropped the obvious errors by model consensus, but the panel mostly shares VoxCeleb training, so it can share blind spots.",
        "**yodas has model-made labels** and is kept out of every ranking. It stays as a secondary check.",
        "**Picking the best of raw, centered and AS-norm per model** flatters every model slightly. The Δ intervals don't include that selection.",
        "**TAR at FAR 1e-4 is thin.** Even 30,000 different-person pairs allow only 3 false accepts per cell, so 1e-4 numbers are pooled under one threshold and noisy.",
        "**The naming simulation is a Python mirror of the app, not the app.** It assumes the diarizer is perfect, uses point estimates without intervals, "
        "and calibrates each model's bars on half the speakers. Its calibrated bars differ from the bars the app ships (see the note under the naming table).",
        "**License triage is engineering, not legal advice.** VoxCeleb-trained weights ship with credit; medium-risk items (TitaNet's telephone data, "
        "Alibaba's undisclosed 'common' data) need the owner's call.",
    ]
    partial = [m for m in reps.values() if m["verify"] and not m["verify"]["complete"]]
    if partial:
        c.insert(0, f"**Not every model is fully scored yet** ({len(partial)} networks are missing some cells). Their pooled numbers average a different mix "
                    "of sets and conditions than the complete rows, so compare with the paired Δ, which uses only shared cells.")
    lat_src = {m["latency_best"]["source"] for m in reps.values() if m.get("latency_best")}
    if lat_src and "latency.md" not in lat_src:
        c.append("**Latency numbers here are rough.** They come from the embedding job's timings on a machine running other jobs, across different devices "
                 "(CPU, MPS, Core ML). Use them for order of magnitude. `latency.md` has the real benchmark once it exists.")
    return c


# --------------------------------------------------------------------------------------------
# data.json
# --------------------------------------------------------------------------------------------

def entry_pct(e):
    if not e:
        return None
    return {"value": pct_num(e.get("v")), "lo": pct_num(e.get("lo")), "hi": pct_num(e.get("hi"))}


def model_json(m: dict, reps: dict) -> dict:
    v = m.get("verify")
    out = {
        "model_id": m["model_id"], "network": m["network"], "is_coreml_build": m["is_coreml_build"], "family": m["family"],
        "runtime": m["runtime"], "params_m": m["params_m"], "dim": m["dim"], "baseline": m["baseline"], "status": m["status"],
        "train_data": m["train_data"], "license": m["license"], "reference_only": m["reference_only"], "scored": m["scored"],
        "shippable": m["license"]["ship"] == "yes",
    }
    if v:
        out["verify"] = {
            "variant": v["variant"], "headline_group": v["headline_group"],
            "tar_clean": entry_pct(v["tar_clean"]), "tar_call": entry_pct(v["tar_call"]),
            "eer_clean": entry_pct(v["eer_clean"]), "eer_call": entry_pct(v["eer_call"]),
            "min_dcf": r3(v["min_dcf"]), "auc": pct_num(v["auc"], 3),
            "tar4_call_one_threshold": pct_num(v["tar4_call_one_threshold"]),
            "yodas_tar_call": pct_num(v["yodas_tar_call"]), "yodas_tar_clean": pct_num(v["yodas_tar_clean"]),
            "delta_vs_baseline_points": None if not v["delta"] else {"value": pct_num(v["delta"]["v"]), "lo": pct_num(v["delta"].get("lo")),
                                                                    "hi": pct_num(v["delta"].get("hi")), "cells": v["delta"].get("n_cells")},
            "by_condition": {g: {"tar": pct_num(d["tar"]), "eer": pct_num(d["eer"])} for g, d in v["conds"].items()},
            "by_clip_length_call": {b: {"tar": pct_num(d["tar"]), "eer": pct_num(d["eer"])} for b, d in v["buckets"].items()},
            "cells_scored": v["cells_have"], "cells_expected": v["cells_expected"], "complete": v["complete"],
        }
    else:
        out["verify"] = None
    n = m.get("naming")

    def nn(p):
        if not p:
            return None
        return {"wrong_silent_names": p.get("wrong_silent_names"), "auto_share_from_meeting3": pct_num(p.get("auto_share_from_meeting3")),
                "first_auto_median_meeting": p.get("first_auto_median"), "first_auto_p90_meeting": p.get("first_auto_p90"),
                "never_auto_share": pct_num(p.get("never_auto_share")), "work_per_meeting": r3(p.get("work_per_meeting"), 2),
                "wrong_suggestions": p.get("wrong_suggestions"), "wrong_suggestion_rate": pct_num(p.get("wrong_suggestion_rate")),
                "strangers_wrongly_named": p.get("strangers_wrongly_named"), "regular_appearances": p.get("appearances")}
    if n:
        out["naming"] = {"clean_only_bars": nn(n["clean_only"]),
                         "with_call_audio": None if not n["with_call"] else {"clean": nn(n["with_call"]["clean"]), "call": nn(n["with_call"]["call"])},
                         "wrong_silent_names_all_runs": n["wrong_silent_total"], "lookalike_pairs_over_bar": n["lookalike_over"],
                         "lookalike_pairs_checked": n["lookalike_checked"], "bars_per_fold": n["bars"],
                         "app_bars_reference": None if not n["app_bars"] else {k: nn(n["app_bars"].get(k)) for k in ("clean", "call")}}
    else:
        out["naming"] = None
    out["lineup"] = m.get("lineup")
    lat = m.get("latency") or (reps.get(m["network"]) or {}).get("latency_best")
    out["latency"] = None if not lat else {"ms": r3(lat["ms"], 2), "source": lat["source"], "device": lat.get("device"), "rough": lat["source"] != "latency.md"}
    out["coreml"] = m.get("coreml")
    return out


# --------------------------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------------------------

def compute_pending(ctx) -> list[str]:
    p = []
    seen = ctx["inputs"].seen
    for label, what in (("lineup_summary.md", "334-person lineup results"), ("latency.md", "latency benchmark (ms/clip uses rough embed-job timings until then)"),
                        ("fusion_summary.md", "score fusion results"), ("e2e_summary.md", "end-to-end pipeline results")):
        if label in seen and not seen[label]["found"]:
            p.append(what)
    reps = ctx["reps"]
    no_call = [m["model_id"] for m in reps.values() if m["verify"] and not m["verify"]["tar_call"]]
    if no_call:
        p.append(f"call-audio verification for {len(no_call)} networks ({', '.join(no_call[:5])}{'...' if len(no_call) > 5 else ''})")
    partial = [m for m in reps.values() if m["verify"] and m["verify"]["tar_call"] and not m["verify"]["complete"]]
    if partial:
        p.append(f"full cell coverage for {len(partial)} networks ({', '.join(m['model_id'] for m in partial[:5])}{'...' if len(partial) > 5 else ''})")
    no_naming = [m["model_id"] for m in reps.values() if not (m.get("naming") and m["naming"].get("clean_only"))]
    if no_naming:
        p.append(f"naming simulation for {len(no_naming)} models ({', '.join(no_naming[:5])}{'...' if len(no_naming) > 5 else ''})")
    no_call_naming = [m["model_id"] for m in reps.values() if m.get("naming") and not m["naming"].get("with_call")]
    if no_call_naming:
        p.append(f"naming with call audio for {len(no_call_naming)} models")
    ds = ctx["daemon_status"]
    if ds and ds.get("pending"):
        p.append(f"{ds['pending']} embedding jobs still queued")
    if not ctx["lineup"]["per_model"] and seen.get("lineup_summary.md", {}).get("found"):
        p.append("lineup_summary.md exists but no model rows could be parsed; check its table format (first column = model id)")
    if not ctx["latency"]["per_model"] and seen.get("latency.md", {}).get("found"):
        p.append("latency.md exists but no model rows could be parsed; check its table format (first column = model id)")
    return p


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--vp", default=str(DEFAULT_VP), help="voiceprint data dir (default data/eval/voiceprint or $VP_ROOT)")
    ap.add_argument("--out", default=str(DEFAULT_OUT), help="Markdown write-up path")
    ap.add_argument("--no-charts", action="store_true")
    args = ap.parse_args(argv)
    vp = Path(args.vp)
    out_md = Path(args.out)
    report_dir = vp / "results" / "report"
    if not vp.is_dir():
        log(f"error: {vp} not found")
        return 2
    report_dir.mkdir(parents=True, exist_ok=True)

    inp = Inputs(vp)
    idx, headline_mode, baseline_id, delta_idx = load_verify(vp, inp)
    verify = Verify(idx, headline_mode, delta_idx)
    naming_docs = load_naming(vp, inp)
    licenses = load_licenses(vp, inp)
    meta_all = load_model_meta(vp)
    coreml = load_coreml(vp)
    datasets = load_sets(vp, inp)
    audit = load_audit(vp, inp)
    daemon_ms = load_daemon_ms(vp)
    known = set(meta_all) | set(headline_mode) | set(naming_docs["all"]) | set(naming_docs["clean"])
    lineup = load_lineup(vp, inp, known)
    latency = load_latency(vp, inp, known)
    for name in ("fusion_summary.md", "e2e_summary.md"):
        inp.note(name, vp / "results" / name)
    fusion_text = read_text(vp / "results" / "fusion_summary.md")
    if fusion_text is None:  # the fusion scorer's working file, until it writes the summary
        fusion_text = read_text(vp / "results" / "fusion_dev.md")
        if fusion_text is not None:
            inp.seen["fusion_summary.md"]["note"] = "not written yet; using fusion_dev.md"
            inp.seen["fusion_summary.md"]["found"] = True
    e2e_text = read_text(vp / "results" / "e2e_summary.md")
    trials = load_trials_table(vp)

    if baseline_id is None:
        baseline_id = next((k for k, m in meta_all.items() if m.get("baseline") and k == "app-wespeaker-coreml"), None)
    models = build_models(vp, verify, baseline_id, naming_docs, licenses, meta_all, coreml, lineup, latency, daemon_ms, inp)
    reps = pick_representatives(models)
    # models scored only by naming/lineup (no verification row) still get their own rep so the naming table lists them
    for m in models.values():
        if m["scored"] and not m["verify"] and m["network"] not in reps:
            r = dict(m)
            r["builds"] = [m["model_id"]]
            r["latency_best"] = m.get("latency")
            reps[m["network"]] = r
    decision = decide(reps, baseline_id)

    ctx = {"models": models, "reps": reps, "datasets": datasets, "decision": decision, "baseline_id": baseline_id, "inputs": inp, "vp": vp,
           "trials": trials, "audit": audit, "lineup": lineup, "latency": latency, "fusion_text": fusion_text, "e2e_text": e2e_text,
           "daemon_status": load_daemon_status(vp), "meta_all": meta_all, "coreml_raw": coreml, "now": time.strftime("%Y-%m-%d %H:%M")}
    ctx["pending"] = compute_pending(ctx)

    # ---- charts
    charts, charts_rel = {}, {}
    if not args.no_charts:
        try:
            plt = setup_mpl()
            charts["ranking"] = chart_ranking(plt, reps, report_dir / "ranking.png", {})
            charts["clean_vs_call"] = chart_slope(plt, reps, report_dir / "clean_vs_call.png")
            charts["accuracy_vs_latency"] = chart_latency(plt, reps, report_dir / "accuracy_vs_latency.png")
            relbase = Path(os.path.relpath(report_dir, out_md.resolve().parent))
            for key, name in (("ranking", "ranking"), ("slope", "clean_vs_call"), ("latency", "accuracy_vs_latency")):
                charts_rel[key] = str(relbase / f"{name}.png")
        except Exception as e:  # noqa: BLE001
            log(f"warning: charts failed: {type(e).__name__}: {e}")
    ctx["charts_rel"] = charts_rel
    ctx["didnt_work"] = build_didnt_work(ctx)
    ctx["caveats"] = build_caveats(ctx)

    md = build_markdown(ctx)
    out_md.parent.mkdir(parents=True, exist_ok=True)
    out_md.write_text(md)

    # ---- data.json
    order = sorted([m for m in models.values() if m["scored"]], key=sort_key_ranking)
    data = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "generator": "scripts/voiceprint/build_report.py",
        "units": {"tar_*, eer_*, auc, naming shares": "percent (0-100)", "delta": "percentage points", "latency": "milliseconds",
                  "min_dcf": "normalized 0-1"},
        "headline_metric": "human sets pooled, TAR at FAR 1e-3, enroll clean / test degraded (cross), 95% bootstrap CI over speakers",
        "baseline": baseline_id,
        "decision": {"winner": decision["winner"], "runner_up": decision["runner_up"], "provisional_leader": decision["provisional_leader"],
                     "best_not_shippable": decision["best_not_shippable"], "still_filling": decision["still_filling"],
                     "blocked_by_naming": decision["blocked_by_naming"],
                     "rule": "shippable license, fully scored, zero wrong silent names in the naming simulation; then highest call-audio TAR@1e-3"},
        "datasets": datasets, "trials": trials,
        "models": [model_json(m, reps) for m in order],
        "unscored_models": [{"model_id": m["model_id"], "shippable": m["license"]["ship"] == "yes", "status": m["status"],
                             "license": m["license"]} for m in models.values() if not m["scored"]],
        "networks_ranked": [m["model_id"] for m in sorted(reps.values(), key=sort_key_ranking)],
        "yodas_bias": audit["bias"],
        "charts": charts,
        "inputs": inp.seen,
        "pending": ctx["pending"],
        "daemon_status": ctx["daemon_status"],
        "lineup_files_parsed": sorted(lineup["per_model"]),
        "latency_files_parsed": sorted(latency["per_model"]),
    }
    (report_dir / "data.json").write_text(json.dumps(clean_json(data), indent=1))

    # ---- console summary
    log(f"wrote {rel_to_repo(out_md)}")
    log(f"wrote {rel_to_repo(report_dir)}/data.json" + ("" if args.no_charts else " and 3 charts"))
    log(f"models: {len(models)} known, {sum(1 for m in models.values() if m['scored'])} scored, {len(reps)} networks")
    log(f"winner: {decision['winner']}  runner-up: {decision['runner_up']}  provisional leader: {decision['provisional_leader']}")
    for p in ctx["pending"]:
        log(f"pending: {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

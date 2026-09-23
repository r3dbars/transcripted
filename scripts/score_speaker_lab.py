#!/usr/bin/env python3
"""Speaker lab scorer: side-by-side diarizer / fingerprint bake-off.

Driven by scripts/run_speaker_lab.sh, which dumps every meeting once per VARIANT
(diarizer backend x embedding model x optional Nemotron preset), replays each
variant's dumps through the real clusterer + speaker DB for every knob setting,
and then calls `score` on the run directory. Pure Python, no third-party deps.

Subcommands
-----------
  grid            print one replay setting per line: "<tag>\\t<harness replay args>"
  dump-ok         exit 0 when a cached dump was produced by the requested variant
  own-calls-list  list a Transcripted capture library's meeting call tracks, oldest first
  score           score a run directory -> scores.json + REPORT.md (+ timeline.html)

Run-directory contract (written by run_speaker_lab.sh)
------------------------------------------------------
  run.env         KEY=VALUE lines: MODE (corpus|own-calls), CORPUS, RTTM_DIR, COLLAR,
                  MIN_APPEARANCE_SEC, WRONG_PENALTY, GIT_REVISION, GIT_DIRTY, COMMAND, ...
  meetings.tsv    id <TAB> audio path <TAB> display name   (replay order)
  variants.tsv    name <TAB> backend <TAB> embedder <TAB> preset <TAB> dumps dir
  replays.tsv     variant <TAB> tag <TAB> replay json path

Metrics (see Tools/SpeakerEvalHarness/README.md "Speaker lab" for the full schema)
  raw.*           the diarizer's own output (dump speakerId labels) vs the RTTM
  pipeline.*      after EmbeddingClusterer + DB matching (replay dbProfile labels)
  recognition.*   returning-speaker outcomes (speaker_eval_common.recognition_metrics)
  objective       recognizedRate - WRONG_PENALTY * (wrongPersonRate + firstAppearanceFalseMatchRate)
"""
import argparse
import datetime
import hashlib
import html
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from speaker_eval_common import (  # noqa: E402
    diarization_error,
    identity_metrics,
    parse_rttm,
    recognition_metrics,
    union_seconds,
)

SCHEMA = "transcripted.speaker-lab.scores"
SCHEMA_VERSION = 1
AUDIO_EXTS = (".wav", ".m4a", ".caf", ".aiff", ".aif", ".mp3", ".flac", ".aac", ".mp4", ".mov")
# Call-track priority inside a Transcripted `<stem>_audio/` folder (see
# Sources/TranscriptedCore/Storage/RecordingAudioArchiver.swift): the remote call audio is
# `system_audio.*` when a mic track exists, `recording.*` for system-only or imported audio.
CALL_TRACK_STEMS = ("system_audio", "recording")


def r4(x):
    return None if x is None else round(float(x), 4)


def mean(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) / len(xs) if xs else None


# ---------------------------------------------------------------------------
# grid
# ---------------------------------------------------------------------------

GRID_KNOBS = [
    # (cli name, harness flag, short tag)
    ("match", "--match", "m"),
    ("same_voice", "--same-voice", "sv"),
    ("consolidation", "--consolidation", "c"),
    ("write_path_fixes", "--write-path-fixes", "fx"),
    ("thresholds", "--thresholds", "th"),
    ("dedup", "--dedup", "dd"),
    ("blend_confident", "--blend-confident", "bc"),
    ("blend_cautious", "--blend-cautious", "bu"),
    ("writeback_confident_sim", "--writeback-confident-sim", "wc"),
    ("writeback_cautious_sim", "--writeback-cautious-sim", "wu"),
    ("writeback_margin", "--writeback-margin", "wm"),
]


def grid_settings(values):
    """values: {knob: "space separated grid" or ""}. Empty = leave at the harness
    default (not passed). Returns [(tag, [args])] as a cartesian product."""
    combos = [([], [])]
    for name, flag, short in GRID_KNOBS:
        grid = (values.get(name) or "").split()
        if not grid:
            continue
        combos = [(tags + [f"{short}-{v}"], args + [flag, v]) for tags, args in combos for v in grid]
    return [("_".join(t) or "defaults", a) for t, a in combos]


def cmd_grid(a):
    vals = {name: getattr(a, name) for name, _, _ in GRID_KNOBS}
    for tag, args in grid_settings(vals):
        safe = "".join(ch if (ch.isalnum() or ch in "._-") else "_" for ch in tag)
        print(safe + "\t" + " ".join(args))


# ---------------------------------------------------------------------------
# dump-ok
# ---------------------------------------------------------------------------

def dump_matches(dump, backend, embedder, preset):
    """A cached dump is reusable only if it was produced by exactly this variant."""
    if dump.get("backend") != backend:
        return False
    want_embedder = "wespeaker" if embedder in ("native", "wespeaker") else embedder
    if (dump.get("embedder") or "") != want_embedder:
        return False
    if backend == "nemotron":
        if (dump.get("nemotronPreset") or "default") != (preset or "default"):
            return False
    return isinstance(dump.get("segments"), list)


def cmd_dump_ok(a):
    try:
        with open(a.dump) as f:
            dump = json.load(f)
    except Exception:
        return 1
    return 0 if dump_matches(dump, a.backend, a.embedder, a.preset) else 1


# ---------------------------------------------------------------------------
# own-calls-list
# ---------------------------------------------------------------------------

def find_call_tracks(folder):
    """Return [(id, audio_path, display_name)] oldest first.

    Accepts the capture library's meetings folder (with audio/<stem>_audio/ inside),
    its audio/ folder, a single <stem>_audio folder, or a flat folder of audio files.
    Order = call-track modification time (≈ recording time), then name.
    """
    folder = os.path.abspath(os.path.expanduser(folder))
    if not os.path.isdir(folder):
        raise SystemExit(f"own-calls folder not found: {folder}")
    candidates = []
    roots = [folder]
    if os.path.isdir(os.path.join(folder, "audio")):
        roots.insert(0, os.path.join(folder, "audio"))

    def pick_track(d):
        files = os.listdir(d)
        for stem in CALL_TRACK_STEMS:
            for f in sorted(files):
                base, ext = os.path.splitext(f)
                if base == stem and ext.lower() in AUDIO_EXTS:
                    return os.path.join(d, f)
        return None

    if folder.endswith("_audio"):
        t = pick_track(folder)
        if t:
            candidates.append((os.path.basename(folder)[: -len("_audio")], t))
    else:
        for root in roots:
            for name in sorted(os.listdir(root)):
                p = os.path.join(root, name)
                if os.path.isdir(p) and name.endswith("_audio") and not os.path.islink(p):
                    t = pick_track(p)
                    if t:
                        candidates.append((name[: -len("_audio")], t))
            if candidates:
                break
        if not candidates:
            for name in sorted(os.listdir(folder)):
                p = os.path.join(folder, name)
                if os.path.isfile(p) and os.path.splitext(name)[1].lower() in AUDIO_EXTS:
                    candidates.append((os.path.splitext(name)[0], p))
    candidates.sort(key=lambda c: (os.path.getmtime(c[1]), c[0]))
    out = []
    for stem, path in candidates:
        cid = "call-" + hashlib.sha1(stem.encode("utf-8")).hexdigest()[:10]
        out.append((cid, path, stem))
    return out


def cmd_own_calls_list(a):
    rows = find_call_tracks(a.folder)
    if a.limit:
        rows = rows[-a.limit:]
    for cid, path, stem in rows:
        print(f"{cid}\t{path}\t{stem}")


# ---------------------------------------------------------------------------
# score: loading
# ---------------------------------------------------------------------------

def read_env(path):
    env = {}
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                line = line.rstrip("\n")
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    env[k.strip()] = v
    return env


def read_tsv(path, ncols):
    rows = []
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t")
                parts += [""] * (ncols - len(parts))
                rows.append(parts[:ncols])
    return rows


def load_json(path):
    with open(path) as f:
        return json.load(f)


def raw_hyp(dump):
    return [(s["start"], s["end"], f"S{s['speakerId']}") for s in dump.get("segments", [])]


def pipeline_hyp(meeting_result):
    return [(a["start"], a["end"], a["dbProfile"]) for a in meeting_result.get("assignments", [])]


def replay_knobs(replay):
    wb = replay.get("writeBack") or {}
    fixed = replay.get("matchMode", "fixed") != "adaptive"
    return {
        "match": r4(replay.get("matchThreshold")) if fixed else "adaptive",
        "consolidation": replay.get("consolidationThreshold"),
        "sameVoice": r4(replay.get("sameVoiceThreshold")),
        "thresholds": replay.get("thresholdProfile"),
        "dedup": r4(replay.get("dedupThreshold")),
        "writePathFixes": replay.get("writePathFixes"),
        "blendConfident": r4(wb.get("confidentAlpha")),
        "blendCautious": r4(wb.get("cautiousAlpha")),
        "writebackConfidentSim": r4(wb.get("confidentSimilarity")),
        "writebackCautiousSim": r4(wb.get("cautiousSimilarity")),
        "writebackMargin": r4(wb.get("marginMin")),
    }


def objective(recog, wrong_penalty):
    if not recog or recog.get("returningAppearances", 0) == 0 and recog.get("firstAppearances", 0) == 0:
        return None
    rec = recog.get("recognizedRate") or 0.0
    wrong = recog.get("wrongPersonRate") or 0.0
    fm = recog.get("firstAppearanceFalseMatchRate") or 0.0
    return round(rec - wrong_penalty * (wrong + fm), 4)


# ---------------------------------------------------------------------------
# score: corpus mode (ground truth)
# ---------------------------------------------------------------------------

def score_speed(dumps):
    audio = sum(d.get("audioSeconds") or d.get("durationSeconds") or 0.0 for d in dumps)
    dia = sum(d.get("diarizeSeconds") or 0.0 for d in dumps)
    init = [d.get("initSeconds") for d in dumps if d.get("initSeconds") is not None]
    return {
        "audioSeconds": round(audio, 2),
        "diarizeSeconds": round(dia, 2),
        "xRealtime": round(audio / dia, 1) if dia > 0 else None,
        "meanInitSeconds": r4(mean(init)),
    }


def count_summary(rows, hyp_key):
    errs = [r[hyp_key] - r["refSpeakers"] for r in rows]
    return {
        "meanSpeakerCountError": r4(mean(errs)),
        "meanAbsSpeakerCountError": r4(mean([abs(e) for e in errs])),
        "exactSpeakerCountRate": r4(sum(1 for e in errs if e == 0) / len(errs)) if errs else None,
    }


def der_summary(rows):
    return {
        "meanDER": r4(mean([r["der"] for r in rows])),
        "meanMiss": r4(mean([r["miss"] for r in rows])),
        "meanFalseAlarm": r4(mean([r["falseAlarm"] for r in rows])),
        "meanConfusion": r4(mean([r["confusion"] for r in rows])),
        "meanJER": r4(mean([r["jer"] for r in rows])),
    }


def der_row(meeting, ref, hyp, collar, hyp_count_key):
    d = diarization_error(ref, hyp, collar=collar)
    return {
        "meeting": meeting,
        "der": r4(d["der"]), "miss": r4(d["miss_rate"]), "falseAlarm": r4(d["false_alarm_rate"]),
        "confusion": r4(d["confusion_rate"]), "jer": r4(d["jer"]),
        "refSpeakers": len({t for _, _, t in ref}),
        hyp_count_key: len({h for _, _, h in hyp}),
    }


def score_setting(replay, refs, collar, min_app, wrong_penalty):
    by_meeting = {m["meeting"]: m for m in replay.get("meetings", [])}
    per_meeting = []
    series = []
    for meeting, ref in refs:
        mr = by_meeting.get(meeting)
        if mr is None:
            continue
        hyp = pipeline_hyp(mr)
        row = der_row(meeting, ref, hyp, collar, "hypSpeakers")
        row["countError"] = row["hypSpeakers"] - row["refSpeakers"]
        status = mr.get("clusterStatus") or {}
        row["clustersMatched"] = sum(1 for v in status.values() if v == "matched")
        row["clustersNew"] = sum(1 for v in status.values() if v == "new")
        per_meeting.append(row)
        series.append((meeting, ref, hyp))
    recog = recognition_metrics(series, min_appearance_sec=min_app)
    ident = identity_metrics(series)
    frag = ident["fragmentation"]
    pipeline = der_summary(per_meeting)
    pipeline.update(count_summary(per_meeting, "hypSpeakers"))
    events = recog.pop("events")
    return {
        "pipeline": pipeline,
        "recognition": recog,
        "identity": {
            "trueSpeakers": len(ident["true_speakers"]),
            "profilesAtEnd": replay.get("profilesAtEnd"),
            "fragmentationMean": r4(mean(list(frag.values()))),
            "falseMergeProfiles": len(ident["false_merge"]),
            "reidCurve": ident["reid_curve"],
        },
        "objective": objective(recog, wrong_penalty),
        "perMeeting": per_meeting,
        "recognitionEvents": events,
    }


def pick_best(settings):
    def key(s):
        obj = s["objective"]
        der = s["pipeline"]["meanDER"]
        return (obj is None, -(obj or 0.0), der if der is not None else 9.0, s["tag"])
    return sorted(settings, key=key)[0] if settings else None


def score_corpus(run_dir, env, meetings, variants, replays):
    collar = float(env.get("COLLAR", "0.25") or 0.25)
    min_app = float(env.get("MIN_APPEARANCE_SEC", "5") or 5)
    wrong_penalty = float(env.get("WRONG_PENALTY", "2") or 2)
    rttm_dir = env.get("RTTM_DIR", "")
    refs = [(mid, parse_rttm(os.path.join(rttm_dir, f"{mid}.rttm"))) for mid, _, _ in meetings]
    out = []
    for name, backend, embedder, preset, dumps_dir in variants:
        dumps = []
        raw_rows = []
        for mid, ref in refs:
            path = os.path.join(dumps_dir, f"{mid}.json")
            if not os.path.exists(path):
                continue
            d = load_json(path)
            dumps.append(d)
            row = der_row(mid, ref, raw_hyp(d), collar, "rawSpeakers")
            row["countError"] = row["rawSpeakers"] - row["refSpeakers"]
            if d.get("audioSeconds") and d.get("diarizeSeconds"):
                row["xRealtime"] = round(d["audioSeconds"] / d["diarizeSeconds"], 1)
            raw_rows.append(row)
        raw = der_summary(raw_rows)
        raw.update(count_summary(raw_rows, "rawSpeakers"))
        raw["perMeeting"] = raw_rows
        settings = []
        for vname, tag, path in replays:
            if vname != name:
                continue
            rp = load_json(path)
            s = score_setting(rp, refs, collar, min_app, wrong_penalty)
            s["tag"] = tag
            s["replay"] = os.path.relpath(path, run_dir)
            s["knobs"] = replay_knobs(rp)
            settings.append(s)
        best = pick_best(settings)
        out.append({
            "name": name, "backend": backend, "embedder": embedder, "nemotronPreset": preset or None,
            "meetingsScored": len(raw_rows),
            "speed": score_speed(dumps),
            "raw": raw,
            "best": None if best is None else {
                "tag": best["tag"], "knobs": best["knobs"], "objective": best["objective"],
                "pipeline": best["pipeline"], "recognition": best["recognition"],
                "identity": best["identity"],
            },
            "settings": settings,
        })
    return out


# ---------------------------------------------------------------------------
# score: own-calls mode (no ground truth)
# ---------------------------------------------------------------------------

def score_own_calls(run_dir, env, meetings, variants, replays):
    per_variant = []
    raw_by_variant = {}
    for name, backend, embedder, preset, dumps_dir in variants:
        dumps = {}
        for mid, _, _ in meetings:
            path = os.path.join(dumps_dir, f"{mid}.json")
            if os.path.exists(path):
                dumps[mid] = load_json(path)
        raw_by_variant[name] = dumps
        rep = [(tag, path) for v, tag, path in replays if v == name]
        replay = load_json(rep[0][1]) if rep else None
        rmeet = {m["meeting"]: m for m in (replay or {}).get("meetings", [])}
        rows = []
        for mid, _, disp in meetings:
            d = dumps.get(mid)
            if d is None:
                rows.append({"meeting": mid, "name": disp, "status": "no dump"})
                continue
            segs = raw_hyp(d)
            audio = d.get("audioSeconds") or d.get("durationSeconds") or 0.0
            speech = union_seconds([(s, e) for s, e, _ in segs])
            row = {
                "meeting": mid, "name": disp, "status": "ok",
                "audioSeconds": round(audio, 1),
                "rawSpeakers": len({l for _, _, l in segs}),
                "speechSeconds": round(speech, 1),
                "speechCoverage": r4(speech / audio) if audio else None,
                "xRealtime": round(audio / d["diarizeSeconds"], 1) if d.get("diarizeSeconds") else None,
            }
            mr = rmeet.get(mid)
            if mr is not None:
                status = mr.get("clusterStatus") or {}
                row["pipelineSpeakers"] = len({a["dbProfile"] for a in mr.get("assignments", [])})
                row["clustersMatched"] = sum(1 for v in status.values() if v == "matched")
                row["clustersNew"] = sum(1 for v in status.values() if v == "new")
            rows.append(row)
        ok = [r for r in rows if r.get("status") == "ok"]
        per_variant.append({
            "name": name, "backend": backend, "embedder": embedder, "nemotronPreset": preset or None,
            "speed": score_speed(list(dumps.values())),
            "knobs": replay_knobs(replay) if replay else None,
            "summary": {
                "meetingsScored": len(ok),
                "meanRawSpeakers": r4(mean([r["rawSpeakers"] for r in ok])),
                "meanPipelineSpeakers": r4(mean([r.get("pipelineSpeakers") for r in ok])),
                "meanSpeechCoverage": r4(mean([r["speechCoverage"] for r in ok])),
                "clustersMatched": sum(r.get("clustersMatched", 0) for r in ok),
                "clustersNew": sum(r.get("clustersNew", 0) for r in ok),
                "profilesAtEnd": (replay or {}).get("profilesAtEnd"),
            },
            "perMeeting": rows,
        })
    # agreement vs the first variant (pseudo-reference; NOT ground truth)
    if variants:
        base = variants[0][0]
        for v in per_variant[1:]:
            agree = []
            for mid, _, _ in meetings:
                a = raw_by_variant[base].get(mid)
                b = raw_by_variant[v["name"]].get(mid)
                if a is None or b is None:
                    continue
                d = diarization_error(raw_hyp(a), raw_hyp(b), collar=0.25)
                agree.append({"meeting": mid, "derVsBaseline": r4(d["der"]), "jerVsBaseline": r4(d["jer"]),
                              "missVsBaseline": r4(d["miss_rate"]),
                              "falseAlarmVsBaseline": r4(d["false_alarm_rate"])})
            v["agreement"] = {"baseline": base, "meanDerVsBaseline": r4(mean([x["derVsBaseline"] for x in agree])),
                              "perMeeting": agree}
    return per_variant, raw_by_variant


# ---------------------------------------------------------------------------
# reports
# ---------------------------------------------------------------------------

def fmt(x, pct=False):
    if x is None:
        return "—"
    if pct:
        return f"{100 * x:.1f}%"
    if isinstance(x, float):
        return f"{x:.3f}"
    return str(x)


def fmt_speed(x):
    return "—" if x is None else f"{x:.0f}x"


def knob_str(k):
    if not k:
        return "—"
    parts = [f"match={k['match']}", f"sameVoice={k['sameVoice']}", f"fixes={'on' if k['writePathFixes'] else 'off'}"]
    if k.get("consolidation") not in (None, "none"):
        parts.append(f"pairwise={k['consolidation']}")
    parts.append(f"dedup={k['dedup']}")
    parts.append(f"blend={k['blendConfident']}/{k['blendCautious']}")
    return " ".join(parts)


def corpus_markdown(scores):
    L = []
    L.append(f"# Speaker lab — {scores['corpus']} ({len(scores['meetings'])} meetings)")
    L.append("")
    L.append(f"Generated {scores['generatedAt']} at git `{scores['gitRevision']}`"
             + (" (dirty tree)" if scores.get("gitDirty") else "") + f". DER collar {scores['collar']} s "
             f"(pyannote convention). Appearances under {scores['minAppearanceSeconds']} s of speech are not scored "
             "for recognition.")
    L.append("")
    L.append("## Headline (each variant at its best setting)")
    L.append("")
    L.append("| variant | raw DER | pipeline DER | speaker count err raw / pipeline | recognized | wrong person "
             "| asked again | new person false-matched | speed | best setting |")
    L.append("|---|---|---|---|---|---|---|---|---|---|")
    for v in scores["variants"]:
        b = v["best"] or {}
        rc = b.get("recognition") or {}
        pl = b.get("pipeline") or {}
        L.append(
            f"| **{v['name']}** | {fmt(v['raw']['meanDER'])} | {fmt(pl.get('meanDER'))} "
            f"| {fmt(v['raw']['meanSpeakerCountError'])} / {fmt(pl.get('meanSpeakerCountError'))} "
            f"| {fmt(rc.get('recognizedRate'), True)} | {fmt(rc.get('wrongPersonRate'), True)} "
            f"| {fmt(rc.get('askedAgainRate'), True)} | {fmt(rc.get('firstAppearanceFalseMatchRate'), True)} "
            f"| {fmt_speed(v['speed']['xRealtime'])} | {knob_str(b.get('knobs'))} |")
    L.append("")
    L.append("How to read it:")
    L.append("")
    L.append("- **raw DER** scores the diarizer alone (its own speaker labels, best one-to-one mapping per meeting). "
             "**pipeline DER** scores what the app would save: after same-voice consolidation and DB matching. "
             "Lower is better. DER = missed speech + false alarm + speaker confusion, as a share of reference speech.")
    L.append("- **speaker count err** is mean (found speakers − real speakers) per meeting. Negative = merged people, "
             "positive = split someone.")
    L.append("- **recognized / wrong person / asked again** cover every time a person shows up again in a later "
             "meeting. Recognized = they landed on the profile that already held their voice (no re-naming). "
             "Wrong person = they landed on someone else's profile (the worst case: a wrong name). Asked again = a "
             "brand-new profile, so the user names them again. The rest were not detected at all.")
    L.append("- **new person false-matched** = a first-time speaker got glued to an existing profile.")
    L.append(f"- Best setting = highest objective = recognized − {scores['wrongPenalty']} × (wrong person + "
             "new-person false match), ties broken by pipeline DER.")
    L.append("")
    for v in scores["variants"]:
        L.append(f"## {v['name']}")
        L.append("")
        L.append(f"backend `{v['backend']}`, embedder `{v['embedder']}`"
                 + (f", Nemotron preset `{v['nemotronPreset']}`" if v.get("nemotronPreset") else "")
                 + f". Speed {fmt_speed(v['speed']['xRealtime'])} realtime over {v['speed']['audioSeconds']} s of audio.")
        L.append("")
        ss = sorted(v["settings"], key=lambda s: (s["objective"] is None, -(s["objective"] or 0)))
        if ss:
            L.append("Settings, best first (top 12):")
            L.append("")
            L.append("| setting | objective | recognized | wrong | asked again | 1st-time false match "
                     "| pipeline DER | count err | profiles end / people | false-merge profiles |")
            L.append("|---|---|---|---|---|---|---|---|---|---|")
            for s in ss[:12]:
                rc, pl, idn = s["recognition"], s["pipeline"], s["identity"]
                L.append(f"| {s['tag']} | {fmt(s['objective'])} | {fmt(rc['recognizedRate'], True)} "
                         f"| {fmt(rc['wrongPersonRate'], True)} | {fmt(rc['askedAgainRate'], True)} "
                         f"| {fmt(rc['firstAppearanceFalseMatchRate'], True)} | {fmt(pl['meanDER'])} "
                         f"| {fmt(pl['meanSpeakerCountError'])} | {idn['profilesAtEnd']} / {idn['trueSpeakers']} "
                         f"| {idn['falseMergeProfiles']} |")
            L.append("")
            # knob sensitivity: best objective per value of every knob that varied
            varied = {}
            for k in (ss[0]["knobs"] or {}):
                vals = {json.dumps(s["knobs"].get(k)) for s in ss}
                if len(vals) > 1:
                    varied[k] = vals
            if varied:
                L.append("What moved recognition (best objective / recognized rate reachable at each knob value):")
                L.append("")
                for k in sorted(varied):
                    cells = []
                    for val in sorted(varied[k]):
                        group = [s for s in ss if json.dumps(s["knobs"].get(k)) == val]
                        top = pick_best(group)
                        cells.append(f"{json.loads(val)} → {fmt(top['objective'])} / "
                                     f"{fmt(top['recognition']['recognizedRate'], True)}")
                    L.append(f"- `{k}`: " + "; ".join(cells))
                L.append("")
        best = next((s for s in v["settings"] if v["best"] and s["tag"] == v["best"]["tag"]), None)
        L.append("Per meeting (raw diarizer vs best-setting pipeline):")
        L.append("")
        L.append("| meeting | people | raw spk | raw DER | pipeline spk | pipeline DER | matched / new clusters | speed |")
        L.append("|---|---|---|---|---|---|---|---|")
        pm = {r["meeting"]: r for r in (best["perMeeting"] if best else [])}
        for r in v["raw"]["perMeeting"]:
            p = pm.get(r["meeting"], {})
            L.append(f"| {r['meeting']} | {r['refSpeakers']} | {r['rawSpeakers']} | {fmt(r['der'])} "
                     f"| {p.get('hypSpeakers', '—')} | {fmt(p.get('der'))} "
                     f"| {p.get('clustersMatched', '—')} / {p.get('clustersNew', '—')} | {fmt_speed(r.get('xRealtime'))} |")
        L.append("")
    return "\n".join(L) + "\n"


def own_calls_markdown(scores):
    L = []
    L.append(f"# Speaker lab — your own calls ({len(scores['meetings'])} meetings)")
    L.append("")
    L.append(f"Generated {scores['generatedAt']} at git `{scores['gitRevision']}`. No ground truth here, so these "
             "numbers describe behavior, not accuracy. Eyeball `timeline.html` next to this file to judge who is "
             "right. Everything stayed on this Mac.")
    L.append("")
    L.append("| variant | avg speakers raw / pipeline | speech covered | clusters matched to a known profile / new "
             "| profiles at end | disagreement vs baseline (DER) | speed |")
    L.append("|---|---|---|---|---|---|---|")
    for v in scores["variants"]:
        s = v["summary"]
        ag = (v.get("agreement") or {}).get("meanDerVsBaseline")
        L.append(f"| **{v['name']}** | {fmt(s['meanRawSpeakers'])} / {fmt(s['meanPipelineSpeakers'])} "
                 f"| {fmt(s['meanSpeechCoverage'], True)} | {s['clustersMatched']} / {s['clustersNew']} "
                 f"| {s['profilesAtEnd']} | {'baseline' if v.get('agreement') is None else fmt(ag)} "
                 f"| {fmt_speed(v['speed']['xRealtime'])} |")
    L.append("")
    L.append("- More **matched** clusters with the same number of real people means fewer times you'd be asked to "
             "name someone you've already named. Fewer **profiles at end** for the same calls usually means better "
             "recognition — unless two people got merged, which the timeline shows.")
    L.append("- **Disagreement** is the DER of that variant's raw output scored against the first variant as if it "
             "were the truth. High disagreement just means they differ; the timeline tells you which one is right.")
    L.append("")
    L.append("| meeting | " + " | ".join(f"{v['name']} spk raw/pipe, matched/new" for v in scores["variants"]) + " |")
    L.append("|---|" + "---|" * len(scores["variants"]))
    for i, (mid, _, disp) in enumerate(scores["meetings"]):
        cells = []
        for v in scores["variants"]:
            r = v["perMeeting"][i]
            if r.get("status") != "ok":
                cells.append("—")
            else:
                cells.append(f"{r['rawSpeakers']}/{r.get('pipelineSpeakers', '—')}, "
                             f"{r.get('clustersMatched', '—')}/{r.get('clustersNew', '—')}")
        L.append(f"| {disp} | " + " | ".join(cells) + " |")
    L.append("")
    return "\n".join(L) + "\n"


PALETTE_LIGHT = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"]
PALETTE_DARK = ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9", "#e66767"]


def timeline_html(scores, raw_by_variant, replay_by_variant):
    """Self-contained HTML: per meeting, one lane per variant (pipeline profiles, same
    color = same profile across meetings within that variant) plus an optional raw
    diarizer lane. No transcript text, no audio."""
    data = {"meetings": [], "variants": [v["name"] for v in scores["variants"]]}
    profile_names = {}
    for vname in data["variants"]:
        rp = replay_by_variant.get(vname) or {}
        rmeet = {m["meeting"]: m for m in rp.get("meetings", [])}
        order = {}
        for m in rp.get("meetings", []):
            for a in sorted(m.get("assignments", []), key=lambda a: a["start"]):
                if a["dbProfile"] not in order:
                    order[a["dbProfile"]] = len(order)
        profile_names[vname] = (order, rmeet)
    for mid, _, disp in scores["meetings"]:
        entry = {"id": mid, "name": disp, "lanes": []}
        dur = 0.0
        for vname in data["variants"]:
            order, rmeet = profile_names[vname]
            d = raw_by_variant.get(vname, {}).get(mid)
            raw = [[round(s, 2), round(e, 2), l] for s, e, l in raw_hyp(d)] if d else []
            m = rmeet.get(mid)
            pipe = []
            if m:
                status = m.get("clusterStatus") or {}
                for a in m.get("assignments", []):
                    idx = order.get(a["dbProfile"], 0)
                    known = status.get(str(a.get("diarizerCluster"))) == "matched"
                    pipe.append([round(a["start"], 2), round(a["end"], 2), idx, 1 if known else 0])
            if d:
                dur = max(dur, d.get("audioSeconds") or d.get("durationSeconds") or 0.0)
            entry["lanes"].append({"variant": vname, "raw": raw, "pipe": pipe})
        entry["duration"] = round(dur, 1)
        data["meetings"].append(entry)
    payload = json.dumps(data, separators=(",", ":")).replace("</", "<\\/")
    css_light = "".join(f"--s{i}:{c};" for i, c in enumerate(PALETTE_LIGHT))
    css_dark = "".join(f"--s{i}:{c};" for i, c in enumerate(PALETTE_DARK))
    title = html.escape(f"Speaker lab timeline — {len(scores['meetings'])} calls")
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Speaker lab timeline</title>
<style>
:root{{color-scheme:light;--bg:#fcfcfb;--ink:#0b0b0b;--ink2:#52514e;--muted:#8a8984;--rule:#e4e3df;--other:#9d9c97;{css_light}}}
@media (prefers-color-scheme:dark){{:root:not([data-theme="light"]){{color-scheme:dark;--bg:#1a1a19;--ink:#fff;--ink2:#c3c2b7;--muted:#8f8e86;--rule:#33332f;--other:#6f6e69;{css_dark}}}}}
:root[data-theme="dark"]{{color-scheme:dark;--bg:#1a1a19;--ink:#fff;--ink2:#c3c2b7;--muted:#8f8e86;--rule:#33332f;--other:#6f6e69;{css_dark}}}
body{{margin:0;padding:16px;background:var(--bg);color:var(--ink);font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}}
h1{{font-size:18px;margin:0 0 4px}} p{{color:var(--ink2);margin:0 0 12px;max-width:70ch}}
.controls{{display:flex;gap:16px;flex-wrap:wrap;margin:0 0 16px;color:var(--ink2)}}
.meeting{{border-top:1px solid var(--rule);padding:12px 0}}
.mh{{display:flex;justify-content:space-between;gap:8px;flex-wrap:wrap;margin-bottom:6px}}
.mh b{{overflow-wrap:anywhere}} .mh span{{color:var(--muted)}}
.lane{{display:grid;grid-template-columns:minmax(90px,180px) 1fr;gap:8px;align-items:center;margin:3px 0}}
.lane .lbl{{color:var(--ink2);font-size:12px;overflow-wrap:anywhere}}
.track{{position:relative;height:18px;background:color-mix(in srgb,var(--rule) 45%,transparent);border-radius:4px;overflow:hidden}}
.raw .track{{height:10px}}
.seg{{position:absolute;top:0;bottom:0;border-radius:2px;box-shadow:0 0 0 1px var(--bg)}}
.seg.new{{background-image:repeating-linear-gradient(45deg,transparent 0 3px,rgba(255,255,255,.45) 3px 5px)}}
.legend{{font-size:12px;color:var(--ink2)}}
#tip{{position:fixed;pointer-events:none;background:var(--ink);color:var(--bg);padding:4px 8px;border-radius:4px;font-size:12px;display:none;z-index:9}}
</style></head><body>
<h1>{title}</h1>
<p>Each call shows one lane per variant. Bars are the speaker profile the app would save after matching.
Same color inside one variant = the same profile across calls, so a returning person should keep their color.
Striped bars landed on a profile created in that call (you'd be asked to name them); solid bars matched a profile that already existed.
Colors past eight profiles fold to gray. Hover a bar for times.</p>
<div class="controls"><label><input type="checkbox" id="raw"> show raw diarizer lanes</label>
<span class="legend">times in minutes; no transcript text or audio in this file</span></div>
<div id="root"></div><div id="tip"></div>
<script>
const DATA={payload};
const root=document.getElementById('root'),tip=document.getElementById('tip');
function color(i){{return i<8?`var(--s${{i}})`:'var(--other)';}}
function mmss(t){{const m=Math.floor(t/60),s=Math.round(t%60);return m+':'+String(s).padStart(2,'0');}}
function bar(track,s,e,dur,fill,cls,label){{const d=document.createElement('div');d.className='seg '+cls;
d.style.left=(100*s/dur)+'%';d.style.width=Math.max(0.15,100*(e-s)/dur)+'%';d.style.background=fill;
d.dataset.tip=label+' · '+mmss(s)+'–'+mmss(e);track.appendChild(d);}}
function render(){{root.textContent='';const showRaw=document.getElementById('raw').checked;
for(const m of DATA.meetings){{const box=document.createElement('div');box.className='meeting';
const h=document.createElement('div');h.className='mh';const b=document.createElement('b');b.textContent=m.name;
const sp=document.createElement('span');sp.textContent=mmss(m.duration);h.append(b,sp);box.appendChild(h);
const dur=Math.max(m.duration,1);
for(const lane of m.lanes){{const row=document.createElement('div');row.className='lane';
const l=document.createElement('div');l.className='lbl';l.textContent=lane.variant;const t=document.createElement('div');t.className='track';
for(const [s,e,p,known] of lane.pipe) bar(t,s,e,dur,color(p),known?'':'new','P'+(p+1)+(known?' (known)':' (new)'));
row.append(l,t);box.appendChild(row);
if(showRaw){{const rr=document.createElement('div');rr.className='lane raw';const rl=document.createElement('div');rl.className='lbl';
rl.textContent=lane.variant+' raw';const rt=document.createElement('div');rt.className='track';const ids={{}};
for(const [s,e,lbl] of lane.raw){{if(!(lbl in ids))ids[lbl]=Object.keys(ids).length;bar(rt,s,e,dur,color(ids[lbl]),'',lbl);}}
rr.append(rl,rt);box.appendChild(rr);}}}}
root.appendChild(box);}}}}
document.getElementById('raw').addEventListener('change',render);
root.addEventListener('mousemove',ev=>{{const t=ev.target.dataset&&ev.target.dataset.tip;if(!t){{tip.style.display='none';return;}}
tip.textContent=t;tip.style.display='block';tip.style.left=Math.min(ev.clientX+12,innerWidth-200)+'px';tip.style.top=(ev.clientY+12)+'px';}});
root.addEventListener('mouseleave',()=>tip.style.display='none');
render();
</script></body></html>
"""


def cmd_score(a):
    run_dir = os.path.abspath(a.run_dir)
    env = read_env(os.path.join(run_dir, "run.env"))
    meetings = read_tsv(os.path.join(run_dir, "meetings.tsv"), 3)
    variants = read_tsv(os.path.join(run_dir, "variants.tsv"), 5)
    replays = read_tsv(os.path.join(run_dir, "replays.tsv"), 3)
    if not meetings or not variants:
        print("error: run dir has no meetings.tsv / variants.tsv", file=sys.stderr)
        return 2
    mode = env.get("MODE", "corpus")
    knob_env = {k: v for k, v in env.items() if k.startswith("KNOB_")}
    scores = {
        "schema": SCHEMA,
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "mode": mode,
        "gitRevision": env.get("GIT_REVISION", "unknown"),
        "gitDirty": env.get("GIT_DIRTY", "0") == "1",
        "command": env.get("COMMAND", ""),
        "corpus": env.get("CORPUS", "own-calls" if mode == "own-calls" else "unknown"),
        "collar": float(env.get("COLLAR", "0.25") or 0.25),
        "minAppearanceSeconds": float(env.get("MIN_APPEARANCE_SEC", "5") or 5),
        "wrongPenalty": float(env.get("WRONG_PENALTY", "2") or 2),
        "single": env.get("SINGLE", "0") == "1",
        "requestedKnobs": {k[len("KNOB_"):].lower(): v for k, v in sorted(knob_env.items())},
        "meetings": [m[0] for m in meetings],
    }
    if mode == "own-calls":
        scores["meetings"] = [(m[0], m[1], m[2]) for m in meetings]
        per_variant, raw_by_variant = score_own_calls(run_dir, env, meetings, variants, replays)
        scores["variants"] = per_variant
        replay_by_variant = {}
        for v, tag, path in replays:
            replay_by_variant.setdefault(v, load_json(path))
        with open(os.path.join(run_dir, "timeline.html"), "w") as f:
            f.write(timeline_html(scores, raw_by_variant, replay_by_variant))
        md = own_calls_markdown(scores)
        # scores.json carries meeting ids only: no audio paths, no meeting names
        scores["meetings"] = [m[0] for m in meetings]
        for v in scores["variants"]:
            for row in v["perMeeting"]:
                row.pop("name", None)
    else:
        scores["variants"] = score_corpus(run_dir, env, meetings, variants, replays)
        md = corpus_markdown(scores)
    events_path = os.path.join(run_dir, "recognition-events.json")
    if mode != "own-calls":
        events = {v["name"]: {s["tag"]: s.pop("recognitionEvents") for s in v["settings"]}
                  for v in scores["variants"]}
        with open(events_path, "w") as f:
            json.dump(events, f, indent=1)
    with open(os.path.join(run_dir, "scores.json"), "w") as f:
        json.dump(scores, f, indent=2)
    with open(os.path.join(run_dir, "REPORT.md"), "w") as f:
        f.write(md)
    if not a.quiet:
        print(md)
    failed = [v["name"] for v in scores["variants"]
              if (v.get("meetingsScored") if mode != "own-calls" else v["summary"]["meetingsScored"]) == 0]
    if failed:
        print(f"error: no scorable meetings for variant(s): {', '.join(failed)}", file=sys.stderr)
        return 1
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("grid")
    for name, _, _ in GRID_KNOBS:
        g.add_argument("--" + name.replace("_", "-"), dest=name, default="")
    d = sub.add_parser("dump-ok")
    d.add_argument("--dump", required=True)
    d.add_argument("--backend", required=True)
    d.add_argument("--embedder", required=True)
    d.add_argument("--preset", default="")
    o = sub.add_parser("own-calls-list")
    o.add_argument("--folder", required=True)
    o.add_argument("--limit", type=int, default=0, help="keep only the N most recent calls")
    s = sub.add_parser("score")
    s.add_argument("--run-dir", required=True)
    s.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv)
    if a.cmd == "grid":
        return cmd_grid(a) or 0
    if a.cmd == "dump-ok":
        return cmd_dump_ok(a)
    if a.cmd == "own-calls-list":
        return cmd_own_calls_list(a) or 0
    return cmd_score(a)


if __name__ == "__main__":
    sys.exit(main())

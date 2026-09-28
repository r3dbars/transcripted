#!/usr/bin/env python3
"""Keep every ready model embedded over every ready set and condition.

Scans VP/models/*/model.json (status "ready") and VP/sets/*/READY plus
VP/clips/<set>/<cond>/READY, and runs embed_job.py for each missing
VP/emb/<model>/<set>__<cond>.npz, a few at a time. Clean audio goes first and the
baseline models first, so the headline numbers land early.

Live controls (read every loop):
  VP/logs/daemon.slots   number of parallel jobs (default 5)
  VP/logs/daemon.stop    exit once running jobs finish
  VP/logs/daemon.hold    model_id prefixes to skip for now, one per line
  VP/logs/daemon.clean_only  model_id prefixes that only get clean audio (weak screens)
Status: VP/logs/daemon.status.json. Per-job logs: VP/logs/embed/.
An embedding whose recorded model_sig no longer matches model.json + the runtime
module is stale and gets redone. A job that fails twice is left alone (VP/logs/embed/<job>.failed) until that
file is deleted.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
VP = Path(os.environ.get("VP_ROOT", REPO / "data" / "eval" / "voiceprint"))
PY = VP / "venv" / "bin" / "python"
JOB = Path(__file__).resolve().parent / "embed_job.py"
LOGS = VP / "logs" / "embed"
CONDS = ["clean", "opus12", "noisy", "phone"]
THREADS = 3


def held() -> list[str]:
    try:
        return [l.strip() for l in (VP / "logs" / "daemon.hold").read_text().splitlines() if l.strip()]
    except Exception:
        return []


def clean_only() -> list[str]:
    try:
        return [l.strip() for l in (VP / "logs" / "daemon.clean_only").read_text().splitlines() if l.strip()]
    except Exception:
        return []


HUMAN_SETS = {"vox1o", "libri", "ami", "icsi"}
MAX_MPS = 3


def full_models() -> list[str]:
    """Models that also get degraded audio (VP/logs/daemon.full, one model_id per line)."""
    try:
        return [l.strip() for l in (VP / "logs" / "daemon.full").read_text().splitlines() if l.strip()]
    except Exception:
        return []


def tier(model: dict, set_name: str, cond: str, full: list[str]):
    """Scheduling tier, lower first; None = don't run. Clean on the human sets for every
    model, then call audio (opus12, noisy) for the contenders, then yodas clean, then
    phone, then yodas call audio."""
    human = set_name in HUMAN_SETS
    is_full = model["model_id"] in full or model.get("baseline", False)
    if cond == "clean":
        return 0 if human else 2
    if not is_full:
        return None
    if cond in ("opus12", "noisy"):
        return 1 if human else 4
    return 3 if human else 5


def ready_models() -> list[dict]:
    out = []
    hold = held()
    for path in sorted((VP / "models").glob("*/model.json")):
        try:
            meta = json.loads(path.read_text())
        except Exception:
            continue
        if meta.get("status") == "ready" and (Path(__file__).parent / "runtimes" / f"{meta.get('runtime')}.py").exists():
            meta.setdefault("model_id", path.parent.name)
            if not any(meta["model_id"].startswith(h) for h in hold):
                out.append(meta)
    # Baselines first, then the contenders (daemon.full), then smaller models.
    full = set(full_models())
    return sorted(out, key=lambda m: (not m.get("baseline", False), m["model_id"] not in full,
                                      float(m.get("params_m") or 50)))


RUNTIMES = Path(__file__).resolve().parent / "runtimes"
_sig_cache: dict[str, tuple[float, str]] = {}


def model_signature(model_id: str, runtime: str) -> str:
    import hashlib
    mj, rt = VP / "models" / model_id / "model.json", RUNTIMES / f"{runtime}.py"
    stamp = mj.stat().st_mtime + rt.stat().st_mtime
    cached = _sig_cache.get(model_id)
    if cached and cached[0] == stamp:
        return cached[1]
    h = hashlib.sha1(mj.read_bytes())
    h.update(rt.read_bytes())
    sig = h.hexdigest()[:16]
    _sig_cache[model_id] = (stamp, sig)
    return sig


_set_cache: dict[str, tuple[float, str]] = {}


def set_signature(set_name: str) -> str:
    import hashlib
    seg = VP / "sets" / set_name / "segments.jsonl"
    stamp = seg.stat().st_mtime
    cached = _set_cache.get(set_name)
    if cached and cached[0] == stamp:
        return cached[1]
    sig = hashlib.sha1(seg.read_bytes()).hexdigest()[:16]
    _set_cache[set_name] = (stamp, sig)
    return sig


def is_current(model: dict, set_name: str, cond: str) -> bool:
    out = VP / "emb" / model["model_id"] / f"{set_name}__{cond}"
    if not out.with_suffix(".npz").exists():
        return False
    try:
        info = json.loads(out.with_suffix(".json").read_text())
        return (info.get("model_sig") == model_signature(model["model_id"], model["runtime"])
                and info.get("set_sig") in (None, set_signature(set_name)))
    except Exception:
        return False


def ready_pairs() -> list[tuple[str, str]]:
    pairs = []
    for ready in sorted((VP / "sets").glob("*/READY")):
        name = ready.parent.name
        if name.startswith("_"):
            continue
        for cond in CONDS:
            if cond == "clean" or (VP / "clips" / name / cond / "READY").exists():
                pairs.append((name, cond))
    return pairs


def slots() -> int:
    try:
        return max(0, int((VP / "logs" / "daemon.slots").read_text().strip()))
    except Exception:
        return 5


def main() -> None:
    LOGS.mkdir(parents=True, exist_ok=True)
    running: dict[str, subprocess.Popen] = {}
    running_device: dict[str, str] = {}
    attempts: dict[str, int] = {}
    done_count = 0
    while True:
        for key, proc in list(running.items()):
            if proc.poll() is not None:
                del running[key]
                if proc.returncode == 0:
                    done_count += 1
                else:
                    attempts[key] = attempts.get(key, 0) + 1
                    if attempts[key] >= 2:
                        (LOGS / f"{key}.failed").write_text(f"exit {proc.returncode}\n")
        stop = (VP / "logs" / "daemon.stop").exists()
        pending = []
        if not stop:
            pairs = ready_pairs()
            models = ready_models()
            full = full_models()
            for model in models:
                for set_name, cond in pairs:
                    key = f"{model['model_id']}__{set_name}__{cond}"
                    if key in running or (LOGS / f"{key}.failed").exists():
                        continue
                    t = tier(model, set_name, cond, full)
                    if t is None or is_current(model, set_name, cond):
                        continue
                    pending.append((t, key, model, set_name, cond))
            order = {m["model_id"]: i for i, m in enumerate(models)}
            pending.sort(key=lambda p: (p[0], order[p[2]["model_id"]], p[3]))
            mps_running = sum(1 for k in running if running_device.get(k) == "mps")
            for t, key, model, set_name, cond in list(pending):
                if len(running) >= slots():
                    break
                device = str(model.get("device", "cpu"))
                if device == "mps" and mps_running >= MAX_MPS:
                    continue
                env = dict(os.environ, OMP_NUM_THREADS=str(THREADS), MKL_NUM_THREADS=str(THREADS),
                           VECLIB_MAXIMUM_THREADS=str(THREADS), HF_HUB_OFFLINE="1", TOKENIZERS_PARALLELISM="false",
                           TRANSCRIPTED_DISABLE_FILE_LOGGER="1")
                log = open(LOGS / f"{key}.log", "w")
                running[key] = subprocess.Popen(
                    [str(PY), str(JOB), "--model", model["model_id"], "--set", set_name, "--cond", cond, "--threads", str(THREADS)],
                    stdout=log, stderr=subprocess.STDOUT, env=env, cwd=str(REPO))
                running_device[key] = device
                if device == "mps":
                    mps_running += 1
                pending.remove((t, key, model, set_name, cond))
        status = {"time": time.strftime("%H:%M:%S"), "running": sorted(running), "pending": len(pending),
                  "done_this_run": done_count, "failed": sorted(p.stem for p in LOGS.glob("*.failed")),
                  "slots": slots(), "stopping": stop}
        (VP / "logs" / "daemon.status.json").write_text(json.dumps(status, indent=1))
        if stop and not running:
            print("daemon stopped", flush=True)
            return
        time.sleep(20)


if __name__ == "__main__":
    main()

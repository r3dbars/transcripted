#!/usr/bin/env python3
"""Hill-climb bench adapter for the dictation stop path (objective dictation-stop-latency).

    python3 scripts/hillclimb/benches/dictation_stop.py --request PATH
    python3 scripts/hillclimb/benches/dictation_stop.py --self-test

The climber hands us a request (see hc_benches.py). We turn each suite item
into a WAV fixture (speech via macOS `say` + `afconvert`, exactly like
scripts/ops/dictation-stop-autoeval.sh; silence via the stdlib `wave` module),
run the app binary once in DictationStopBenchmarkRunner mode with an isolated
HOME, and map its JSONL case_result rows back to suite items.

Why the extra plumbing:
- The runner derives case_id from the WAV file name, so fixtures are staged as
  `<index>-<safe id>.wav` and we keep our own case_id -> item id table instead
  of trusting ids to be file-name safe.
- The runner never puts transcript text in the JSONL, only `text_hash`
  (FNV-1a 64). It does save the text to Dictations_*.md under SAVE_DIR, so WER
  reads those sections back and keeps only texts whose FNV hash matches a row.
- unstable_output compares text hashes across repetitions of one trial, which
  run as separate processes, so hashes persist in a locked sidecar JSON next to
  the per-repetition work dirs.

The result holds only numbers, hashes, ids, and short error strings.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import wave
from pathlib import Path
from typing import Any, Mapping, Sequence

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))

from hc_benches import RESULT_SCHEMA  # noqa: E402
from hc_proc import run_group  # noqa: E402

BENCH_ID = "dictation-stop"
REPO_ROOT = HERE.parents[2]
DEFAULT_APP_BINARY = "build/Transcripted.app/Contents/MacOS/Transcripted"
DEFAULT_VOICE = "Samantha"
SPEECH_RATE = 170
SAMPLE_RATE = 48_000
DEFAULT_TIMEOUT_SECONDS = 3000.0
DEFAULT_FIXTURE_CACHE = "~/Library/Caches/Transcripted Lab/hillclimb-dictation-fixtures"
BENCH_ENV_PREFIX = "TRANSCRIPTED_DICTATION_STOP_BENCH_"
HASH_SIDECAR = "dictation-hashes.json"

KNOB_PATH = "dictation.stop.path"
KNOB_ORDER = "dictation.stop.finalization_order"
KNOB_CHUNK = "dictation.stop.chunk_seconds"
DEFAULT_PATH = "production"
DEFAULT_ORDER = "saveBeforeAutoEnter"
DEFAULT_CHUNK_SECONDS = 30.0
VARIANTS = ("native", "pre_resampled", "chunked", "production")
ORDERS = {
    "savebeforeautoenter": "saveBeforeAutoEnter",
    "save_before_auto_enter": "saveBeforeAutoEnter",
    "saveafterautoenter": "saveAfterAutoEnter",
    "save_after_auto_enter": "saveAfterAutoEnter",
}

LATENCY_METRICS = ("stop_to_text_s", "stop_to_delivery_s", "decode_s", "stop_to_saved_s", "audio_duration_s")
GATES = ("missing_text", "silence_text", "unstable_output")
ERROR_LIMIT = 200


class AdapterError(RuntimeError):
    """Nothing could run at all; the adapter exits non-zero."""


# ---------------------------------------------------------------- text math


def normalize_words(text: str) -> list[str]:
    """Lowercase, drop apostrophes and digit-group commas, other punctuation -> space."""
    lowered = text.lower().replace("’", "'")
    lowered = lowered.replace("'", "")
    lowered = re.sub(r"(?<=\d),(?=\d{3}\b)", "", lowered)
    lowered = re.sub(r"[^\w\s]|_", " ", lowered)
    return lowered.split()


def word_error_rate(reference: str, hypothesis: str) -> float:
    """Word-level Levenshtein distance over the normalized reference length."""
    ref = normalize_words(reference)
    hyp = normalize_words(hypothesis)
    if not ref:
        return 0.0 if not hyp else float(len(hyp))
    previous = list(range(len(hyp) + 1))
    for i, ref_word in enumerate(ref, 1):
        current = [i] + [0] * len(hyp)
        for j, hyp_word in enumerate(hyp, 1):
            cost = 0 if ref_word == hyp_word else 1
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        previous = current
    return previous[-1] / len(ref)


def fnv1a64(text: str) -> str:
    """Same hash as DictationStopBenchmarkRunner.stableHash."""
    value = 14_695_981_039_346_656_037
    for byte in text.encode("utf-8"):
        value ^= byte
        value = (value * 1_099_511_628_211) & 0xFFFF_FFFF_FFFF_FFFF
    return f"{value:016x}"


SECTION_HEADER = re.compile(r"^## [^\n]*\n\nEntry ID: `[^`\n]*`\n", re.MULTILINE)
CHARACTERS_LINE = re.compile(r"\nCharacters: \d+\n\n")


def saved_texts_by_hash(save_dir: Path) -> dict[str, str]:
    """Read Dictations_*.md sections (DictationTranscriptWriter format), keyed by FNV hash."""
    texts: dict[str, str] = {}
    for path in sorted(save_dir.glob("Dictations_*.md")):
        content = path.read_text(encoding="utf-8", errors="replace")
        headers = list(SECTION_HEADER.finditer(content))
        for index, header in enumerate(headers):
            end = headers[index + 1].start() if index + 1 < len(headers) else len(content)
            body = content[header.start():end]
            marker = CHARACTERS_LINE.search(body)
            if not marker:
                continue
            text = body[marker.end():].strip()
            texts[fnv1a64(text)] = text
    return texts


# ---------------------------------------------------------------- fixtures


def item_kind(item: Mapping[str, Any]) -> str:
    kind = item.get("kind")
    if kind:
        return str(kind)
    return "speech" if item.get("text") else "unknown"


def fixture_key(voice: str, rate: int, text: str) -> str:
    return hashlib.sha256(f"{voice}|{rate}|{text}".encode("utf-8")).hexdigest()[:16]


def resolve_path(value: str, repo_root: Path) -> Path:
    path = Path(os.path.expandvars(value)).expanduser()
    return path if path.is_absolute() else repo_root / path


def command_list(value: Any, default: Sequence[str]) -> list[str]:
    if value is None:
        return list(default)
    if isinstance(value, str):
        return [value]
    return [str(part) for part in value]


def run_quiet(argv: Sequence[str], timeout: float = 600.0) -> str | None:
    """Run a helper; return None on success or a short error."""
    try:
        completed = run_group(argv, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"{Path(argv[0]).name}: {type(error).__name__}"
    if completed.returncode != 0:
        return f"{Path(argv[0]).name} exited {completed.returncode}"
    return None


def synthesize_speech(text: str, options: Mapping[str, Any], cache_dir: Path) -> Path:
    """Return a cached 48 kHz 16-bit WAV of `text`, making it with say + afconvert if needed."""
    voice = str(options.get("voice") or DEFAULT_VOICE)
    target = cache_dir / f"{fixture_key(voice, SPEECH_RATE, text)}.wav"
    if target.exists() and target.stat().st_size > 44:
        return target
    cache_dir.mkdir(parents=True, exist_ok=True)
    say = command_list(options.get("say_command"), ["/usr/bin/say"])
    afconvert = command_list(options.get("afconvert_command"), ["/usr/bin/afconvert"])
    with tempfile.TemporaryDirectory(prefix="fixture-", dir=cache_dir) as scratch:
        text_file = Path(scratch) / "text.txt"
        aiff = Path(scratch) / "speech.aiff"
        wav = Path(scratch) / "speech.wav"
        text_file.write_text(text + "\n", encoding="utf-8")
        problem = run_quiet([*say, "-v", voice, "-r", str(SPEECH_RATE), "-f", str(text_file), "-o", str(aiff)])
        if problem is None:
            problem = run_quiet([*afconvert, "-f", "WAVE", "-d", f"LEI16@{SAMPLE_RATE}", str(aiff), str(wav)])
        if problem is None and (not wav.exists() or wav.stat().st_size <= 44):
            problem = "afconvert wrote no audio"
        if problem:
            raise AdapterError(problem)
        os.replace(wav, target)
    return target


def write_silence(path: Path, seconds: float) -> None:
    frames = max(1, int(round(float(seconds) * SAMPLE_RATE)))
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(b"\x00\x00" * frames)


def link_or_copy(source: Path, destination: Path) -> None:
    try:
        os.link(source, destination)
    except OSError:
        shutil.copyfile(source, destination)


def case_stem(index: int, item_id: str) -> str:
    """File stem the runner will report as case_id; index keeps it unique and ordered."""
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", item_id)[:48]
    return f"{index:04d}-{safe}"


def stage_fixtures(
    items: Sequence[Mapping[str, Any]], audio_dir: Path, options: Mapping[str, Any], repo_root: Path
) -> tuple[dict[str, str], dict[str, str]]:
    """Write one WAV per item into audio_dir. Returns (case_id -> item id, item id -> error)."""
    audio_dir.mkdir(parents=True, exist_ok=True)
    cache_dir = resolve_path(str(options.get("fixture_cache") or DEFAULT_FIXTURE_CACHE), repo_root)
    cases: dict[str, str] = {}
    errors: dict[str, str] = {}
    for index, item in enumerate(items):
        item_id = str(item["id"])
        stem = case_stem(index, item_id)
        destination = audio_dir / f"{stem}.wav"
        kind = item_kind(item)
        try:
            if kind == "speech":
                text = str(item.get("text") or "").strip()
                if not text:
                    raise AdapterError("speech item has no text")
                link_or_copy(synthesize_speech(text, options, cache_dir), destination)
            elif kind == "silence":
                write_silence(destination, float(item.get("seconds", 3)))
            else:
                raise AdapterError(f"unknown item kind {kind!r}")
        except (AdapterError, OSError, ValueError) as error:
            errors[item_id] = f"fixture: {error}"[:ERROR_LIMIT]
            continue
        cases[stem] = item_id
    return cases, errors


# ---------------------------------------------------------------- app run


def stop_settings(knobs: Mapping[str, Any]) -> dict[str, str]:
    """Runner env for the dictation.stop.* knobs, with production defaults."""
    variant = str(knobs.get(KNOB_PATH, DEFAULT_PATH)).strip().replace("-", "_")
    if variant not in VARIANTS:
        raise ValueError(f"{KNOB_PATH}={variant!r} is not one of {VARIANTS}")
    order_raw = str(knobs.get(KNOB_ORDER, DEFAULT_ORDER)).strip().replace("-", "_").lower()
    if order_raw not in ORDERS:
        raise ValueError(f"{KNOB_ORDER}={knobs.get(KNOB_ORDER)!r} is not a known order")
    chunk = float(knobs.get(KNOB_CHUNK, DEFAULT_CHUNK_SECONDS))
    if not chunk > 0:
        raise ValueError(f"{KNOB_CHUNK} must be > 0")
    return {
        "VARIANT": variant,
        "FINALIZATION_ORDER": ORDERS[order_raw],
        "CHUNK_SECONDS": format(chunk, "g"),
    }


def app_environment(work: Path, audio_dir: Path, output: Path, settings: Mapping[str, str]) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith(BENCH_ENV_PREFIX)}
    home = work / "home"
    for directory in (home, work / "saved", work / "recovery"):
        directory.mkdir(parents=True, exist_ok=True)
    env.update(
        {
            "HOME": str(home),
            "CFFIXED_USER_HOME": str(home),
            "TRANSCRIPTED_DISABLE_FILE_LOGGER": "1",
            "TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS": "1",
            "TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD": "1",
        }
    )
    bench = {
        "AUDIO_DIR": str(audio_dir),
        "OUTPUT": str(output),
        "SAVE_DIR": str(work / "saved"),
        "RECOVERY_DIR": str(work / "recovery"),
        "ITERATIONS": "1",
        "AUTO_ENTER": "1",
        **settings,
    }
    env.update({BENCH_ENV_PREFIX + key: value for key, value in bench.items()})
    return env


def write_app_logs(work: Path, stdout: str | bytes | None, stderr: str | bytes | None) -> None:
    """Keep the app's output in app-stdout.log / app-stderr.log, as before run_group captured it."""
    for name, data in (("app-stdout.log", stdout), ("app-stderr.log", stderr)):
        if isinstance(data, bytes):
            data = data.decode("utf-8", errors="replace")
        (work / name).write_text(data or "", encoding="utf-8", errors="replace")


def run_app(binary: Path, env: Mapping[str, str], work: Path, timeout: float) -> str | None:
    """Run the runner; return None on a clean exit or a short problem string."""
    try:
        completed = run_group([str(binary)], timeout=timeout, cwd=work, env=env)
    except subprocess.TimeoutExpired as error:
        write_app_logs(work, error.output, error.stderr)
        return f"app timed out after {timeout:g}s"
    except OSError as error:
        write_app_logs(work, "", "")
        return f"app could not start: {type(error).__name__}"
    except UnicodeDecodeError:
        write_app_logs(work, "", "")
        return "app output was not valid text"
    write_app_logs(work, completed.stdout, completed.stderr)
    if completed.returncode != 0:
        tail = (work / "app-stderr.log").read_text(errors="replace").strip().splitlines()[-1:]
        detail = f": {tail[0]}" if tail else ""
        return f"app exited {completed.returncode}{detail}"[:ERROR_LIMIT]
    return None


def read_jsonl(path: Path) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    run_start: dict[str, Any] = {}
    cases: dict[str, dict[str, Any]] = {}
    if not path.exists():
        return run_start, cases
    for line in path.read_text(errors="replace").splitlines():
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if record.get("record_type") == "run_start":
            run_start = record
        elif record.get("record_type") == "case_result" and record.get("case_id"):
            cases.setdefault(str(record["case_id"]), record)
    return run_start, cases


def sha256_prefix(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return "sha256:" + digest.hexdigest()[:16]


# ---------------------------------------------------------------- stability sidecar


def record_hashes(
    sidecar: Path, trial_id: str, knobs: Mapping[str, Any], repetition: int, hashes: Mapping[str, str]
) -> set[str]:
    """Store this repetition's hashes; return item ids whose hash differs from another repetition."""
    sidecar.parent.mkdir(parents=True, exist_ok=True)
    fingerprint = json.dumps(knobs, sort_keys=True, default=str)
    lock_path = sidecar.with_name(sidecar.name + ".lock")
    with open(lock_path, "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            data = json.loads(sidecar.read_text()) if sidecar.exists() else {}
        except json.JSONDecodeError:
            data = {}
        entry = data.get(trial_id)
        if not isinstance(entry, dict) or entry.get("config") != fingerprint:
            entry = {"config": fingerprint, "items": {}}
        unstable = set()
        rep_key = str(repetition)
        for item_id, text_hash in hashes.items():
            seen = entry["items"].setdefault(item_id, {})
            if any(rep != rep_key and old != text_hash for rep, old in seen.items()):
                unstable.add(item_id)
            seen[rep_key] = text_hash
        data[trial_id] = entry
        handle, temp_name = tempfile.mkstemp(prefix=".dictation-hashes-", dir=sidecar.parent)
        with os.fdopen(handle, "w") as temp:
            json.dump(data, temp, indent=1, sort_keys=True)
        os.replace(temp_name, sidecar)
    return unstable


# ---------------------------------------------------------------- results


def item_metrics(item: Mapping[str, Any], record: Mapping[str, Any], texts: Mapping[str, str]) -> tuple[dict, dict, str | None]:
    """Metrics, gates, and an optional warning for one measured item."""
    metrics: dict[str, float] = {}
    for name in LATENCY_METRICS:
        value = record.get(name)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            metrics[name] = float(value)
    words = int(record.get("words") or 0)
    speech = item_kind(item) == "speech"
    warning = None
    if speech:
        text_hash = str(record.get("text_hash") or "")
        if words == 0 or not text_hash:
            metrics["word_error_rate"] = word_error_rate(str(item.get("text", "")), "")
        elif text_hash in texts:
            metrics["word_error_rate"] = word_error_rate(str(item.get("text", "")), texts[text_hash])
        else:
            warning = "saved text not found for text_hash; word_error_rate omitted"
    gates = {
        "missing_text": 1 if speech and words == 0 else 0,
        "silence_text": 1 if not speech and words > 0 else 0,
        "unstable_output": 0,
    }
    return metrics, gates, warning


def error_items(items: Sequence[Mapping[str, Any]], message: str) -> list[dict]:
    return [{"id": str(item["id"]), "metrics": {}, "gates": {}, "error": message[:ERROR_LIMIT]} for item in items]


def base_environment(binary: Path | None, options: Mapping[str, Any]) -> dict[str, Any]:
    env: dict[str, Any] = {
        "app_revision": sha256_prefix(binary) if binary and binary.is_file() else "missing",
        "host": platform.node(),
        "os": platform.mac_ver()[0] or platform.platform(),
        "voice": str(options.get("voice") or DEFAULT_VOICE),
        "speech_rate": SPEECH_RATE,
    }
    return env


def run_request(request: Mapping[str, Any], request_path: Path, repo_root: Path = REPO_ROOT) -> dict:
    """Do the whole bench run; raises AdapterError only when nothing could run."""
    items = list(request.get("items") or [])
    options = dict(request.get("bench_options") or {})
    knobs = dict(request.get("knobs") or {})
    work = request_path.parent
    binary = resolve_path(str(options.get("app_binary") or DEFAULT_APP_BINARY), repo_root)
    environment = base_environment(binary, options)
    result = {"schema": RESULT_SCHEMA, "bench": BENCH_ID, "environment": environment, "items": []}

    if not (binary.is_file() and os.access(binary, os.X_OK)):
        result["items"] = error_items(items, "app binary missing or not executable")
        raise AdapterError(f"app binary missing or not executable: {binary}", result)
    try:
        settings = stop_settings(knobs)
    except (TypeError, ValueError) as error:
        result["items"] = error_items(items, f"bad knob: {error}")
        return result

    audio_dir = work / "audio"
    cases, fixture_errors = stage_fixtures(items, audio_dir, options, repo_root)
    speech_ids = [str(i["id"]) for i in items if item_kind(i) == "speech"]
    if not cases or (speech_ids and all(i in fixture_errors for i in speech_ids)):
        result["items"] = [
            {"id": str(i["id"]), "metrics": {}, "gates": {}, "error": fixture_errors.get(str(i["id"]), "fixture: skipped, no speech fixtures")}
            for i in items
        ]
        raise AdapterError("fixture synthesis failed for every speech item (is `say` available?)", result)

    output = work / "dictation-stop.jsonl"
    env = app_environment(work, audio_dir, output, settings)
    timeout = float(options.get("timeout_seconds") or DEFAULT_TIMEOUT_SECONDS)
    app_problem = run_app(binary, env, work, timeout)
    shutil.rmtree(audio_dir, ignore_errors=True)
    shutil.rmtree(work / "recovery", ignore_errors=True)

    run_start, records = read_jsonl(output)
    environment["app_exit"] = app_problem or "ok"
    environment["variant"] = settings["VARIANT"]
    environment["finalization_order"] = settings["FINALIZATION_ORDER"]
    environment["chunk_seconds"] = float(settings["CHUNK_SECONDS"])
    environment["encoder_compute_units"] = str(run_start.get("encoder_compute_units") or env.get("TRANSCRIPTED_PARAKEET_ENCODER_COMPUTE_UNITS", "default"))
    if isinstance(run_start.get("model_init_s"), (int, float)):
        environment["model_init_s"] = float(run_start["model_init_s"])

    texts = saved_texts_by_hash(work / "saved")
    record_for = {item_id: records.get(case_id) for case_id, item_id in cases.items()}
    hashes = {item_id: str(rec.get("text_hash") or "") for item_id, rec in record_for.items() if rec}
    unstable = record_hashes(
        request_path.parent.parent / HASH_SIDECAR,
        str(request.get("trial_id", "")),
        knobs,
        int(request.get("repetition", 0)),
        hashes,
    )
    warnings = 0
    for item in items:
        item_id = str(item["id"])
        if item_id in fixture_errors:
            result["items"].append({"id": item_id, "metrics": {}, "gates": {}, "error": fixture_errors[item_id]})
            continue
        record = record_for.get(item_id)
        if record is None:
            message = f"no case_result ({app_problem})" if app_problem else "no case_result"
            result["items"].append({"id": item_id, "metrics": {}, "gates": {}, "error": message[:ERROR_LIMIT]})
            continue
        metrics, gates, warning = item_metrics(item, record, texts)
        gates["unstable_output"] = 1 if item_id in unstable else 0
        row: dict[str, Any] = {"id": item_id, "metrics": metrics, "gates": gates, "error": None}
        if warning:
            row["warning"] = warning
            warnings += 1
        result["items"].append(row)
    if warnings:
        print(f"dictation-stop: WARNING word_error_rate missing for {warnings} item(s); saved Markdown did not match text_hash", file=sys.stderr)
    return result


def write_result(result: Mapping[str, Any], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(json.dumps(result, indent=2, sort_keys=True))
    os.replace(temp, path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--request", type=Path)
    parser.add_argument("--self-test", action="store_true", help="run this adapter's unit tests")
    args = parser.parse_args(argv)
    if args.self_test:
        import unittest

        suite = unittest.defaultTestLoader.discover(str(HERE), pattern="test_dictation_stop.py")
        return 0 if unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful() else 1
    if not args.request:
        parser.error("--request is required")
    request_path = args.request.resolve()
    request = json.loads(request_path.read_text())
    result_path = Path(request.get("result_path") or request_path.parent / "result.json")
    try:
        result = run_request(request, request_path)
    except AdapterError as error:
        message = error.args[0]
        if len(error.args) > 1:
            write_result(error.args[1], result_path)
        print(f"dictation-stop: {message}", file=sys.stderr)
        return 2
    write_result(result, result_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())

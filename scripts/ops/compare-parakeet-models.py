#!/usr/bin/env python3
"""Compare Parakeet V3 and the experimental Parakeet Ultra on the same recordings.

Runs Transcripted's own transcription CLI twice over the same files, once with
the Parakeet V3 model the app ships and once with the locally installed
Parakeet Ultra (scripts/models/parakeet-ultra/install.sh), then scores both.

  python3 scripts/ops/compare-parakeet-models.py ~/Desktop/test-clips/

Scoring: when a recording has a hand-checked transcript next to it
(<name>.txt beside <name>.m4a, or in --references), each model gets a word
error rate against it (lower is better). Without one, the report can only say
how much the two models disagree and show where, which is still worth reading.

Writes report.md and report.json (plus each model's raw transcripts) to
--out, default ~/Desktop/parakeet-ultra-vs-v3-<timestamp>/. Standard library
only. Local only: nothing leaves the Mac.
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import subprocess
import sys
import unicodedata
from datetime import datetime
from pathlib import Path

MEDIA_EXTENSIONS = {
    ".wav", ".mp3", ".m4a", ".aac", ".aiff", ".aif", ".caf", ".flac",
    ".mp4", ".mov", ".m4v",
}
MARKER = "transcripted-model.json"
DEFAULT_ULTRA_DIR = (
    Path.home() / "Library/Application Support/Transcripted/models/parakeet-ultra/parakeet-tdt-0.6b-v3"
)
CLI_CANDIDATES = [
    Path("/Applications/Transcripted.app/Contents/Helpers/transcripted-cli"),
    Path.home() / "Applications/Transcripted.app/Contents/Helpers/transcripted-cli",
]


def normalize(text: str) -> list[str]:
    """Lowercase words without punctuation, so scoring counts words, not commas."""
    text = unicodedata.normalize("NFKC", text).lower()
    text = re.sub(r"[‘’]", "'", text)
    text = re.sub(r"[^\w\s']", " ", text)
    return [w.strip("'") for w in text.split() if w.strip("'")]


def edit_distance(reference: list[str], hypothesis: list[str]) -> int:
    prev = list(range(len(hypothesis) + 1))
    for i, ref_word in enumerate(reference, start=1):
        cur = [i]
        for j, hyp_word in enumerate(hypothesis, start=1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ref_word != hyp_word)))
        prev = cur
    return prev[-1]


def differences(a: list[str], b: list[str], limit: int = 8, context: int = 3) -> list[tuple[str, str]]:
    """Up to `limit` spots where the two transcripts disagree, with a little context."""
    spots = []
    matcher = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag == "equal":
            continue
        left = " ".join(filter(None, [
            " ".join(a[max(0, i1 - context):i1]), f"[{' '.join(a[i1:i2]) or '-'}]", " ".join(a[i2:i2 + context]),
        ]))
        right = " ".join(filter(None, [
            " ".join(b[max(0, j1 - context):j1]), f"[{' '.join(b[j1:j2]) or '-'}]", " ".join(b[j2:j2 + context]),
        ]))
        spots.append((left, right))
        if len(spots) >= limit:
            break
    return spots


def find_media(paths: list[Path]) -> list[Path]:
    media = []
    for path in paths:
        if path.is_dir():
            media.extend(sorted(p for p in path.iterdir() if p.suffix.lower() in MEDIA_EXTENSIONS))
        elif path.is_file():
            media.append(path)
        else:
            sys.exit(f"Not found: {path}")
    if not media:
        sys.exit("No audio or video files to compare.")
    stems = [p.stem for p in media]
    if len(set(stems)) != len(stems):
        sys.exit("Two inputs share a file name; rename one so their transcripts can't be mixed up.")
    return [p.resolve() for p in media]


def find_reference(media: Path, references: Path | None) -> Path | None:
    for folder in filter(None, [references, media.parent]):
        candidate = folder / f"{media.stem}.txt"
        if candidate.is_file():
            return candidate
    return None


def resolve_cli(explicit: str | None) -> Path:
    candidates = [Path(explicit)] if explicit else []
    if os.environ.get("TRANSCRIPTED_CLI"):
        candidates.append(Path(os.environ["TRANSCRIPTED_CLI"]))
    candidates += CLI_CANDIDATES
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate.resolve()
    sys.exit("Could not find transcripted-cli. Install Transcripted in Applications or pass --cli.")


def transcribe(cli: Path, media: list[Path], models_dir: Path | None, label: str) -> dict[str, dict]:
    command = [str(cli), "transcribe", "--json", "--no-download"]
    if models_dir:
        command += ["--models-dir", str(models_dir)]
    command += [str(p) for p in media]
    print(f"Transcribing {len(media)} file(s) with {label}...", file=sys.stderr)
    env = {**os.environ, "TRANSCRIPTED_DISABLE_FILE_LOGGER": "1"}
    result = subprocess.run(command, capture_output=True, text=True, env=env)
    if result.returncode != 0:
        sys.exit(f"{label} failed:\n{result.stderr.strip()}")
    decoded = json.loads(result.stdout)
    outputs = decoded if isinstance(decoded, list) else [decoded]
    return {Path(o["file"]).resolve().as_posix(): o for o in outputs}


def pct(value: float | None) -> str:
    return "n/a" if value is None else f"{value * 100:.1f}%"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("inputs", nargs="+", type=Path, help="Audio/video files or folders of them")
    parser.add_argument("--references", type=Path, help="Folder of <name>.txt reference transcripts")
    parser.add_argument("--ultra-dir", type=Path, default=DEFAULT_ULTRA_DIR)
    parser.add_argument("--v3-dir", type=Path, help="Staged Parakeet V3 folder (default: the one Transcripted uses)")
    parser.add_argument("--cli", help="Path to transcripted-cli")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    media = find_media(args.inputs)
    cli = resolve_cli(args.cli)
    ultra_marker = args.ultra_dir / MARKER
    if not ultra_marker.is_file():
        sys.exit(f"Parakeet Ultra isn't installed at {args.ultra_dir}. Run scripts/models/parakeet-ultra/install.sh first.")
    ultra_info = json.loads(ultra_marker.read_text())

    v3 = transcribe(cli, media, args.v3_dir, "Parakeet V3")
    ultra = transcribe(cli, media, args.ultra_dir, "Parakeet Ultra")
    if not ultra_marker.is_file():
        # An older CLI lets FluidAudio swap an unloadable folder for stock v3.
        sys.exit("Parakeet Ultra failed to load and was replaced by stock V3, so these results would be V3 twice. Reinstall Ultra.")

    rows = []
    totals = {"ref_words": 0, "v3_errors": 0, "ultra_errors": 0, "audio_seconds": 0.0,
              "v3_seconds": 0.0, "ultra_seconds": 0.0, "compared_words": 0, "disagreements": 0}
    for path in media:
        key = path.as_posix()
        if key not in v3 or key not in ultra:
            sys.exit(f"The CLI returned no transcript for {path.name}.")
        v3_words, ultra_words = normalize(v3[key]["text"]), normalize(ultra[key]["text"])
        reference = find_reference(path, args.references)
        row = {
            "file": path.name,
            "audio_seconds": v3[key]["durationSeconds"],
            "v3_seconds": v3[key]["processingSeconds"],
            "ultra_seconds": ultra[key]["processingSeconds"],
            "disagreement": edit_distance(v3_words, ultra_words) / max(1, len(v3_words)),
            "reference": reference.name if reference else None,
            "v3_wer": None,
            "ultra_wer": None,
            "spots": differences(v3_words, ultra_words),
        }
        totals["audio_seconds"] += row["audio_seconds"]
        totals["v3_seconds"] += row["v3_seconds"]
        totals["ultra_seconds"] += row["ultra_seconds"]
        totals["compared_words"] += len(v3_words)
        totals["disagreements"] += edit_distance(v3_words, ultra_words)
        if reference:
            ref_words = normalize(reference.read_text())
            v3_errors, ultra_errors = edit_distance(ref_words, v3_words), edit_distance(ref_words, ultra_words)
            row["v3_wer"] = v3_errors / max(1, len(ref_words))
            row["ultra_wer"] = ultra_errors / max(1, len(ref_words))
            totals["ref_words"] += len(ref_words)
            totals["v3_errors"] += v3_errors
            totals["ultra_errors"] += ultra_errors
        rows.append(row)

    scored = [r for r in rows if r["reference"]]
    v3_wer = totals["v3_errors"] / totals["ref_words"] if totals["ref_words"] else None
    ultra_wer = totals["ultra_errors"] / totals["ref_words"] if totals["ref_words"] else None
    if v3_wer is None:
        verdict = ("No reference transcripts, so there is no winner yet. The two models disagree on "
                   f"{pct(totals['disagreements'] / max(1, totals['compared_words']))} of words; "
                   "read the differences below and judge which side is right.")
    elif ultra_wer < v3_wer:
        verdict = (f"Ultra made {(1 - ultra_wer / v3_wer) * 100 if v3_wer else 0:.0f}% fewer word mistakes "
                   f"({pct(ultra_wer)} vs {pct(v3_wer)} word error rate) on {len(scored)} checked file(s).")
    elif ultra_wer > v3_wer:
        verdict = (f"Ultra made more word mistakes than V3 ({pct(ultra_wer)} vs {pct(v3_wer)} word error rate) "
                   f"on {len(scored)} checked file(s).")
    else:
        verdict = f"Tie: both models scored {pct(v3_wer)} word error rate on {len(scored)} checked file(s)."

    out = args.out or Path.home() / "Desktop" / f"parakeet-ultra-vs-v3-{datetime.now():%Y%m%d-%H%M%S}"
    out.mkdir(parents=True, exist_ok=True)
    for label, results in (("v3", v3), ("ultra", ultra)):
        folder = out / label
        folder.mkdir(exist_ok=True)
        for path in media:
            (folder / f"{path.stem}.txt").write_text(results[path.as_posix()]["text"].strip() + "\n")

    def speed(seconds: float) -> str:
        return f"{totals['audio_seconds'] / seconds:.0f}x real time" if seconds else "n/a"

    lines = [
        "# Parakeet Ultra vs Parakeet V3",
        "",
        verdict,
        "",
        f"Speed: V3 {speed(totals['v3_seconds'])}, Ultra {speed(totals['ultra_seconds'])} "
        f"over {totals['audio_seconds'] / 60:.1f} min of audio.",
        f"Ultra build: {ultra_info.get('model', '?')} @ {str(ultra_info.get('revision', '?'))[:12]}, "
        f"encoder {ultra_info.get('encoder', '?')}.",
        "",
        "| File | V3 errors | Ultra errors | Words that differ |",
        "|---|---:|---:|---:|",
    ]
    for r in rows:
        lines.append(f"| {r['file']} | {pct(r['v3_wer'])} | {pct(r['ultra_wer'])} | {pct(r['disagreement'])} |")
    lines += ["", "## Where they differ", "", "Brackets mark the words that changed: V3 first, then Ultra.", ""]
    for r in rows:
        if not r["spots"]:
            continue
        lines += [f"### {r['file']}", ""]
        for left, right in r["spots"]:
            lines += [f"- V3: {left}", f"  Ultra: {right}"]
        lines.append("")
    lines += [
        "Transcripts: v3/ and ultra/ in this folder.",
        "Parakeet Ultra by Moondream (M87 Labs), CC-BY-4.0; based on NVIDIA parakeet-tdt-0.6b-v3.",
    ]
    (out / "report.md").write_text("\n".join(lines) + "\n")
    (out / "report.json").write_text(json.dumps({
        "verdict": verdict,
        "v3_wer": v3_wer,
        "ultra_wer": ultra_wer,
        "totals": totals,
        "ultra_build": ultra_info,
        "files": [{k: v for k, v in r.items() if k != "spots"} for r in rows],
    }, indent=2) + "\n")

    print(verdict)
    print(f"Report: {out / 'report.md'}")


if __name__ == "__main__":
    main()

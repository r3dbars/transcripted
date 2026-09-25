#!/usr/bin/env python3
"""Build the Mac-local items file for the `meeting-corpus` hill-climb suite.

    # from the private Zoom corpus that scripts/ops/validate-meeting-corpus.py reads
    python3 scripts/hillclimb/benches/make_meeting_suite.py --corpus-root ~/Downloads/meeting-corpus
    python3 scripts/hillclimb/benches/make_meeting_suite.py --corpus-root ~/Downloads/meeting-corpus \\
        --ids meeting-0024,meeting-0025 --track system

    # from any folder of audio files, with optional same-stem .txt truth
    python3 scripts/hillclimb/benches/make_meeting_suite.py --folder ~/Desktop/test-calls

The suite file config/hillclimb/suites/meeting-corpus.json is in git and holds
the salt and holdout rule; the item list (absolute audio paths on this Mac)
must never be committed, so it goes to the suite's `items_file` under
~/Library/Application Support/Transcripted Lab/HillClimb/suites/.

Item ids decide the dev/holdout split, so they must never change when files
move: corpus items use the manifest id (meeting-0024), folder items use
clip-<first 12 hex of the audio's sha256>. Each item is
{"id", "audio", "truth"?, "speakers"?, "duration_s"?}. duration_s is measured
once here (ffprobe/afinfo, then the wave module) so every trial divides by
the same number.

Nothing here prints transcript text or speaker names.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Mapping

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from meeting_import import load_ops_module, probe_duration, resolve_path, sha256_file  # noqa: E402

SUITE_FILE = HERE.parents[2] / "config" / "hillclimb" / "suites" / "meeting-corpus.json"
ITEMS_SCHEMA = "transcripted.hillclimb.items.v1"
AUDIO_EXTENSIONS = {".wav", ".m4a", ".mp3", ".aiff", ".aif", ".caf", ".flac", ".mp4", ".mov", ".m4v"}
# Preferred corpus track labels, most useful first: import-audio takes one file,
# and a mixed/meeting track carries every speaker. Substring, case-insensitive.
TRACK_PREFERENCE = ("mix", "combined", "meeting", "zoom", "system", "remote", "audio")


def default_items_path() -> Path:
    return resolve_path(json.loads(SUITE_FILE.read_text())["items_file"])


def zoom_speaker_count(path: Path) -> int | None:
    parsed = load_ops_module("compare-meeting-corpus").parse_zoom(path)
    return parsed["speaker_count"] if parsed["turn_count"] > 0 else None


def choose_track(tracks: Mapping[str, Path], wanted: str | None) -> tuple[str, Path] | None:
    """Pick one present audio track: --track if given, else the only one, else by preference."""
    present = {label: path for label, path in tracks.items() if path.is_file()}
    if wanted is not None:
        return (wanted, present[wanted]) if wanted in present else None
    if len(present) == 1:
        return next(iter(present.items()))
    for hint in TRACK_PREFERENCE:
        for label in sorted(present):
            if hint in label.lower():
                return label, present[label]
    if present:
        label = max(sorted(present), key=lambda name: present[name].stat().st_size)
        return label, present[label]
    return None


def item_for(item_id: str, audio: Path, truth: Path | None, speakers: int | None,
             fallback_duration: float | None = None) -> dict[str, Any]:
    item: dict[str, Any] = {"id": item_id, "audio": str(audio.resolve())}
    if truth is not None and truth.is_file():
        item["truth"] = str(truth.resolve())
    if speakers is not None and speakers > 0:
        item["speakers"] = int(speakers)
    duration = probe_duration(audio) or fallback_duration
    if duration:
        item["duration_s"] = round(float(duration), 3)
    return item


def items_from_corpus(root: Path, ids: list[str] | None, track: str | None) -> tuple[list[dict[str, Any]], list[str]]:
    """Items from root/manifest.json in the layout validate-meeting-corpus.py reads."""
    validate = load_ops_module("validate-meeting-corpus")
    manifest = validate.load_manifest(root)
    if ids:
        by_id = {entry["id"]: entry for entry in manifest}
        missing = [meeting_id for meeting_id in ids if meeting_id not in by_id]
        if missing:
            raise ValueError(f"meeting ids not in manifest: {', '.join(missing)}")
        manifest = [by_id[meeting_id] for meeting_id in ids]
    items, skipped = [], []
    for entry in manifest:
        meeting_id = str(entry["id"])
        meeting_dir = root / meeting_id
        tracks = {label: meeting_dir / str(info.get("path", "")) for label, info in (entry.get("audio") or {}).items()}
        chosen = choose_track(tracks, track)
        if chosen is None:
            skipped.append(f"{meeting_id}: no usable audio track (labels: {', '.join(sorted(tracks)) or 'none'})")
            continue
        transcript_info = entry.get("zoom_transcript") or {}
        truth = meeting_dir / str(transcript_info["path"]) if transcript_info.get("path") else None
        names = entry.get("speaker_names") or []
        speakers = len(names) if names else (zoom_speaker_count(truth) if truth and truth.is_file() else None)
        # The manifest duration is the meeting's; only trust it when there is one track.
        fallback = entry.get("duration_seconds") if len(tracks) == 1 else None
        items.append(item_for(meeting_id, chosen[1], truth, speakers, fallback))
    return items, skipped


def items_from_folder(folder: Path) -> tuple[list[dict[str, Any]], list[str]]:
    """Items from every audio/video file under folder; a same-stem .txt is truth."""
    items, skipped, seen = [], [], {}
    for audio in sorted(folder.rglob("*")):
        if audio.suffix.lower() not in AUDIO_EXTENSIONS or not audio.is_file():
            continue
        if any(part.startswith(".") for part in audio.relative_to(folder).parts):
            continue
        item_id = "clip-" + sha256_file(audio)[:12]
        if item_id in seen:
            skipped.append(f"{item_id}: duplicate audio content, kept the first copy")
            continue
        seen[item_id] = audio
        truth = audio.with_suffix(".txt")
        speakers = zoom_speaker_count(truth) if truth.is_file() else None
        items.append(item_for(item_id, audio, truth, speakers))
    return items, skipped


def write_items(path: Path, items: list[dict[str, Any]], source: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema": ITEMS_SCHEMA,
        "suite": "meeting-corpus",
        "source": source,
        "notes": "Local-only. Holds absolute paths to private audio; never commit this file.",
        "items": sorted(items, key=lambda item: item["id"]),
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def summary(items: list[dict[str, Any]]) -> str:
    with_truth = sum(1 for item in items if "truth" in item)
    with_speakers = sum(1 for item in items if "speakers" in item)
    with_duration = sum(1 for item in items if "duration_s" in item)
    return (f"{len(items)} items: {with_truth} with truth, {with_speakers} with speaker counts, "
            f"{with_duration} with measured duration")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--corpus-root", help="corpus folder with manifest.json (validate-meeting-corpus.py layout)")
    source.add_argument("--folder", help="plain folder of audio files with optional same-stem .txt truth")
    parser.add_argument("--ids", default="", help="corpus mode: comma-separated meeting ids (default: all)")
    parser.add_argument("--track", default=None, help="corpus mode: audio track label to import (default: auto)")
    parser.add_argument("--out", default=None, help="items file (default: the suite's items_file)")
    parser.add_argument("--dry-run", action="store_true", help="print the summary without writing")
    args = parser.parse_args(argv)

    try:
        if args.corpus_root:
            root = Path(args.corpus_root).expanduser().resolve()
            ids = [part.strip() for part in args.ids.split(",") if part.strip()] or None
            items, skipped = items_from_corpus(root, ids, args.track)
            kind = "corpus-manifest"
        else:
            items, skipped = items_from_folder(Path(args.folder).expanduser().resolve())
            kind = "folder"
    except (OSError, ValueError, KeyError) as error:
        print(f"make_meeting_suite: {error}", file=sys.stderr)
        return 1
    for line in skipped:
        print(f"skipped {line}", file=sys.stderr)
    if not items:
        print("make_meeting_suite: no usable items found", file=sys.stderr)
        return 1
    print(summary(items))
    missing_duration = [item["id"] for item in items if "duration_s" not in item]
    if missing_duration:
        print(f"warning: no duration for {', '.join(missing_duration)}; the bench will fall back to "
              "transcript frontmatter (whole seconds)", file=sys.stderr)
    if args.dry_run:
        return 0
    out = Path(args.out).expanduser() if args.out else default_items_path()
    write_items(out, items, kind)
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

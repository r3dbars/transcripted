#!/usr/bin/env python3
"""Validate a local Transcripted meeting corpus without exposing transcript text."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_ROOT = Path.home() / "Downloads" / "meeting-corpus"
DEFAULT_IDS = ["meeting-0024", "meeting-0025", "meeting-0004", "meeting-0003"]
ZOOM_LINE_RE = re.compile(r"^\[(?P<speaker>[^\]]+)\]\s+(?P<time>\d{1,2}:\d{2}:\d{2})\s+(?P<text>.*)$")


@dataclass
class Check:
    status: str
    check: str
    target: str
    detail: str = ""


def sha256(path: Path, chunk_size: int = 4 * 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(chunk_size)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def duration_seconds(path: Path) -> float | None:
    commands = [
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=nw=1:nk=1",
            str(path),
        ],
        ["/usr/bin/afinfo", str(path)],
    ]

    for command in commands:
        try:
            output = subprocess.check_output(command, text=True, stderr=subprocess.DEVNULL, timeout=30)
        except Exception:
            continue

        if command[0].endswith("ffprobe"):
            try:
                return float(output.strip())
            except ValueError:
                continue

        match = re.search(r"estimated duration:\s*([0-9.]+)\s*sec", output)
        if match:
            return float(match.group(1))

    return None


def parse_zoom_transcript(path: Path) -> dict[str, Any]:
    speakers: dict[str, int] = {}
    turn_count = 0
    word_count = 0
    timestamp_count = 0
    active_speaker: str | None = None

    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if not stripped:
            continue

        match = ZOOM_LINE_RE.match(stripped)
        if match:
            speaker = match.group("speaker").strip()
            text = match.group("text").strip()
            speakers[speaker] = speakers.get(speaker, 0) + 1
            turn_count += 1
            timestamp_count += 1
            word_count += len(re.findall(r"\b[\w']+\b", text))
            active_speaker = None
            continue

        speaker_only_match = re.match(r"^\[(?P<speaker>[^\]]+)\]\s+(?P<time>\d{1,2}:\d{2}:\d{2})$", stripped)
        if speaker_only_match:
            speaker = speaker_only_match.group("speaker").strip()
            speakers[speaker] = speakers.get(speaker, 0) + 1
            turn_count += 1
            timestamp_count += 1
            active_speaker = speaker
            continue

        if active_speaker:
            word_count += len(re.findall(r"\b[\w']+\b", stripped))
            continue

    return {
        "speaker_count": len(speakers),
        "turn_count": turn_count,
        "word_count": word_count,
        "timestamp_count": timestamp_count,
        "speaker_hashes": [hashlib.sha256(name.encode("utf-8")).hexdigest()[:12] for name in sorted(speakers)],
        "private_speaker_names": sorted(speakers),
    }


def status_rank(status: str) -> int:
    return {"FAIL": 0, "WARN": 1, "PASS": 2}.get(status, 3)


def load_manifest(root: Path) -> list[dict[str, Any]]:
    manifest_path = root / "manifest.json"
    return json.loads(manifest_path.read_text(encoding="utf-8"))


def select_meetings(manifest: list[dict[str, Any]], ids: list[str] | None) -> list[dict[str, Any]]:
    by_id = {entry["id"]: entry for entry in manifest}
    if ids:
        missing = [mid for mid in ids if mid not in by_id]
        if missing:
            raise ValueError(f"Requested meeting ids not found in manifest: {', '.join(missing)}")
        return [by_id[mid] for mid in ids]

    selected = [by_id[mid] for mid in DEFAULT_IDS if mid in by_id]
    if selected:
        return selected
    return manifest[: min(4, len(manifest))]


def validate_meeting(root: Path, entry: dict[str, Any], verify_hashes: bool) -> tuple[list[Check], dict[str, Any]]:
    checks: list[Check] = []
    meeting_id = entry["id"]
    meeting_dir = root / meeting_id
    metadata_path = meeting_dir / "metadata.json"

    summary: dict[str, Any] = {
        "id": meeting_id,
        "date": entry.get("date"),
        "duration_seconds": entry.get("duration_seconds"),
        "expected_speaker_count": len(entry.get("speaker_names") or []),
        "expected_turn_count": entry.get("speaker_turn_count"),
        "audio_tracks": [],
        "transcript": None,
        "available_for_audio_eval": False,
        "available_for_transcript_eval": False,
    }

    if meeting_dir.is_dir():
        checks.append(Check("PASS", "corpus/meeting-dir", meeting_id))
    else:
        checks.append(Check("FAIL", "corpus/meeting-dir", meeting_id, "meeting folder missing"))
        return checks, summary

    if metadata_path.is_file():
        checks.append(Check("PASS", "corpus/metadata", meeting_id))
    else:
        checks.append(Check("WARN", "corpus/metadata", meeting_id, "metadata.json missing"))

    available_tracks = 0
    expected_audio = entry.get("audio") or {}
    for label, audio_info in expected_audio.items():
        relative_path = Path(audio_info.get("path", ""))
        audio_path = meeting_dir / relative_path
        track_summary = {
            "label": label,
            "present": audio_path.is_file(),
            "size_bytes": audio_path.stat().st_size if audio_path.is_file() else 0,
            "duration_seconds": None,
        }

        if not audio_path.is_file():
            checks.append(Check("WARN", "corpus/audio-present", f"{meeting_id}:{label}", f"missing {relative_path}"))
            summary["audio_tracks"].append(track_summary)
            continue

        available_tracks += 1
        checks.append(Check("PASS", "corpus/audio-present", f"{meeting_id}:{label}"))

        audio_duration = duration_seconds(audio_path)
        track_summary["duration_seconds"] = audio_duration
        if audio_duration and audio_duration > 30:
            checks.append(Check("PASS", "corpus/audio-duration", f"{meeting_id}:{label}", f"{audio_duration:.1f}s"))
        else:
            checks.append(Check("FAIL", "corpus/audio-duration", f"{meeting_id}:{label}", "duration missing or too short"))

        if verify_hashes:
            expected_hash = audio_info.get("sha256")
            actual_hash = sha256(audio_path)
            if expected_hash and actual_hash == expected_hash:
                checks.append(Check("PASS", "corpus/audio-hash", f"{meeting_id}:{label}"))
            else:
                checks.append(Check("FAIL", "corpus/audio-hash", f"{meeting_id}:{label}", "sha256 mismatch"))

        summary["audio_tracks"].append(track_summary)

    summary["available_for_audio_eval"] = available_tracks >= 2
    if summary["available_for_audio_eval"]:
        checks.append(Check("PASS", "corpus/audio-pair", meeting_id))
    elif available_tracks > 0:
        checks.append(Check("WARN", "corpus/audio-pair", meeting_id, "only one expected audio track is present"))
    else:
        checks.append(Check("WARN", "corpus/audio-pair", meeting_id, "no local audio tracks present"))

    transcript_info = entry.get("zoom_transcript") or {}
    transcript_path = meeting_dir / transcript_info.get("path", "")
    if transcript_path.is_file():
        checks.append(Check("PASS", "corpus/zoom-transcript", meeting_id))
        parsed = parse_zoom_transcript(transcript_path)
        private_speaker_names = set(parsed.pop("private_speaker_names", []))
        summary["transcript"] = parsed
        summary["available_for_transcript_eval"] = parsed["turn_count"] > 0
        if parsed["turn_count"] > 0:
            checks.append(Check("PASS", "corpus/zoom-turns", meeting_id, f"{parsed['turn_count']} turns"))
        else:
            checks.append(Check("FAIL", "corpus/zoom-turns", meeting_id, "no parseable Zoom caption turns"))
        if parsed["speaker_count"] >= 2:
            checks.append(Check("PASS", "corpus/zoom-speakers", meeting_id, f"{parsed['speaker_count']} speakers"))
        else:
            checks.append(Check("WARN", "corpus/zoom-speakers", meeting_id, "fewer than two parsed speakers"))

        expected_speakers = set(entry.get("speaker_names") or [])
        if expected_speakers and private_speaker_names == expected_speakers:
            checks.append(Check("PASS", "corpus/zoom-speaker-ground-truth", meeting_id))
        elif expected_speakers:
            checks.append(Check(
                "WARN",
                "corpus/zoom-speaker-ground-truth",
                meeting_id,
                f"parsed {len(private_speaker_names)} speakers; manifest has {len(expected_speakers)}",
            ))
        if verify_hashes:
            expected_hash = transcript_info.get("sha256")
            actual_hash = sha256(transcript_path)
            if expected_hash and actual_hash == expected_hash:
                checks.append(Check("PASS", "corpus/zoom-hash", meeting_id))
            else:
                checks.append(Check("FAIL", "corpus/zoom-hash", meeting_id, "sha256 mismatch"))
    else:
        checks.append(Check("FAIL", "corpus/zoom-transcript", meeting_id, "Zoom transcript missing"))

    return checks, summary


def write_markdown(path: Path, root: Path, selected: list[dict[str, Any]], checks: list[Check], summaries: list[dict[str, Any]]) -> None:
    passed = sum(1 for check in checks if check.status == "PASS")
    warned = sum(1 for check in checks if check.status == "WARN")
    failed = sum(1 for check in checks if check.status == "FAIL")
    verdict = "FAIL" if failed else "INCOMPLETE" if warned else "PASS"

    lines = [
        "# Transcripted Meeting Corpus QA",
        "",
        f"- Verdict: {verdict}",
        f"- Corpus root: `{root}`",
        f"- Selected meetings: {len(selected)}",
        f"- Passed: {passed}",
        f"- Warnings: {warned}",
        f"- Failed: {failed}",
        "",
        "Raw transcript text and speaker names are intentionally omitted.",
        "",
        "## Selected Meetings",
        "",
        "| Meeting | Audio | Transcript turns | Speakers | Eval use |",
        "| --- | ---: | ---: | ---: | --- |",
    ]

    for summary in summaries:
        audio_count = sum(1 for track in summary["audio_tracks"] if track["present"])
        transcript = summary["transcript"] or {}
        eval_use = []
        if summary["available_for_audio_eval"]:
            eval_use.append("audio")
        if summary["available_for_transcript_eval"]:
            eval_use.append("transcript")
        lines.append(
            "| `{id}` | {audio} | {turns} | {speakers} | {eval_use} |".format(
                id=summary["id"],
                audio=audio_count,
                turns=transcript.get("turn_count", 0),
                speakers=transcript.get("speaker_count", 0),
                eval_use=", ".join(eval_use) if eval_use else "metadata only",
            )
        )

    lines.extend([
        "",
        "## Checks",
        "",
        "| Status | Check | Target | Detail |",
        "| --- | --- | --- | --- |",
    ])
    for check in sorted(checks, key=lambda item: (status_rank(item.status), item.check, item.target)):
        detail = check.detail.replace("|", "\\|")
        lines.append(f"| {check.status} | `{check.check}` | `{check.target}` | {detail} |")

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus-root", default=str(DEFAULT_ROOT))
    parser.add_argument("--ids", default="", help="Comma-separated meeting ids. Defaults to a small representative subset.")
    parser.add_argument("--json-out", required=True)
    parser.add_argument("--markdown-out", required=True)
    parser.add_argument("--subset-out", default="")
    parser.add_argument("--verify-hashes", action="store_true")
    args = parser.parse_args()

    root = Path(args.corpus_root).expanduser().resolve()
    if not root.exists():
        print(f"Corpus root not found: {root}", file=sys.stderr)
        return 1

    manifest = load_manifest(root)
    requested_ids = [part.strip() for part in args.ids.split(",") if part.strip()] or None
    try:
        selected = select_meetings(manifest, requested_ids)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1

    all_checks: list[Check] = []
    summaries: list[dict[str, Any]] = []
    for entry in selected:
        checks, summary = validate_meeting(root, entry, verify_hashes=args.verify_hashes)
        all_checks.extend(checks)
        summaries.append(summary)

    payload = {
        "corpusRoot": str(root),
        "selectedMeetingIds": [entry["id"] for entry in selected],
        "summary": {
            "passed": sum(1 for check in all_checks if check.status == "PASS"),
            "warnings": sum(1 for check in all_checks if check.status == "WARN"),
            "failed": sum(1 for check in all_checks if check.status == "FAIL"),
        },
        "meetings": summaries,
        "checks": [check.__dict__ for check in all_checks],
    }

    json_path = Path(args.json_out)
    markdown_path = Path(args.markdown_out)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    markdown_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    write_markdown(markdown_path, root, selected, all_checks, summaries)

    if args.subset_out:
        subset_path = Path(args.subset_out).expanduser()
        subset_path.parent.mkdir(parents=True, exist_ok=True)
        subset_payload = {
            "corpusRoot": str(root),
            "meetingIds": [entry["id"] for entry in selected],
            "notes": "Local-only Transcripted QA subset. Do not commit meeting audio or transcripts.",
        }
        subset_path.write_text(json.dumps(subset_payload, indent=2, sort_keys=True), encoding="utf-8")

    failed = payload["summary"]["failed"]
    warnings = payload["summary"]["warnings"]
    print(f"Corpus meetings: {len(selected)}   Failures: {failed}   Warnings: {warnings}")
    print(f"Report: {markdown_path}")
    if failed:
        return 1
    if warnings:
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

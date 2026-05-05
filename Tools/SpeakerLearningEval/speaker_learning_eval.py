#!/usr/bin/env python3
"""Cold-start speaker-learning scoreboard for the local meeting corpus.

The harness treats Zoom speaker labels as ground truth. It intentionally does
not print or persist transcript utterance text; body lines are used only to
identify turn boundaries and are then discarded.
"""

from __future__ import annotations

import argparse
import json
import re
import time
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from statistics import median
from typing import Any, Iterable


DEFAULT_CORPUS = Path("/Users/redbars/Downloads/meeting-corpus")
ZOOM_LABEL_LINE = re.compile(r"^\[(?P<label>[^\]]+)\]\s+\d{1,2}:\d{2}:\d{2}(?:\.\d+)?\s*$")


@dataclass(frozen=True)
class ZoomTurn:
    speaker_label: str


@dataclass
class SpeakerProfileState:
    speaker_id: str
    canonical_label: str
    first_seen_meeting_id: str
    first_seen_ordinal: int
    first_recognition_meeting_id: str | None = None
    first_recognition_ordinal: int | None = None
    meetings_seen: set[str] = field(default_factory=set)
    raw_labels: set[str] = field(default_factory=set)
    turn_count: int = 0

    @property
    def duplicate_profiles(self) -> int:
        # This first baseline creates one profile per normalized real speaker.
        return 0


def normalize_speaker_label(label: str) -> str:
    folded = unicodedata.normalize("NFKD", label)
    ascii_label = folded.encode("ascii", "ignore").decode("ascii")
    ascii_label = ascii_label.lower()
    ascii_label = re.sub(r"\([^)]*\)", " ", ascii_label)
    ascii_label = re.sub(r"[^a-z0-9]+", " ", ascii_label)
    return re.sub(r"\s+", " ", ascii_label).strip()


def parse_zoom_turns(transcript_path: Path) -> list[ZoomTurn]:
    raw = transcript_path.read_text(encoding="utf-8", errors="replace")
    turns: list[ZoomTurn] = []
    for block in re.split(r"\n\s*\n", raw):
        lines = [line.strip() for line in block.splitlines() if line.strip()]
        if len(lines) < 2:
            continue
        speaker_label = extract_speaker_label(lines[0])
        if _looks_like_non_speaker_header(speaker_label):
            continue
        turns.append(ZoomTurn(speaker_label=speaker_label))
    return turns


def extract_speaker_label(line: str) -> str:
    match = ZOOM_LABEL_LINE.match(line.strip())
    if match:
        return match.group("label").strip()
    return line.strip()


def _looks_like_non_speaker_header(value: str) -> bool:
    lowered = value.strip().lower()
    if lowered in {"webvtt", "kind: captions", "language: en"}:
        return True
    if "-->" in lowered:
        return True
    return False


def load_manifest(corpus_root: Path) -> list[dict[str, Any]]:
    manifest_path = corpus_root / "manifest.json"
    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        raise ValueError(f"Expected {manifest_path} to contain a list")
    return data


def evaluate_corpus(
    corpus_root: Path,
    limit: int | None = None,
    include_speaker_labels: bool = False,
) -> dict[str, Any]:
    start = time.perf_counter()
    meetings = [meeting for meeting in load_manifest(corpus_root) if meeting.get("usable_for_eval", True)]
    meetings.sort(key=lambda item: (item.get("start_local", ""), item.get("id", "")))
    if limit is not None:
        meetings = meetings[:limit]

    profiles: dict[str, SpeakerProfileState] = {}
    unknown_labels_required = 0
    correct_automatic_matches = 0
    false_matches = 0
    unknown_turns = 0
    correct_match_turns = 0
    total_turns = 0
    parser_mismatches: list[dict[str, Any]] = []
    meeting_results: list[dict[str, Any]] = []

    for ordinal, meeting in enumerate(meetings, start=1):
        meeting_id = str(meeting["id"])
        transcript_rel_path = meeting["zoom_transcript"]["path"]
        transcript_path = corpus_root / meeting_id / transcript_rel_path
        turns = parse_zoom_turns(transcript_path)
        total_turns += len(turns)

        expected_turns = int(meeting.get("speaker_turn_count", 0) or 0)
        expected_speakers = {
            normalize_speaker_label(label)
            for label in meeting.get("speaker_names", [])
            if normalize_speaker_label(label)
        }
        parsed_speakers = {
            normalize_speaker_label(turn.speaker_label)
            for turn in turns
            if normalize_speaker_label(turn.speaker_label)
        }

        if expected_turns != len(turns) or expected_speakers != parsed_speakers:
            parser_mismatches.append(
                {
                    "meeting_id": meeting_id,
                    "expected_turn_count": expected_turns,
                    "parsed_turn_count": len(turns),
                    "expected_speaker_count": len(expected_speakers),
                    "parsed_speaker_count": len(parsed_speakers),
                }
            )

        turn_count_by_speaker: dict[str, int] = {}
        raw_labels_by_speaker: dict[str, set[str]] = {}
        for turn in turns:
            canonical = normalize_speaker_label(turn.speaker_label)
            if not canonical:
                continue
            turn_count_by_speaker[canonical] = turn_count_by_speaker.get(canonical, 0) + 1
            raw_labels_by_speaker.setdefault(canonical, set()).add(turn.speaker_label)

        meeting_unknown = 0
        meeting_correct = 0
        meeting_unknown_turns = 0
        meeting_correct_turns = 0

        for canonical in _stable_speaker_order(turns):
            turns_for_speaker = turn_count_by_speaker.get(canonical, 0)
            raw_labels = raw_labels_by_speaker.get(canonical, set())
            if canonical in profiles:
                profile = profiles[canonical]
                correct_automatic_matches += 1
                meeting_correct += 1
                correct_match_turns += turns_for_speaker
                meeting_correct_turns += turns_for_speaker
                if profile.first_recognition_meeting_id is None:
                    profile.first_recognition_meeting_id = meeting_id
                    profile.first_recognition_ordinal = ordinal
            else:
                speaker_id = f"speaker_{len(profiles) + 1:04d}"
                profiles[canonical] = SpeakerProfileState(
                    speaker_id=speaker_id,
                    canonical_label=canonical,
                    first_seen_meeting_id=meeting_id,
                    first_seen_ordinal=ordinal,
                )
                unknown_labels_required += 1
                meeting_unknown += 1
                unknown_turns += turns_for_speaker
                meeting_unknown_turns += turns_for_speaker

            profile = profiles[canonical]
            profile.meetings_seen.add(meeting_id)
            profile.raw_labels.update(raw_labels)
            profile.turn_count += turns_for_speaker

        meeting_results.append(
            {
                "meeting_id": meeting_id,
                "ordinal": ordinal,
                "speaker_count": len(turn_count_by_speaker),
                "turn_count": len(turns),
                "unknown_labels_required": meeting_unknown,
                "correct_automatic_matches": meeting_correct,
                "false_matches": 0,
                "unknown_turns": meeting_unknown_turns,
                "correct_automatic_match_turns": meeting_correct_turns,
            }
        )

    per_speaker = [
        _speaker_report(profile, include_speaker_labels=include_speaker_labels)
        for profile in profiles.values()
    ]
    per_speaker.sort(key=lambda item: item["speaker_id"])

    recognized_gaps = [
        item["meetings_to_first_recognition"]
        for item in per_speaker
        if item["meetings_to_first_recognition"] is not None
    ]
    duplicate_profile_counts = [item["duplicate_profiles"] for item in per_speaker]
    elapsed = time.perf_counter() - start

    report = {
        "schema_version": 1,
        "corpus_root": str(corpus_root),
        "assumptions": {
            "ground_truth": "Zoom transcript speaker labels",
            "baseline": "cold_start_label_carry_forward",
            "threshold_tuning": "not_performed",
            "automatic_match_definition": (
                "A speaker is an automatic match only after the same normalized "
                "Zoom speaker label was manually labeled in an earlier meeting."
            ),
            "transcript_text_policy": "utterance text is used only for turn boundaries and is never printed or persisted",
            "speaker_labels_redacted": not include_speaker_labels,
        },
        "summary": {
            "meetings_evaluated": len(meetings),
            "distinct_real_speakers": len(profiles),
            "speaker_meeting_instances": unknown_labels_required + correct_automatic_matches,
            "unknown_labels_required": unknown_labels_required,
            "correct_automatic_matches": correct_automatic_matches,
            "false_matches": false_matches,
            "duplicate_profiles_per_real_speaker": {
                "total": sum(duplicate_profile_counts),
                "max": max(duplicate_profile_counts, default=0),
                "speakers_affected": sum(1 for count in duplicate_profile_counts if count > 0),
            },
            "turns": {
                "zoom_turns": total_turns,
                "unknown_turns": unknown_turns,
                "correct_automatic_match_turns": correct_match_turns,
            },
            "meetings_to_first_recognition": _recognition_summary(per_speaker, recognized_gaps),
            "runtime_seconds": round(elapsed, 4),
            "parser_mismatch_count": len(parser_mismatches),
        },
        "meetings": meeting_results,
        "speakers": per_speaker,
        "top_failure_cases": _top_failure_cases(
            meeting_results=meeting_results,
            per_speaker=per_speaker,
            parser_mismatches=parser_mismatches,
            include_speaker_labels=include_speaker_labels,
        ),
    }
    return report


def _stable_speaker_order(turns: Iterable[ZoomTurn]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for turn in turns:
        canonical = normalize_speaker_label(turn.speaker_label)
        if canonical and canonical not in seen:
            seen.add(canonical)
            ordered.append(canonical)
    return ordered


def _speaker_report(profile: SpeakerProfileState, include_speaker_labels: bool) -> dict[str, Any]:
    meetings_to_first_recognition: int | None = None
    if profile.first_recognition_ordinal is not None:
        meetings_to_first_recognition = profile.first_recognition_ordinal - profile.first_seen_ordinal

    report: dict[str, Any] = {
        "speaker_id": profile.speaker_id,
        "meeting_count": len(profile.meetings_seen),
        "turn_count": profile.turn_count,
        "first_seen_meeting_id": profile.first_seen_meeting_id,
        "first_recognition_meeting_id": profile.first_recognition_meeting_id,
        "meetings_to_first_recognition": meetings_to_first_recognition,
        "duplicate_profiles": profile.duplicate_profiles,
        "raw_label_variant_count": len(profile.raw_labels),
    }
    if include_speaker_labels:
        report["canonical_label"] = profile.canonical_label
        report["raw_labels"] = sorted(profile.raw_labels)
    return report


def _recognition_summary(per_speaker: list[dict[str, Any]], gaps: list[int]) -> dict[str, Any]:
    never_recognized = [
        speaker for speaker in per_speaker
        if speaker["first_recognition_meeting_id"] is None
    ]
    return {
        "recognized_speakers": len(gaps),
        "never_recognized_speakers": len(never_recognized),
        "median_meetings_after_first_seen": median(gaps) if gaps else None,
        "max_meetings_after_first_seen": max(gaps) if gaps else None,
    }


def _top_failure_cases(
    meeting_results: list[dict[str, Any]],
    per_speaker: list[dict[str, Any]],
    parser_mismatches: list[dict[str, Any]],
    include_speaker_labels: bool,
) -> dict[str, Any]:
    unknown_heavy = sorted(
        meeting_results,
        key=lambda item: (-item["unknown_labels_required"], item["ordinal"]),
    )[:5]
    never_recognized = [
        speaker for speaker in per_speaker
        if speaker["first_recognition_meeting_id"] is None
    ]
    never_recognized.sort(key=lambda item: (-item["turn_count"], item["speaker_id"]))
    label_variants = [
        speaker for speaker in per_speaker
        if speaker["raw_label_variant_count"] > 1
    ]
    label_variants.sort(key=lambda item: (-item["raw_label_variant_count"], item["speaker_id"]))

    speaker_fields = ["speaker_id", "meeting_count", "turn_count", "first_seen_meeting_id"]
    if include_speaker_labels:
        speaker_fields.append("canonical_label")

    return {
        "unknown_heavy_meetings": [
            {
                "meeting_id": item["meeting_id"],
                "unknown_labels_required": item["unknown_labels_required"],
                "speaker_count": item["speaker_count"],
                "turn_count": item["turn_count"],
            }
            for item in unknown_heavy
            if item["unknown_labels_required"] > 0
        ],
        "never_recognized_speakers": [
            {field: speaker[field] for field in speaker_fields if field in speaker}
            for speaker in never_recognized[:10]
        ],
        "parser_mismatches": parser_mismatches[:10],
        "label_variant_speakers": [
            {
                "speaker_id": speaker["speaker_id"],
                "raw_label_variant_count": speaker["raw_label_variant_count"],
                **({"canonical_label": speaker["canonical_label"]} if include_speaker_labels else {}),
            }
            for speaker in label_variants[:10]
        ],
        "false_match_cases": [],
        "duplicate_profile_cases": [],
    }


def write_report(report: dict[str, Any], output_path: Path | None) -> None:
    encoded = json.dumps(report, indent=2, sort_keys=True)
    if output_path is None:
        print(encoded)
        return
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(encoded + "\n", encoding="utf-8")


def print_summary(report: dict[str, Any], output_path: Path | None) -> None:
    summary = report["summary"]
    destination = str(output_path) if output_path else "stdout"
    print(
        "speaker-learning eval complete "
        f"meetings={summary['meetings_evaluated']} "
        f"unknown_labels={summary['unknown_labels_required']} "
        f"correct_auto_matches={summary['correct_automatic_matches']} "
        f"false_matches={summary['false_matches']} "
        f"duplicates={summary['duplicate_profiles_per_real_speaker']['total']} "
        f"runtime_seconds={summary['runtime_seconds']} "
        f"report={destination}"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run the local cold-start speaker-learning eval over Zoom-ground-truth corpus labels."
    )
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS, help="Path to meeting-corpus root.")
    parser.add_argument("--limit", type=int, help="Evaluate only the first N usable meetings.")
    parser.add_argument("--output", type=Path, help="Write the JSON report to this local path.")
    parser.add_argument(
        "--include-speaker-labels",
        action="store_true",
        help="Include local speaker labels in the JSON report. Off by default.",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    report = evaluate_corpus(
        corpus_root=args.corpus.expanduser(),
        limit=args.limit,
        include_speaker_labels=args.include_speaker_labels,
    )
    write_report(report, args.output)
    if args.output is not None:
        print_summary(report, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

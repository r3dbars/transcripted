#!/usr/bin/env python3
"""Cold-start speaker-learning scoreboard for the local meeting corpus.

The harness treats Zoom speaker labels as ground truth. It intentionally does
not print or persist transcript utterance text; body lines are used only to
identify turn boundaries and are then discarded.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shlex
import subprocess
import re
import time
import unicodedata
from dataclasses import dataclass, field, replace
from pathlib import Path
from statistics import median
from typing import Any, Callable, Iterable, Optional


DEFAULT_CORPUS = Path("/Users/redbars/Downloads/meeting-corpus")
ZOOM_LABEL_LINE = re.compile(
    r"^\[(?P<label>[^\]]+)\]\s+(?P<timestamp>\d{1,2}:\d{2}:\d{2}(?:\.\d+)?)\s*$"
)
TRANSCRIPTED_DEFAULT_PAIRWISE_MERGE_THRESHOLD = 0.78
TRANSCRIPTED_DB_SPLIT_THRESHOLD = 0.62


@dataclass(frozen=True)
class ZoomTurn:
    speaker_label: str
    start_seconds: float = 0.0


@dataclass(frozen=True)
class AudioSegment:
    channel: str
    speaker_id: str
    start_seconds: float
    end_seconds: float
    quality_score: float
    embedding: list[float] | None = None
    diarization_seconds: float = 0.0

    @property
    def duration_seconds(self) -> float:
        return max(0.0, self.end_seconds - self.start_seconds)


@dataclass
class AudioSpeakerProfile:
    profile_id: str
    embedding: list[float]
    first_seen_meeting_id: str
    first_seen_ordinal: int
    assigned_label: str | None = None
    first_recognition_meeting_id: str | None = None
    first_recognition_ordinal: int | None = None
    call_count: int = 1
    confidence: float = 0.5
    dispute_count: int = 0
    meetings_seen: set[str] = field(default_factory=set)
    source_channels: set[str] = field(default_factory=set)


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
    raw_turns: list[ZoomTurn] = []
    for block in re.split(r"\n\s*\n", raw):
        lines = [line.strip() for line in block.splitlines() if line.strip()]
        if len(lines) < 2:
            continue
        speaker_label, start_seconds = extract_speaker_header(lines[0])
        if _looks_like_non_speaker_header(speaker_label):
            continue
        raw_turns.append(ZoomTurn(speaker_label=speaker_label, start_seconds=start_seconds))

    first_timestamp = raw_turns[0].start_seconds if raw_turns else None
    if first_timestamp is None:
        return raw_turns
    return [
        ZoomTurn(
            speaker_label=turn.speaker_label,
            start_seconds=max(0.0, turn.start_seconds - first_timestamp),
        )
        for turn in raw_turns
    ]


def extract_speaker_label(line: str) -> str:
    return extract_speaker_header(line)[0]


def extract_speaker_header(line: str) -> tuple[str, float]:
    match = ZOOM_LABEL_LINE.match(line.strip())
    if match:
        return match.group("label").strip(), parse_timestamp_seconds(match.group("timestamp"))
    return line.strip(), 0.0


def parse_timestamp_seconds(value: str) -> float:
    hours, minutes, seconds = value.split(":")
    return (int(hours) * 3600) + (int(minutes) * 60) + float(seconds)


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


DiarizationProvider = Callable[[Path, str, dict[str, Any], Optional[Path]], list[AudioSegment]]


def evaluate_audio_corpus(
    corpus_root: Path,
    limit: int | None = None,
    include_speaker_labels: bool = False,
    audio_cache_dir: Path | None = None,
    diarization_provider: DiarizationProvider | None = None,
    diarizer_command: str | None = None,
) -> dict[str, Any]:
    """Run the audio-backed speaker-learning eval.

    The audio path uses diarization segments and embeddings only. Zoom transcript
    labels are used as time-aligned ground truth labels; utterance text is not
    printed or written into reports.
    """

    start = time.perf_counter()
    meetings = [meeting for meeting in load_manifest(corpus_root) if meeting.get("usable_for_eval", True)]
    meetings.sort(key=lambda item: (item.get("start_local", ""), item.get("id", "")))
    if limit is not None:
        meetings = meetings[:limit]

    profiles: dict[str, AudioSpeakerProfile] = {}
    real_speaker_ids: dict[str, str] = {}
    real_speaker_meetings: dict[str, set[str]] = {}
    real_speaker_first_seen: dict[str, int] = {}
    real_speaker_first_recognition: dict[str, int] = {}
    real_speaker_profiles: dict[str, list[str]] = {}

    unknown_labels_required = 0
    correct_automatic_matches = 0
    false_automatic_matches = 0
    missed_real_speaker_instances = 0
    diarization_failures: list[dict[str, Any]] = []
    false_match_cases: list[dict[str, Any]] = []
    duplicate_profile_cases: list[dict[str, Any]] = []
    missed_speaker_cases: list[dict[str, Any]] = []
    meeting_results: list[dict[str, Any]] = []
    total_diarization_seconds = 0.0

    provider = diarization_provider or (
        lambda audio_path, channel, meeting, cache_dir: run_transcripted_diarizer(
            audio_path=audio_path,
            channel=channel,
            meeting=meeting,
            cache_dir=cache_dir,
            diarizer_command=diarizer_command,
        )
    )

    for ordinal, meeting in enumerate(meetings, start=1):
        meeting_start = time.perf_counter()
        meeting_id = str(meeting["id"])
        transcript_path = corpus_root / meeting_id / meeting["zoom_transcript"]["path"]
        turns = parse_zoom_turns(transcript_path)
        meeting_labels = _stable_speaker_order(turns)
        for canonical in meeting_labels:
            real_speaker_meetings.setdefault(canonical, set()).add(meeting_id)
            real_speaker_first_seen.setdefault(canonical, ordinal)
            _real_speaker_id(canonical, real_speaker_ids)

        channel_segments: list[AudioSegment] = []
        meeting_failures: list[dict[str, Any]] = []
        for manifest_key, channel in (("system_audio", "system"), ("microphone", "microphone")):
            audio_info = meeting.get("audio", {}).get(manifest_key)
            if not audio_info or not audio_info.get("path"):
                continue
            audio_path = corpus_root / meeting_id / audio_info["path"]
            try:
                channel_segments.extend(provider(audio_path, channel, meeting, audio_cache_dir))
            except Exception as error:  # noqa: BLE001 - report local tool failures without leaking transcript text.
                failure = {
                    "meeting_id": meeting_id,
                    "channel": channel,
                    "error_type": type(error).__name__,
                    "detail": str(error).splitlines()[0][:240],
                }
                meeting_failures.append(failure)
                diarization_failures.append(failure)

        snapshot = [_clone_audio_profile(profile) for profile in profiles.values()]
        processed_segments: list[AudioSegment] = []
        for channel in ("system", "microphone"):
            segments = [segment for segment in channel_segments if segment.channel == channel]
            processed_segments.extend(post_process_audio_segments(segments, snapshot))

        predictions = classify_audio_speakers(
            segments=processed_segments,
            profiles=profiles,
            existing_profiles=snapshot,
            meeting_id=meeting_id,
            ordinal=ordinal,
        )
        label_scores_by_profile = score_profiles_against_zoom_turns(
            turns=turns,
            segments=processed_segments,
            predictions=predictions,
        )
        meeting_diarization_seconds = diarization_seconds_for_meeting(channel_segments)
        total_diarization_seconds += meeting_diarization_seconds
        predictions_by_profile: dict[str, dict[str, Any]] = {}
        for prediction in predictions.values():
            profile_id = prediction["profile_id"]
            existing = predictions_by_profile.get(profile_id)
            if existing is None or prediction["status"] == "matched":
                predictions_by_profile[profile_id] = prediction

        meeting_unknown = 0
        meeting_correct = 0
        meeting_false = 0
        meeting_duplicates = 0
        predicted_labels: set[str] = set()

        for profile_id, label_scores in sorted(label_scores_by_profile.items()):
            canonical = max(label_scores.items(), key=lambda item: item[1])[0]
            predicted_labels.add(canonical)
            profile = profiles[profile_id]
            prediction = predictions_by_profile.get(profile_id)
            was_matched = bool(prediction and prediction["status"] == "matched")

            if was_matched and profile.assigned_label:
                if profile.assigned_label == canonical:
                    correct_automatic_matches += 1
                    meeting_correct += 1
                    profile.first_recognition_meeting_id = profile.first_recognition_meeting_id or meeting_id
                    profile.first_recognition_ordinal = profile.first_recognition_ordinal or ordinal
                    real_speaker_first_recognition.setdefault(canonical, ordinal)
                else:
                    false_automatic_matches += 1
                    meeting_false += 1
                    false_match_cases.append(
                        _redacted_label_case(
                            {
                                "meeting_id": meeting_id,
                                "profile_id": profile.profile_id,
                                "expected_real_speaker": canonical,
                                "profile_real_speaker": profile.assigned_label,
                                "duration_seconds": round(label_scores[canonical], 2),
                            },
                            real_speaker_ids,
                            include_speaker_labels,
                        )
                    )
                continue

            unknown_labels_required += 1
            meeting_unknown += 1
            profile.assigned_label = canonical
            assigned_profiles = real_speaker_profiles.setdefault(canonical, [])
            if profile.profile_id not in assigned_profiles:
                if assigned_profiles:
                    meeting_duplicates += 1
                    duplicate_profile_cases.append(
                        _redacted_label_case(
                            {
                                "meeting_id": meeting_id,
                                "real_speaker": canonical,
                                "profile_id": profile.profile_id,
                                "existing_profile_ids": list(assigned_profiles),
                            },
                            real_speaker_ids,
                            include_speaker_labels,
                        )
                    )
                assigned_profiles.append(profile.profile_id)

        missed_labels = [canonical for canonical in meeting_labels if canonical not in predicted_labels]
        missed_real_speaker_instances += len(missed_labels)
        for canonical in missed_labels[:10]:
            missed_speaker_cases.append(
                _redacted_label_case(
                    {"meeting_id": meeting_id, "real_speaker": canonical},
                    real_speaker_ids,
                    include_speaker_labels,
                )
            )

        meeting_results.append(
            {
                "meeting_id": meeting_id,
                "ordinal": ordinal,
                "ground_truth_speaker_count": len(meeting_labels),
                "raw_audio_segment_count": len(channel_segments),
                "post_processed_audio_segment_count": len(processed_segments),
                "predicted_persistent_speaker_count": len(label_scores_by_profile),
                "unknown_labels_required": meeting_unknown,
                "correct_automatic_matches": meeting_correct,
                "false_automatic_matches": meeting_false,
                "duplicate_profiles_created": meeting_duplicates,
                "missed_real_speaker_instances": len(missed_labels),
                "runtime_seconds": round(time.perf_counter() - meeting_start, 4),
                "diarization_processing_seconds": round(meeting_diarization_seconds, 4),
                "diarization_failure_count": len(meeting_failures),
            }
        )

    duplicate_counts = {
        canonical: max(0, len(profile_ids) - 1)
        for canonical, profile_ids in real_speaker_profiles.items()
    }
    recurring_labels = [
        canonical for canonical, meeting_ids in real_speaker_meetings.items()
        if len(meeting_ids) > 1
    ]
    recognition_gaps = [
        real_speaker_first_recognition[canonical] - real_speaker_first_seen[canonical]
        for canonical in recurring_labels
        if canonical in real_speaker_first_recognition
    ]

    report = {
        "schema_version": 1,
        "corpus_root": str(corpus_root),
        "assumptions": {
            "ground_truth": "Zoom transcript speaker labels aligned by timestamp",
            "evaluation_mode": "audio_backed_transcripted_diarization",
            "threshold_tuning": "not_performed",
            "diarization": "Transcripted offline diarization CLI with per-segment embeddings",
            "speaker_db": "temporary cold-start profile store reset for each eval run",
            "transcript_text_policy": "utterance text is never printed or persisted",
            "speaker_labels_redacted": not include_speaker_labels,
        },
        "summary": {
            "meetings_evaluated": len(meetings),
            "distinct_real_speakers": len(real_speaker_ids),
            "recurring_speakers": len(recurring_labels),
            "unknown_labels_required": unknown_labels_required,
            "correct_automatic_matches": correct_automatic_matches,
            "false_automatic_matches": false_automatic_matches,
            "missed_real_speaker_instances": missed_real_speaker_instances,
            "duplicate_profiles_per_real_speaker": {
                "total": sum(duplicate_counts.values()),
                "max": max(duplicate_counts.values(), default=0),
                "speakers_affected": sum(1 for count in duplicate_counts.values() if count > 0),
            },
            "meetings_to_first_recognition": _audio_recognition_summary(
                recurring_labels,
                real_speaker_ids,
                real_speaker_first_seen,
                real_speaker_first_recognition,
                include_speaker_labels,
            ),
            "runtime_seconds": round(time.perf_counter() - start, 4),
            "diarization_processing_seconds": round(total_diarization_seconds, 4),
            "diarization_failure_count": len(diarization_failures),
        },
        "meetings": meeting_results,
        "speakers": _audio_speaker_reports(
            real_speaker_ids=real_speaker_ids,
            real_speaker_meetings=real_speaker_meetings,
            real_speaker_profiles=real_speaker_profiles,
            real_speaker_first_seen=real_speaker_first_seen,
            real_speaker_first_recognition=real_speaker_first_recognition,
            include_speaker_labels=include_speaker_labels,
        ),
        "top_failure_cases": {
            "unknown_heavy_meetings": [
                {
                    "meeting_id": item["meeting_id"],
                    "unknown_labels_required": item["unknown_labels_required"],
                    "ground_truth_speaker_count": item["ground_truth_speaker_count"],
                    "predicted_persistent_speaker_count": item["predicted_persistent_speaker_count"],
                }
                for item in sorted(
                    meeting_results,
                    key=lambda item: (-item["unknown_labels_required"], item["ordinal"]),
                )[:5]
                if item["unknown_labels_required"] > 0
            ],
            "false_match_cases": false_match_cases[:10],
            "duplicate_profile_cases": duplicate_profile_cases[:10],
            "missed_real_speaker_cases": missed_speaker_cases[:10],
            "diarization_failures": diarization_failures[:10],
        },
    }
    return report


def run_transcripted_diarizer(
    audio_path: Path,
    channel: str,
    meeting: dict[str, Any],
    cache_dir: Path | None,
    diarizer_command: str | None,
) -> list[AudioSegment]:
    if cache_dir is not None:
        cache_dir.mkdir(parents=True, exist_ok=True)
        output_path = cache_dir / f"{meeting['id']}-{channel}.diarization.json"
    else:
        output_path = None

    if output_path is None or not output_path.exists():
        command = resolve_diarizer_command(diarizer_command)
        command.extend(
            [
                str(audio_path),
                "--json",
                "--include-embeddings",
                "--transcripted-defaults",
            ]
        )
        if output_path is not None:
            command.extend(["--output", str(output_path)])
        result = subprocess.run(
            command,
            cwd=repo_root(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            detail = subprocess_error_summary(result.stderr, result.stdout)
            raise RuntimeError(f"diarizer failed for {channel}: {detail[:500]}")
        if output_path is None:
            data = json.loads(result.stdout)
        else:
            data = json.loads(output_path.read_text(encoding="utf-8"))
    else:
        data = json.loads(output_path.read_text(encoding="utf-8"))

    return audio_segments_from_diarizer_json(data, channel)


def subprocess_error_summary(stderr: str, stdout: str) -> str:
    lines = [line.strip() for line in (stderr + "\n" + stdout).splitlines() if line.strip()]
    for line in reversed(lines):
        if line.lower().startswith("error:"):
            return line
    return lines[-1] if lines else "unknown error"


def resolve_diarizer_command(diarizer_command: str | None) -> list[str]:
    if diarizer_command:
        return shlex.split(diarizer_command)

    cli_binary = repo_root() / "Tools" / "TranscriptedCLI" / ".build" / "debug" / "transcripted-cli"
    if cli_binary.exists():
        return [str(cli_binary), "diarize"]

    return [
        "swift",
        "run",
        "--package-path",
        str(repo_root() / "Tools" / "TranscriptedCLI"),
        "transcripted-cli",
        "diarize",
    ]


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def audio_segments_from_diarizer_json(data: dict[str, Any], channel: str) -> list[AudioSegment]:
    segments: list[AudioSegment] = []
    processing_seconds = float(data.get("processingSeconds", 0.0) or 0.0)
    for raw in data.get("segments", []):
        start = float(raw.get("startSeconds", 0.0))
        end = float(raw.get("endSeconds", start))
        embedding = raw.get("embedding")
        segments.append(
            AudioSegment(
                channel=channel,
                speaker_id=str(raw.get("speakerId", "")),
                start_seconds=start,
                end_seconds=end,
                quality_score=float(raw.get("qualityScore", 0.0)),
                embedding=[float(value) for value in embedding] if isinstance(embedding, list) else None,
                diarization_seconds=processing_seconds,
            )
        )
    return segments


def diarization_seconds_for_meeting(segments: list[AudioSegment]) -> float:
    seconds_by_channel: dict[str, float] = {}
    for segment in segments:
        seconds_by_channel[segment.channel] = max(
            seconds_by_channel.get(segment.channel, 0.0),
            segment.diarization_seconds,
        )
    return sum(seconds_by_channel.values())


def post_process_audio_segments(
    segments: list[AudioSegment],
    existing_profiles: list[AudioSpeakerProfile],
) -> list[AudioSegment]:
    if len(segments) < 2:
        return segments
    result = pairwise_merge_audio_segments(
        segments,
        threshold=TRANSCRIPTED_DEFAULT_PAIRWISE_MERGE_THRESHOLD,
    )
    result = absorb_small_audio_clusters(result)
    result = db_informed_split_audio_segments(result, existing_profiles)
    return result


def pairwise_merge_audio_segments(segments: list[AudioSegment], threshold: float) -> list[AudioSegment]:
    means = mean_embeddings_by_speaker(segments)
    speaker_ids = sorted(means)
    if len(speaker_ids) < 2:
        return segments

    parent = {speaker_id: speaker_id for speaker_id in speaker_ids}

    def find(speaker_id: str) -> str:
        root = speaker_id
        while parent[root] != root:
            root = parent[root]
        while speaker_id != root:
            next_id = parent[speaker_id]
            parent[speaker_id] = root
            speaker_id = next_id
        return root

    def union(a: str, b: str) -> None:
        root_a = find(a)
        root_b = find(b)
        if root_a != root_b:
            parent[root_b] = root_a

    for index, speaker_a in enumerate(speaker_ids):
        for speaker_b in speaker_ids[index + 1:]:
            if cosine_similarity(means[speaker_a], means[speaker_b]) >= threshold:
                union(speaker_a, speaker_b)

    merge_map = {speaker_id: find(speaker_id) for speaker_id in speaker_ids}
    if all(speaker_id == merged for speaker_id, merged in merge_map.items()):
        return segments
    return [
        replace(segment, speaker_id=merge_map.get(segment.speaker_id, segment.speaker_id))
        for segment in segments
    ]


def absorb_small_audio_clusters(
    segments: list[AudioSegment],
    min_cluster_duration: float = 30.0,
    absorption_threshold: float = 0.72,
    micro_cluster_duration: float = 10.0,
    micro_absorption_threshold: float = 0.62,
) -> list[AudioSegment]:
    duration_by_speaker: dict[str, float] = {}
    count_by_speaker: dict[str, int] = {}
    raw_embeddings: dict[str, list[list[float]]] = {}
    for segment in segments:
        duration_by_speaker[segment.speaker_id] = duration_by_speaker.get(segment.speaker_id, 0.0) + segment.duration_seconds
        count_by_speaker[segment.speaker_id] = count_by_speaker.get(segment.speaker_id, 0) + 1
        if segment.embedding:
            raw_embeddings.setdefault(segment.speaker_id, []).append(segment.embedding)

    small_ids = {speaker_id for speaker_id, duration in duration_by_speaker.items() if duration < min_cluster_duration}
    large_ids = {speaker_id for speaker_id, duration in duration_by_speaker.items() if duration >= min_cluster_duration}
    if not small_ids or not large_ids:
        return segments

    means = mean_embeddings_by_speaker(segments)
    for speaker_id in small_ids:
        if speaker_id not in means and raw_embeddings.get(speaker_id):
            means[speaker_id] = mean_embedding(raw_embeddings[speaker_id])

    merge_map: dict[str, str] = {}
    for small_id in small_ids:
        if count_by_speaker.get(small_id, 0) >= 3 or small_id not in means:
            continue
        best_id: str | None = None
        best_similarity = 0.0
        for large_id in large_ids:
            if large_id not in means:
                continue
            similarity = cosine_similarity(means[small_id], means[large_id])
            if similarity > best_similarity:
                best_similarity = similarity
                best_id = large_id
        duration = duration_by_speaker.get(small_id, 0.0)
        threshold = micro_absorption_threshold if duration < micro_cluster_duration else absorption_threshold
        if best_id is not None and best_similarity >= threshold:
            merge_map[small_id] = best_id

    surviving_ids = set(duration_by_speaker).difference(merge_map)
    if not merge_map or len(surviving_ids) < 2:
        return segments
    return [
        replace(segment, speaker_id=merge_map.get(segment.speaker_id, segment.speaker_id))
        for segment in segments
    ]


def db_informed_split_audio_segments(
    segments: list[AudioSegment],
    profiles: list[AudioSpeakerProfile],
    per_segment_threshold: float = TRANSCRIPTED_DB_SPLIT_THRESHOLD,
    min_segments_per_profile: int = 8,
) -> list[AudioSegment]:
    if not profiles:
        return segments

    grouped: dict[str, list[tuple[int, AudioSegment]]] = {}
    for index, segment in enumerate(segments):
        grouped.setdefault(segment.speaker_id, []).append((index, segment))

    result = list(segments)
    split_index = 1
    for speaker_id, indexed_segments in grouped.items():
        if len(indexed_segments) < min_segments_per_profile * 2:
            continue
        matches_by_profile: dict[str, list[int]] = {}
        for index, segment in indexed_segments:
            if not segment.embedding or segment.duration_seconds < 0.5 or segment.quality_score < 0.2:
                continue
            best_profile: AudioSpeakerProfile | None = None
            best_similarity = 0.0
            for profile in profiles:
                similarity = cosine_similarity(segment.embedding, profile.embedding)
                if similarity >= per_segment_threshold and similarity > best_similarity:
                    best_similarity = similarity
                    best_profile = profile
            if best_profile is not None:
                matches_by_profile.setdefault(best_profile.profile_id, []).append(index)

        significant = {
            profile_id: indices
            for profile_id, indices in matches_by_profile.items()
            if len(indices) >= min_segments_per_profile
        }
        if len(significant) < 2:
            continue

        ordered = sorted(significant.items(), key=lambda item: len(item[1]), reverse=True)
        for offset, (_, indices) in enumerate(ordered):
            assigned_id = speaker_id if offset == 0 else f"{speaker_id}_dbsplit_{split_index}"
            split_index += 1
            for index in indices:
                result[index] = replace(result[index], speaker_id=assigned_id)
    return result


def classify_audio_speakers(
    segments: list[AudioSegment],
    profiles: dict[str, AudioSpeakerProfile],
    existing_profiles: list[AudioSpeakerProfile],
    meeting_id: str,
    ordinal: int,
) -> dict[str, dict[str, Any]]:
    embeddings_by_key: dict[str, list[list[float]]] = {}
    segments_by_key: dict[str, list[AudioSegment]] = {}
    for segment in segments:
        key = audio_speaker_key(segment)
        segments_by_key.setdefault(key, []).append(segment)
        if segment.embedding and segment.quality_score >= 0.3 and segment.duration_seconds >= 1.0:
            embeddings_by_key.setdefault(key, []).append(segment.embedding)

    for key, grouped_segments in segments_by_key.items():
        if key in embeddings_by_key:
            continue
        best_segment = max(
            (segment for segment in grouped_segments if segment.embedding),
            key=lambda segment: segment.quality_score,
            default=None,
        )
        if best_segment and best_segment.embedding:
            embeddings_by_key[key] = [best_segment.embedding]

    predictions: dict[str, dict[str, Any]] = {}
    for key in sorted(segments_by_key, key=lambda item: segments_by_key[item][0].start_seconds):
        embeddings = embeddings_by_key.get(key, [])
        if not embeddings:
            continue
        mean = mean_embedding(embeddings)
        threshold = adaptive_match_threshold(len(embeddings))
        match = match_against_audio_profiles(mean, existing_profiles, threshold)
        channel = key.split(":", 1)[0]
        if match is not None:
            profile = profiles[match["profile_id"]]
            update_audio_profile(profile, mean)
            status = "matched"
            similarity = match["similarity"]
        else:
            profile_id = f"profile_{len(profiles) + 1:04d}"
            profile = AudioSpeakerProfile(
                profile_id=profile_id,
                embedding=l2_normalize(mean),
                first_seen_meeting_id=meeting_id,
                first_seen_ordinal=ordinal,
            )
            profiles[profile_id] = profile
            status = "new"
            similarity = None

        profile.meetings_seen.add(meeting_id)
        profile.source_channels.add(channel)
        predictions[key] = {
            "profile_id": profile.profile_id,
            "status": status,
            "similarity": similarity,
            "embedding_count": len(embeddings),
            "threshold": threshold,
        }
    return predictions


def score_profiles_against_zoom_turns(
    turns: list[ZoomTurn],
    segments: list[AudioSegment],
    predictions: dict[str, dict[str, Any]],
) -> dict[str, dict[str, float]]:
    scores: dict[str, dict[str, float]] = {}
    for segment in segments:
        prediction = predictions.get(audio_speaker_key(segment))
        if not prediction:
            continue
        canonical = label_for_segment_midpoint(turns, segment)
        if not canonical:
            continue
        profile_id = prediction["profile_id"]
        scores.setdefault(profile_id, {})
        scores[profile_id][canonical] = scores[profile_id].get(canonical, 0.0) + segment.duration_seconds
    return scores


def label_for_segment_midpoint(turns: list[ZoomTurn], segment: AudioSegment) -> str:
    if not turns:
        return ""
    midpoint = segment.start_seconds + (segment.duration_seconds / 2.0)
    current = turns[0]
    for turn in turns:
        if turn.start_seconds <= midpoint:
            current = turn
        else:
            break
    return normalize_speaker_label(current.speaker_label)


def mean_embeddings_by_speaker(segments: list[AudioSegment]) -> dict[str, list[float]]:
    grouped: dict[str, list[list[float]]] = {}
    for segment in segments:
        if segment.embedding and segment.quality_score >= 0.3 and segment.duration_seconds >= 1.0:
            grouped.setdefault(segment.speaker_id, []).append(segment.embedding)
    return {speaker_id: mean_embedding(embeddings) for speaker_id, embeddings in grouped.items()}


def mean_embedding(embeddings: list[list[float]]) -> list[float]:
    first = embeddings[0] if embeddings else []
    if not first:
        return []
    totals = [0.0] * len(first)
    for embedding in embeddings:
        for index, value in enumerate(embedding[:len(totals)]):
            totals[index] += value
    return l2_normalize([value / len(embeddings) for value in totals])


def l2_normalize(values: list[float]) -> list[float]:
    norm = math.sqrt(sum(value * value for value in values))
    if norm <= 0:
        return values
    return [value / norm for value in values]


def cosine_similarity(a: list[float], b: list[float]) -> float:
    if len(a) != len(b) or not a:
        return 0.0
    denominator = math.sqrt(sum(value * value for value in a)) * math.sqrt(sum(value * value for value in b))
    if denominator <= 0:
        return 0.0
    return sum(left * right for left, right in zip(a, b)) / denominator


def adaptive_match_threshold(embedding_count: int) -> float:
    if embedding_count == 1:
        return 0.85
    if embedding_count <= 3:
        return 0.78
    return 0.70


def match_against_audio_profiles(
    embedding: list[float],
    profiles: list[AudioSpeakerProfile],
    threshold: float,
) -> dict[str, Any] | None:
    best_profile: AudioSpeakerProfile | None = None
    best_similarity = -1.0
    second_best_similarity = -1.0
    for profile in profiles:
        if profile.dispute_count != 0:
            continue
        similarity = cosine_similarity(embedding, profile.embedding)
        if similarity >= threshold:
            if similarity > best_similarity:
                second_best_similarity = best_similarity
                best_similarity = similarity
                best_profile = profile
            elif similarity > second_best_similarity:
                second_best_similarity = similarity

    if best_profile is None:
        return None

    maturity_bonus = 0.08 if best_profile.call_count <= 2 else 0.04 if best_profile.call_count <= 4 else 0.0
    if best_similarity < threshold + maturity_bonus:
        return None
    if second_best_similarity >= threshold and (best_similarity - second_best_similarity) < 0.05:
        return None
    return {"profile_id": best_profile.profile_id, "similarity": best_similarity}


def update_audio_profile(profile: AudioSpeakerProfile, embedding: list[float]) -> None:
    alpha = 0.15
    blended = [
        (old * (1 - alpha)) + (new * alpha)
        for old, new in zip(profile.embedding, embedding)
    ]
    profile.embedding = l2_normalize(blended)
    profile.call_count += 1
    profile.confidence = min(1.0, profile.confidence + 0.1)


def audio_speaker_key(segment: AudioSegment) -> str:
    return f"{segment.channel}:{segment.speaker_id}"


def _clone_audio_profile(profile: AudioSpeakerProfile) -> AudioSpeakerProfile:
    return AudioSpeakerProfile(
        profile_id=profile.profile_id,
        embedding=list(profile.embedding),
        first_seen_meeting_id=profile.first_seen_meeting_id,
        first_seen_ordinal=profile.first_seen_ordinal,
        assigned_label=profile.assigned_label,
        first_recognition_meeting_id=profile.first_recognition_meeting_id,
        first_recognition_ordinal=profile.first_recognition_ordinal,
        call_count=profile.call_count,
        confidence=profile.confidence,
        dispute_count=profile.dispute_count,
        meetings_seen=set(profile.meetings_seen),
        source_channels=set(profile.source_channels),
    )


def _real_speaker_id(canonical: str, real_speaker_ids: dict[str, str]) -> str:
    if canonical not in real_speaker_ids:
        digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:10]
        real_speaker_ids[canonical] = f"real_speaker_{len(real_speaker_ids) + 1:04d}_{digest}"
    return real_speaker_ids[canonical]


def _redacted_label_case(
    item: dict[str, Any],
    real_speaker_ids: dict[str, str],
    include_speaker_labels: bool,
) -> dict[str, Any]:
    redacted = dict(item)
    for key in ("expected_real_speaker", "profile_real_speaker", "real_speaker"):
        if key in redacted:
            canonical = redacted[key]
            redacted[f"{key}_id"] = _real_speaker_id(canonical, real_speaker_ids)
            if include_speaker_labels:
                redacted[f"{key}_label"] = canonical
            del redacted[key]
    return redacted


def _audio_recognition_summary(
    recurring_labels: list[str],
    real_speaker_ids: dict[str, str],
    first_seen: dict[str, int],
    first_recognition: dict[str, int],
    include_speaker_labels: bool,
) -> dict[str, Any]:
    per_speaker = []
    gaps = []
    for canonical in sorted(recurring_labels, key=lambda label: real_speaker_ids[label]):
        recognized_at = first_recognition.get(canonical)
        gap = recognized_at - first_seen[canonical] if recognized_at is not None else None
        if gap is not None:
            gaps.append(gap)
        item = {
            "real_speaker_id": real_speaker_ids[canonical],
            "meetings_to_first_recognition": gap,
        }
        if include_speaker_labels:
            item["canonical_label"] = canonical
        per_speaker.append(item)
    return {
        "recognized_speakers": len(gaps),
        "never_recognized_speakers": len(recurring_labels) - len(gaps),
        "median_meetings_after_first_seen": median(gaps) if gaps else None,
        "max_meetings_after_first_seen": max(gaps) if gaps else None,
        "per_recurring_speaker": per_speaker,
    }


def _audio_speaker_reports(
    real_speaker_ids: dict[str, str],
    real_speaker_meetings: dict[str, set[str]],
    real_speaker_profiles: dict[str, list[str]],
    real_speaker_first_seen: dict[str, int],
    real_speaker_first_recognition: dict[str, int],
    include_speaker_labels: bool,
) -> list[dict[str, Any]]:
    reports: list[dict[str, Any]] = []
    for canonical, speaker_id in sorted(real_speaker_ids.items(), key=lambda item: item[1]):
        first_seen = real_speaker_first_seen.get(canonical)
        first_recognition = real_speaker_first_recognition.get(canonical)
        report: dict[str, Any] = {
            "real_speaker_id": speaker_id,
            "meeting_count": len(real_speaker_meetings.get(canonical, set())),
            "profile_count": len(real_speaker_profiles.get(canonical, [])),
            "duplicate_profiles": max(0, len(real_speaker_profiles.get(canonical, [])) - 1),
            "first_seen_ordinal": first_seen,
            "first_recognition_ordinal": first_recognition,
            "meetings_to_first_recognition": (
                first_recognition - first_seen
                if first_seen is not None and first_recognition is not None
                else None
            ),
        }
        if include_speaker_labels:
            report["canonical_label"] = canonical
        reports.append(report)
    return reports


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
    false_matches = summary.get("false_matches", summary.get("false_automatic_matches", 0))
    print(
        "speaker-learning eval complete "
        f"meetings={summary['meetings_evaluated']} "
        f"unknown_labels={summary['unknown_labels_required']} "
        f"correct_auto_matches={summary['correct_automatic_matches']} "
        f"false_matches={false_matches} "
        f"duplicates={summary['duplicate_profiles_per_real_speaker']['total']} "
        f"runtime_seconds={summary['runtime_seconds']} "
        f"report={destination}"
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Run the local cold-start speaker-learning eval over Zoom-ground-truth corpus labels."
    )
    parser.add_argument(
        "--mode",
        choices=("baseline", "audio"),
        default="baseline",
        help="baseline keeps the label-carry-forward scoreboard; audio runs Transcripted diarization/matching.",
    )
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS, help="Path to meeting-corpus root.")
    parser.add_argument("--limit", type=int, help="Evaluate only the first N usable meetings.")
    parser.add_argument("--output", type=Path, help="Write the JSON report to this local path.")
    parser.add_argument(
        "--audio-cache",
        type=Path,
        help="Local cache directory for audio-backed diarization JSON. Defaults beside --output.",
    )
    parser.add_argument(
        "--diarizer-command",
        help=(
            "Base command ending in `transcripted-cli diarize`. "
            "Defaults to the built CLI binary or swift run."
        ),
    )
    parser.add_argument(
        "--include-speaker-labels",
        action="store_true",
        help="Include local speaker labels in the JSON report. Off by default.",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    corpus_root = args.corpus.expanduser()
    if args.mode == "audio":
        audio_cache = args.audio_cache
        if audio_cache is None and args.output is not None:
            audio_cache = args.output.parent / "audio-cache"
        report = evaluate_audio_corpus(
            corpus_root=corpus_root,
            limit=args.limit,
            include_speaker_labels=args.include_speaker_labels,
            audio_cache_dir=audio_cache,
            diarizer_command=args.diarizer_command,
        )
    else:
        report = evaluate_corpus(
            corpus_root=corpus_root,
            limit=args.limit,
            include_speaker_labels=args.include_speaker_labels,
        )
    write_report(report, args.output)
    if args.output is not None:
        print_summary(report, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

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
from itertools import combinations
from pathlib import Path
from statistics import median
from typing import Any, Callable, Iterable, Optional


DEFAULT_CORPUS = Path("/Users/redbars/Downloads/meeting-corpus")
ZOOM_LABEL_LINE = re.compile(
    r"^\[(?P<label>[^\]]+)\]\s+(?P<timestamp>\d{1,2}:\d{2}:\d{2}(?:\.\d+)?)\s*$"
)
TRANSCRIPTED_DEFAULT_PAIRWISE_MERGE_THRESHOLD = 0.78
TRANSCRIPTED_DB_SPLIT_THRESHOLD = 0.62
MICROPHONE_BLEED_OVERLAP_THRESHOLD = 0.70
MICROPHONE_BLEED_SIMILARITY_THRESHOLD = 0.30
CONFIRMATION_SIMILARITY_BANDS = [
    ("0.98+", 0.98, None),
    ("0.95-0.98", 0.95, 0.98),
    ("0.90-0.95", 0.90, 0.95),
    ("0.85-0.90", 0.85, 0.90),
    ("below 0.85", None, 0.85),
]
AUTO_RECOGNITION_EXPERIMENT_TOTAL_OBSERVATIONS = [2, 3, 4, 5, 6, 8, 10]
AUTO_RECOGNITION_EXPERIMENT_PRIOR_MEETINGS = [0, 1, 2, 3, 4, 5]
AUTO_RECOGNITION_EXPERIMENT_SIMILARITIES = [0.95, 0.97, 0.98, 0.985, 0.99, 0.995]
AUTO_RECOGNITION_EXPERIMENT_SEPARATIONS: list[float | None] = [None, 0.02, 0.05, 0.10, 0.15, 0.20]


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
    confirmation_labels_required = 0
    correct_automatic_matches = 0
    false_automatic_matches = 0
    deferred_profile_matches = 0
    missed_real_speaker_instances = 0
    suppressed_microphone_bleed_segments = 0
    diarization_failures: list[dict[str, Any]] = []
    false_match_cases: list[dict[str, Any]] = []
    confirmation_suggestions: list[dict[str, Any]] = []
    auto_recognition_candidates: list[dict[str, Any]] = []
    speaker_observation_events: list[dict[str, Any]] = []
    duplicate_profile_cases: list[dict[str, Any]] = []
    missed_speaker_cases: list[dict[str, Any]] = []
    meeting_results: list[dict[str, Any]] = []
    total_diarization_seconds = 0.0
    observation_index = 0

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
        pre_suppression_segment_count = len(processed_segments)
        processed_segments = suppress_overlapping_microphone_bleed(processed_segments)
        meeting_suppressed_microphone_bleed = pre_suppression_segment_count - len(processed_segments)
        suppressed_microphone_bleed_segments += meeting_suppressed_microphone_bleed

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
        meeting_confirmation = 0
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
            observation_index += 1
            observation_event = {
                "observation_index": observation_index,
                "meeting_id": meeting_id,
                "ordinal": ordinal,
                "profile_id": profile.profile_id,
                "expected_real_speaker": canonical,
                "profile_real_speaker": profile.assigned_label,
                "was_matched": was_matched,
                "baseline_label_action": "pending",
                "embedding": prediction.get("speaker_embedding") if prediction else None,
                "duration_seconds": round(label_scores[canonical], 2),
            }
            speaker_observation_events.append(observation_event)
            auto_accepted = (
                was_matched
                and profile.assigned_label is not None
                and prediction is not None
                and prediction["similarity"] is not None
                and should_auto_accept_audio_profile(profile, float(prediction["similarity"]))
            )
            auto_candidate: dict[str, Any] | None = None
            if was_matched and profile.assigned_label and prediction and prediction["similarity"] is not None:
                similarity = float(prediction["similarity"])
                auto_candidate = {
                    "meeting_id": meeting_id,
                    "ordinal": ordinal,
                    "observation_index": observation_index,
                    "profile_id": profile.profile_id,
                    "expected_real_speaker": canonical,
                    "profile_real_speaker": profile.assigned_label,
                    "similarity": similarity,
                    "similarity_separation": prediction.get("similarity_separation"),
                    "profile_prior_call_count": prediction.get("profile_prior_call_count", 0),
                    "profile_total_observation_count": int(prediction.get("profile_prior_call_count", 0)) + 1,
                    "profile_prior_meeting_count": prediction.get("profile_prior_meeting_count", 0),
                    "embedding_count": prediction.get("embedding_count", 0),
                    "segment_count": prediction.get("segment_count", 0),
                    "speaker_duration_seconds": prediction.get("speaker_duration_seconds", 0.0),
                    "baseline_label_action": "pending",
                    "correct": profile.assigned_label == canonical,
                }
                auto_recognition_candidates.append(auto_candidate)

            if auto_accepted and profile.assigned_label:
                if profile.assigned_label == canonical:
                    observation_event["baseline_label_action"] = "automatic_correct"
                    if auto_candidate is not None:
                        auto_candidate["baseline_label_action"] = "automatic_correct"
                    correct_automatic_matches += 1
                    meeting_correct += 1
                    profile.first_recognition_meeting_id = profile.first_recognition_meeting_id or meeting_id
                    profile.first_recognition_ordinal = profile.first_recognition_ordinal or ordinal
                    real_speaker_first_recognition.setdefault(canonical, ordinal)
                else:
                    observation_event["baseline_label_action"] = "automatic_false"
                    if auto_candidate is not None:
                        auto_candidate["baseline_label_action"] = "automatic_false"
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

            if was_matched and profile.assigned_label:
                observation_event["baseline_label_action"] = "confirmation_needed"
                if auto_candidate is not None:
                    auto_candidate["baseline_label_action"] = "confirmation_needed"
                similarity = float(prediction["similarity"]) if prediction and prediction["similarity"] is not None else 0.0
                confirmation_suggestions.append(
                    {
                        "meeting_id": meeting_id,
                        "profile_id": profile.profile_id,
                        "expected_real_speaker": canonical,
                        "profile_real_speaker": profile.assigned_label,
                        "similarity": similarity,
                        "second_best_similarity": prediction.get("second_best_similarity") if prediction else None,
                        "similarity_separation": prediction.get("similarity_separation") if prediction else None,
                        "channel": prediction.get("channel") if prediction else None,
                        "profile_source_channels": prediction.get("profile_source_channels", []) if prediction else [],
                        "profile_prior_meeting_count": prediction.get("profile_prior_meeting_count", 0) if prediction else 0,
                        "profile_prior_call_count": prediction.get("profile_prior_call_count", 0) if prediction else 0,
                        "profile_first_seen_ordinal": prediction.get("profile_first_seen_ordinal") if prediction else None,
                        "segment_count": prediction.get("segment_count", 0) if prediction else 0,
                        "embedding_count": prediction.get("embedding_count", 0) if prediction else 0,
                        "speaker_duration_seconds": prediction.get("speaker_duration_seconds", 0.0) if prediction else 0.0,
                        "meeting_had_microphone_bleed_suppression": meeting_suppressed_microphone_bleed > 0,
                        "profile_created_in_same_meeting": profile.first_seen_meeting_id == meeting_id,
                        "profile_has_prior_manual_name": profile.assigned_label is not None,
                        "duration_seconds": round(label_scores[canonical], 2),
                        "correct": profile.assigned_label == canonical,
                    }
                )
                confirmation_labels_required += 1
                meeting_confirmation += 1
                deferred_profile_matches += 1
                continue

            unknown_labels_required += 1
            meeting_unknown += 1
            observation_event["baseline_label_action"] = "unknown_label"
            if auto_candidate is not None:
                auto_candidate["baseline_label_action"] = "unknown_label"
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
                "confirmation_labels_required": meeting_confirmation,
                "correct_automatic_matches": meeting_correct,
                "false_automatic_matches": meeting_false,
                "duplicate_profiles_created": meeting_duplicates,
                "suppressed_microphone_bleed_segments": meeting_suppressed_microphone_bleed,
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
    confirmation_simulation = build_confirmation_simulation(
        suggestions=confirmation_suggestions,
        duplicate_counts=duplicate_counts,
        unknown_labels_required=unknown_labels_required,
        real_speaker_ids=real_speaker_ids,
        include_speaker_labels=include_speaker_labels,
    )
    duplicate_merge_review = build_duplicate_merge_review_report(
        profiles=list(profiles.values()),
        duplicate_counts=duplicate_counts,
        real_speaker_ids=real_speaker_ids,
        include_speaker_labels=include_speaker_labels,
    )
    recurring_labels = [
        canonical for canonical, meeting_ids in real_speaker_meetings.items()
        if len(meeting_ids) > 1
    ]
    recognition_gaps = [
        real_speaker_first_recognition[canonical] - real_speaker_first_seen[canonical]
        for canonical in recurring_labels
        if canonical in real_speaker_first_recognition
    ]
    auto_recognition_experiment = build_auto_recognition_experiment(
        candidates=auto_recognition_candidates,
        recurring_labels=recurring_labels,
        real_speaker_ids=real_speaker_ids,
        first_seen=real_speaker_first_seen,
        include_speaker_labels=include_speaker_labels,
    )
    oracle_merged_candidates = with_oracle_merged_maturity(
        candidates=auto_recognition_candidates,
        observations=speaker_observation_events,
    )
    auto_recognition_after_merge_experiment = build_auto_recognition_experiment(
        candidates=oracle_merged_candidates,
        recurring_labels=recurring_labels,
        real_speaker_ids=real_speaker_ids,
        first_seen=real_speaker_first_seen,
        include_speaker_labels=include_speaker_labels,
        maturity_source="oracle_merged_profile_maturity",
        total_observation_field="oracle_merged_total_observation_count",
        prior_meeting_field="oracle_merged_prior_meeting_count",
    )
    confirmed_merge_auto_naming_projection = build_confirmed_merge_auto_naming_projection(
        observations=speaker_observation_events,
        safe_after_merge_candidates=oracle_merged_candidates,
        safe_after_merge_policy=auto_recognition_after_merge_experiment["current_product_gate_projection"],
        duplicate_merge_review=duplicate_merge_review,
        duplicate_counts=duplicate_counts,
        unknown_labels_required=unknown_labels_required,
        confirmation_labels_required=confirmation_labels_required,
        correct_automatic_matches=correct_automatic_matches,
        false_automatic_matches=false_automatic_matches,
        recurring_labels=recurring_labels,
        real_speaker_ids=real_speaker_ids,
        first_seen=real_speaker_first_seen,
        include_speaker_labels=include_speaker_labels,
    )

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
            "microphone_bleed_policy": "microphone clusters mostly overlapping similar system audio are suppressed before scoring",
        },
        "summary": {
            "meetings_evaluated": len(meetings),
            "distinct_real_speakers": len(real_speaker_ids),
            "recurring_speakers": len(recurring_labels),
            "unknown_labels_required": unknown_labels_required,
            "confirmation_labels_required": confirmation_labels_required,
            "correct_automatic_matches": correct_automatic_matches,
            "false_automatic_matches": false_automatic_matches,
            "deferred_profile_matches": deferred_profile_matches,
            "missed_real_speaker_instances": missed_real_speaker_instances,
            "suppressed_microphone_bleed_segments": suppressed_microphone_bleed_segments,
            "duplicate_merge_candidates": duplicate_merge_review["merge_candidates_total"],
            "duplicate_merge_candidates_correct": duplicate_merge_review["merge_candidates_correct"],
            "duplicate_merge_candidates_wrong": duplicate_merge_review["merge_candidates_wrong"],
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
        "confirmation_simulation": confirmation_simulation,
        "duplicate_merge_review": duplicate_merge_review,
        "auto_recognition_experiment": auto_recognition_experiment,
        "auto_recognition_after_oracle_merge_experiment": auto_recognition_after_merge_experiment,
        "confirmed_merge_auto_naming_projection": confirmed_merge_auto_naming_projection,
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
            "confirmation_wrong_suggestions": confirmation_simulation["wrong_suggestion_cases"][:10],
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


def suppress_overlapping_microphone_bleed(
    segments: list[AudioSegment],
    overlap_threshold: float = MICROPHONE_BLEED_OVERLAP_THRESHOLD,
    similarity_threshold: float = MICROPHONE_BLEED_SIMILARITY_THRESHOLD,
) -> list[AudioSegment]:
    system_segments = [segment for segment in segments if segment.channel == "system"]
    microphone_segments = [segment for segment in segments if segment.channel == "microphone"]
    if not system_segments or not microphone_segments:
        return segments

    system_by_speaker: dict[str, list[AudioSegment]] = {}
    microphone_by_speaker: dict[str, list[AudioSegment]] = {}
    for segment in system_segments:
        system_by_speaker.setdefault(segment.speaker_id, []).append(segment)
    for segment in microphone_segments:
        microphone_by_speaker.setdefault(segment.speaker_id, []).append(segment)

    system_means = {
        speaker_id: mean_embedding_for_segments(grouped_segments)
        for speaker_id, grouped_segments in system_by_speaker.items()
    }

    suppressed_speaker_ids: set[str] = set()
    for speaker_id, grouped_segments in microphone_by_speaker.items():
        total_duration = sum(segment.duration_seconds for segment in grouped_segments)
        if total_duration <= 0:
            continue

        overlapped_duration = sum(
            max((segment_overlap(segment, system_segment) for system_segment in system_segments), default=0.0)
            for segment in grouped_segments
        )
        overlap_fraction = overlapped_duration / total_duration
        if overlap_fraction < overlap_threshold:
            continue

        microphone_mean = mean_embedding_for_segments(grouped_segments)
        best_system_similarity = max(
            (
                cosine_similarity(microphone_mean, system_mean)
                for system_mean in system_means.values()
                if microphone_mean and system_mean
            ),
            default=-1.0,
        )
        if best_system_similarity >= similarity_threshold:
            suppressed_speaker_ids.add(speaker_id)

    if not suppressed_speaker_ids:
        return segments

    return [
        segment
        for segment in segments
        if not (segment.channel == "microphone" and segment.speaker_id in suppressed_speaker_ids)
    ]


def segment_overlap(left: AudioSegment, right: AudioSegment) -> float:
    return max(0.0, min(left.end_seconds, right.end_seconds) - max(left.start_seconds, right.start_seconds))


def mean_embedding_for_segments(segments: list[AudioSegment]) -> list[float]:
    quality_filtered = [
        segment.embedding
        for segment in segments
        if segment.embedding and segment.quality_score >= 0.3 and segment.duration_seconds >= 1.0
    ]
    if quality_filtered:
        return mean_embedding(quality_filtered)

    fallback = [segment.embedding for segment in segments if segment.embedding]
    return mean_embedding(fallback) if fallback else []


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
        grouped_segments = segments_by_key[key]
        speaker_duration_seconds = sum(segment.duration_seconds for segment in grouped_segments)
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
            "speaker_embedding": mean,
            "embedding_count": len(embeddings),
            "segment_count": len(grouped_segments),
            "speaker_duration_seconds": round(speaker_duration_seconds, 4),
            "channel": channel,
            "threshold": threshold,
        }
        if match is not None:
            predictions[key].update(
                {
                    "second_best_similarity": match["second_best_similarity"],
                    "similarity_separation": match["similarity_separation"],
                    "profile_prior_call_count": match["profile_call_count"],
                    "profile_prior_meeting_count": match["profile_meeting_count"],
                    "profile_first_seen_ordinal": match["profile_first_seen_ordinal"],
                    "profile_source_channels": match["profile_source_channels"],
                }
            )
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
        if similarity > best_similarity:
            second_best_similarity = best_similarity
            best_similarity = similarity
            best_profile = profile
        elif similarity > second_best_similarity:
            second_best_similarity = similarity

    if best_profile is None or best_similarity < threshold:
        return None

    maturity_bonus = 0.08 if best_profile.call_count <= 2 else 0.04 if best_profile.call_count <= 4 else 0.0
    if best_similarity < threshold + maturity_bonus:
        return None
    if second_best_similarity >= threshold and (best_similarity - second_best_similarity) < 0.05:
        return None
    normalized_second_best = second_best_similarity if second_best_similarity >= 0 else None
    return {
        "profile_id": best_profile.profile_id,
        "similarity": best_similarity,
        "second_best_similarity": normalized_second_best,
        "similarity_separation": (
            best_similarity - normalized_second_best
            if normalized_second_best is not None
            else None
        ),
        "profile_call_count": best_profile.call_count,
        "profile_meeting_count": len(best_profile.meetings_seen),
        "profile_first_seen_ordinal": best_profile.first_seen_ordinal,
        "profile_source_channels": sorted(best_profile.source_channels),
    }


def should_auto_accept_audio_profile(profile: AudioSpeakerProfile, similarity: float) -> bool:
    return (
        profile.assigned_label is not None
        and profile.dispute_count == 0
        and similarity > 0.98
        and profile.call_count > 4
    )


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
    for key in (
        "expected_real_speaker",
        "profile_real_speaker",
        "real_speaker",
        "source_real_speaker",
        "target_real_speaker",
    ):
        if key in redacted:
            canonical = redacted[key]
            if canonical is not None:
                redacted[f"{key}_id"] = _real_speaker_id(canonical, real_speaker_ids)
                if include_speaker_labels:
                    redacted[f"{key}_label"] = canonical
            del redacted[key]
    return redacted


def build_confirmation_simulation(
    suggestions: list[dict[str, Any]],
    duplicate_counts: dict[str, int],
    unknown_labels_required: int,
    real_speaker_ids: dict[str, str],
    include_speaker_labels: bool,
) -> dict[str, Any]:
    total = len(suggestions)
    correct = [suggestion for suggestion in suggestions if suggestion["correct"]]
    wrong = [suggestion for suggestion in suggestions if not suggestion["correct"]]
    confirmed_speakers = {suggestion["expected_real_speaker"] for suggestion in correct}
    oracle_duplicate_reduction = sum(duplicate_counts.get(canonical, 0) for canonical in confirmed_speakers)
    duplicate_total = sum(duplicate_counts.values())
    bands = [
        confirmation_band_report(
            label=label,
            min_similarity=min_similarity,
            max_similarity=max_similarity,
            suggestions=suggestions,
        )
        for label, min_similarity, max_similarity in CONFIRMATION_SIMILARITY_BANDS
    ]
    recommended_threshold = recommended_confirmation_threshold(bands)
    safety_filters = build_confirmation_safety_filter_reports(
        suggestions=suggestions,
        duplicate_counts=duplicate_counts,
    )
    compound_strategy_search = build_confirmation_compound_strategy_search(
        suggestions=suggestions,
        duplicate_counts=duplicate_counts,
    )
    safe_filters = [
        report for report in safety_filters
        if report["suggestions_shown"] > 0 and report["wrong_suggestions"] == 0
    ]
    best_precision_filters = sorted(
        (report for report in safety_filters if report["suggestions_shown"] > 0),
        key=lambda item: (
            -(item["precision"] if item["precision"] is not None else -1),
            -item["correct_suggestions"],
            -item["suggestions_shown"],
            item["filter"],
        ),
    )[:5]

    return {
        "confirmation_suggestions_total": total,
        "confirmation_suggestions_correct": len(correct),
        "confirmation_suggestions_wrong": len(wrong),
        "confirmation_precision": ratio(len(correct), total),
        "confirmation_bands_by_similarity": bands,
        "confirmation_safety_filters": safety_filters,
        "safe_candidate_filters": sorted(
            safe_filters,
            key=lambda item: (-item["correct_suggestions"], -item["suggestions_shown"], item["filter"]),
        ),
        "safe_candidate_filter_count": len(safe_filters),
        "best_precision_filters": best_precision_filters,
        "compound_strategy_search": compound_strategy_search,
        "safety_filter_conclusion": (
            "At least one tested non-transcript filter or compound strategy had zero wrong suggestions."
            if (
                safe_filters
                or compound_strategy_search["zero_wrong_compound_strategy_min_coverage_count"] > 0
            )
            else "Zero-wrong compound strategies existed only at tiny coverage; no broadly safe strategy was found."
            if compound_strategy_search["zero_wrong_compound_strategy_count"] > 0
            else "None of the tested non-transcript filters or compound strategies had zero wrong suggestions."
        ),
        "recommended_show_suggestion_threshold": recommended_threshold,
        "recommendation_basis": (
            "lowest observed similarity band with no wrong suggestions across that band and all higher bands"
            if recommended_threshold is not None
            else "no observed similarity-only band can be recommended without wrong suggestions"
        ),
        "projected_unknown_label_reduction_if_confirmed": len(correct),
        "projected_unknown_labels_after_review": unknown_labels_required + len(wrong),
        "projected_duplicate_reduction_if_confirmed": 0,
        "projected_duplicate_profiles_after_confirmation": duplicate_total,
        "oracle_duplicate_reduction_for_confirmed_real_speakers": oracle_duplicate_reduction,
        "oracle_duplicate_profiles_after_confirmed_speaker_merges": max(0, duplicate_total - oracle_duplicate_reduction),
        "projection_notes": [
            "Correct confirmations avoid typed unknown labels but do not auto-apply names.",
            "Confirmation-only matches existing profiles, so direct duplicate reduction is zero.",
            "Oracle duplicate reduction is an eval-only upper bound using ground-truth labels to estimate merge upside.",
        ],
        "wrong_suggestion_cases": [
            _redacted_label_case(suggestion, real_speaker_ids, include_speaker_labels)
            for suggestion in wrong[:10]
        ],
    }


def build_duplicate_merge_review_report(
    profiles: list[AudioSpeakerProfile],
    duplicate_counts: dict[str, int],
    real_speaker_ids: dict[str, str],
    include_speaker_labels: bool,
) -> dict[str, Any]:
    all_candidates = duplicate_merge_candidates_from_profiles(profiles, include_voice_only=True)
    candidates = [
        candidate for candidate in all_candidates
        if candidate["reason"] != "similar_voice"
    ]
    held_back = [
        candidate for candidate in all_candidates
        if candidate["reason"] == "similar_voice"
    ]
    correct = [candidate for candidate in candidates if candidate["correct"]]
    wrong = [candidate for candidate in candidates if not candidate["correct"]]
    reason_reports = [
        duplicate_merge_reason_report(reason, candidates)
        for reason in [
            "same_saved_name_and_similar_voice",
            "same_saved_name",
            "similar_saved_name_and_voice",
            "similar_saved_name",
            "similar_voice",
        ]
    ]
    projected_reduction = projected_duplicate_merge_reduction(correct)
    duplicate_total = sum(duplicate_counts.values())
    return {
        "merge_candidates_total": len(candidates),
        "merge_candidates_correct": len(correct),
        "merge_candidates_wrong": len(wrong),
        "merge_candidate_precision": ratio(len(correct), len(candidates)),
        "held_back_voice_only_candidates": len(held_back),
        "held_back_voice_only_candidates_correct": sum(1 for candidate in held_back if candidate["correct"]),
        "held_back_voice_only_candidates_wrong": sum(1 for candidate in held_back if not candidate["correct"]),
        "projected_duplicate_reduction_upper_bound": projected_reduction,
        "projected_duplicate_profiles_after_perfect_review": max(0, duplicate_total - projected_reduction),
        "candidates_by_reason": reason_reports,
        "held_back_candidates_by_reason": [
            duplicate_merge_reason_report("similar_voice", held_back),
        ],
        "wrong_candidate_cases": [
            _redacted_label_case(candidate, real_speaker_ids, include_speaker_labels)
            for candidate in wrong[:10]
        ],
        "held_back_wrong_candidate_cases": [
            _redacted_label_case(candidate, real_speaker_ids, include_speaker_labels)
            for candidate in held_back
            if not candidate["correct"]
        ][:10],
        "report_notes": [
            "Merge candidates are reported separately from confirmation suggestions.",
            "Candidate filters use profile names, profile metadata, and voice embeddings only; Zoom labels are used only to score correctness.",
            "Voice-only pairs are held out of the default review queue because the corpus still shows wrong voice-only duplicate candidates.",
            "The product flow should show these as possible duplicates and require an explicit user merge.",
        ],
    }


def duplicate_merge_candidates_from_profiles(
    profiles: list[AudioSpeakerProfile],
    include_voice_only: bool = False,
) -> list[dict[str, Any]]:
    candidates: list[dict[str, Any]] = []
    sorted_profiles = sorted(profiles, key=lambda profile: profile.profile_id)
    for index, lhs in enumerate(sorted_profiles):
        for rhs in sorted_profiles[index + 1:]:
            reason, similarity = duplicate_merge_candidate_reason(lhs, rhs)
            if reason is None:
                continue
            if reason == "similar_voice" and not include_voice_only:
                continue
            target, source = duplicate_merge_default_order(lhs, rhs)
            candidates.append(
                {
                    "source_profile_id": source.profile_id,
                    "target_profile_id": target.profile_id,
                    "source_real_speaker": source.assigned_label,
                    "target_real_speaker": target.assigned_label,
                    "reason": reason,
                    "voice_similarity": round(similarity, 4) if similarity is not None else None,
                    "source_call_count": source.call_count,
                    "target_call_count": target.call_count,
                    "source_meeting_count": len(source.meetings_seen),
                    "target_meeting_count": len(target.meetings_seen),
                    "source_channel_count": len(source.source_channels),
                    "target_channel_count": len(target.source_channels),
                    "correct": (
                        source.assigned_label is not None
                        and source.assigned_label == target.assigned_label
                    ),
                }
            )
    return sorted(
        candidates,
        key=lambda candidate: (
            candidate["reason"],
            -(candidate["voice_similarity"] or 0),
            -(candidate["source_call_count"] + candidate["target_call_count"]),
            candidate["source_profile_id"],
            candidate["target_profile_id"],
        ),
    )


def duplicate_merge_candidate_reason(
    lhs: AudioSpeakerProfile,
    rhs: AudioSpeakerProfile,
) -> tuple[str | None, float | None]:
    lhs_name = normalize_speaker_label(lhs.assigned_label or "")
    rhs_name = normalize_speaker_label(rhs.assigned_label or "")
    same_name = bool(lhs_name and lhs_name == rhs_name)
    similar_name = bool(not same_name and names_look_related(lhs_name, rhs_name))
    name_conflict = bool(lhs_name and rhs_name and not same_name and not similar_name)
    similarity = cosine_similarity(lhs.embedding, rhs.embedding) if lhs.embedding and rhs.embedding else None
    voice_threshold = 0.96 if name_conflict else 0.90
    voice_match = lhs.dispute_count == 0 and rhs.dispute_count == 0 and (similarity or 0) >= voice_threshold

    if same_name and voice_match:
        return "same_saved_name_and_similar_voice", similarity
    if same_name:
        return "same_saved_name", similarity
    if similar_name and voice_match:
        return "similar_saved_name_and_voice", similarity
    if similar_name:
        return "similar_saved_name", similarity
    if voice_match:
        return "similar_voice", similarity
    return None, similarity


def duplicate_merge_default_order(
    lhs: AudioSpeakerProfile,
    rhs: AudioSpeakerProfile,
) -> tuple[AudioSpeakerProfile, AudioSpeakerProfile]:
    if lhs.call_count != rhs.call_count:
        target = lhs if lhs.call_count > rhs.call_count else rhs
    elif bool(lhs.assigned_label) != bool(rhs.assigned_label):
        target = lhs if lhs.assigned_label else rhs
    else:
        target = lhs if lhs.first_seen_ordinal <= rhs.first_seen_ordinal else rhs
    source = rhs if target.profile_id == lhs.profile_id else lhs
    return target, source


def names_look_related(lhs: str | None, rhs: str | None) -> bool:
    if not lhs or not rhs or lhs == rhs:
        return False
    if len(lhs) >= 3 and len(rhs) >= 3 and (lhs in rhs or rhs in lhs):
        return True
    lhs_tokens = name_tokens(lhs)
    rhs_tokens = name_tokens(rhs)
    if not lhs_tokens or not rhs_tokens:
        return False
    return lhs_tokens.issubset(rhs_tokens) or rhs_tokens.issubset(lhs_tokens)


def name_tokens(name: str) -> set[str]:
    ignored_tokens = {"speaker", "unknown", "unnamed", "person", "profile"}
    return {token for token in name.split() if len(token) >= 3 and token not in ignored_tokens}


def duplicate_merge_reason_report(reason: str, candidates: list[dict[str, Any]]) -> dict[str, Any]:
    matches = [candidate for candidate in candidates if candidate["reason"] == reason]
    correct = [candidate for candidate in matches if candidate["correct"]]
    return {
        "reason": reason,
        "candidates": len(matches),
        "correct_candidates": len(correct),
        "wrong_candidates": len(matches) - len(correct),
        "precision": ratio(len(correct), len(matches)),
        "projected_duplicate_reduction_upper_bound": projected_duplicate_merge_reduction(correct),
    }


def projected_duplicate_merge_reduction(candidates: list[dict[str, Any]]) -> int:
    parent: dict[str, str] = {}

    def find(profile_id: str) -> str:
        parent.setdefault(profile_id, profile_id)
        while parent[profile_id] != profile_id:
            parent[profile_id] = parent[parent[profile_id]]
            profile_id = parent[profile_id]
        return profile_id

    def union(lhs: str, rhs: str) -> None:
        lhs_root = find(lhs)
        rhs_root = find(rhs)
        if lhs_root != rhs_root:
            parent[rhs_root] = lhs_root

    for candidate in candidates:
        union(candidate["source_profile_id"], candidate["target_profile_id"])

    components: dict[str, set[str]] = {}
    for profile_id in list(parent):
        components.setdefault(find(profile_id), set()).add(profile_id)
    return sum(max(0, len(profile_ids) - 1) for profile_ids in components.values())


def build_auto_recognition_experiment(
    candidates: list[dict[str, Any]],
    recurring_labels: list[str],
    real_speaker_ids: dict[str, str],
    first_seen: dict[str, int],
    include_speaker_labels: bool,
    maturity_source: str = "raw_profile_maturity",
    total_observation_field: str = "profile_total_observation_count",
    prior_meeting_field: str = "profile_prior_meeting_count",
) -> dict[str, Any]:
    policies = [
        auto_recognition_policy_report(
            candidates=candidates,
            recurring_labels=recurring_labels,
            real_speaker_ids=real_speaker_ids,
            first_seen=first_seen,
            include_speaker_labels=include_speaker_labels,
            minimum_total_observations=minimum_total_observations,
            minimum_prior_meetings=minimum_prior_meetings,
            minimum_similarity=minimum_similarity,
            minimum_similarity_separation=minimum_similarity_separation,
            maturity_source=maturity_source,
            total_observation_field=total_observation_field,
            prior_meeting_field=prior_meeting_field,
        )
        for minimum_total_observations in AUTO_RECOGNITION_EXPERIMENT_TOTAL_OBSERVATIONS
        for minimum_prior_meetings in AUTO_RECOGNITION_EXPERIMENT_PRIOR_MEETINGS
        for minimum_similarity in AUTO_RECOGNITION_EXPERIMENT_SIMILARITIES
        for minimum_similarity_separation in AUTO_RECOGNITION_EXPERIMENT_SEPARATIONS
    ]
    current_policy = auto_recognition_policy_report(
        candidates=candidates,
        recurring_labels=recurring_labels,
        real_speaker_ids=real_speaker_ids,
        first_seen=first_seen,
        include_speaker_labels=include_speaker_labels,
        minimum_total_observations=5,
        minimum_prior_meetings=1,
        minimum_similarity=0.98,
        minimum_similarity_separation=None,
        maturity_source=maturity_source,
        total_observation_field=total_observation_field,
        prior_meeting_field=prior_meeting_field,
        policy_name="current_product_gate",
    )
    zero_false = [
        policy for policy in policies
        if policy["false_automatic_matches"] == 0 and policy["automatic_matches_total"] > 0
    ]
    best_zero_false = sorted(
        zero_false,
        key=lambda item: (
            -item["recognized_recurring_speakers"],
            -item["correct_automatic_matches"],
            item["median_meetings_after_first_seen"] if item["median_meetings_after_first_seen"] is not None else 999,
            item["minimum_total_observations"],
            item["minimum_prior_meetings"],
            item["minimum_similarity"],
        ),
    )
    return {
        "maturity_source": maturity_source,
        "total_observation_field": total_observation_field,
        "prior_meeting_field": prior_meeting_field,
        "candidate_events_total": len(candidates),
        "experiment_policy_count": len(policies),
        "current_product_gate_projection": current_policy,
        "best_zero_false_policies": best_zero_false[:10],
        "risk_frontier_by_false_match_budget": risk_frontier_by_false_match_budget(policies),
        "policies": policies,
        "notes": [
            "Eval-only sweep. Product auto-naming behavior is not changed.",
            "minimum_total_observations means the current hearing counts, so 5 means recognize on the fifth observed match or later.",
            "Zoom labels are used only after the fact to score whether each simulated automatic recognition would be correct.",
        ],
    }


def auto_recognition_policy_report(
    candidates: list[dict[str, Any]],
    recurring_labels: list[str],
    real_speaker_ids: dict[str, str],
    first_seen: dict[str, int],
    include_speaker_labels: bool,
    minimum_total_observations: int,
    minimum_prior_meetings: int,
    minimum_similarity: float,
    minimum_similarity_separation: float | None,
    maturity_source: str = "raw_profile_maturity",
    total_observation_field: str = "profile_total_observation_count",
    prior_meeting_field: str = "profile_prior_meeting_count",
    policy_name: str | None = None,
) -> dict[str, Any]:
    accepted = [
        candidate for candidate in candidates
        if auto_recognition_candidate_passes(
            candidate,
            minimum_total_observations=minimum_total_observations,
            minimum_prior_meetings=minimum_prior_meetings,
            minimum_similarity=minimum_similarity,
            minimum_similarity_separation=minimum_similarity_separation,
            total_observation_field=total_observation_field,
            prior_meeting_field=prior_meeting_field,
        )
    ]
    correct = [candidate for candidate in accepted if candidate["correct"]]
    wrong = [candidate for candidate in accepted if not candidate["correct"]]
    recurring_set = set(recurring_labels)
    first_recognition: dict[str, int] = {}
    for candidate in sorted(correct, key=lambda item: (item["ordinal"], item["meeting_id"], item["profile_id"])):
        canonical = candidate["expected_real_speaker"]
        if canonical in recurring_set:
            first_recognition.setdefault(canonical, int(candidate["ordinal"]))

    gaps = [
        first_recognition[canonical] - first_seen[canonical]
        for canonical in recurring_labels
        if canonical in first_recognition
    ]
    return {
        "policy": policy_name or auto_recognition_policy_name(
            minimum_total_observations,
            minimum_prior_meetings,
            minimum_similarity,
            minimum_similarity_separation,
        ),
        "maturity_source": maturity_source,
        "minimum_total_observations": minimum_total_observations,
        "minimum_prior_meetings": minimum_prior_meetings,
        "minimum_similarity": minimum_similarity,
        "minimum_similarity_separation": minimum_similarity_separation,
        "automatic_matches_total": len(accepted),
        "correct_automatic_matches": len(correct),
        "false_automatic_matches": len(wrong),
        "precision": ratio(len(correct), len(accepted)),
        "recognized_recurring_speakers": len(gaps),
        "never_recognized_recurring_speakers": len(recurring_labels) - len(gaps),
        "median_meetings_after_first_seen": median(gaps) if gaps else None,
        "max_meetings_after_first_seen": max(gaps) if gaps else None,
        "recognized_by_meetings_after_first_seen": recognition_curve(gaps),
        "wrong_cases": [
            _redacted_label_case(candidate, real_speaker_ids, include_speaker_labels)
            for candidate in wrong[:10]
        ],
    }


def auto_recognition_candidate_passes(
    candidate: dict[str, Any],
    minimum_total_observations: int,
    minimum_prior_meetings: int,
    minimum_similarity: float,
    minimum_similarity_separation: float | None,
    total_observation_field: str = "profile_total_observation_count",
    prior_meeting_field: str = "profile_prior_meeting_count",
) -> bool:
    if float(candidate["similarity"]) <= minimum_similarity:
        return False
    if int(candidate.get(total_observation_field) or 0) < minimum_total_observations:
        return False
    if int(candidate.get(prior_meeting_field) or 0) < minimum_prior_meetings:
        return False
    if minimum_similarity_separation is None:
        return True
    separation = candidate.get("similarity_separation")
    return separation is None or float(separation) >= minimum_similarity_separation


def auto_recognition_policy_name(
    minimum_total_observations: int,
    minimum_prior_meetings: int,
    minimum_similarity: float,
    minimum_similarity_separation: float | None,
) -> str:
    similarity = str(minimum_similarity).replace(".", "_")
    separation = (
        "any"
        if minimum_similarity_separation is None
        else str(minimum_similarity_separation).replace(".", "_")
    )
    return (
        f"heard_{minimum_total_observations}_times_"
        f"prior_meetings_{minimum_prior_meetings}_"
        f"similarity_{similarity}_"
        f"separation_{separation}"
    )


def recognition_curve(gaps: list[int]) -> dict[str, int]:
    return {
        f"within_{limit}_meetings": sum(1 for gap in gaps if gap <= limit)
        for limit in [1, 2, 3, 4, 5]
    }


def risk_frontier_by_false_match_budget(policies: list[dict[str, Any]]) -> list[dict[str, Any]]:
    frontier: list[dict[str, Any]] = []
    for false_budget in [0, 1, 2, 5, 10, 20]:
        candidates = [
            policy for policy in policies
            if policy["automatic_matches_total"] > 0
            and policy["false_automatic_matches"] <= false_budget
        ]
        if not candidates:
            continue
        best = sorted(
            candidates,
            key=lambda policy: (
                -policy["recognized_recurring_speakers"],
                -policy["correct_automatic_matches"],
                policy["false_automatic_matches"],
                policy["median_meetings_after_first_seen"]
                if policy["median_meetings_after_first_seen"] is not None
                else 999,
                -policy["automatic_matches_total"],
            ),
        )[0]
        frontier.append(
            {
                "false_match_budget": false_budget,
                "policy": best["policy"],
                "automatic_matches_total": best["automatic_matches_total"],
                "correct_automatic_matches": best["correct_automatic_matches"],
                "false_automatic_matches": best["false_automatic_matches"],
                "recognized_recurring_speakers": best["recognized_recurring_speakers"],
                "median_meetings_after_first_seen": best["median_meetings_after_first_seen"],
                "minimum_total_observations": best["minimum_total_observations"],
                "minimum_prior_meetings": best["minimum_prior_meetings"],
                "minimum_similarity": best["minimum_similarity"],
                "minimum_similarity_separation": best["minimum_similarity_separation"],
            }
        )
    return frontier


def with_oracle_merged_maturity(
    candidates: list[dict[str, Any]],
    observations: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    sorted_candidates = sorted(candidates, key=lambda item: item["observation_index"])
    sorted_observations = sorted(observations, key=lambda item: item["observation_index"])
    prior_counts: dict[str, int] = {}
    prior_meetings: dict[str, set[str]] = {}
    observation_cursor = 0
    enriched: list[dict[str, Any]] = []

    for candidate in sorted_candidates:
        while (
            observation_cursor < len(sorted_observations)
            and sorted_observations[observation_cursor]["observation_index"] < candidate["observation_index"]
        ):
            observation = sorted_observations[observation_cursor]
            canonical = observation["expected_real_speaker"]
            prior_counts[canonical] = prior_counts.get(canonical, 0) + 1
            prior_meetings.setdefault(canonical, set()).add(observation["meeting_id"])
            observation_cursor += 1

        profile_label = candidate["profile_real_speaker"]
        candidate_with_maturity = dict(candidate)
        candidate_with_maturity["oracle_merged_prior_observation_count"] = prior_counts.get(profile_label, 0)
        candidate_with_maturity["oracle_merged_total_observation_count"] = prior_counts.get(profile_label, 0) + 1
        candidate_with_maturity["oracle_merged_prior_meeting_count"] = len(prior_meetings.get(profile_label, set()))
        enriched.append(candidate_with_maturity)

    return enriched


def build_confirmed_merge_auto_naming_projection(
    observations: list[dict[str, Any]],
    safe_after_merge_candidates: list[dict[str, Any]],
    safe_after_merge_policy: dict[str, Any],
    duplicate_merge_review: dict[str, Any],
    duplicate_counts: dict[str, int],
    unknown_labels_required: int,
    confirmation_labels_required: int,
    correct_automatic_matches: int,
    false_automatic_matches: int,
    recurring_labels: list[str],
    real_speaker_ids: dict[str, str],
    first_seen: dict[str, int],
    include_speaker_labels: bool,
) -> dict[str, Any]:
    voice_anchor_candidates = confirmed_merged_profile_candidates(observations)
    voice_anchor_policy = auto_recognition_policy_report(
        candidates=voice_anchor_candidates,
        recurring_labels=recurring_labels,
        real_speaker_ids=real_speaker_ids,
        first_seen=first_seen,
        include_speaker_labels=include_speaker_labels,
        minimum_total_observations=5,
        minimum_prior_meetings=1,
        minimum_similarity=0.98,
        minimum_similarity_separation=None,
        maturity_source="confirmed_merged_profile_anchors",
        total_observation_field="confirmed_merged_total_observation_count",
        prior_meeting_field="confirmed_merged_prior_meeting_count",
        policy_name="current_product_gate_after_voice_anchor_merges",
    )
    accepted = [
        candidate for candidate in safe_after_merge_candidates
        if auto_recognition_candidate_passes(
            candidate,
            minimum_total_observations=5,
            minimum_prior_meetings=1,
            minimum_similarity=0.98,
            minimum_similarity_separation=None,
            total_observation_field="oracle_merged_total_observation_count",
            prior_meeting_field="oracle_merged_prior_meeting_count",
        )
    ]
    correct_accepted = [candidate for candidate in accepted if candidate["correct"]]
    unknown_reduction = sum(
        1 for candidate in correct_accepted
        if candidate.get("baseline_label_action") == "unknown_label"
    )
    confirmation_reduction = sum(
        1 for candidate in correct_accepted
        if candidate.get("baseline_label_action") == "confirmation_needed"
    )
    duplicate_total = sum(duplicate_counts.values())
    projected_duplicate_after = duplicate_merge_review["projected_duplicate_profiles_after_perfect_review"]
    before = {
        "unknown_labels_required": unknown_labels_required,
        "confirmation_labels_required": confirmation_labels_required,
        "correct_automatic_matches": correct_automatic_matches,
        "false_automatic_matches": false_automatic_matches,
        "duplicate_profiles": duplicate_total,
        "recognized_recurring_speakers": current_baseline_recurring_count(
            observations=observations,
            recurring_labels=recurring_labels,
        ),
    }
    after = {
        "unknown_labels_required": max(0, unknown_labels_required - unknown_reduction),
        "confirmation_labels_required": max(0, confirmation_labels_required - confirmation_reduction),
        "correct_automatic_matches": safe_after_merge_policy["correct_automatic_matches"],
        "false_automatic_matches": safe_after_merge_policy["false_automatic_matches"],
        "duplicate_profiles": projected_duplicate_after,
        "recognized_recurring_speakers": safe_after_merge_policy["recognized_recurring_speakers"],
    }
    return {
        "projection_basis": (
            "Eval-only simulation: user-approved duplicate merges share profile maturity before applying "
            "the unchanged 0.98 automatic naming gate."
        ),
        "safe_merge_candidates_confirmed": duplicate_merge_review["merge_candidates_correct"],
        "wrong_merge_candidates_shown": duplicate_merge_review["merge_candidates_wrong"],
        "held_back_voice_only_candidates": duplicate_merge_review["held_back_voice_only_candidates"],
        "candidate_events_total": len(safe_after_merge_candidates),
        "current_product_gate_projection": safe_after_merge_policy,
        "voice_anchor_candidate_events_total": len(voice_anchor_candidates),
        "voice_anchor_current_product_gate_projection": voice_anchor_policy,
        "before": before,
        "after_confirmed_merges": after,
        "delta": {
            "unknown_labels_required": after["unknown_labels_required"] - before["unknown_labels_required"],
            "confirmation_labels_required": after["confirmation_labels_required"] - before["confirmation_labels_required"],
            "correct_automatic_matches": after["correct_automatic_matches"] - before["correct_automatic_matches"],
            "false_automatic_matches": after["false_automatic_matches"] - before["false_automatic_matches"],
            "duplicate_profiles": after["duplicate_profiles"] - before["duplicate_profiles"],
            "recognized_recurring_speakers": (
                after["recognized_recurring_speakers"] - before["recognized_recurring_speakers"]
            ),
        },
        "label_reduction_sources": {
            "unknown_labels_reduced_by_correct_auto_names": unknown_reduction,
            "confirmation_labels_reduced_by_correct_auto_names": confirmation_reduction,
        },
        "report_notes": [
            "This does not change product thresholds or auto-naming behavior.",
            "Zoom labels are used only to score and simulate confirmed user outcomes in the eval.",
            "The main projection shares maturity/history only; the voice-anchor stress test is reported separately.",
            "Voice anchors are used transiently for local scoring and are not written into the report.",
        ],
    }


def confirmed_merged_profile_candidates(observations: list[dict[str, Any]]) -> list[dict[str, Any]]:
    states: dict[str, dict[str, Any]] = {}
    candidates: list[dict[str, Any]] = []
    for observation in sorted(observations, key=lambda item: item["observation_index"]):
        embedding = observation.get("embedding")
        expected = observation["expected_real_speaker"]
        if embedding and states:
            ranked = sorted(
                (
                    (label, max_anchor_similarity(embedding, state["embeddings"]), state)
                    for label, state in states.items()
                ),
                key=lambda item: item[1],
                reverse=True,
            )
            best_label, similarity, best_state = ranked[0]
            second_best = ranked[1][1] if len(ranked) > 1 else None
            candidates.append(
                {
                    "meeting_id": observation["meeting_id"],
                    "ordinal": observation["ordinal"],
                    "observation_index": observation["observation_index"],
                    "profile_id": f"confirmed_merged_{_stable_hash(best_label)}",
                    "expected_real_speaker": expected,
                    "profile_real_speaker": best_label,
                    "similarity": similarity,
                    "second_best_similarity": second_best,
                    "similarity_separation": (
                        similarity - second_best
                        if second_best is not None
                        else None
                    ),
                    "confirmed_merged_prior_observation_count": best_state["observation_count"],
                    "confirmed_merged_total_observation_count": best_state["observation_count"] + 1,
                    "confirmed_merged_prior_meeting_count": len(best_state["meeting_ids"]),
                    "baseline_label_action": observation.get("baseline_label_action"),
                    "correct": best_label == expected,
                }
            )
        if embedding:
            update_confirmed_merged_profile_state(states, expected, embedding, observation["meeting_id"])
    return candidates


def update_confirmed_merged_profile_state(
    states: dict[str, dict[str, Any]],
    canonical: str,
    embedding: list[float],
    meeting_id: str,
) -> None:
    if canonical not in states:
        states[canonical] = {
            "embeddings": [list(embedding)],
            "observation_count": 1,
            "meeting_ids": {meeting_id},
        }
        return

    state = states[canonical]
    state["embeddings"].append(list(embedding))
    state["observation_count"] += 1
    state["meeting_ids"].add(meeting_id)


def max_anchor_similarity(embedding: list[float], anchors: list[list[float]]) -> float:
    return max((cosine_similarity(embedding, anchor) for anchor in anchors), default=0.0)


def current_baseline_recurring_count(
    observations: list[dict[str, Any]],
    recurring_labels: list[str],
) -> int:
    recurring_set = set(recurring_labels)
    recognized = {
        observation["expected_real_speaker"]
        for observation in observations
        if observation.get("baseline_label_action") == "automatic_correct"
        and observation["expected_real_speaker"] in recurring_set
    }
    return len(recognized)


def _stable_hash(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:10]


def build_confirmation_safety_filter_reports(
    suggestions: list[dict[str, Any]],
    duplicate_counts: dict[str, int],
) -> list[dict[str, Any]]:
    return [
        confirmation_filter_report(
            suggestions=suggestions,
            duplicate_counts=duplicate_counts,
            filter_name=spec["filter"],
            category=spec["category"],
            criteria=spec["criteria"],
            predicate=spec["predicate"],
        )
        for spec in confirmation_safety_filter_specs()
    ]


def confirmation_safety_filter_specs() -> list[dict[str, Any]]:
    return [
        *threshold_filter_specs(
            field="profile_prior_meeting_count",
            label="profile meetings seen",
            category="profile_maturity",
            thresholds=[2, 3, 5],
        ),
        *threshold_filter_specs(
            field="profile_prior_call_count",
            label="profile call count",
            category="profile_maturity",
            thresholds=[3, 5, 10],
        ),
        *threshold_filter_specs(
            field="speaker_duration_seconds",
            label="current speaking duration seconds",
            category="current_evidence",
            thresholds=[10, 30, 60, 120, 300],
        ),
        *threshold_filter_specs(
            field="segment_count",
            label="current segment count",
            category="current_evidence",
            thresholds=[3, 5, 10],
        ),
        *threshold_filter_specs(
            field="similarity_separation",
            label="similarity separation from second-best profile",
            category="ambiguity",
            thresholds=[0.10, 0.15, 0.20, 0.30],
            missing_passes=True,
        ),
        {
            "filter": "current_channel_system_only",
            "category": "channel",
            "criteria": "current channel is system",
            "group": "current_channel",
            "predicate": lambda suggestion: suggestion.get("channel") == "system",
        },
        {
            "filter": "current_channel_microphone_only",
            "category": "channel",
            "criteria": "current channel is microphone",
            "group": "current_channel",
            "predicate": lambda suggestion: suggestion.get("channel") == "microphone",
        },
        {
            "filter": "profile_seen_on_same_channel",
            "category": "channel",
            "criteria": "profile was previously seen on the same channel",
            "group": "profile_channel_history",
            "predicate": lambda suggestion: suggestion.get("channel") in set(suggestion.get("profile_source_channels", [])),
        },
        {
            "filter": "profile_same_channel_only",
            "category": "channel",
            "criteria": "profile was previously seen only on the current channel",
            "group": "profile_channel_history",
            "predicate": lambda suggestion: set(suggestion.get("profile_source_channels", [])) == {suggestion.get("channel")},
        },
        {
            "filter": "profile_cross_channel_history",
            "category": "channel",
            "criteria": "profile has prior cross-channel history or lacks current channel history",
            "group": "profile_channel_history",
            "predicate": lambda suggestion: set(suggestion.get("profile_source_channels", [])) != {suggestion.get("channel")},
        },
        {
            "filter": "profile_seen_multiple_prior_meetings",
            "category": "repeat_evidence",
            "criteria": "profile was seen in at least two prior meetings",
            "group": "profile_prior_meeting_count",
            "predicate": lambda suggestion: int(suggestion.get("profile_prior_meeting_count") or 0) >= 2,
        },
        {
            "filter": "no_microphone_bleed_suppression_in_meeting",
            "category": "recording_quality",
            "criteria": "meeting had no microphone-bleed suppression",
            "group": "microphone_bleed_suppression",
            "predicate": lambda suggestion: not suggestion.get("meeting_had_microphone_bleed_suppression", False),
        },
        {
            "filter": "profile_not_created_in_same_meeting",
            "category": "profile_origin",
            "criteria": "profile existed before this meeting",
            "group": "profile_created_in_same_meeting",
            "predicate": lambda suggestion: not suggestion.get("profile_created_in_same_meeting", False),
        },
        {
            "filter": "profile_has_prior_manual_name",
            "category": "profile_origin",
            "criteria": "profile already has a user-confirmed/manual name",
            "group": "profile_has_prior_manual_name",
            "predicate": lambda suggestion: bool(suggestion.get("profile_has_prior_manual_name")),
        },
        {
            "filter": "system_duration_300_separation_0_3",
            "category": "compound_strategy",
            "criteria": "system channel, current speaking duration >= 300s, similarity separation >= 0.30",
            "predicate": lambda suggestion: (
                suggestion.get("channel") == "system"
                and value_at_least(suggestion.get("speaker_duration_seconds"), 300)
                and value_at_least(suggestion.get("similarity_separation"), 0.30, missing_passes=True)
            ),
        },
        {
            "filter": "system_duration_120_separation_0_2",
            "category": "compound_strategy",
            "criteria": "system channel, current speaking duration >= 120s, similarity separation >= 0.20",
            "predicate": lambda suggestion: (
                suggestion.get("channel") == "system"
                and value_at_least(suggestion.get("speaker_duration_seconds"), 120)
                and value_at_least(suggestion.get("similarity_separation"), 0.20, missing_passes=True)
            ),
        },
        {
            "filter": "profile_meetings_2_system_duration_120",
            "category": "compound_strategy",
            "criteria": "profile seen in >= 2 prior meetings, system channel, current speaking duration >= 120s",
            "predicate": lambda suggestion: (
                value_at_least(suggestion.get("profile_prior_meeting_count"), 2)
                and suggestion.get("channel") == "system"
                and value_at_least(suggestion.get("speaker_duration_seconds"), 120)
            ),
        },
        {
            "filter": "profile_meetings_2_same_channel_separation_0_2",
            "category": "compound_strategy",
            "criteria": "profile seen in >= 2 prior meetings, same-channel profile history, similarity separation >= 0.20",
            "predicate": lambda suggestion: (
                value_at_least(suggestion.get("profile_prior_meeting_count"), 2)
                and suggestion.get("channel") in set(suggestion.get("profile_source_channels", []))
                and value_at_least(suggestion.get("similarity_separation"), 0.20, missing_passes=True)
            ),
        },
        {
            "filter": "no_bleed_system_separation_0_2",
            "category": "compound_strategy",
            "criteria": "no microphone-bleed suppression in meeting, system channel, similarity separation >= 0.20",
            "predicate": lambda suggestion: (
                not suggestion.get("meeting_had_microphone_bleed_suppression", False)
                and suggestion.get("channel") == "system"
                and value_at_least(suggestion.get("similarity_separation"), 0.20, missing_passes=True)
            ),
        },
        {
            "filter": "profile_call_count_5_duration_120",
            "category": "compound_strategy",
            "criteria": "profile call count >= 5, current speaking duration >= 120s",
            "predicate": lambda suggestion: (
                value_at_least(suggestion.get("profile_prior_call_count"), 5)
                and value_at_least(suggestion.get("speaker_duration_seconds"), 120)
            ),
        },
        {
            "filter": "profile_meetings_3_duration_300",
            "category": "compound_strategy",
            "criteria": "profile seen in >= 3 prior meetings, current speaking duration >= 300s",
            "predicate": lambda suggestion: (
                value_at_least(suggestion.get("profile_prior_meeting_count"), 3)
                and value_at_least(suggestion.get("speaker_duration_seconds"), 300)
            ),
        },
    ]


def threshold_filter_specs(
    field: str,
    label: str,
    category: str,
    thresholds: list[int | float],
    missing_passes: bool = False,
) -> list[dict[str, Any]]:
    specs = []
    for threshold in thresholds:
        suffix = str(threshold).replace(".", "_")
        specs.append(
            {
                "filter": f"{field}_at_least_{suffix}",
                "category": category,
                "criteria": f"{label} >= {threshold}",
                "group": field,
                "predicate": (
                    lambda suggestion, field=field, threshold=threshold, missing_passes=missing_passes:
                    value_at_least(suggestion.get(field), threshold, missing_passes)
                ),
            }
        )
    return specs


def value_at_least(value: Any, threshold: int | float, missing_passes: bool = False) -> bool:
    if value is None:
        return missing_passes
    try:
        return float(value) >= float(threshold)
    except (TypeError, ValueError):
        return False


def build_confirmation_compound_strategy_search(
    suggestions: list[dict[str, Any]],
    duplicate_counts: dict[str, int],
) -> dict[str, Any]:
    searchable_specs = [
        spec
        for spec in confirmation_safety_filter_specs()
        if spec["category"] != "compound_strategy"
    ]
    reports: list[dict[str, Any]] = []
    searched = 0
    for size in range(2, 5):
        for combo in combinations(searchable_specs, size):
            groups = [spec.get("group", spec["filter"]) for spec in combo]
            if len(set(groups)) != len(groups):
                continue
            searched += 1
            filter_name = "all_of__" + "__".join(spec["filter"] for spec in combo)
            criteria = " AND ".join(spec["criteria"] for spec in combo)
            report = confirmation_filter_report(
                suggestions=suggestions,
                duplicate_counts=duplicate_counts,
                filter_name=filter_name,
                category="compound_search",
                criteria=criteria,
                predicate=lambda suggestion, combo=combo: all(
                    spec["predicate"](suggestion)
                    for spec in combo
                ),
            )
            if report["suggestions_shown"] == 0:
                continue
            reports.append(report)

    zero_wrong = [report for report in reports if report["wrong_suggestions"] == 0]
    ranked_zero_wrong = sorted(
        zero_wrong,
        key=lambda item: (
            -item["correct_suggestions"],
            -item["suggestions_shown"],
            -item["projected_duplicate_reduction_upper_bound"],
            item["filter"],
        ),
    )
    best_precision = sorted(
        reports,
        key=lambda item: (
            -(item["precision"] if item["precision"] is not None else -1),
            -item["correct_suggestions"],
            -item["suggestions_shown"],
            -item["projected_duplicate_reduction_upper_bound"],
            item["filter"],
        ),
    )
    zero_wrong_min_coverage = [
        report for report in ranked_zero_wrong
        if report["suggestions_shown"] >= 3
    ]
    best_min_3 = [
        report for report in best_precision
        if report["suggestions_shown"] >= 3
    ]
    best_min_10 = [
        report for report in best_precision
        if report["suggestions_shown"] >= 10
    ]
    max_zero_wrong_suggestions = max(
        (report["suggestions_shown"] for report in zero_wrong),
        default=0,
    )
    return {
        "minimum_coverage_for_candidate_strategy": 3,
        "searched_strategy_count": searched,
        "strategies_with_suggestions": len(reports),
        "zero_wrong_compound_strategy_count": len(zero_wrong),
        "zero_wrong_compound_strategy_min_coverage_count": len(zero_wrong_min_coverage),
        "max_zero_wrong_suggestions_shown": max_zero_wrong_suggestions,
        "zero_wrong_compound_strategies": ranked_zero_wrong[:10],
        "zero_wrong_compound_strategies_min_3_suggestions": zero_wrong_min_coverage[:10],
        "best_precision_compound_strategies": best_precision[:10],
        "best_precision_compound_strategies_min_3_suggestions": best_min_3[:10],
        "best_precision_compound_strategies_min_10_suggestions": best_min_10[:10],
        "search_notes": [
            "Eval-only exploratory search over conjunctions of non-transcript safety filters.",
            "Strategies are scored with Zoom labels only after filtering; labels are not part of the filter criteria.",
            "Zero wrong suggestions on this corpus is evidence to investigate, not enough by itself for automatic naming.",
        ],
    }


def confirmation_filter_report(
    suggestions: list[dict[str, Any]],
    duplicate_counts: dict[str, int],
    filter_name: str,
    category: str,
    criteria: str,
    predicate: Callable[[dict[str, Any]], bool],
) -> dict[str, Any]:
    shown = [suggestion for suggestion in suggestions if predicate(suggestion)]
    correct = [suggestion for suggestion in shown if suggestion["correct"]]
    wrong = len(shown) - len(correct)
    confirmed_speakers = {suggestion["expected_real_speaker"] for suggestion in correct}
    return {
        "filter": filter_name,
        "category": category,
        "criteria": criteria,
        "suggestions_shown": len(shown),
        "correct_suggestions": len(correct),
        "wrong_suggestions": wrong,
        "precision": ratio(len(correct), len(shown)),
        "projected_unknown_label_reduction": len(correct),
        "projected_duplicate_reduction_upper_bound": sum(
            duplicate_counts.get(canonical, 0)
            for canonical in confirmed_speakers
        ),
        "safe_for_confirmation_suggestion": len(shown) > 0 and wrong == 0,
    }


def confirmation_band_report(
    label: str,
    min_similarity: float | None,
    max_similarity: float | None,
    suggestions: list[dict[str, Any]],
) -> dict[str, Any]:
    band_suggestions = [
        suggestion
        for suggestion in suggestions
        if similarity_in_band(float(suggestion["similarity"]), min_similarity, max_similarity)
    ]
    correct = sum(1 for suggestion in band_suggestions if suggestion["correct"])
    wrong = len(band_suggestions) - correct
    return {
        "band": label,
        "min_similarity": min_similarity,
        "max_similarity": max_similarity,
        "suggestions_total": len(band_suggestions),
        "suggestions_correct": correct,
        "suggestions_wrong": wrong,
        "precision": ratio(correct, len(band_suggestions)),
        "safe_for_looks_like": bool(band_suggestions) and wrong == 0,
    }


def similarity_in_band(similarity: float, min_similarity: float | None, max_similarity: float | None) -> bool:
    if min_similarity is not None and similarity < min_similarity:
        return False
    if max_similarity is not None and similarity >= max_similarity:
        return False
    return True


def recommended_confirmation_threshold(bands: list[dict[str, Any]]) -> float | None:
    recommended: float | None = None
    for band in bands:
        if band["suggestions_wrong"] > 0:
            break
        if band["suggestions_total"] > 0:
            recommended = band["min_similarity"]
    return recommended


def ratio(numerator: int, denominator: int) -> float | None:
    if denominator == 0:
        return None
    return round(numerator / denominator, 4)


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
        f"confirmations={summary.get('confirmation_labels_required', 0)} "
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

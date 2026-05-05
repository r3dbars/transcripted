from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from speaker_learning_eval import (
    AudioSegment,
    AudioSpeakerProfile,
    evaluate_audio_corpus,
    evaluate_corpus,
    parse_zoom_turns,
    should_auto_accept_audio_profile,
)


class SpeakerLearningEvalTests(unittest.TestCase):
    def test_parse_zoom_turns_uses_labels_without_exposing_text(self):
        with tempfile.TemporaryDirectory() as temp:
            transcript = Path(temp) / "transcript.txt"
            transcript.write_text(
                "[Speaker One] 00:00:01\n"
                "SECRET TRANSCRIPT TEXT SHOULD NOT ENTER REPORTS\n\n"
                "[Speaker Two] 00:00:02\n"
                "More private transcript text\n",
                encoding="utf-8",
            )

            turns = parse_zoom_turns(transcript)

            self.assertEqual([turn.speaker_label for turn in turns], ["Speaker One", "Speaker Two"])

    def test_cold_start_metrics_track_unknowns_matches_and_recognition(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_meeting(root, "meeting-0001", ["Speaker A", "Speaker B", "Speaker A"])
            self._write_meeting(root, "meeting-0002", ["Speaker A", "Speaker C"])
            self._write_meeting(root, "meeting-0003", ["Speaker B", "Speaker C", "Speaker C"])

            report = evaluate_corpus(root)
            summary = report["summary"]

            self.assertEqual(summary["meetings_evaluated"], 3)
            self.assertEqual(summary["distinct_real_speakers"], 3)
            self.assertEqual(summary["unknown_labels_required"], 3)
            self.assertEqual(summary["correct_automatic_matches"], 3)
            self.assertEqual(summary["false_matches"], 0)
            self.assertEqual(summary["duplicate_profiles_per_real_speaker"]["total"], 0)
            self.assertEqual(summary["turns"]["unknown_turns"], 4)
            self.assertEqual(summary["turns"]["correct_automatic_match_turns"], 4)
            self.assertEqual(summary["meetings_to_first_recognition"]["recognized_speakers"], 3)
            self.assertEqual(summary["meetings_to_first_recognition"]["max_meetings_after_first_seen"], 2)

    def test_zoom_turn_timestamps_are_relative_to_first_caption(self):
        with tempfile.TemporaryDirectory() as temp:
            transcript = Path(temp) / "transcript.txt"
            transcript.write_text(
                "[Speaker One] 08:04:08\n"
                "private text\n\n"
                "[Speaker Two] 08:04:18\n"
                "private text\n",
                encoding="utf-8",
            )

            turns = parse_zoom_turns(transcript)

            self.assertEqual([turn.speaker_label for turn in turns], ["Speaker One", "Speaker Two"])
            self.assertEqual([turn.start_seconds for turn in turns], [0.0, 10.0])

    def test_audio_eval_tracks_matches_duplicates_and_false_matches(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_meeting(root, "meeting-0001", ["Speaker A", "Speaker B"], include_audio=True)
            self._write_meeting(root, "meeting-0002", ["Speaker A", "Speaker B"], include_audio=True)
            self._write_meeting(root, "meeting-0003", ["Speaker C"], include_audio=True)

            def fake_diarizer(
                audio_path: Path,
                channel: str,
                meeting: dict,
                cache_dir: Path | None,
            ) -> list[AudioSegment]:
                if channel != "system":
                    return []
                data = {
                    "meeting-0001": [
                        ("0", 0.0, 1.0, [1.0, 0.0, 0.0]),
                        ("1", 1.0, 2.0, [0.0, 1.0, 0.0]),
                    ],
                    "meeting-0002": [
                        ("0", 0.0, 1.0, [1.0, 0.0, 0.0]),
                        ("1", 1.0, 2.0, [0.6, 0.0, 0.8]),
                    ],
                    "meeting-0003": [
                        ("0", 0.0, 1.0, [1.0, 0.0, 0.0]),
                    ],
                }
                return [
                    AudioSegment(
                        channel=channel,
                        speaker_id=speaker_id,
                        start_seconds=start,
                        end_seconds=end,
                        quality_score=0.95,
                        embedding=embedding,
                    )
                    for speaker_id, start, end, embedding in data[meeting["id"]]
                ]

            report = evaluate_audio_corpus(root, diarization_provider=fake_diarizer)
            summary = report["summary"]

            self.assertEqual(summary["meetings_evaluated"], 3)
            self.assertEqual(summary["unknown_labels_required"], 3)
            self.assertEqual(summary["confirmation_labels_required"], 2)
            self.assertEqual(summary["correct_automatic_matches"], 0)
            self.assertEqual(summary["false_automatic_matches"], 0)
            self.assertEqual(summary["deferred_profile_matches"], 2)
            self.assertEqual(summary["duplicate_profiles_per_real_speaker"]["total"], 1)
            self.assertEqual(summary["meetings_to_first_recognition"]["recognized_speakers"], 0)

    def test_audio_eval_only_auto_accepts_mature_high_similarity_matches(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for index in range(1, 7):
                self._write_meeting(root, f"meeting-000{index}", ["Speaker A"], include_audio=True)

            def fake_diarizer(
                audio_path: Path,
                channel: str,
                meeting: dict,
                cache_dir: Path | None,
            ) -> list[AudioSegment]:
                if channel != "system":
                    return []
                return [
                    AudioSegment(
                        channel=channel,
                        speaker_id="0",
                        start_seconds=0.0,
                        end_seconds=1.0,
                        quality_score=0.95,
                        embedding=[1.0, 0.0],
                    )
                ]

            report = evaluate_audio_corpus(root, diarization_provider=fake_diarizer)
            summary = report["summary"]

            self.assertEqual(summary["unknown_labels_required"], 1)
            self.assertEqual(summary["confirmation_labels_required"], 3)
            self.assertEqual(summary["deferred_profile_matches"], 3)
            self.assertEqual(summary["correct_automatic_matches"], 2)
            self.assertEqual(summary["false_automatic_matches"], 0)

    def test_audio_eval_suppresses_overlapping_microphone_bleed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_meeting(root, "meeting-0001", ["Speaker A"], include_audio=True)

            def fake_diarizer(
                audio_path: Path,
                channel: str,
                meeting: dict,
                cache_dir: Path | None,
            ) -> list[AudioSegment]:
                return [
                    AudioSegment(
                        channel=channel,
                        speaker_id="0",
                        start_seconds=0.0,
                        end_seconds=1.0,
                        quality_score=0.95,
                        embedding=[1.0, 0.0] if channel == "system" else [0.95, 0.05],
                    )
                ]

            report = evaluate_audio_corpus(root, diarization_provider=fake_diarizer)
            summary = report["summary"]

            self.assertEqual(summary["unknown_labels_required"], 1)
            self.assertEqual(summary["duplicate_profiles_per_real_speaker"]["total"], 0)
            self.assertEqual(summary["suppressed_microphone_bleed_segments"], 1)

    def test_audio_auto_accept_gate_rejects_near_matches(self):
        profile = AudioSpeakerProfile(
            profile_id="profile_0001",
            embedding=[1.0, 0.0],
            first_seen_meeting_id="meeting-0001",
            first_seen_ordinal=1,
            assigned_label="Speaker A",
            call_count=8,
        )

        self.assertFalse(should_auto_accept_audio_profile(profile, 0.97))
        self.assertTrue(should_auto_accept_audio_profile(profile, 0.99))

    def test_report_redacts_labels_and_transcript_text_by_default(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_meeting(root, "meeting-0001", ["Sensitive Name"])

            report = evaluate_corpus(root)
            encoded = json.dumps(report)

            self.assertNotIn("Sensitive Name", encoded)
            self.assertNotIn("SECRET", encoded)
            self.assertTrue(report["assumptions"]["speaker_labels_redacted"])

    def test_audio_report_redacts_labels_and_transcript_text_by_default(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_meeting(root, "meeting-0001", ["Sensitive Name"], include_audio=True)

            def fake_diarizer(
                audio_path: Path,
                channel: str,
                meeting: dict,
                cache_dir: Path | None,
            ) -> list[AudioSegment]:
                if channel != "system":
                    return []
                return [
                    AudioSegment(
                        channel=channel,
                        speaker_id="0",
                        start_seconds=0.0,
                        end_seconds=1.0,
                        quality_score=0.95,
                        embedding=[1.0, 0.0],
                    )
                ]

            report = evaluate_audio_corpus(root, diarization_provider=fake_diarizer)
            encoded = json.dumps(report)

            self.assertNotIn("Sensitive Name", encoded)
            self.assertNotIn("SECRET", encoded)
            self.assertTrue(report["assumptions"]["speaker_labels_redacted"])

    def _write_meeting(self, root: Path, meeting_id: str, labels: list[str], include_audio: bool = False) -> None:
        meeting_dir = root / meeting_id
        zoom_dir = meeting_dir / "zoom"
        zoom_dir.mkdir(parents=True)
        transcript_blocks = []
        for index, label in enumerate(labels):
            transcript_blocks.append(f"[{label}] 00:00:0{index}\nSECRET turn {index}")
        (zoom_dir / "transcript.txt").write_text("\n\n".join(transcript_blocks), encoding="utf-8")

        speaker_names = list(dict.fromkeys(labels))
        metadata = {
            "id": meeting_id,
            "start_local": f"2026-01-01T00:0{meeting_id[-1]}:00",
            "usable_for_eval": True,
            "zoom_transcript": {"path": "zoom/transcript.txt"},
            "speaker_names": speaker_names,
            "speaker_turn_count": len(labels),
        }
        if include_audio:
            audio_dir = meeting_dir / "audio"
            audio_dir.mkdir(parents=True)
            (audio_dir / "system_audio.wav").write_bytes(b"fake system audio")
            (audio_dir / "microphone.wav").write_bytes(b"fake microphone audio")
            metadata["audio"] = {
                "system_audio": {"path": "audio/system_audio.wav", "duration_seconds": len(labels)},
                "microphone": {"path": "audio/microphone.wav", "duration_seconds": len(labels)},
            }
        (meeting_dir / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")

        manifest_path = root / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else []
        manifest.append(metadata)
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")


if __name__ == "__main__":
    unittest.main()

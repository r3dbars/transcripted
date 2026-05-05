import json
import tempfile
import unittest
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from speaker_learning_eval import evaluate_corpus, parse_zoom_turns


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

    def test_report_redacts_labels_and_transcript_text_by_default(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self._write_meeting(root, "meeting-0001", ["Sensitive Name"])

            report = evaluate_corpus(root)
            encoded = json.dumps(report)

            self.assertNotIn("Sensitive Name", encoded)
            self.assertNotIn("SECRET", encoded)
            self.assertTrue(report["assumptions"]["speaker_labels_redacted"])

    def _write_meeting(self, root: Path, meeting_id: str, labels: list[str]) -> None:
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
        (meeting_dir / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")

        manifest_path = root / "manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else []
        manifest.append(metadata)
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")


if __name__ == "__main__":
    unittest.main()

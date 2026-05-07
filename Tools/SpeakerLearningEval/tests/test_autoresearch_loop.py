from __future__ import annotations

import unittest
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from autoresearch_loop import candidate_routes, rank_routes, score_route


class AutoresearchLoopTests(unittest.TestCase):
    def test_score_route_treats_wrong_names_as_hard_failure(self):
        safe = score_route(
            {
                "route": "safe",
                "metrics": {
                    "correct_automatic_matches": 2,
                    "false_automatic_matches": 0,
                },
            }
        )
        unsafe = score_route(
            {
                "route": "unsafe",
                "metrics": {
                    "correct_automatic_matches": 100,
                    "false_automatic_matches": 1,
                },
            }
        )

        self.assertTrue(safe["safe"])
        self.assertFalse(unsafe["safe"])
        self.assertGreater(safe["score"], unsafe["score"])

    def test_candidate_routes_extracts_and_ranks_zero_false_policies(self):
        report = {
            "summary": {},
            "auto_recognition_experiment": {
                "current_product_gate_projection": {
                    "correct_automatic_matches": 1,
                    "false_automatic_matches": 0,
                    "recognized_recurring_speakers": 1,
                    "confirmation_labels_avoided": 1,
                    "median_meetings_after_first_seen": 4,
                }
            },
            "auto_recognition_after_oracle_merge_experiment": {
                "current_product_gate_projection": {
                    "correct_automatic_matches": 2,
                    "false_automatic_matches": 0,
                    "recognized_recurring_speakers": 1,
                    "confirmation_labels_avoided": 2,
                    "median_meetings_after_first_seen": 3,
                }
            },
            "auto_recognition_quality_knob_experiment": {
                "best_zero_false_by_goal": {
                    "most_correct_auto_names": {
                        "correct_automatic_matches": 3,
                        "false_automatic_matches": 1,
                        "recognized_recurring_speakers": 2,
                        "confirmation_labels_avoided": 3,
                    }
                }
            },
            "auto_recognition_quality_after_oracle_merge_knob_experiment": {
                "best_zero_false_by_goal": {
                    "most_correct_auto_names": {
                        "correct_automatic_matches": 4,
                        "false_automatic_matches": 0,
                        "recognized_recurring_speakers": 2,
                        "confirmation_labels_avoided": 4,
                        "median_meetings_after_first_seen": 2,
                    }
                }
            },
            "duplicate_merge_review": {
                "strategy_experiment": {
                    "best_zero_wrong_strategies": [
                        {
                            "strategy": "current_named_only",
                            "correct_candidates": 2,
                            "wrong_candidates": 0,
                            "projected_duplicate_reduction_upper_bound": 2,
                        }
                    ]
                }
            },
        }

        ranked = rank_routes(candidate_routes(report))

        self.assertEqual(ranked[0]["route"], "clean_folders_quality_knobs.most_correct_auto_names")
        self.assertTrue(ranked[0]["safe"])
        self.assertTrue(any(route["route"] == "duplicate_review.current_named_only" for route in ranked))


if __name__ == "__main__":
    unittest.main()

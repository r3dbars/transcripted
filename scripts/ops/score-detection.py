#!/usr/bin/env python3
"""Score meeting-detection accuracy and emit score-detection.json.

Measures whether the meeting-prompt detector fires when it should and stays
quiet when it shouldn't, over a labelled fixture of app-state cases.

Inputs:
  --fixture   gold labels: {"items": [{"id": "...", "should_prompt": true, "note": "..."}]}
  --candidate detector decisions keyed by id: {"<id>": true|false}

The candidate is the detector's real decision for each fixture case, captured by
replaying the case's app-state through the detector on the Mac. Without it this
is INCOMPLETE.

score = 100 * F1 over the cases present in both fixture and candidate.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def score_detection(items: list[dict[str, Any]], candidate: dict[str, bool]) -> dict[str, Any]:
    tp = fp = fn = tn = 0
    scored = 0
    for item in items:
        cid = str(item["id"])
        if cid not in candidate:
            continue
        gold = bool(item.get("should_prompt", False))
        pred = bool(candidate[cid])
        scored += 1
        if gold and pred:
            tp += 1
        elif gold and not pred:
            fn += 1
        elif not gold and pred:
            fp += 1
        else:
            tn += 1

    if scored == 0:
        return {"present": False, "detail": "no overlapping candidate ids"}

    precision = tp / (tp + fp) if (tp + fp) else (1.0 if fn == 0 else 0.0)
    recall = tp / (tp + fn) if (tp + fn) else 1.0
    f1 = (2 * precision * recall) / (precision + recall) if (precision + recall) else 0.0
    return {
        "present": True,
        "score": round(100.0 * f1, 1),
        "precision": round(precision, 4),
        "recall": round(recall, 4),
        "f1": round(f1, 4),
        "tp": tp, "fp": fp, "fn": fn, "tn": tn,
        "scoredCases": scored,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--candidate", default="")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    out_path = Path(args.out).expanduser()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fixture = json.loads(Path(args.fixture).expanduser().read_text(encoding="utf-8"))
    items = fixture.get("items", [])

    if not args.candidate or not Path(args.candidate).expanduser().is_file():
        out_path.write_text(json.dumps({
            "board": "detection", "metric": "f1", "present": False, "score": None,
            "detail": "no detector decisions supplied (replay fixture cases through the detector on the Mac)",
        }, indent=2, sort_keys=True), encoding="utf-8")
        print("INCOMPLETE: meeting detection needs candidate decisions")
        return 3

    candidate = json.loads(Path(args.candidate).expanduser().read_text(encoding="utf-8"))
    result = score_detection(items, candidate)
    present = result.get("present", False)
    detail = (
        f"F1 {result['f1']:.2f} (P {result['precision']:.2f} / R {result['recall']:.2f}) "
        f"over {result['scoredCases']} cases" if present else result.get("detail", "")
    )
    out_path.write_text(json.dumps({
        "board": "detection", "metric": "f1",
        "present": present, "score": result.get("score"), "detail": detail, "subscores": result,
    }, indent=2, sort_keys=True), encoding="utf-8")
    print(f"detection: {detail}")
    return 0 if present else 3


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Score meeting-summary quality via an LLM judge and emit score-summary.json.

Summary quality is subjective, so the "judge" is the agent driving QA (Claude
Code, Codex, or any capable assistant) scoring the saved summary against the
transcript on a fixed rubric. Keeping the rubric frozen here is what makes the
judgement repeatable instead of vibes.

Two modes:

  --mode prompt   Build a local judge prompt packet from a transcript + summary
                  so the agent knows exactly what to score and how. Writes the
                  packet next to --out. Content stays local; nothing is uploaded.

  --mode score    Ingest the agent's rubric scores and fold them into a 0-100
                  board score. Judge result JSON:
                    {"meetings": [
                       {"id": "m1", "rubric": {
                          "coverage": 0-5, "faithfulness": 0-5,
                          "actionItems": 0-5, "conciseness": 0-5}}]}

Rubric dimensions and weights:
  coverage      0.30  did the summary capture the meeting's real topics
  faithfulness  0.35  no hallucinated facts, decisions, or attributions
  actionItems   0.25  action items / decisions captured and correctly assigned
  conciseness   0.10  tight, no filler, readable
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

RUBRIC_WEIGHTS = {"coverage": 0.30, "faithfulness": 0.35, "actionItems": 0.25, "conciseness": 0.10}

JUDGE_INSTRUCTIONS = """\
You are scoring a meeting summary against its source transcript. Score each
dimension 0-5 (0 unusable, 3 acceptable, 5 excellent). Be strict on
faithfulness: any invented fact, decision, or wrong attribution caps it at 2.

Return ONLY JSON in this exact shape:
{"id": "<meeting-id>", "rubric": {"coverage": N, "faithfulness": N, "actionItems": N, "conciseness": N}, "notes": "<one line, no transcript text>"}

Dimensions:
- coverage: are the meeting's real topics and outcomes represented?
- faithfulness: is everything in the summary actually supported by the transcript?
- actionItems: are action items / decisions captured and correctly assigned?
- conciseness: tight and readable, no filler or repetition?
"""


def rubric_to_score(rubric: dict[str, Any]) -> float:
    total = 0.0
    weight = 0.0
    for key, w in RUBRIC_WEIGHTS.items():
        if key in rubric:
            total += w * (float(rubric[key]) / 5.0)
            weight += w
    if weight <= 0:
        return 0.0
    return 100.0 * (total / weight)


def score_meetings(meetings: list[dict[str, Any]]) -> dict[str, Any]:
    scores = []
    for m in meetings:
        rubric = m.get("rubric", {})
        if rubric:
            scores.append(rubric_to_score(rubric))
    if not scores:
        return {"present": False, "detail": "no rubric scores supplied"}
    mean = sum(scores) / len(scores)
    return {"present": True, "score": round(mean, 1), "meetingsJudged": len(scores)}


def write_score(out_path: Path, result: dict[str, Any]) -> int:
    present = result.get("present", False)
    detail = f"judged {result['meetingsJudged']} meeting(s)" if present else result.get("detail", "")
    out_path.write_text(json.dumps({
        "board": "summary", "metric": "rubric", "present": present,
        "score": result.get("score"), "detail": detail, "subscores": result,
    }, indent=2, sort_keys=True), encoding="utf-8")
    print(f"summary: {detail}")
    return 0 if present else 3


def build_prompt(transcript_path: Path, summary_path: Path, meeting_id: str) -> str:
    transcript = transcript_path.read_text(encoding="utf-8", errors="replace")
    summary = summary_path.read_text(encoding="utf-8", errors="replace")
    return (
        JUDGE_INSTRUCTIONS
        + f"\nMeeting id: {meeting_id}\n"
        + "\n=== SUMMARY UNDER TEST ===\n" + summary
        + "\n\n=== SOURCE TRANSCRIPT ===\n" + transcript
        + "\n\n=== END ===\nReturn only the JSON object described above.\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--mode", choices=["prompt", "score"], default="score")
    parser.add_argument("--judge-result", default="", help="score mode: agent rubric scores JSON.")
    parser.add_argument("--transcript", default="", help="prompt mode: source transcript file.")
    parser.add_argument("--summary", default="", help="prompt mode: summary file under test.")
    parser.add_argument("--meeting-id", default="meeting", help="prompt mode: id to embed.")
    parser.add_argument("--out", required=True, help="score mode: score-summary.json; prompt mode: prompt packet path.")
    args = parser.parse_args()

    out_path = Path(args.out).expanduser()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    if args.mode == "prompt":
        if not args.transcript or not args.summary:
            print("prompt mode needs --transcript and --summary")
            return 1
        packet = build_prompt(Path(args.transcript).expanduser(), Path(args.summary).expanduser(), args.meeting_id)
        out_path.write_text(packet, encoding="utf-8")
        print(f"Wrote judge prompt packet to {out_path} (local only — do not upload)")
        return 0

    if not args.judge_result or not Path(args.judge_result).expanduser().is_file():
        return write_score(out_path, {"present": False, "detail": "no judge result supplied"})

    payload = json.loads(Path(args.judge_result).expanduser().read_text(encoding="utf-8"))
    meetings = payload.get("meetings", [])
    return write_score(out_path, score_meetings(meetings))


if __name__ == "__main__":
    raise SystemExit(main())

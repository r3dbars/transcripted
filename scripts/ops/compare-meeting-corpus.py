#!/usr/bin/env python3
"""Compare Transcripted meeting Markdown against a private Zoom-caption corpus."""

from __future__ import annotations

import argparse
import collections
import json
import math
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


DEFAULT_ROOT = Path.home() / "Downloads" / "meeting-corpus"
DEFAULT_OUTPUT_DIR = DEFAULT_ROOT / "transcripted-output"
DEFAULT_IDS = ["meeting-0024", "meeting-0025"]
ZOOM_SPEAKER_RE = re.compile(r"^\[(?P<speaker>[^\]]+)\]\s+(?P<time>\d{1,2}:\d{2}:\d{2})(?:\s+(?P<text>.*))?$")
TRANSCRIPTED_TIME_RE = re.compile(
    r"^(?:\*\*(?P<bold_time>\d+:\d{2}(?::\d{2})?)\*\*|\[(?P<bracket_time>\d+:\d{2}(?::\d{2})?)\])\s+"
)
WORD_RE = re.compile(r"[a-z0-9][a-z0-9']*", re.IGNORECASE)
STOPWORDS = {
    "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "do", "for", "from",
    "had", "has", "have", "he", "her", "his", "i", "if", "in", "is", "it", "its", "just",
    "like", "not", "of", "on", "or", "our", "she", "so", "that", "the", "their", "them",
    "then", "there", "they", "this", "to", "was", "we", "were", "what", "with", "you",
    "your",
}


@dataclass
class Check:
    status: str
    check: str
    target: str
    detail: str = ""


def tokenize(text: str, content_only: bool = False) -> list[str]:
    words = [match.group(0).lower().strip("'") for match in WORD_RE.finditer(text)]
    if not content_only:
        return [word for word in words if word]
    return [word for word in words if len(word) > 2 and word not in STOPWORDS]


def overlap_metrics(reference_words: list[str], candidate_words: list[str]) -> dict[str, float]:
    if not reference_words and not candidate_words:
        return {"precision": 1.0, "recall": 1.0, "f1": 1.0}
    if not reference_words or not candidate_words:
        return {"precision": 0.0, "recall": 0.0, "f1": 0.0}

    ref_counts = collections.Counter(reference_words)
    candidate_counts = collections.Counter(candidate_words)
    overlap = sum(min(ref_counts[word], candidate_counts[word]) for word in ref_counts.keys() & candidate_counts.keys())
    precision = overlap / len(candidate_words)
    recall = overlap / len(reference_words)
    f1 = 0.0 if precision + recall == 0 else (2 * precision * recall) / (precision + recall)
    return {"precision": precision, "recall": recall, "f1": f1}


def load_manifest(root: Path) -> list[dict[str, Any]]:
    return json.loads((root / "manifest.json").read_text(encoding="utf-8"))


def select_meetings(manifest: list[dict[str, Any]], ids: list[str] | None) -> list[dict[str, Any]]:
    by_id = {entry["id"]: entry for entry in manifest}
    selected_ids = ids or DEFAULT_IDS
    missing = [mid for mid in selected_ids if mid not in by_id]
    if missing:
        raise ValueError(f"Requested meeting ids not found in manifest: {', '.join(missing)}")
    return [by_id[mid] for mid in selected_ids]


def parse_zoom(path: Path) -> dict[str, Any]:
    speakers: dict[str, int] = {}
    text_parts: list[str] = []
    turn_count = 0
    active_speaker: str | None = None

    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if not stripped:
            continue

        match = ZOOM_SPEAKER_RE.match(stripped)
        if match:
            speaker = match.group("speaker").strip()
            text = (match.group("text") or "").strip()
            speakers[speaker] = speakers.get(speaker, 0) + 1
            turn_count += 1
            active_speaker = speaker
            if text:
                text_parts.append(text)
            continue

        if active_speaker:
            text_parts.append(stripped)

    return {
        "speaker_names": sorted(speakers),
        "speaker_count": len(speakers),
        "turn_count": turn_count,
        "text": "\n".join(text_parts),
    }


def strip_frontmatter(markdown: str) -> str:
    if not markdown.startswith("---"):
        return markdown
    end = markdown.find("\n---", 3)
    if end == -1:
        return markdown
    return markdown[end + 4 :]


def parse_transcripted_row(line: str) -> tuple[str, str] | None:
    match = TRANSCRIPTED_TIME_RE.match(line)
    if not match:
        return None

    rest = line[match.end() :]
    if not rest.startswith("["):
        return None

    wiki_depth = 0
    index = 1
    while index < len(rest):
        if rest.startswith("[[", index):
            wiki_depth += 1
            index += 2
            continue
        if rest.startswith("]]", index) and wiki_depth > 0:
            wiki_depth -= 1
            index += 2
            continue
        if rest[index] == "]" and wiki_depth == 0:
            return rest[1:index].strip(), rest[index + 1 :].strip()
        index += 1

    return None


def parse_transcripted_markdown(path: Path) -> dict[str, Any]:
    content = strip_frontmatter(path.read_text(encoding="utf-8", errors="replace"))
    text_parts: list[str] = []
    speaker_labels: dict[str, int] = {}
    turn_count = 0
    in_transcript = False
    current_speaker: str | None = None

    for line in content.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("## "):
            in_transcript = stripped.lower() in {"## transcript", "## full transcript"}
            current_speaker = None
            continue
        if not in_transcript:
            continue
        if (
            stripped == "---"
            or stripped.startswith("**Participants:**")
            or stripped.startswith("*Generated by Transcripted")
        ):
            in_transcript = False
            current_speaker = None
            continue

        row = parse_transcripted_row(stripped)
        if row:
            speaker, text = row
            speaker_labels[speaker] = speaker_labels.get(speaker, 0) + 1
            turn_count += 1
            current_speaker = speaker
            if text:
                text_parts.append(text)
            continue

        if current_speaker and not stripped.startswith("#"):
            text_parts.append(stripped)

    if not text_parts:
        # Fallback: score body text if a future formatter changes headings.
        text_parts = [line.strip() for line in content.splitlines() if line.strip() and not line.strip().startswith("#")]

    return {
        "speaker_labels": sorted(speaker_labels),
        "speaker_label_count": len(speaker_labels),
        "turn_count": turn_count,
        "text": "\n".join(text_parts),
    }


def normalize_speaker_label(label: str) -> str:
    name = label.split("/")[-1].strip()
    if name.startswith("[[") and name.endswith("]]"):
        name = name[2:-2].strip()
    return re.sub(r"\s+", " ", name).casefold()


def load_candidate_map(path: Path | None) -> dict[str, Path]:
    if not path:
        return {}
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict):
        raise ValueError("candidate map must be a JSON object")
    base = path.parent
    result: dict[str, Path] = {}
    for key, value in raw.items():
        candidate = Path(value).expanduser()
        if not candidate.is_absolute():
            candidate = base / candidate
        result[str(key)] = candidate
    return result


def find_candidate(meeting_id: str, output_dir: Path, candidate_map: dict[str, Path]) -> Path | None:
    mapped = candidate_map.get(meeting_id)
    if mapped:
        return mapped if mapped.is_file() else None

    candidates = [
        output_dir / f"{meeting_id}.md",
        output_dir / meeting_id / "transcript.md",
        output_dir / meeting_id / f"{meeting_id}.md",
    ]
    candidates.extend(sorted((output_dir / meeting_id).glob("*.md")) if (output_dir / meeting_id).is_dir() else [])
    candidates.extend(sorted(output_dir.glob(f"*{meeting_id}*.md")) if output_dir.is_dir() else [])

    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


def compare_meeting(
    root: Path,
    output_dir: Path,
    candidate_map: dict[str, Path],
    entry: dict[str, Any],
    min_recall: float,
    min_content_recall: float,
) -> tuple[list[Check], dict[str, Any]]:
    meeting_id = entry["id"]
    checks: list[Check] = []
    zoom_path = root / meeting_id / entry["zoom_transcript"]["path"]
    reference = parse_zoom(zoom_path)
    candidate_path = find_candidate(meeting_id, output_dir, candidate_map)

    summary: dict[str, Any] = {
        "id": meeting_id,
        "candidatePresent": candidate_path is not None,
        "candidatePath": str(candidate_path) if candidate_path else None,
        "referenceTurnCount": reference["turn_count"],
        "referenceSpeakerCount": reference["speaker_count"],
        "referenceWordCount": len(tokenize(reference["text"])),
        "candidateWordCount": 0,
        "candidateTurnCount": 0,
        "candidateSpeakerLabelCount": 0,
        "wordPrecision": None,
        "wordRecall": None,
        "wordF1": None,
        "contentRecall": None,
        "privateSpeakerNameMatches": 0,
        "privateSpeakerNameTotal": reference["speaker_count"],
    }

    checks.append(Check("PASS", "compare/reference-zoom", meeting_id, f"{reference['turn_count']} turns"))

    if candidate_path is None:
        checks.append(Check("WARN", "compare/transcripted-output-present", meeting_id, f"missing Transcripted Markdown under {output_dir}"))
        return checks, summary

    checks.append(Check("PASS", "compare/transcripted-output-present", meeting_id))
    candidate = parse_transcripted_markdown(candidate_path)
    candidate_text = candidate["text"]
    ref_words = tokenize(reference["text"])
    candidate_words = tokenize(candidate_text)
    ref_content_words = tokenize(reference["text"], content_only=True)
    candidate_content_words = tokenize(candidate_text, content_only=True)
    word_metrics = overlap_metrics(ref_words, candidate_words)
    content_metrics = overlap_metrics(ref_content_words, candidate_content_words)

    candidate_label_names = {normalize_speaker_label(label) for label in candidate["speaker_labels"]}
    private_name_matches = sum(
        1 for name in reference["speaker_names"]
        if name and normalize_speaker_label(name) in candidate_label_names
    )
    summary.update({
        "candidateWordCount": len(candidate_words),
        "candidateTurnCount": candidate["turn_count"],
        "candidateSpeakerLabelCount": candidate["speaker_label_count"],
        "wordPrecision": round(word_metrics["precision"], 4),
        "wordRecall": round(word_metrics["recall"], 4),
        "wordF1": round(word_metrics["f1"], 4),
        "contentRecall": round(content_metrics["recall"], 4),
        "privateSpeakerNameMatches": private_name_matches,
    })

    if len(candidate_words) > 50:
        checks.append(Check("PASS", "compare/transcripted-word-count", meeting_id, f"{len(candidate_words)} words"))
    else:
        checks.append(Check("FAIL", "compare/transcripted-word-count", meeting_id, "candidate transcript is too short"))

    if word_metrics["recall"] >= min_recall:
        checks.append(Check("PASS", "compare/word-recall", meeting_id, f"{word_metrics['recall']:.1%}"))
    else:
        checks.append(Check("FAIL", "compare/word-recall", meeting_id, f"{word_metrics['recall']:.1%} below {min_recall:.0%}"))

    if content_metrics["recall"] >= min_content_recall:
        checks.append(Check("PASS", "compare/content-word-recall", meeting_id, f"{content_metrics['recall']:.1%}"))
    else:
        checks.append(Check("FAIL", "compare/content-word-recall", meeting_id, f"{content_metrics['recall']:.1%} below {min_content_recall:.0%}"))

    expected_speakers = reference["speaker_count"]
    candidate_speakers = candidate["speaker_label_count"]
    if candidate_speakers == 0:
        checks.append(Check("WARN", "compare/speaker-labels", meeting_id, "no Transcripted speaker labels parsed"))
    elif abs(candidate_speakers - expected_speakers) <= max(2, math.ceil(expected_speakers * 0.35)):
        checks.append(Check("PASS", "compare/speaker-labels", meeting_id, f"{candidate_speakers} labels vs {expected_speakers} reference speakers"))
    else:
        checks.append(Check("WARN", "compare/speaker-labels", meeting_id, f"{candidate_speakers} labels vs {expected_speakers} reference speakers"))

    if private_name_matches > 0:
        checks.append(Check("PASS", "compare/private-speaker-name-matches", meeting_id, f"{private_name_matches}/{expected_speakers} private names present locally"))
    else:
        checks.append(Check("WARN", "compare/private-speaker-name-matches", meeting_id, "no private speaker names found in Transcripted output"))

    return checks, summary


def status_rank(status: str) -> int:
    return {"FAIL": 0, "WARN": 1, "PASS": 2}.get(status, 3)


def verdict_for_counts(passed: int, warned: int, failed: int) -> str:
    if failed:
        return "FAIL"
    if warned:
        return "INCOMPLETE"
    return "PASS"


def short_summary(verdict: str, passed: int, warned: int, failed: int) -> str:
    total = passed + warned + failed
    if verdict == "PASS":
        return f"PASS: tested {passed}/{total} checks. Good to go."
    if verdict == "FAIL":
        return f"FAIL: tested {passed}/{total} checks. Not good yet: {failed + warned} flagged."
    return f"INCOMPLETE: tested {passed}/{total} checks. Not good yet: {warned} flagged."


def flag_line(check: Check) -> str:
    detail = f" - {check.detail}" if check.detail else ""
    return f"{check.status} - {check.target} - {check.check}{detail}"


def write_markdown(path: Path, root: Path, output_dir: Path, checks: list[Check], summaries: list[dict[str, Any]]) -> None:
    passed = sum(1 for check in checks if check.status == "PASS")
    warned = sum(1 for check in checks if check.status == "WARN")
    failed = sum(1 for check in checks if check.status == "FAIL")
    verdict = verdict_for_counts(passed, warned, failed)
    flags = [check for check in checks if check.status != "PASS"]

    lines = [
        "# Transcripted Corpus Comparison QA",
        "",
        "## Short Answer",
        "",
        short_summary(verdict, passed, warned, failed),
        "",
        "## Flags",
        "",
    ]

    if not flags:
        lines.append("No flags.")
    else:
        for check in flags[:10]:
            lines.append(f"- {flag_line(check)}")
        if len(flags) > 10:
            lines.append(f"- ...and {len(flags) - 10} more flags.")

    lines.extend([
        "",
        "## Run Details",
        "",
        f"- Verdict: {verdict}",
        f"- Corpus root: `{root}`",
        f"- Transcripted output dir: `{output_dir}`",
        f"- Meetings compared: {len(summaries)}",
        f"- Passed: {passed}",
        f"- Warnings: {warned}",
        f"- Failed: {failed}",
        "",
        "Raw transcript text and speaker names are intentionally omitted.",
        "",
        "## Meeting Scores",
        "",
        "| Meeting | Candidate | Word recall | Content recall | Speaker labels | Private name matches |",
        "| --- | --- | ---: | ---: | ---: | ---: |",
    ])

    for summary in summaries:
        word_recall = "n/a" if summary["wordRecall"] is None else f"{summary['wordRecall'] * 100:.1f}%"
        content_recall = "n/a" if summary["contentRecall"] is None else f"{summary['contentRecall'] * 100:.1f}%"
        candidate = "yes" if summary["candidatePresent"] else "missing"
        lines.append(
            "| `{id}` | {candidate} | {word_recall} | {content_recall} | {labels}/{speakers} | {name_matches}/{name_total} |".format(
                id=summary["id"],
                candidate=candidate,
                word_recall=word_recall,
                content_recall=content_recall,
                labels=summary["candidateSpeakerLabelCount"],
                speakers=summary["referenceSpeakerCount"],
                name_matches=summary["privateSpeakerNameMatches"],
                name_total=summary["privateSpeakerNameTotal"],
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
    parser.add_argument("--transcripted-output-dir", default="")
    parser.add_argument("--candidate-map", default="")
    parser.add_argument("--ids", default="", help="Comma-separated meeting ids.")
    parser.add_argument("--json-out", required=True)
    parser.add_argument("--markdown-out", required=True)
    parser.add_argument("--min-recall", type=float, default=0.45)
    parser.add_argument("--min-content-recall", type=float, default=0.35)
    args = parser.parse_args()

    root = Path(args.corpus_root).expanduser().resolve()
    output_dir_arg = args.transcripted_output_dir or str(root / "transcripted-output")
    output_dir = Path(output_dir_arg).expanduser().resolve()
    candidate_map_path = Path(args.candidate_map).expanduser().resolve() if args.candidate_map else None

    if not root.exists():
        print(f"Corpus root not found: {root}", file=sys.stderr)
        return 1

    try:
        manifest = load_manifest(root)
        selected = select_meetings(manifest, [part.strip() for part in args.ids.split(",") if part.strip()] or None)
        candidate_map = load_candidate_map(candidate_map_path)
    except Exception as error:
        print(error, file=sys.stderr)
        return 1

    all_checks: list[Check] = []
    summaries: list[dict[str, Any]] = []
    for entry in selected:
        try:
            checks, summary = compare_meeting(
                root,
                output_dir,
                candidate_map,
                entry,
                min_recall=args.min_recall,
                min_content_recall=args.min_content_recall,
            )
        except Exception as error:
            checks = [Check("FAIL", "compare/meeting", entry.get("id", "unknown"), str(error))]
            summary = {
                "id": entry.get("id", "unknown"),
                "candidatePresent": False,
                "candidatePath": None,
                "referenceTurnCount": 0,
                "referenceSpeakerCount": 0,
                "referenceWordCount": 0,
                "candidateWordCount": 0,
                "candidateTurnCount": 0,
                "candidateSpeakerLabelCount": 0,
                "wordPrecision": None,
                "wordRecall": None,
                "wordF1": None,
                "contentRecall": None,
                "privateSpeakerNameMatches": 0,
                "privateSpeakerNameTotal": 0,
            }
        all_checks.extend(checks)
        summaries.append(summary)

    payload = {
        "corpusRoot": str(root),
        "transcriptedOutputDir": str(output_dir),
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
    write_markdown(markdown_path, root, output_dir, all_checks, summaries)

    failed = payload["summary"]["failed"]
    warnings = payload["summary"]["warnings"]
    passed = payload["summary"]["passed"]
    verdict = verdict_for_counts(passed, warnings, failed)
    flags = [check for check in all_checks if check.status != "PASS"]
    print(short_summary(verdict, passed, warnings, failed))
    if flags:
        print("Flags:")
        for check in flags[:5]:
            print(f"- {flag_line(check)}")
        if len(flags) > 5:
            print(f"- ...and {len(flags) - 5} more flags in the report.")
    print(f"Report: {markdown_path}")
    if failed:
        return 1
    if warnings:
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

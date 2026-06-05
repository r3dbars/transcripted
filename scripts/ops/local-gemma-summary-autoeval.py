#!/usr/bin/env python3
"""Local Gemma summary autoeval for Transcripted meeting transcripts.

The harness intentionally keeps raw transcript text inside the local run
directory. Console output, TSV rows, and reports use hashed case ids by default.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time
from difflib import SequenceMatcher
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
RUNNER = REPO_ROOT / "Resources" / "LocalSummarizer" / "gemma4_mlx_prompt_runner.py"
DEFAULT_MODEL = "mlx-community/gemma-4-12B-it-4bit"
DEFAULT_RUNTIME_PACKAGE = "mlx-vlm"
DEFAULT_PROFILE = "m1-low-memory"
WORD_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9']*")
ZOOM_LINE_RE = re.compile(r"^\[[^\]]+\]\s+\d{1,2}:\d{2}:\d{2}(?:\s+(.*))?$")
VTT_TIME_RE = re.compile(r"^\d{1,2}:\d{2}:\d{2}\.\d{3}\s+-->\s+\d{1,2}:\d{2}:\d{2}\.\d{3}")
TIME_REAL_RE = re.compile(r"\b([0-9.]+)\s+real\b")
TIME_USER_RE = re.compile(r"\b([0-9.]+)\s+user\b")
TIME_SYS_RE = re.compile(r"\b([0-9.]+)\s+sys\b")
TIME_RSS_RE = re.compile(r"^\s*(\d+)\s+maximum resident set size\b", re.MULTILINE)
STOPWORDS = {
    "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "do", "for", "from",
    "had", "has", "have", "he", "her", "his", "i", "if", "in", "is", "it", "its", "just",
    "like", "not", "of", "on", "or", "our", "she", "so", "that", "the", "their", "them",
    "then", "there", "they", "this", "to", "was", "we", "were", "what", "with", "you",
    "your",
}

PROFILES: dict[str, dict[str, int]] = {
    "m1-low-memory": {
        "chunk_character_limit": 9_000,
        "chunk_max_tokens": 300,
        "direct_max_tokens": 900,
        "merge_max_tokens": 2_400,
        "max_kv_size": 6_144,
        "nice": 15,
        "cpu_thread_limit": 2,
        "cooldown_seconds": 4,
    },
    "apple-silicon-balanced": {
        "chunk_character_limit": 18_000,
        "chunk_max_tokens": 520,
        "direct_max_tokens": 1_000,
        "merge_max_tokens": 2_400,
        "max_kv_size": 8_192,
        "nice": 10,
        "cpu_thread_limit": 4,
        "cooldown_seconds": 2,
    },
}

REQUIRED_HEADINGS = [
    "# Title",
    "# Summary",
    "# Decisions",
    "# Action Items",
    "# Open Questions",
    "# Risks or Follow-ups",
    "# Accuracy Notes",
]

ACTIONABLE_SECTIONS = [
    ("action_item", "Action Items"),
    ("decision", "Decisions"),
    ("open_question", "Open Questions"),
]

RESULT_FIELDS = [
    "attempt",
    "case_id",
    "repeat",
    "arm",
    "status",
    "words",
    "chunks",
    "seconds",
    "seconds_per_10k_words",
    "max_rss_gib",
    "mlx_peak_memory_gb",
    "cpu_percent",
    "quality_score",
    "quality_guardrail",
    "truncation_guardrail",
    "action_item_recall",
    "decision_recall",
    "open_question_recall",
    "none_found_regressions",
    "retention_guardrail",
    "paired_quality_delta",
    "paired_pass",
    "support_ratio",
    "viability",
    "log",
    "decision",
]


@dataclass(frozen=True)
class TranscriptCase:
    case_id: str
    path: Path
    title: str
    transcript: str
    word_count: int
    char_count: int
    chunk_count: int
    source_kind: str


@dataclass
class PromptRun:
    label: str
    status: str
    elapsed_seconds: float
    cpu_percent: float | None
    max_rss_gib: float | None
    metrics: list[dict[str, Any]]
    log_path: Path
    error: str = ""


@dataclass
class SummaryArmResult:
    arm: str
    status: str
    elapsed_seconds: float
    chunks: int
    final_output: str
    notes: str
    prompt_runs: list[PromptRun]
    error: str = ""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Benchmark Transcripted's local Gemma meeting-summary path on real local transcripts."
    )
    parser.add_argument(
        "--input",
        action="append",
        default=[],
        help="Transcript file or directory. Repeatable. Defaults to Transcripted meetings plus ~/Downloads/meeting-corpus.",
    )
    parser.add_argument("--out-root", default=".autoeval/local-gemma-summary")
    parser.add_argument("--run-id", default="")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--runtime-package", default=DEFAULT_RUNTIME_PACKAGE)
    parser.add_argument("--profile", choices=sorted(PROFILES), default=DEFAULT_PROFILE)
    parser.add_argument("--chunk-character-limit", type=int, default=None)
    parser.add_argument("--chunk-max-tokens", type=int, default=None)
    parser.add_argument("--direct-max-tokens", type=int, default=None)
    parser.add_argument("--merge-max-tokens", type=int, default=None)
    parser.add_argument("--max-kv-size", type=int, default=None)
    parser.add_argument("--memory-limit-gb", type=float, default=16.0)
    parser.add_argument("--os-reserve-gb", type=float, default=3.5)
    parser.add_argument("--min-words", type=int, default=40)
    parser.add_argument("--scan-limit", type=int, default=2_000)
    parser.add_argument("--include-longest", type=int, default=5)
    parser.add_argument("--sample-count", type=int, default=0)
    parser.add_argument("--limit", type=int, default=5)
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--timeout-seconds", type=int, default=900)
    parser.add_argument("--max-seconds-per-10k-words", type=float, default=900.0)
    parser.add_argument("--nice", type=int, default=None, help="nice value for the local model process. Defaults to the selected profile.")
    parser.add_argument("--cpu-thread-limit", type=int, default=None, help="CPU helper thread env cap. Defaults to the selected profile.")
    parser.add_argument("--cooldown-seconds", type=float, default=None, help="Pause between chunk jobs. Defaults to the selected profile.")
    parser.add_argument("--paired-direct-vs-chunk", action="store_true", help="Run each selected direct-fit transcript twice: direct and forced-chunked.")
    parser.add_argument("--paired-chunk-character-limit", type=int, default=None, help="Chunk size for the paired chunked arm. Defaults to min(profile chunk size, 3000).")
    parser.add_argument("--direct-fit-only", action="store_true", help="In paired mode, keep only transcripts that conservatively fit direct context.")
    parser.add_argument("--execute", action="store_true", help="Actually run the local MLX model. Default is a dry plan.")
    parser.add_argument("--show-paths", action="store_true", help="Include local file paths in reports.")
    parser.add_argument("--uv-path", default=os.environ.get("TRANSCRIPTED_UV_PATH", ""))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    profile = PROFILES[args.profile]
    apply_profile_defaults(args, profile)
    run_dir = make_run_dir(args)
    logs_dir = run_dir / "logs"
    raw_dir = run_dir / "raw"
    logs_dir.mkdir(parents=True, exist_ok=True)
    raw_dir.mkdir(parents=True, exist_ok=True)

    discovered_cases = discover_cases(args, profile)
    if args.paired_direct_vs_chunk and args.direct_fit_only:
        discovered_cases = [case for case in discovered_cases if direct_prompt_fits_context(case, args)]
    cases = select_cases(discovered_cases, args)
    command = command_string(args)
    write_resume(
        run_dir,
        status="running",
        current_best="none yet",
        command=command,
        next_attempt="baseline run" if args.execute else "run again with --execute",
        args=args,
        case_count=len(cases),
    )

    results_path = run_dir / "results.tsv"
    with results_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=RESULT_FIELDS,
            delimiter="\t",
        )
        writer.writeheader()

    if not cases:
        write_report(run_dir, args, [], "blocked", "No eligible transcripts found.", cases)
        write_resume(
            run_dir,
            status="blocked",
            current_best="none",
            command=command,
            next_attempt="pass --input with meeting markdown/txt/vtt files",
            args=args,
            case_count=0,
        )
        print(f"Blocked: no eligible transcripts found. Report: {run_dir / 'final-report.md'}")
        return 2

    if not args.execute:
        dry_results = []
        for case in cases:
            if args.paired_direct_vs_chunk:
                dry_results.append(dry_result(case, args, arm="direct", chunks=1))
                dry_results.append(
                    dry_result(
                        case,
                        args,
                        arm="chunked",
                        chunks=len(chunk_transcript(case.transcript, args.paired_chunk_character_limit)),
                        paired_pass="pending",
                    )
                )
            else:
                dry_results.append(dry_result(case, args, arm="summary", chunks=case.chunk_count))
        append_results(results_path, dry_results)
        write_report(
            run_dir,
            args,
            dry_results,
            "dry-run",
            "Dry run only. Use --execute to run MLX generation.",
            cases,
        )
        write_resume(
            run_dir,
            status="partial",
            current_best="dry-run plan only",
            command=command,
            next_attempt=f"{command} --execute",
            args=args,
            case_count=len(cases),
        )
        print(f"Dry run complete. Selected {len(cases)} transcript(s). Report: {run_dir / 'final-report.md'}")
        return 0

    uv_path = resolve_uv(args.uv_path)
    if uv_path is None:
        write_report(run_dir, args, [], "blocked", "uv executable was not found.", cases)
        print("Blocked: uv executable was not found. Set TRANSCRIPTED_UV_PATH or pass --uv-path.", file=sys.stderr)
        return 2

    all_results: list[dict[str, Any]] = []
    attempt = 0
    for case in cases:
        for repeat in range(1, max(1, args.repeats) + 1):
            attempt += 1
            if args.paired_direct_vs_chunk:
                results = run_paired_case(
                    attempt=attempt,
                    repeat=repeat,
                    case=case,
                    args=args,
                    uv_path=uv_path,
                    run_dir=run_dir,
                    logs_dir=logs_dir,
                    raw_dir=raw_dir,
                )
            else:
                results = [
                    run_case(
                        attempt=attempt,
                        repeat=repeat,
                        case=case,
                        args=args,
                        profile=profile,
                        uv_path=uv_path,
                        run_dir=run_dir,
                        logs_dir=logs_dir,
                        raw_dir=raw_dir,
                    )
                ]
            all_results.extend(results)
            append_results(results_path, results)
            write_resume(
                run_dir,
                status="running",
                current_best=best_result_summary(all_results),
                command=command,
                next_attempt="continuing selected cases",
                args=args,
                case_count=len(cases),
            )

    verdict = aggregate_verdict(all_results)
    write_report(run_dir, args, all_results, verdict, verdict_message(verdict), cases)
    write_resume(
        run_dir,
        status="complete",
        current_best=best_result_summary(all_results),
        command=command,
        next_attempt="inspect final-report.md or rerun with more cases/repeats",
        args=args,
        case_count=len(cases),
    )
    print(f"Gemma autoeval complete: {verdict}. Report: {run_dir / 'final-report.md'}")
    return 0 if verdict in {"green", "yellow"} else 1


def make_run_dir(args: argparse.Namespace) -> Path:
    out_root = Path(args.out_root).expanduser()
    if not out_root.is_absolute():
        out_root = REPO_ROOT / out_root
    run_id = args.run_id or datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    run_dir = out_root / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    return run_dir


def command_string(args: argparse.Namespace) -> str:
    parts = ["python3", "scripts/ops/local-gemma-summary-autoeval.py"]
    for value in args.input:
        parts.extend(["--input", shell_quote(value)])
    parts.extend(["--profile", args.profile])
    parts.extend(["--model", args.model])
    parts.extend(["--memory-limit-gb", str(args.memory_limit_gb)])
    parts.extend(["--include-longest", str(args.include_longest)])
    parts.extend(["--sample-count", str(args.sample_count)])
    parts.extend(["--limit", str(args.limit)])
    parts.extend(["--repeats", str(args.repeats)])
    parts.extend(["--chunk-character-limit", str(args.chunk_character_limit)])
    parts.extend(["--chunk-max-tokens", str(args.chunk_max_tokens)])
    parts.extend(["--direct-max-tokens", str(args.direct_max_tokens)])
    parts.extend(["--merge-max-tokens", str(args.merge_max_tokens)])
    parts.extend(["--max-kv-size", str(args.max_kv_size)])
    parts.extend(["--nice", str(args.nice)])
    parts.extend(["--cpu-thread-limit", str(args.cpu_thread_limit)])
    parts.extend(["--cooldown-seconds", str(args.cooldown_seconds)])
    if args.paired_direct_vs_chunk:
        parts.append("--paired-direct-vs-chunk")
        parts.extend(["--paired-chunk-character-limit", str(args.paired_chunk_character_limit)])
    if args.direct_fit_only:
        parts.append("--direct-fit-only")
    if args.execute:
        parts.append("--execute")
    return " ".join(parts)


def apply_profile_defaults(args: argparse.Namespace, profile: dict[str, int]) -> None:
    if args.chunk_character_limit is None:
        args.chunk_character_limit = int(profile["chunk_character_limit"])
    if args.chunk_max_tokens is None:
        args.chunk_max_tokens = int(profile["chunk_max_tokens"])
    if args.direct_max_tokens is None:
        args.direct_max_tokens = int(profile["direct_max_tokens"])
    if args.merge_max_tokens is None:
        args.merge_max_tokens = int(profile["merge_max_tokens"])
    if args.max_kv_size is None:
        args.max_kv_size = int(profile["max_kv_size"])
    if args.nice is None:
        args.nice = int(profile["nice"])
    if args.cpu_thread_limit is None:
        args.cpu_thread_limit = int(profile["cpu_thread_limit"])
    if args.cooldown_seconds is None:
        args.cooldown_seconds = float(profile["cooldown_seconds"])
    if args.paired_chunk_character_limit is None:
        args.paired_chunk_character_limit = min(int(args.chunk_character_limit), 3_000)


def shell_quote(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_./:=+-]+", value):
        return value
    return "'" + value.replace("'", "'\\''") + "'"


def default_inputs() -> list[Path]:
    return [
        Path.home() / "Library" / "Application Support" / "Transcripted" / "captures" / "meetings",
        Path.home() / "Library" / "Application Support" / "Draft" / "meetings" / "transcripts",
        Path.home() / "Downloads" / "meeting-corpus",
    ]


def discover_cases(args: argparse.Namespace, profile: dict[str, int]) -> list[TranscriptCase]:
    roots = [Path(value).expanduser() for value in args.input] if args.input else default_inputs()
    files: list[Path] = []
    for root in roots:
        if root.is_file():
            files.append(root)
            continue
        if not root.is_dir():
            continue
        for path in root.rglob("*"):
            if len(files) >= args.scan_limit:
                break
            if path.is_file() and is_candidate_file(path):
                files.append(path)

    cases: list[TranscriptCase] = []
    seen: set[Path] = set()
    for path in files:
        resolved = path.resolve()
        if resolved in seen:
            continue
        seen.add(resolved)
        case = parse_case(path, vars(args), args.min_words)
        if case is not None:
            cases.append(case)
    return cases


def is_candidate_file(path: Path) -> bool:
    if path.name.startswith("."):
        return False
    if path.suffix.lower() not in {".md", ".txt", ".vtt"}:
        return False
    stem = path.with_suffix("").name
    if stem.endswith(".summary"):
        return False
    if path.name in {"AGENT.md", "CLAUDE.md", "README.md", "validation-report.md", "final-report.md", "resume.md"}:
        return False
    return True


def parse_case(path: Path, profile: dict[str, int], min_words: int) -> TranscriptCase | None:
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    title = path.stem
    source_kind = path.suffix.lower().lstrip(".") or "text"

    if path.suffix.lower() == ".md":
        values, body = split_frontmatter(raw)
        if values.get("capture_type") == "meeting_summary":
            return None
        title = values.get("local_summary_title") or values.get("title") or first_markdown_heading(body) or title
        transcript = extract_markdown_transcript(body)
    else:
        transcript = extract_plain_transcript(raw)

    transcript = transcript.strip()
    words = count_words(transcript)
    if words < min_words:
        return None
    chunks = chunk_transcript(transcript, profile["chunk_character_limit"])
    return TranscriptCase(
        case_id=case_id(path),
        path=path,
        title=title.strip()[:96] or path.stem,
        transcript=transcript,
        word_count=words,
        char_count=len(transcript),
        chunk_count=max(1, len(chunks)),
        source_kind=source_kind,
    )


def split_frontmatter(markdown: str) -> tuple[dict[str, str], str]:
    if not markdown.startswith("---\n"):
        return {}, markdown
    end = markdown.find("\n---\n", 4)
    if end == -1:
        return {}, markdown
    frontmatter = markdown[4:end]
    body = markdown[end + 5 :]
    values: dict[str, str] = {}
    for line in frontmatter.splitlines():
        if not line or line[0].isspace() or ":" not in line:
            continue
        key, value = line.split(":", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values, body


def first_markdown_heading(body: str) -> str | None:
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith("# "):
            return stripped[2:].strip()
    return None


def extract_markdown_transcript(body: str) -> str:
    lines = body.splitlines()
    start: int | None = None
    for index, line in enumerate(lines):
        if line.strip() in {"## Full Transcript", "## Transcript"}:
            start = index + 1
            break
    if start is None:
        return body

    collected: list[str] = []
    for line in lines[start:]:
        stripped = line.strip()
        if stripped.startswith("## ") or stripped == "---" or stripped.startswith("*Generated by "):
            break
        if stripped:
            collected.append(stripped)
    return "\n".join(collected)


def extract_plain_transcript(raw: str) -> str:
    lines: list[str] = []
    active_speaker = False
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped or stripped == "WEBVTT" or stripped.isdigit() or VTT_TIME_RE.match(stripped):
            continue
        match = ZOOM_LINE_RE.match(stripped)
        if match:
            active_speaker = True
            lines.append(stripped)
            continue
        if active_speaker or len(stripped.split()) >= 3:
            lines.append(stripped)
    return "\n".join(lines)


def count_words(text: str) -> int:
    return len(WORD_RE.findall(text))


def case_id(path: Path) -> str:
    return hashlib.sha256(str(path.expanduser()).encode("utf-8")).hexdigest()[:12]


def select_cases(cases: list[TranscriptCase], args: argparse.Namespace) -> list[TranscriptCase]:
    ordered = sorted(cases, key=lambda case: case.word_count, reverse=True)
    selected: list[TranscriptCase] = ordered[: max(0, args.include_longest)]
    selected_ids = {case.case_id for case in selected}
    rest = [case for case in ordered if case.case_id not in selected_ids]
    rng = random.Random(args.seed)
    if args.sample_count > 0 and rest:
        selected.extend(rng.sample(rest, min(args.sample_count, len(rest))))
    if args.limit > 0:
        selected = selected[: args.limit]
    return selected


def direct_prompt_fits_context(case: TranscriptCase, args: argparse.Namespace) -> bool:
    prompt = direct_prompt(case.title, case.transcript)
    budget = max(512, args.max_kv_size - args.direct_max_tokens - 256)
    return estimated_token_count(prompt) <= budget


def estimated_token_count(text: str) -> int:
    # Conservative enough for case selection without importing model tokenizers.
    return int(max(count_words(text) * 1.35, len(text) / 3.5))


def chunk_transcript(transcript: str, target_character_limit: int) -> list[str]:
    text = transcript.strip()
    if not text:
        return []
    if target_character_limit <= 0 or len(text) <= target_character_limit:
        return [text]

    turns = split_into_turns(text)
    result: list[str] = []
    current: list[str] = []
    current_count = 0
    for turn in turns:
        turn_count = len(turn) + 2
        if turn_count > target_character_limit:
            if current:
                result.append("\n\n".join(current))
                current = []
                current_count = 0
            result.extend(split_long_turn(turn, target_character_limit))
            continue
        if current and current_count + turn_count > target_character_limit:
            result.append("\n\n".join(current))
            current = [turn]
            current_count = turn_count
        else:
            current.append(turn)
            current_count += turn_count
    if current:
        result.append("\n\n".join(current))
    return result


def split_long_turn(turn: str, target_character_limit: int) -> list[str]:
    words = turn.split()
    if not words:
        return [turn]
    pieces: list[str] = []
    current: list[str] = []
    current_count = 0
    for word in words:
        word_count = len(word) + 1
        if current and current_count + word_count > target_character_limit:
            pieces.append(" ".join(current))
            current = [word]
            current_count = word_count
        else:
            current.append(word)
            current_count += word_count
    if current:
        pieces.append(" ".join(current))
    return pieces


def split_into_turns(transcript: str) -> list[str]:
    turns: list[str] = []
    current: list[str] = []

    def flush() -> None:
        nonlocal current
        text = "\n".join(current).strip()
        if text:
            turns.append(text)
        current = []

    for raw_line in transcript.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if is_turn_boundary(line) and current:
            flush()
        current.append(line)
    flush()
    return turns or [transcript]


def is_turn_boundary(line: str) -> bool:
    if line.startswith("**"):
        match = re.match(r"^\*\*([0-9:]+)\*\*", line)
        if match and looks_like_timestamp(match.group(1)):
            return True
    if line.startswith("["):
        bracket = line[1:].split("]", 1)[0]
        if looks_like_timestamp(bracket):
            return True
        if re.match(r"^\[[^\]]+\]\s+\d{1,2}:\d{2}:\d{2}", line):
            return True
    return False


def looks_like_timestamp(value: str) -> bool:
    parts = value.split(":")
    return len(parts) in {2, 3} and all(part.isdigit() for part in parts)


def direct_prompt(title: str, transcript: str) -> str:
    return f"""You are Transcripted's local meeting summarizer. You are running fully on-device with Gemma 4 12B.

Summarize "{title}" accurately. Do not invent decisions, tasks, dates, names, or facts. If something is unclear, write unclear.

Return markdown with exactly these sections:
# Title
# Summary
# Decisions
# Action Items
# Open Questions
# Risks or Follow-ups
# Accuracy Notes

Rules:
- Always include every section heading exactly as listed, even when the section says "None found."
- Base every point only on the transcript.
- Title must be specific, plain, and 3 to 8 words.
- Keep it concise and useful.
- Use compact one-line bullets. Do not use sub-bullets, long explanations, or repeated qualifiers.
- Include timestamps when available.
- Decisions include explicit choices, selections, agreed settings, approvals, or commitments from the transcript.
- Action Items are only future follow-up work after the meeting, not instructions already completed during the transcript.
- Do not list one-off navigation, roleplay, game, or setup instructions as Action Items unless the transcript leaves them as unfinished follow-up work.
- Put brainstorms, proposals, or maybes in Open Questions or Risks unless the transcript clearly says they were decided.
- If a section has nothing supported, write "None found."

Transcript:
{transcript}
"""


def chunk_prompt(title: str, chunk: str, index: int, total: int) -> str:
    return f"""You are Transcripted's local meeting-note extractor. This is chunk {index} of {total} from "{title}".

Extract only facts supported by this chunk. Do not invent.

Return markdown with these exact headings:
## Chunk Summary
## Decisions
## Action Items
## Open Questions
## Risks or Follow-ups

Rules:
- Always include every section heading exactly as listed, even when the section says "None found."
- Preserve every explicit decision, action item, open question, and follow-up from this chunk.
- Use compact one-line bullets. Do not use sub-bullets or long explanations.
- Include timestamps and speakers when available, especially for action items and decisions.
- Decisions include explicit choices, selections, agreed settings, approvals, or commitments from this chunk.
- Action Items are only future follow-up work after the meeting, not in-call setup steps or instructions already completed during the transcript.
- Do not list one-off navigation, roleplay, game, or setup instructions as Action Items unless the chunk leaves them as unfinished follow-up work.
- Keep brainstorms, proposals, or maybes out of Decisions unless the chunk clearly says they were decided.
- If a heading has nothing supported, write "None found."

Chunk transcript:
{chunk}
"""


def merge_prompt(title: str, notes: str) -> str:
    return f"""You are Transcripted's local meeting summarizer. Merge these chunk notes for "{title}" into one accurate meeting summary.

Do not invent decisions, tasks, dates, names, or facts.

Return markdown with exactly these sections:
# Title
# Summary
# Decisions
# Action Items
# Open Questions
# Risks or Follow-ups
# Accuracy Notes

Rules:
- Always include every section heading exactly as listed, even when the section says "None found."
- Base every point only on the chunk notes.
- Title must be specific, plain, and 3 to 8 words.
- Keep each section concise.
- Use compact one-line bullets. Do not use sub-bullets, long explanations, or repeated qualifiers.
- Include timestamps when available.
- Preserve explicit action items, decisions, open questions, and follow-ups from the chunk notes.
- Decisions include explicit choices, selections, agreed settings, approvals, or commitments from the chunk notes.
- Action Items are only future follow-up work after the meeting, not in-call setup steps or instructions already completed during the transcript.
- Do not list one-off navigation, roleplay, game, or setup instructions as Action Items unless the notes leave them as unfinished follow-up work.
- Remove duplicates only when the same owner, same task or decision, and same topic are repeated.
- Never promote brainstorms, proposals, or unresolved questions into Decisions.
- If a section has nothing supported, write "None found."

Chunk notes:
{notes}
"""


def run_case(
    attempt: int,
    repeat: int,
    case: TranscriptCase,
    args: argparse.Namespace,
    profile: dict[str, int],
    uv_path: Path,
    run_dir: Path,
    logs_dir: Path,
    raw_dir: Path,
) -> dict[str, Any]:
    case_dir = raw_dir / f"{attempt:03d}-{case.case_id}-r{repeat}"
    case_dir.mkdir(parents=True, exist_ok=True)
    (case_dir / "transcript.txt").write_text(case.transcript, encoding="utf-8")
    arm = run_summary_arm(
        arm="summary",
        attempt=attempt,
        case=case,
        args=args,
        uv_path=uv_path,
        run_dir=run_dir,
        logs_dir=logs_dir,
        case_dir=case_dir,
        chunk_character_limit=args.chunk_character_limit,
        force_direct=False,
    )
    (case_dir / "final-output.md").write_text(arm.final_output.strip() + "\n", encoding="utf-8")
    return result_from_arm(attempt, repeat, case, args, run_dir, arm, quality_source=case.transcript)


def run_paired_case(
    attempt: int,
    repeat: int,
    case: TranscriptCase,
    args: argparse.Namespace,
    uv_path: Path,
    run_dir: Path,
    logs_dir: Path,
    raw_dir: Path,
) -> list[dict[str, Any]]:
    case_dir = raw_dir / f"{attempt:03d}-{case.case_id}-r{repeat}"
    case_dir.mkdir(parents=True, exist_ok=True)
    (case_dir / "transcript.txt").write_text(case.transcript, encoding="utf-8")

    direct = run_summary_arm(
        arm="direct",
        attempt=attempt,
        case=case,
        args=args,
        uv_path=uv_path,
        run_dir=run_dir,
        logs_dir=logs_dir,
        case_dir=case_dir / "direct",
        chunk_character_limit=len(case.transcript) + 1,
        force_direct=True,
    )
    chunked = run_summary_arm(
        arm="chunked",
        attempt=attempt,
        case=case,
        args=args,
        uv_path=uv_path,
        run_dir=run_dir,
        logs_dir=logs_dir,
        case_dir=case_dir / "chunked",
        chunk_character_limit=args.paired_chunk_character_limit,
        force_direct=False,
    )
    (case_dir / "direct-output.md").write_text(direct.final_output.strip() + "\n", encoding="utf-8")
    (case_dir / "chunked-output.md").write_text(chunked.final_output.strip() + "\n", encoding="utf-8")

    direct_row = result_from_arm(attempt, repeat, case, args, run_dir, direct, quality_source=case.transcript)
    chunk_row = result_from_arm(
        attempt,
        repeat,
        case,
        args,
        run_dir,
        chunked,
        quality_source=case.transcript,
        retention_source=direct.final_output,
    )
    delta = safe_int(chunk_row["quality_score"]) - safe_int(direct_row["quality_score"])
    paired_pass = (
        direct_row["status"] == "pass"
        and chunk_row["status"] == "pass"
        and direct_row["quality_guardrail"] == "pass"
        and chunk_row["quality_guardrail"] == "pass"
        and chunk_row["retention_guardrail"] == "pass"
        and delta >= -10
    )
    chunk_row["paired_quality_delta"] = delta
    chunk_row["paired_pass"] = "pass" if paired_pass else "fail"
    (case_dir / "quality-diff.json").write_text(
        json.dumps(
            {
                "case_id": case.case_id,
                "quality_delta_chunk_minus_direct": delta,
                "paired_pass": paired_pass,
                "chunked_retention": {
                    key: chunk_row.get(key, "")
                    for key in [
                        "action_item_recall",
                        "decision_recall",
                        "open_question_recall",
                        "none_found_regressions",
                        "retention_guardrail",
                    ]
                },
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return [direct_row, chunk_row]


def run_summary_arm(
    arm: str,
    attempt: int,
    case: TranscriptCase,
    args: argparse.Namespace,
    uv_path: Path,
    run_dir: Path,
    logs_dir: Path,
    case_dir: Path,
    chunk_character_limit: int,
    force_direct: bool,
) -> SummaryArmResult:
    case_dir.mkdir(parents=True, exist_ok=True)
    chunks = [case.transcript] if force_direct else chunk_transcript(case.transcript, chunk_character_limit)
    started = time.monotonic()
    prompt_runs: list[PromptRun] = []
    status = "pass"
    error = ""
    final_output = ""
    notes = ""

    try:
        if len(chunks) == 1:
            jobs = [
                make_job(
                    case_dir,
                    label="direct",
                    prompt=direct_prompt(case.title, chunks[0]),
                    max_tokens=args.direct_max_tokens,
                )
            ]
            prompt_run = run_jobs(
                label=f"{attempt:03d}-{case.case_id}-{arm}-direct",
                jobs=jobs,
                args=args,
                uv_path=uv_path,
                max_kv_size=args.max_kv_size,
                log_path=logs_dir / f"{attempt:03d}-{case.case_id}-{arm}-direct.log",
            )
            prompt_runs.append(prompt_run)
            final_output = read_output(jobs[0])
        else:
            chunk_jobs = [
                make_job(
                    case_dir,
                    label=f"chunk-{index + 1}",
                    prompt=chunk_prompt(case.title, chunk, index + 1, len(chunks)),
                    max_tokens=args.chunk_max_tokens,
                )
                for index, chunk in enumerate(chunks)
            ]
            chunk_run = run_jobs(
                label=f"{attempt:03d}-{case.case_id}-{arm}-chunks",
                jobs=chunk_jobs,
                args=args,
                uv_path=uv_path,
                max_kv_size=args.max_kv_size,
                log_path=logs_dir / f"{attempt:03d}-{case.case_id}-{arm}-chunks.log",
            )
            prompt_runs.append(chunk_run)
            notes = "\n\n---\n\n".join(
                f"# Chunk {index + 1}\n\n{read_output(job)}"
                for index, job in enumerate(chunk_jobs)
            )
            merge_job = make_job(
                case_dir,
                label="merge",
                prompt=merge_prompt(case.title, notes),
                max_tokens=args.merge_max_tokens,
            )
            merge_run = run_jobs(
                label=f"{attempt:03d}-{case.case_id}-{arm}-merge",
                jobs=[merge_job],
                args=args,
                uv_path=uv_path,
                max_kv_size=args.max_kv_size,
                log_path=logs_dir / f"{attempt:03d}-{case.case_id}-{arm}-merge.log",
            )
            prompt_runs.append(merge_run)
            final_output = read_output(merge_job)
    except Exception as exc:
        status = "fail"
        error = str(exc)

    if error:
        (case_dir / "error.txt").write_text(error + "\n", encoding="utf-8")
    (case_dir / "final-output.md").write_text(final_output.strip() + "\n", encoding="utf-8")
    if notes:
        (case_dir / "chunk-notes.md").write_text(notes.strip() + "\n", encoding="utf-8")
    return SummaryArmResult(
        arm=arm,
        status=status,
        elapsed_seconds=time.monotonic() - started,
        chunks=len(chunks),
        final_output=final_output,
        notes=notes,
        prompt_runs=prompt_runs,
        error=error,
    )


def result_from_arm(
    attempt: int,
    repeat: int,
    case: TranscriptCase,
    args: argparse.Namespace,
    run_dir: Path,
    arm: SummaryArmResult,
    quality_source: str,
    retention_source: str = "",
) -> dict[str, Any]:
    quality = score_quality(arm.final_output, quality_source)
    retention_source = retention_source or arm.notes
    retention = score_actionable_retention(retention_source, arm.final_output) if retention_source else empty_retention_score()
    truncation = truncation_guardrail(arm.prompt_runs)
    max_rss = max((run.max_rss_gib for run in arm.prompt_runs if run.max_rss_gib is not None), default=None)
    mlx_peak = max_mlx_peak_memory_gb(arm.prompt_runs)
    cpu_values = [run.cpu_percent for run in arm.prompt_runs if run.cpu_percent is not None]
    cpu_percent = max(cpu_values) if cpu_values else None
    seconds_per_10k = arm.elapsed_seconds / max(0.001, case.word_count / 10_000)
    quality_pass = quality["guardrail_pass"] and truncation != "fail" and retention["guardrail_pass"]
    viability = viability_label(arm.status, max_rss, mlx_peak, seconds_per_10k, quality_pass, args)
    log_value = ",".join(str(path_relative(run.log_path, run_dir)) for run in arm.prompt_runs) or ""
    return {
        "attempt": attempt,
        "case_id": case.case_id,
        "path": str(case.path) if args.show_paths else "",
        "repeat": repeat,
        "arm": arm.arm,
        "status": arm.status,
        "error": arm.error,
        "source_kind": case.source_kind,
        "words": case.word_count,
        "chars": case.char_count,
        "chunks": arm.chunks,
        "seconds": round(arm.elapsed_seconds, 2),
        "seconds_per_10k_words": round(seconds_per_10k, 2),
        "max_rss_gib": round(max_rss, 2) if max_rss is not None else "",
        "mlx_peak_memory_gb": round(mlx_peak, 2) if mlx_peak is not None else "",
        "cpu_percent": round(cpu_percent, 1) if cpu_percent is not None else "",
        "quality_score": quality["score"],
        "quality_guardrail": "pass" if quality_pass else "fail",
        "truncation_guardrail": truncation,
        "action_item_recall": retention["action_item_recall"],
        "decision_recall": retention["decision_recall"],
        "open_question_recall": retention["open_question_recall"],
        "none_found_regressions": retention["none_found_regressions"],
        "retention_guardrail": "pass" if retention["guardrail_pass"] else "fail",
        "paired_quality_delta": "",
        "paired_pass": "",
        "missing_headings": ",".join(quality["missing_headings"]),
        "support_ratio": quality["support_ratio"],
        "viability": viability,
        "log": log_value,
        "decision": decision_text(viability, arm.status, quality_pass, max_rss, mlx_peak, seconds_per_10k, cpu_percent, args),
    }


def make_job(case_dir: Path, label: str, prompt: str, max_tokens: int) -> dict[str, Any]:
    safe = re.sub(r"[^A-Za-z0-9_-]+", "-", label).strip("-") or "prompt"
    prompt_path = case_dir / f"{safe}-prompt.txt"
    output_path = case_dir / f"{safe}-output.md"
    metrics_path = case_dir / f"{safe}-metrics.json"
    prompt_path.write_text(prompt, encoding="utf-8")
    return {
        "label": label,
        "prompt_file": str(prompt_path),
        "output_file": str(output_path),
        "metrics_file": str(metrics_path),
        "max_tokens": max_tokens,
    }


def run_jobs(
    label: str,
    jobs: list[dict[str, Any]],
    args: argparse.Namespace,
    uv_path: Path,
    max_kv_size: int,
    log_path: Path,
) -> PromptRun:
    jobs_path = log_path.with_suffix(".jobs.json")
    jobs_path.write_text(json.dumps(jobs, indent=2), encoding="utf-8")
    uv_command = [
        str(uv_path),
        "run",
        "--with",
        args.runtime_package,
        "python",
        str(RUNNER),
        "--jobs-file",
        str(jobs_path),
        "--model",
        args.model,
        "--max-kv-size",
        str(max_kv_size),
        "--cooldown-seconds",
        str(args.cooldown_seconds),
    ]
    if args.nice and args.nice > 0:
        uv_command = ["/usr/bin/nice", "-n", str(min(args.nice, 20))] + uv_command
    command = ["/usr/bin/time", "-l"] + uv_command
    env = os.environ.copy()
    env.update(
        {
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "HF_HUB_DISABLE_PROGRESS_BARS": "1",
            "TOKENIZERS_PARALLELISM": "false",
            "PYTHONUNBUFFERED": "1",
            "UV_NO_PROGRESS": "1",
            "NO_COLOR": "1",
            "OMP_NUM_THREADS": str(max(1, args.cpu_thread_limit)),
            "OPENBLAS_NUM_THREADS": str(max(1, args.cpu_thread_limit)),
            "VECLIB_MAXIMUM_THREADS": str(max(1, args.cpu_thread_limit)),
            "NUMEXPR_NUM_THREADS": str(max(1, args.cpu_thread_limit)),
        }
    )
    started = time.monotonic()
    with log_path.open("w", encoding="utf-8") as log:
        log.write("$ " + " ".join(shell_quote(part) for part in command) + "\n\n")
        try:
            completed = subprocess.run(
                command,
                stdout=subprocess.DEVNULL,
                stderr=log,
                text=True,
                env=env,
                timeout=args.timeout_seconds,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            log.write(f"\nTIMEOUT after {args.timeout_seconds}s\n")
            return PromptRun(label, "timeout", time.monotonic() - started, None, None, [], log_path, str(exc))

    stderr_text = log_path.read_text(encoding="utf-8", errors="replace")
    metrics = [read_json(Path(job["metrics_file"])) for job in jobs if Path(job["metrics_file"]).is_file()]
    elapsed = parse_time_real(stderr_text) or (time.monotonic() - started)
    cpu_percent = parse_cpu_percent(stderr_text, elapsed)
    max_rss = parse_max_rss_gib(stderr_text)
    status = "pass" if completed.returncode == 0 else "fail"
    error = "" if status == "pass" else sanitized_error(stderr_text)
    return PromptRun(label, status, elapsed, cpu_percent, max_rss, metrics, log_path, error)


def read_output(job: dict[str, Any]) -> str:
    return Path(job["output_file"]).read_text(encoding="utf-8", errors="replace").strip()


def read_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def max_mlx_peak_memory_gb(prompt_runs: list[PromptRun]) -> float | None:
    values: list[float] = []
    for run in prompt_runs:
        for metric in run.metrics:
            value = metric.get("peak_memory_gb")
            if isinstance(value, (int, float)):
                values.append(float(value))
    return max(values) if values else None


def parse_time_real(text: str) -> float | None:
    match = TIME_REAL_RE.search(text)
    return float(match.group(1)) if match else None


def parse_cpu_percent(text: str, elapsed: float) -> float | None:
    user = TIME_USER_RE.search(text)
    system = TIME_SYS_RE.search(text)
    if not user and not system:
        return None
    cpu_seconds = (float(user.group(1)) if user else 0.0) + (float(system.group(1)) if system else 0.0)
    if elapsed <= 0:
        return None
    return (cpu_seconds / elapsed) * 100


def parse_max_rss_gib(text: str) -> float | None:
    match = TIME_RSS_RE.search(text)
    if not match:
        return None
    # macOS /usr/bin/time -l reports maximum resident set size in bytes.
    return int(match.group(1)) / (1024**3)


def sanitized_error(text: str) -> str:
    lines = [
        line
        for line in text.strip().splitlines()
        if "prompt.txt" not in line and "jobs.json" not in line and "prompt_file" not in line
    ]
    return "\n".join(lines[-10:])


def score_quality(output: str, transcript: str) -> dict[str, Any]:
    output = output.strip()
    lines = [line.strip() for line in output.splitlines()]
    generated_title = generated_title_text(output)
    missing = [
        heading
        for heading in REQUIRED_HEADINGS
        if heading not in lines and not (heading == "# Title" and generated_title)
    ]
    title_words = count_words(generated_title) if generated_title else 0
    summary = section_text("# Summary", output)
    refusal = bool(re.search(r"\b(cannot|can't|unable|insufficient transcript|no transcript)\b", output, re.I))
    support_ratio = generated_support_ratio(output, transcript)

    score = 100
    score -= len(missing) * 12
    if not summary or summary.casefold() == "none found.":
        score -= 25
    if title_words < 3 or title_words > 10:
        score -= 10
    if refusal:
        score -= 25
    if support_ratio < 0.25:
        score -= 10
    score = max(0, score)
    guardrail_pass = not missing and bool(summary) and not refusal and 3 <= title_words <= 10
    return {
        "score": score,
        "guardrail_pass": guardrail_pass,
        "missing_headings": missing,
        "support_ratio": round(support_ratio, 3),
    }


def score_actionable_retention(source: str, final: str) -> dict[str, Any]:
    failures: list[str] = []
    none_regressions = 0
    values: dict[str, Any] = {}
    for key, section_name in ACTIONABLE_SECTIONS:
        source_items = section_items(source, section_name)
        final_items = section_items(final, section_name)
        final_section = "\n".join(section_texts(section_name, final)).strip().casefold()
        if not source_items:
            values[f"{key}_recall"] = ""
            continue
        matched = sum(1 for item in source_items if best_item_similarity(item, final_items, final_section) >= 0.46)
        recall = matched / max(1, len(source_items))
        values[f"{key}_recall"] = round(recall, 2)
        if ("none found" in final_section or not final_section) and source_items:
            none_regressions += 1
            failures.append(f"{section_name}:none-found")
        if len(source_items) >= 3 and recall < 0.70:
            failures.append(f"{section_name}:recall-{recall:.2f}")
    values["none_found_regressions"] = none_regressions
    values["guardrail_pass"] = not failures
    values["failures"] = failures
    return values


def empty_retention_score() -> dict[str, Any]:
    return {
        "action_item_recall": "",
        "decision_recall": "",
        "open_question_recall": "",
        "none_found_regressions": "",
        "guardrail_pass": True,
        "failures": [],
    }


def section_items(markdown: str, section_name: str) -> list[str]:
    items: list[str] = []
    for text in section_texts(section_name, markdown):
        for raw_line in text.splitlines():
            item = clean_item(raw_line)
            if item:
                items.append(item)
    return items


def section_texts(section_name: str, markdown: str) -> list[str]:
    lines = markdown.splitlines()
    sections: list[str] = []
    start: int | None = None
    for index, line in enumerate(lines):
        if heading_name(line) == section_name:
            if start is not None:
                sections.append("\n".join(lines[start:index]).strip())
            start = index + 1
        elif start is not None and line.strip().startswith("#"):
            sections.append("\n".join(lines[start:index]).strip())
            start = None
    if start is not None:
        sections.append("\n".join(lines[start:]).strip())
    return [section for section in sections if section]


def heading_name(line: str) -> str:
    stripped = line.strip()
    if not stripped.startswith("#"):
        return ""
    return stripped.lstrip("#").strip()


def clean_item(line: str) -> str:
    item = line.strip()
    item = re.sub(r"^[-*•]\s+", "", item)
    item = re.sub(r"^\d+[.)]\s+", "", item)
    item = item.strip()
    if not item or item.casefold() == "none found.":
        return ""
    if item.startswith("#"):
        return ""
    return item


def best_item_similarity(source_item: str, final_items: list[str], final_section: str) -> float:
    candidates = final_items or ([final_section] if final_section else [])
    if not candidates:
        return 0.0
    return max(item_similarity(source_item, candidate) for candidate in candidates)


def item_similarity(left: str, right: str) -> float:
    left_norm = normalize_match_text(left)
    right_norm = normalize_match_text(right)
    if not left_norm or not right_norm:
        return 0.0
    left_words = set(content_words(left_norm))
    right_words = set(content_words(right_norm))
    token_recall = len(left_words & right_words) / max(1, len(left_words))
    sequence = SequenceMatcher(None, left_norm, right_norm).ratio()
    grams = char_gram_dice(left_norm, right_norm)
    return max(token_recall, sequence, grams)


def normalize_match_text(text: str) -> str:
    text = re.sub(r"\[[^\]]+\]", " ", text)
    text = re.sub(r"\b\d{1,2}:\d{2}(?::\d{2})?\b", " ", text)
    text = re.sub(r"[^A-Za-z0-9']+", " ", text)
    return " ".join(text.casefold().split())


def char_gram_dice(left: str, right: str) -> float:
    left_grams = char_grams(left)
    right_grams = char_grams(right)
    if not left_grams or not right_grams:
        return 0.0
    overlap = len(left_grams & right_grams)
    return (2 * overlap) / (len(left_grams) + len(right_grams))


def char_grams(text: str, width: int = 3) -> set[str]:
    compact = re.sub(r"\s+", " ", text)
    if len(compact) <= width:
        return {compact} if compact else set()
    return {compact[index : index + width] for index in range(0, len(compact) - width + 1)}


def truncation_guardrail(prompt_runs: list[PromptRun]) -> str:
    saw_chunk_length = False
    for run in prompt_runs:
        for metric in run.metrics:
            if metric.get("finish_reason") != "length":
                continue
            label = str(metric.get("label", "")).lower()
            if "direct" in label or "merge" in label:
                return "fail"
            saw_chunk_length = True
    return "warn" if saw_chunk_length else "pass"


def safe_int(value: Any) -> int:
    try:
        return int(value)
    except Exception:
        return 0


def generated_title_text(markdown: str) -> str:
    explicit = section_text("# Title", markdown).splitlines()[0:1]
    if explicit:
        title = explicit[0].strip()
        return "" if is_structural_title(title) else title
    for line in markdown.splitlines():
        stripped = line.strip()
        if stripped.startswith("# ") and stripped not in REQUIRED_HEADINGS:
            candidate = stripped[2:].strip()
            if not is_structural_title(candidate):
                return candidate
    return ""


def is_structural_title(title: str) -> bool:
    normalized = title.strip().casefold()
    if not normalized or normalized in {"none found.", "title", "summary"}:
        return True
    if normalized.startswith("chunk "):
        suffix = normalized.removeprefix("chunk ").strip()
        return suffix.isdigit()
    return False


def section_text(heading: str, markdown: str) -> str:
    lines = markdown.splitlines()
    start: int | None = None
    for index, line in enumerate(lines):
        if line.strip() == heading:
            start = index + 1
            break
    if start is None:
        return ""
    collected: list[str] = []
    for line in lines[start:]:
        if line.strip().startswith("#"):
            break
        collected.append(line)
    return "\n".join(collected).strip()


def generated_support_ratio(output: str, transcript: str) -> float:
    transcript_words = set(content_words(transcript))
    generated_words = content_words(output)
    if not generated_words:
        return 1.0
    supported = sum(1 for word in generated_words if word in transcript_words)
    return supported / len(generated_words)


def content_words(text: str) -> list[str]:
    words = [match.group(0).lower().strip("'") for match in WORD_RE.finditer(text)]
    return [word for word in words if len(word) > 2 and word not in STOPWORDS]


def viability_label(
    status: str,
    max_rss_gib: float | None,
    mlx_peak_memory_gb: float | None,
    seconds_per_10k: float,
    quality_pass: bool,
    args: argparse.Namespace,
) -> str:
    if status != "pass" or not quality_pass:
        return "red"
    usable = max(1.0, args.memory_limit_gb - args.os_reserve_gb)
    if mlx_peak_memory_gb is not None:
        if mlx_peak_memory_gb > args.memory_limit_gb:
            return "red"
        if mlx_peak_memory_gb > args.memory_limit_gb * 0.9:
            return "yellow"
    if max_rss_gib is not None:
        if max_rss_gib > usable:
            return "red"
        if max_rss_gib > usable * 0.9:
            return "yellow"
    if seconds_per_10k > args.max_seconds_per_10k_words:
        return "yellow"
    return "green"


def decision_text(
    viability: str,
    status: str,
    quality_pass: bool,
    max_rss_gib: float | None,
    mlx_peak_memory_gb: float | None,
    seconds_per_10k: float,
    cpu_percent: float | None,
    args: argparse.Namespace,
) -> str:
    if status != "pass":
        return "reject: model run failed"
    if not quality_pass:
        return "reject: quality guardrail failed"
    usable = max(1.0, args.memory_limit_gb - args.os_reserve_gb)
    if mlx_peak_memory_gb is not None and mlx_peak_memory_gb > args.memory_limit_gb:
        return f"reject: MLX peak memory {mlx_peak_memory_gb:.2f} GB exceeds {args.memory_limit_gb:.2f} GB target"
    if max_rss_gib is not None and max_rss_gib > usable:
        return f"reject: peak RSS {max_rss_gib:.2f} GiB exceeds {usable:.2f} GiB 16GB budget"
    if cpu_percent is not None and cpu_percent > 250:
        return f"watch: CPU helpers averaged {cpu_percent:.0f}% despite throttling"
    if viability == "yellow":
        return "watch: usable but close to memory/time budget"
    return "keep: viable under current guardrails"


def dry_result(
    case: TranscriptCase,
    args: argparse.Namespace,
    arm: str,
    chunks: int,
    paired_pass: str = "",
) -> dict[str, Any]:
    return {
        "attempt": 0,
        "case_id": case.case_id,
        "path": str(case.path) if args.show_paths else "",
        "repeat": 0,
        "arm": arm,
        "status": "dry-run",
        "error": "",
        "source_kind": case.source_kind,
        "words": case.word_count,
        "chars": case.char_count,
        "chunks": chunks,
        "seconds": "",
        "seconds_per_10k_words": "",
        "max_rss_gib": "",
        "mlx_peak_memory_gb": "",
        "cpu_percent": "",
        "quality_score": "",
        "quality_guardrail": "not-run",
        "truncation_guardrail": "not-run",
        "action_item_recall": "",
        "decision_recall": "",
        "open_question_recall": "",
        "none_found_regressions": "",
        "retention_guardrail": "not-run",
        "paired_quality_delta": "",
        "paired_pass": paired_pass,
        "missing_headings": "",
        "support_ratio": "",
        "viability": "unknown",
        "log": "",
        "decision": "not run; add --execute",
    }


def append_results(results_path: Path, results: list[dict[str, Any]]) -> None:
    with results_path.open("a", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(
            handle,
            fieldnames=RESULT_FIELDS,
            delimiter="\t",
            extrasaction="ignore",
        )
        for result in results:
            writer.writerow(result)


def aggregate_verdict(results: list[dict[str, Any]]) -> str:
    if not results:
        return "blocked"
    if any(result.get("paired_pass") == "fail" for result in results):
        return "red"
    labels = [result["viability"] for result in results]
    if any(label == "red" for label in labels):
        return "red"
    if any(label == "yellow" for label in labels):
        return "yellow"
    return "green"


def verdict_message(verdict: str) -> str:
    return {
        "green": "4-bit MLX Gemma passed the selected 16GB runtime and quality guardrails.",
        "yellow": "4-bit MLX Gemma ran, but one or more cases were close to the memory/time budget.",
        "red": "4-bit MLX Gemma failed at least one selected runtime or quality guardrail.",
        "blocked": "The run was blocked before model execution.",
    }.get(verdict, verdict)


def best_result_summary(results: list[dict[str, Any]]) -> str:
    if not results:
        return "none"
    successful = [result for result in results if result["viability"] in {"green", "yellow"}]
    pool = successful or results
    best = sorted(pool, key=lambda result: (str(result["viability"]), float(result["seconds"] or 1e9)))[0]
    return f"{best['case_id']} {best['viability']} {best['seconds']}s rss={best['max_rss_gib']}GiB"


def write_report(
    run_dir: Path,
    args: argparse.Namespace,
    results: list[dict[str, Any]],
    verdict: str,
    message: str,
    cases: list[TranscriptCase],
) -> None:
    report = run_dir / "final-report.md"
    physical_gb = physical_memory_gb()
    usable_gb = max(1.0, args.memory_limit_gb - args.os_reserve_gb)
    lines = [
        "# Autoeval: Local Gemma Meeting Summaries",
        "",
        "## Verdict",
        f"{verdict.upper()}: {message}",
        "",
        "This report does not include raw transcript text. Raw prompts/outputs, if executed, are stored locally under `raw/` in this ignored run directory.",
        "",
        "## Hardware And Budget",
        f"- Actual machine RAM: {physical_gb:.1f} GB" if physical_gb else "- Actual machine RAM: unknown",
        f"- Simulated target RAM budget: {args.memory_limit_gb:.1f} GB",
        f"- OS/app reserve: {args.os_reserve_gb:.1f} GB",
        f"- Process RSS budget: {usable_gb:.1f} GB",
        f"- Nice value: {args.nice}",
        f"- CPU helper thread cap: {args.cpu_thread_limit}",
        f"- Cooldown between chunk jobs: {args.cooldown_seconds:.1f}s",
        f"- Chunk character limit: {args.chunk_character_limit}",
        f"- Chunk max tokens: {args.chunk_max_tokens}",
        f"- Direct max tokens: {args.direct_max_tokens}",
        f"- Merge max tokens: {args.merge_max_tokens}",
        f"- Max KV size: {args.max_kv_size}",
        f"- Model: `{args.model}`",
        f"- Runtime: `{args.runtime_package}`",
        f"- Profile: `{args.profile}`",
        f"- Paired direct-vs-chunk mode: {'on' if args.paired_direct_vs_chunk else 'off'}",
        f"- Paired chunk character limit: {args.paired_chunk_character_limit}",
        f"- Direct-fit-only selection: {'on' if args.direct_fit_only else 'off'}",
        "",
        "## Scoreboard",
        "| Case | Arm | Repeat | Words | Chunks | Seconds | Sec/10k words | RSS GiB | MLX peak GB | CPU % | Quality | Trunc | Action Recall | Decision Recall | Question Recall | Delta | Paired | Viability | Decision |",
        "|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|---|---|---|",
    ]
    for result in results:
        lines.append(
            "| {case} | {arm} | {repeat} | {words} | {chunks} | {seconds} | {sp10k} | {rss} | {mlx} | {cpu} | {quality} | {trunc} | {action} | {decisions} | {questions} | {delta} | {paired} | {viability} | {decision} |".format(
                case=result["case_id"],
                arm=result.get("arm", ""),
                repeat=result["repeat"],
                words=result["words"],
                chunks=result["chunks"],
                seconds=result["seconds"],
                sp10k=result["seconds_per_10k_words"],
                rss=result["max_rss_gib"],
                mlx=result["mlx_peak_memory_gb"],
                cpu=result["cpu_percent"],
                quality=result["quality_score"],
                trunc=result.get("truncation_guardrail", ""),
                action=result.get("action_item_recall", ""),
                decisions=result.get("decision_recall", ""),
                questions=result.get("open_question_recall", ""),
                delta=result.get("paired_quality_delta", ""),
                paired=result.get("paired_pass", ""),
                viability=result["viability"],
                decision=result["decision"],
            )
        )
    if not results:
        lines.append("| none |  | 0 | 0 | 0 |  |  |  |  |  |  |  |  |  |  |  |  | blocked | no runnable results |")

    lines.extend(
        [
            "",
            "## Selected Cases",
            "| Case | Kind | Words | Chars | Chunks | Path |",
            "|---|---|---:|---:|---:|---|",
        ]
    )
    for case in cases:
        path = str(case.path) if args.show_paths else "(hidden; rerun with --show-paths)"
        lines.append(f"| {case.case_id} | {case.source_kind} | {case.word_count} | {case.char_count} | {case.chunk_count} | {path} |")

    lines.extend(
        [
            "",
            "## Metrics",
            "- Primary: peak RSS against the 16GB budget, plus seconds per 10k transcript words.",
            "- MLX peak memory: reported by `mlx-vlm` generation metrics and treated as the best 16GB unified-memory risk signal.",
            "- CPU: computed from `/usr/bin/time -l` user+sys seconds divided by wall time. This is CPU only; MLX Metal/GPU pressure is separate.",
            "- Quality guardrails: required headings present, non-empty summary, 3-10 word generated title, no refusal, no direct/merge truncation, and no obvious action/decision/question retention failure.",
            "- Paired delta: chunked quality score minus direct quality score for the same transcript. The first-pass threshold is >= -10 with retention guardrails passing.",
            f"- Meaningful speed budget: <= {args.max_seconds_per_10k_words:.0f}s per 10k words.",
            "",
            "## Interpretation Rules",
            "- GREEN: model finished, quality guardrails passed, peak RSS stayed under the usable 16GB budget, and speed stayed inside budget.",
            "- YELLOW: model finished but was close to memory or speed budget.",
            "- RED: model failed, quality guardrail failed, or peak RSS exceeded the usable 16GB budget.",
            "",
            "## Risks",
            "- A 128GB Apple Silicon machine cannot perfectly simulate memory pressure on a 16GB M1. Treat peak RSS as a screening signal, not final proof.",
            "- First-run model download and cold model load are included only when `--execute` runs without an already-warm cache.",
            "- Automated support ratio is a smoke check, not a human accuracy grade.",
            "",
            "## Resume",
            f"- Results: `{path_relative(run_dir / 'results.tsv', REPO_ROOT)}`",
            f"- Logs: `{path_relative(run_dir / 'logs', REPO_ROOT)}`",
            f"- Raw local prompts/outputs: `{path_relative(run_dir / 'raw', REPO_ROOT)}`",
            "",
            "## Next Run",
            "Run with more repeats and a mix of longest plus random meetings before changing prompts or chunk sizes.",
        ]
    )
    report.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_resume(
    run_dir: Path,
    status: str,
    current_best: str,
    command: str,
    next_attempt: str,
    args: argparse.Namespace,
    case_count: int,
) -> None:
    text = f"""# Autoeval Resume: Local Gemma Meeting Summaries

- Status: {status}
- Current best: {current_best}
- Primary metric: peak RSS under a {args.memory_limit_gb:.1f}GB target and seconds per 10k words
- Guardrails: required summary headings, non-empty summary, generated title, no refusal, low-priority process profile
- Scoring command: `{command}`
- Editable surface: LocalMeetingSummarizer profile/prompt/chunk settings after baseline
- Frozen surface: selected transcript corpus and this evaluator during one run
- Planned knobs: baseline first; then chunk size, max tokens, prompt length, and persistent runner only after evidence
- Throttle profile: nice={args.nice}, cpu_thread_limit={args.cpu_thread_limit}, cooldown_seconds={args.cooldown_seconds}
- Case count: {case_count}
- Last attempt: see results.tsv
- Next attempt: {next_attempt}
- Noise rule: repeat likely winners with the same repeat count as baseline; single-run results are directional only
"""
    (run_dir / "resume.md").write_text(text, encoding="utf-8")


def resolve_uv(explicit_path: str) -> Path | None:
    candidates = [
        explicit_path,
        "/opt/homebrew/bin/uv",
        "/usr/local/bin/uv",
        str(Path.home() / ".local" / "bin" / "uv"),
    ]
    for value in candidates:
        if not value:
            continue
        path = Path(value).expanduser()
        if path.is_file() and os.access(path, os.X_OK):
            return path
    found = shutil.which("uv")
    return Path(found) if found else None


def physical_memory_gb() -> float | None:
    try:
        output = subprocess.check_output(["sysctl", "-n", "hw.memsize"], text=True, timeout=5)
        return int(output.strip()) / (1000**3)
    except Exception:
        return None


def path_relative(path: Path, base: Path) -> Path:
    try:
        return path.relative_to(base)
    except ValueError:
        return path

if __name__ == "__main__":
    raise SystemExit(main())

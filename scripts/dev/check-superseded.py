#!/usr/bin/env python3
"""Stop wasted "repair PR" work by checking if the fix already merged.

When a PR goes dirty (conflicting), the reflex is to spin up a fresh repair
branch. But sometimes another thread already merged that exact change under a
different PR number, so the repair branch is dead on arrival. This guard fetches
the target title (from a PR number, a branch, or a raw string) and searches
merged PRs for a title that covers the same scope. If it finds one, it prints a
loud STOP and exits non-zero before any repair work happens.

Usage:
    scripts/dev/check-superseded.py --pr 1499
    scripts/dev/check-superseded.py --branch repair-pr-1457
    scripts/dev/check-superseded.py --title "Add local summary proof telemetry"
    scripts/dev/check-superseded.py               # infer from current branch
    scripts/dev/check-superseded.py --self-test   # offline fixture check

Exit codes:
    0  clear - no merged PR looks like it already did this
    1  usage or lookup error
    3  STOP - a merged PR already covers this scope
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from difflib import SequenceMatcher

# Similarity at or above this (0-1) counts as "same scope already merged".
DEFAULT_THRESHOLD = 0.78
# How many merged PRs to consider from each gh query.
CANDIDATE_LIMIT = 40

# Prefixes/markers agents bolt onto repair branches and PRs. Stripped before
# comparison so "Repair PR #1457: gate dictation telemetry" matches the merged
# "Gate dictation saved telemetry on artifact proof".
REPAIR_MARKERS = [
    r"repair\s*(?:pr)?\s*#?\d*",
    r"redo",
    r"reland",
    r"re-?apply",
    r"reopen",
    r"rebase",
    r"resolve\s+conflicts?(?:\s+in)?",
    r"fix\s+conflicts?(?:\s+in)?",
    r"conflict\s+fix",
    r"superseded?",
    r"draft",
    r"wip",
    r"\[[^\]]*\]",  # bracketed tags like [repair], [redo]
]

_STOPWORDS = {
    "the", "a", "an", "to", "of", "for", "in", "on", "and", "or", "pr",
    "fix", "add", "update", "make", "with", "into", "onto",
}


@dataclass
class Candidate:
    number: int
    title: str
    url: str
    merged_at: str


def run_gh(args: list[str]) -> str:
    """Run a gh command and return stdout, or raise with a clear message."""
    result = subprocess.run(
        ["gh", *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"gh {' '.join(args)} failed: {result.stderr.strip() or 'unknown error'}"
        )
    return result.stdout


def current_branch() -> str:
    result = subprocess.run(
        ["git", "branch", "--show-current"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    return result.stdout.strip()


def strip_repair_markers(title: str) -> str:
    cleaned = title
    for marker in REPAIR_MARKERS:
        cleaned = re.sub(marker, " ", cleaned, flags=re.IGNORECASE)
    return cleaned


def normalize(title: str) -> str:
    """Lowercase, drop repair markers and punctuation, collapse whitespace."""
    cleaned = strip_repair_markers(title).lower()
    cleaned = re.sub(r"[^a-z0-9\s]", " ", cleaned)
    return re.sub(r"\s+", " ", cleaned).strip()


def significant_words(title: str) -> list[str]:
    return [w for w in normalize(title).split() if w not in _STOPWORDS and len(w) > 2]


def similarity(a: str, b: str) -> float:
    na, nb = normalize(a), normalize(b)
    if not na or not nb:
        return 0.0
    ratio = SequenceMatcher(None, na, nb).ratio()
    # Reward strong containment: a repair title is often a subset/superset of
    # the merged one, which drags SequenceMatcher ratio down unfairly.
    if na in nb or nb in na:
        ratio = max(ratio, 0.9)
    return ratio


def title_for_pr(number: int) -> str:
    data = json.loads(run_gh(["pr", "view", str(number), "--json", "title"]))
    return data.get("title", "").strip()


def title_for_branch(branch: str) -> str:
    """Prefer the open PR's title for this branch; fall back to the branch name."""
    try:
        raw = run_gh(
            ["pr", "list", "--head", branch, "--state", "all",
             "--json", "title,number", "--limit", "1"]
        )
        rows = json.loads(raw)
        if rows:
            return rows[0]["title"].strip()
    except RuntimeError:
        pass
    # Humanize the branch name as a last resort: repair-pr-1457-gate-telemetry
    words = re.sub(r"[-_/]+", " ", branch)
    words = re.sub(r"\bpr\s*\d+\b", " ", words, flags=re.IGNORECASE)
    return words.strip()


def fetch_candidates(query_title: str, limit: int = CANDIDATE_LIMIT) -> list[Candidate]:
    """Fetch merged PRs likely to overlap with query_title.

    Two passes, unioned: a title-scoped search on the distinctive words, plus a
    broad recent-merged sweep so we still catch rephrasings the search misses.
    """
    seen: dict[int, Candidate] = {}

    def ingest(raw: str) -> None:
        for row in json.loads(raw or "[]"):
            num = int(row["number"])
            if num not in seen:
                seen[num] = Candidate(
                    number=num,
                    title=row.get("title", "").strip(),
                    url=row.get("url", ""),
                    merged_at=row.get("mergedAt", "") or "",
                )

    words = significant_words(query_title)
    if words:
        search = " ".join(words[:6]) + " in:title"
        try:
            ingest(run_gh([
                "pr", "list", "--state", "merged", "--search", search,
                "--json", "number,title,url,mergedAt", "--limit", str(limit),
            ]))
        except RuntimeError:
            pass  # search failure is non-fatal; broad sweep still runs

    try:
        ingest(run_gh([
            "pr", "list", "--state", "merged",
            "--json", "number,title,url,mergedAt", "--limit", str(limit),
        ]))
    except RuntimeError as error:
        if not seen:
            raise error

    return list(seen.values())


def rank(query_title: str, candidates: list[Candidate], threshold: float,
         exclude_pr: int | None) -> list[tuple[float, Candidate]]:
    scored = [
        (similarity(query_title, c.title), c)
        for c in candidates
        if c.number != exclude_pr
    ]
    hits = [(s, c) for s, c in scored if s >= threshold]
    hits.sort(key=lambda pair: pair[0], reverse=True)
    return hits


def report(query_title: str, hits: list[tuple[float, Candidate]], as_json: bool) -> int:
    if as_json:
        print(json.dumps({
            "query": query_title,
            "superseded": bool(hits),
            "matches": [
                {"number": c.number, "title": c.title, "url": c.url,
                 "mergedAt": c.merged_at, "similarity": round(s, 3)}
                for s, c in hits
            ],
        }, indent=2))
        return 3 if hits else 0

    if not hits:
        print(f"OK: no merged PR already covers \"{query_title}\".")
        print("This scope looks novel. Safe to open the branch.")
        return 0

    top = hits[0][1]
    print("=" * 70)
    print(f"STOP: #{top.number} may already have merged this change.")
    print("=" * 70)
    print(f"You are about to repair/re-do: \"{query_title}\"")
    print("But these MERGED PRs cover the same scope:")
    for score, c in hits:
        merged = f" (merged {c.merged_at[:10]})" if c.merged_at else ""
        print(f"  - #{c.number}  {int(round(score * 100))}% match{merged}")
        print(f"      {c.title}")
        if c.url:
            print(f"      {c.url}")
    print("")
    print("Do NOT open a repair branch until you confirm the change is still")
    print("missing on origin/main. Check the merged PR above first.")
    return 3


# --- self-test (offline, no network) -------------------------------------

_SELF_TEST_CASES = [
    # (query title, candidate titles, expect_superseded)
    (
        "Repair PR #1457: Add local summary proof telemetry",
        ["Add local summary proof telemetry", "Fix meeting audio dropouts"],
        True,
    ),
    (
        "[redo] gate dictation saved telemetry",
        ["Gate dictation saved telemetry on artifact proof", "Bump release version"],
        True,
    ),
    (
        "Reland: Add release version bump helper",
        ["Add release version bump helper"],
        True,
    ),
    (
        "Add speaker diarization confidence meter",
        ["Add local summary proof telemetry", "Gate dictation saved telemetry"],
        False,
    ),
    (
        "Fix typo in onboarding copy",
        ["Add release version bump helper", "Improve meeting retry visibility"],
        False,
    ),
]


def self_test() -> int:
    failures: list[str] = []
    for query, titles, expect in _SELF_TEST_CASES:
        candidates = [
            Candidate(number=100 + i, title=t, url=f"https://x/{100 + i}", merged_at="2026-07-04T00:00:00Z")
            for i, t in enumerate(titles)
        ]
        hits = rank(query, candidates, DEFAULT_THRESHOLD, exclude_pr=None)
        got = bool(hits)
        if got != expect:
            failures.append(
                f"  {query!r}: expected superseded={expect}, got {got} "
                f"(top={hits[0][1].title if hits else None!r})"
            )
    if failures:
        print("check-superseded self-test FAILED:", file=sys.stderr)
        for line in failures:
            print(line, file=sys.stderr)
        return 1
    print(f"check-superseded self-test passed ({len(_SELF_TEST_CASES)} cases).")
    return 0


def resolve_query_title(args: argparse.Namespace) -> tuple[str, int | None]:
    if args.title:
        return args.title.strip(), None
    if args.pr is not None:
        return title_for_pr(args.pr), args.pr
    branch = args.branch or current_branch()
    if not branch:
        raise RuntimeError(
            "No --title/--pr/--branch given and no current branch detected."
        )
    return title_for_branch(branch), None


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Warn if a merged PR already covers the change you are about to repair.",
    )
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--pr", type=int, help="Dirty/target PR number to look up.")
    target.add_argument("--branch", help="Branch name to look up (defaults to current).")
    target.add_argument("--title", help="Raw title/scope string to check.")
    parser.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD,
                        help=f"Similarity cutoff 0-1 (default {DEFAULT_THRESHOLD}).")
    parser.add_argument("--json", action="store_true", help="Machine-readable output.")
    parser.add_argument("--self-test", action="store_true",
                        help="Run offline fixture checks and exit.")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    try:
        query_title, exclude_pr = resolve_query_title(args)
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if not query_title:
        print("error: could not determine a title to check.", file=sys.stderr)
        return 1

    try:
        candidates = fetch_candidates(query_title)
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        print("(is gh installed and authenticated? `gh auth status`)", file=sys.stderr)
        return 1

    hits = rank(query_title, candidates, args.threshold, exclude_pr)
    return report(query_title, hits, args.json)


if __name__ == "__main__":
    raise SystemExit(main())

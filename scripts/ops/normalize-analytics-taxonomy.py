#!/usr/bin/env python3
"""Normalize the union-mergeable analytics taxonomy files.

The analytics allowlist is single-sourced from two `merge=union` data files:

  Resources/analytics-events.psv             event_name|prop_a,prop_b,...
  Resources/analytics-reviewed-properties.psv one reviewed non-bucket property per line

Because each new event/property is its own line, two telemetry PRs never collide
on a shared Swift anchor. A union merge can, however, leave the lines unsorted or
(if two PRs added the same event) duplicated. This script re-canonicalizes them:

  * keeps the leading comment/blank header in place
  * sorts data lines, and sorts+dedupes properties within each event line
  * collapses exact duplicate lines

By default it rewrites the files in place. With --check it exits non-zero if any
file is not already normalized (used as a post-merge / pre-commit hygiene gate),
without modifying anything.

Run this after resolving a union merge:  python3 scripts/ops/normalize-analytics-taxonomy.py
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
EVENTS_FILE = REPO_ROOT / "Resources" / "analytics-events.psv"
REVIEWED_FILE = REPO_ROOT / "Resources" / "analytics-reviewed-properties.psv"


def split_header(lines: list[str]) -> tuple[list[str], list[str]]:
    """Split contiguous leading comment/blank lines from the data lines."""
    header: list[str] = []
    idx = 0
    for line in lines:
        stripped = line.strip()
        if stripped == "" or stripped.startswith("#"):
            header.append(line.rstrip("\n"))
            idx += 1
        else:
            break
    data = [line.rstrip("\n") for line in lines[idx:] if line.strip() != ""]
    return header, data


def normalize_event_line(line: str) -> str:
    name, sep, props = line.partition("|")
    name = name.strip()
    if sep == "":
        # No pipe at all — leave as-is so the validator/test can flag it.
        return name
    items = sorted({p.strip() for p in props.split(",") if p.strip()})
    return f"{name}|{','.join(items)}"


def normalize_events(text: str) -> str:
    header, data = split_header(text.splitlines())
    normalized = sorted({normalize_event_line(line) for line in data},
                        key=lambda s: s.split("|", 1)[0])
    body = "\n".join(header + normalized)
    return body + "\n"


def normalize_reviewed(text: str) -> str:
    header, data = split_header(text.splitlines())
    normalized = sorted({line.strip() for line in data if line.strip()})
    body = "\n".join(header + normalized)
    return body + "\n"


JOBS = [
    (EVENTS_FILE, normalize_events),
    (REVIEWED_FILE, normalize_reviewed),
]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true",
                        help="exit non-zero if any file is not already normalized; do not write")
    args = parser.parse_args()

    dirty = []
    for path, normalize in JOBS:
        if not path.exists():
            print(f"missing taxonomy file: {path}", file=sys.stderr)
            return 2
        original = path.read_text(encoding="utf-8")
        normalized = normalize(original)
        if original == normalized:
            continue
        if args.check:
            dirty.append(path)
        else:
            path.write_text(normalized, encoding="utf-8")
            print(f"normalized {path.relative_to(REPO_ROOT)}")

    if args.check and dirty:
        for path in dirty:
            print(f"not normalized: {path.relative_to(REPO_ROOT)}", file=sys.stderr)
        print("run: python3 scripts/ops/normalize-analytics-taxonomy.py", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

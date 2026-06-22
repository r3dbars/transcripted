#!/usr/bin/env python3
"""Normalize the union-mergeable analytics taxonomy files."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
EVENTS_FILE = REPO_ROOT / "Resources" / "analytics-events.psv"
REVIEWED_FILE = REPO_ROOT / "Resources" / "analytics-reviewed-properties.psv"


def split_header(lines: list[str]) -> tuple[list[str], list[str]]:
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
        return name
    items = sorted({prop.strip() for prop in props.split(",") if prop.strip()})
    return f"{name}|{','.join(items)}"


def normalize_events(text: str) -> str:
    header, data = split_header(text.splitlines())
    normalized = sorted({normalize_event_line(line) for line in data}, key=lambda line: line.split("|", 1)[0])
    return "\n".join(header + normalized) + "\n"


def normalize_reviewed(text: str) -> str:
    header, data = split_header(text.splitlines())
    normalized = sorted({line.strip() for line in data if line.strip()})
    return "\n".join(header + normalized) + "\n"


JOBS = [
    (EVENTS_FILE, normalize_events),
    (REVIEWED_FILE, normalize_reviewed),
]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="check normalization without writing")
    args = parser.parse_args()

    dirty: list[Path] = []
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

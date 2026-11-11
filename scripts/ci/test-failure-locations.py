#!/usr/bin/env python3
"""Report only tracked Swift source locations, never assertion/log contents."""
import argparse
import json
from pathlib import Path
import re
import subprocess

MAX_LOG_BYTES = 128 * 1024 * 1024
MAX_LOCATIONS = 64
SOURCE_PATH = re.compile(r"(?:Sources|Tests|Tools)/[A-Za-z0-9_+./-]+\.swift")


def inventory(root):
    names = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z", "--", "*.swift"],
                                    stderr=subprocess.DEVNULL)
    files = {}
    for name in names.decode("utf-8").split("\0"):
        if not SOURCE_PATH.fullmatch(name) or ".." in Path(name).parts:
            continue
        path = root / name
        if path.is_symlink() or not path.resolve().is_relative_to(root) or not path.is_file():
            continue
        if path.stat().st_size > 1024 * 1024:
            continue
        files[name] = len(path.read_text().splitlines())
    return files


def locations(raw, root, files):
    basenames = {}
    for name in files:
        basenames.setdefault(Path(name).name, []).append(name)
    root_prefix = str(root) + "/"
    found = set()
    for line in raw.splitlines():
        # Consume only a recognized failure prefix; ignore all message values.
        match = re.match(r"^\s*FAIL \[([A-Za-z0-9_+.-]+\.swift):([0-9]{1,7})\]", line)
        if match is None:
            match = re.match(r"^(.+?\.swift):([0-9]{1,7}):(?:[0-9]+:)? (?:error|fatal error):", line)
        if match is None:
            match = re.match(r"^.*?Test [A-Za-z0-9_().]+ recorded an issue at ([A-Za-z0-9_+.-]+\.swift):([0-9]{1,7}):", line)
        if match is None:
            continue
        name, number = match.groups()
        if name.startswith(root_prefix):
            name = name[len(root_prefix):]
        elif "/" not in name:
            candidates = basenames.get(name, [])
            if len(candidates) != 1:
                continue
            name = candidates[0]
        if name not in files or not 1 <= int(number) <= files[name]:
            continue
        found.add((name, int(number)))
    ordered = sorted(found)
    return {
        "failure_locations": [{"source": name, "line": number} for name, number in ordered[:MAX_LOCATIONS]],
        "locations_truncated": len(ordered) > MAX_LOCATIONS,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    args = parser.parse_args()
    try:
        with args.log.open("rb") as handle:
            raw = handle.read(MAX_LOG_BYTES + 1)
        if len(raw) > MAX_LOG_BYTES:
            raise ValueError("oversized input")
        root = args.root.resolve(strict=True)
        report = locations(raw.decode("utf-8", errors="replace"), root, inventory(root))
    except (OSError, ValueError, UnicodeError, subprocess.SubprocessError):
        print('{"failure_locations": [], "diagnostic_status": "unavailable"}')
        return 1
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Print what a stalled or crashed xctest run left behind, for CI logs.

Reads two sources and prints a compact, per-thread view of each:
  * `sample` output written by scripts/dev/swift-test-stall-watch.sh
  * macOS crash reports (.ips) for xctest, e.g. from XCTest's stall-detector
    abort ("A stall was detected while waiting on expectations ... aborting")

Usage: python3 scripts/dev/print-stall-diagnostics.py [SAMPLE_DIR]
Always exits 0: it only adds evidence to a step that already failed.
"""

from __future__ import annotations

import glob
import json
import os
import sys

MAX_FRAMES = 40
MAX_SAMPLE_LINES = 400


def print_sample(path: str) -> None:
    header = path + ".header"
    print(f"::group::xctest sample {os.path.basename(path)}")
    if os.path.exists(header):
        with open(header, encoding="utf-8", errors="replace") as handle:
            print(handle.read().rstrip())
    if os.path.exists(path):
        with open(path, encoding="utf-8", errors="replace") as handle:
            lines = handle.read().splitlines()
        # The call graph comes first; the binary-image list after it is noise.
        end = next((i for i, line in enumerate(lines) if line.startswith("Binary Images:")), len(lines))
        for line in lines[: min(end, MAX_SAMPLE_LINES)]:
            print(line)
        if end > MAX_SAMPLE_LINES:
            print(f"... {end - MAX_SAMPLE_LINES} more call-graph lines in {path}")
    print("::endgroup::")


def print_crash_report(path: str) -> None:
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    # .ips = one JSON header line, then the JSON report body.
    _, _, body = text.partition("\n")
    try:
        report = json.loads(body)
    except json.JSONDecodeError:
        print(f"::group::crash report {os.path.basename(path)} (unparsed)")
        print(text[:20000])
        print("::endgroup::")
        return

    images = report.get("usedImages", [])
    print(f"::group::crash report {os.path.basename(path)}")
    exception = report.get("exception", {})
    print(f"process: {report.get('procName')}  exception: {exception.get('type')} {exception.get('signal', '')}")
    for index, thread in enumerate(report.get("threads", [])):
        label = thread.get("name") or thread.get("queue") or ""
        marker = "  <- crashed" if thread.get("triggered") else ""
        print(f"\nThread {index} {label}{marker}")
        for frame in thread.get("frames", [])[:MAX_FRAMES]:
            image_index = frame.get("imageIndex")
            image = images[image_index].get("name", "?") if isinstance(image_index, int) and image_index < len(images) else "?"
            symbol = frame.get("symbol") or f"+{frame.get('imageOffset', '?')}"
            location = f"  ({frame['sourceFile']}:{frame.get('sourceLine', '?')})" if frame.get("sourceFile") else ""
            print(f"  {image:<32} {symbol}{location}")
    print("::endgroup::")


def main() -> int:
    sample_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.environ.get("RUNNER_TEMP", "/tmp"), "xctest-stall-samples"
    )
    samples = sorted(glob.glob(os.path.join(sample_dir, "xctest-*-sample-*.txt.header")))
    for header in samples:
        print_sample(header[: -len(".header")])

    reports = []
    for directory in ("~/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports"):
        reports += glob.glob(os.path.join(os.path.expanduser(directory), "xctest*.ips"))
    for report in sorted(set(reports)):
        try:
            print_crash_report(report)
        except OSError as error:
            print(f"could not read {report}: {error}")

    if not samples and not reports:
        print("No xctest stall samples or crash reports were found.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

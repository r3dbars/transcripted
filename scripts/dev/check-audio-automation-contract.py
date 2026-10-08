#!/usr/bin/env python3
"""Keep the audio-reliability automation, its docs and the smoke source lists in sync.

This used to be a Swift test that read scripts and docs as text
(Tests/AudioAutomationCoverageContractTests.swift). It checks that files agree
with each other and runs no audio code, so it lives here rather than in the
Swift runner. Stdlib only, offline, writes nothing.

    python3 scripts/dev/check-audio-automation-contract.py
    python3 scripts/dev/check-audio-automation-contract.py --self-test
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

DAILY_SCRIPT = "scripts/ops/daily-audio-reliability-check.sh"
ISSUE_500_DOC = "docs/qa-issue-500-meeting-audio.md"
QA_BENCH = "scripts/ops/transcripted-qa-bench.sh"
E2E_SCRIPT = "scripts/entrypoints/run-e2e-smoke.sh"
SHARED_SOURCES = "scripts/entrypoints/lib/shared-smoke-sources.sh"

SYNTHETIC_ROWS = [
    "synthetic-dictation-pasteback-lifecycle",
    "synthetic-meeting-mic-system-split",
    "synthetic-mic-output-mismatch-diagnostics",
    "synthetic-webrtc-zoom-contention-proxy",
    "synthetic-bluetooth-airpods-route-settling-proxy",
    "synthetic-audio-privacy-security",
    "synthetic-webrtc-shared-mic-system-present",
    "synthetic-webrtc-quiet-mic-recovered",
    "synthetic-zoom-system-audio-missing-after-start",
    "synthetic-zoom-output-ducking-route-change-stop-timeout",
    "synthetic-webrtc-route-switch-stop-restart-recovered",
    "synthetic-webrtc-quiet-mic-unrecovered",
]
# Reports must separate automated proxies from manual route proof.
REPORT_MARKERS = [
    "Audio Route Automation Proxy Matrix",
    "Deterministic Meeting Route Fixtures",
    "synthetic_route_fixture=true",
    "simulated_not_real_zoom_webrtc=true",
    "manual_boundary_documented=true",
]
# Route fixtures include deterministic stop/restart artifacts.
RESTART_MARKERS = ["restart_artifacts", "restart_attempted=true", "restart_succeeded=true"]
BLUETOOTH_TOKENS = [
    "mocked connect/disconnect",
    "output-only Bluetooth",
    "built_in_input_to_bluetooth_output",
    "sample-rate settling",
    "route readiness",
    "preferredBuiltInForBluetoothHeadset",
    "builtInFallbackSuppressedForRecoveryAttempt",
    "routeNotSettled",
    "audio_route_not_settled",
    "hfp_suspected",
]
MANUAL_PROOF_LANES = ["Safari Meet", "Firefox Meet", "Chrome Meet", "Zoom", "AirPods/Bluetooth"]
QA_BENCH_MARKERS = [
    "Use `docs/qa-issue-500-meeting-audio.md`",
    "human proof lanes that require GUI, TCC, hardware, meeting apps, or feel checks",
]
# (file, shared array it must be listed in). Checked per array, not per file
# text, so a file listed under the wrong array does not satisfy it.
SHARED_MEMBERS = [("Sources/Meeting/MeetingTranscriptStyler.swift", "SHARED_TEST_STORAGE_SOURCES")]


def array_block(text: str, name: str) -> str:
    match = re.search(rf"^{re.escape(name)}=\(\n(.*?)\n\)", text, re.MULTILINE | re.DOTALL)
    return match.group(1) if match else ""


def check(files: dict[str, str]) -> list[str]:
    problems: list[str] = []

    def need(path: str, needles: list[str], why: str) -> None:
        text = files.get(path, "")
        if not text:
            problems.append(f"{path}: missing or empty ({why})")
            return
        for needle in needles:
            if needle not in text:
                problems.append(f"{path}: should name {needle!r} ({why})")

    need(DAILY_SCRIPT, SYNTHETIC_ROWS, "synthetic audio matrix names each route lane")
    need(DAILY_SCRIPT, REPORT_MARKERS, "reports separate automated proxies from manual proof")
    need(DAILY_SCRIPT, RESTART_MARKERS, "route fixtures include stop/restart artifacts")
    need(DAILY_SCRIPT, BLUETOOTH_TOKENS, "Bluetooth/AirPods synthetic lane stays named")
    need(DAILY_SCRIPT, MANUAL_PROOF_LANES, "synthetic report names manual proof lanes")
    need(ISSUE_500_DOC, MANUAL_PROOF_LANES, "issue 500 QA matrix keeps every manual lane")
    need(QA_BENCH, QA_BENCH_MARKERS, "QA bench keeps route proof in the manual scenario packet")

    e2e = files.get(E2E_SCRIPT, "")
    shared = files.get(SHARED_SOURCES, "")
    for member, array in SHARED_MEMBERS:
        if "${" + array + "[@]" not in e2e:
            problems.append(f"{E2E_SCRIPT}: should expand {array} so {member} is compiled")
        block = array_block(shared, array)
        if not block:
            problems.append(f"{SHARED_SOURCES}: should define {array}=(...)")
        elif f'"{member}"' not in block:
            problems.append(f"{SHARED_SOURCES}: {array} should list {member}")
    return problems


def load() -> dict[str, str]:
    paths = [DAILY_SCRIPT, ISSUE_500_DOC, QA_BENCH, E2E_SCRIPT, SHARED_SOURCES]
    return {
        p: (REPO_ROOT / p).read_text(encoding="utf-8") if (REPO_ROOT / p).exists() else ""
        for p in paths
    }


def self_test() -> int:
    good = {
        DAILY_SCRIPT: "\n".join(
            SYNTHETIC_ROWS + REPORT_MARKERS + RESTART_MARKERS + BLUETOOTH_TOKENS + MANUAL_PROOF_LANES
        ),
        ISSUE_500_DOC: "\n".join(MANUAL_PROOF_LANES),
        QA_BENCH: "\n".join(QA_BENCH_MARKERS),
        E2E_SCRIPT: 'run "${SHARED_TEST_STORAGE_SOURCES[@]}"',
        SHARED_SOURCES: (
            'OTHER=(\n  "Sources/Meeting/MeetingTranscriptStyler.swift"\n)\n'
            'SHARED_TEST_STORAGE_SOURCES=(\n  "Sources/Meeting/MeetingTranscriptStyler.swift"\n)\n'
        ),
    }
    assert check(good) == [], check(good)
    broken = dict(good)
    broken[DAILY_SCRIPT] = good[DAILY_SCRIPT].replace("hfp_suspected", "")
    assert any("hfp_suspected" in p for p in check(broken))
    wrong_array = dict(good)
    wrong_array[SHARED_SOURCES] = (
        'SHARED_TEST_STORAGE_SOURCES=(\n  "Sources/Other.swift"\n)\n'
        'OTHER=(\n  "Sources/Meeting/MeetingTranscriptStyler.swift"\n)\n'
    )
    assert any("should list" in p for p in check(wrong_array))
    no_expand = dict(good)
    no_expand[E2E_SCRIPT] = "nothing"
    assert any("should expand" in p for p in check(no_expand))
    print("audio automation contract self-test OK")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    problems = check(load())
    for problem in problems:
        print(f"FAIL: {problem}")
    if problems:
        return 1
    print("audio automation contract OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

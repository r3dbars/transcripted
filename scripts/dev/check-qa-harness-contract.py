#!/usr/bin/env python3
"""Keep the QA harness permission-state contract true across its files.

The Codex QA harness must not report a green run when macOS blocked its
automation. That promise spans four places that no single Swift test can
exercise (it needs real TCC state), so this is a consistency check across files:

  * the QA CLI registers the no-prompt `permission-state` command and keeps its
    probe matrix (Tools/TranscriptedQA),
  * the QA bench runs permission-state before the live capture smoke and skips
    the smoke when the preflight warns or fails,
  * the bench's manual scenarios mark permission blockers and duplicate running
    apps INCOMPLETE instead of ambiguous UI proof,
  * the docs and .agents/qa-gates.yml say permission blockers are INCOMPLETE.

    python3 scripts/dev/check-qa-harness-contract.py
    python3 scripts/dev/check-qa-harness-contract.py --self-test

Offline, python3 stdlib only, writes nothing.
"""

from __future__ import annotations

import argparse
import importlib.util
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

ENTRYPOINT = "Tools/TranscriptedQA/Sources/TranscriptedQA/TranscriptedQA.swift"
COMMAND = "Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/PermissionState.swift"
BENCH = "scripts/ops/transcripted-qa-bench.sh"
QA_DOCS = "docs/qa-test-bench.md"
QA_GATES = ".agents/qa-gates.yml"

PROBE_MATRIX = [
    'commandName: "permission-state"',
    "PermissionStateMode",
    "CGPreflightScreenCaptureAccess",
    "CGPreflightPostEventAccess",
    "CGPreflightListenEventAccess",
    "AXIsProcessTrusted",
    "AVCaptureDevice.authorizationStatus",
    "AEDeterminePermissionToAutomateTarget",
    "PermissionRunningApplication",
]
PERMISSION_STEP = "transcripted-qa permission-state --mode live-capture"
LIVE_SMOKE_STEP = "bash run-live-capture-smoke.sh --skip-build"

BENCH_PHRASES = [
    ("if run_permission_state; then", "run the live capture smoke only when permission-state passes"),
    ("skipped after permission-state preflight", "say the live smoke was skipped after the preflight"),
    ("INCOMPLETE: harness permission blocked", "stop false-green UI automation when macOS blocks events"),
    ("prove a visible state change after each click", "require proof of a state change after each click"),
    ("No duplicate or wrong running Transcripted app instance", "make duplicate running apps incomplete instead of ambiguous"),
]


def read(root: Path, rel: str, problems: list[str]) -> str:
    try:
        return (root / rel).read_text(encoding="utf-8")
    except OSError:
        problems.append(f"{rel}: cannot read it")
        return ""


def registered_permission_state(entrypoint: str) -> bool:
    # Reuse the Swift lexer so comments and string examples cannot register a CLI.
    spec = importlib.util.spec_from_file_location(
        "qa_contract_swift_lexer", Path(__file__).with_name("check-duplicate-declarations.py")
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    source = module.sanitize(entrypoint)
    configuration = re.search(r"\bsubcommands\s*:\s*\[([^\]]*)\]", source, re.S)
    if configuration is None:
        return False
    return any(re.fullmatch(r"\s*PermissionState\s*\.\s*self\s*", item)
               for item in configuration.group(1).split(","))


LIVE_TAIL_CALL = "run_live_tail"


def live_smoke_gated(bench: str) -> bool:
    """True when the live smoke can only run from the `then` branch of
    `if run_permission_state; then`.

    The smoke command must live only inside the run_live_tail function, and the
    one reference to run_live_tail (besides its definition) must be a bare call
    in that `then` branch: not after the `fi`, not in the `else`, not chained
    elsewhere, and not inlined outside the function.
    """
    code = "\n".join(line for line in bench.splitlines() if not line.lstrip().startswith("#"))
    gate = re.search(r"\bif run_permission_state; then\n(.*?)\n\s*else\b(.*?)\n\s*fi\b", code, re.S)
    tail = re.search(rf"^[ \t]*{LIVE_TAIL_CALL}\(\)[ \t]*\{{\n(.*?)\n\}}", code, re.S | re.M)
    if gate is None or tail is None:
        return False
    then_body, else_body = gate.group(1), gate.group(2)
    outside_tail = code[: tail.start()] + code[tail.end():]
    references = re.findall(rf"\b{LIVE_TAIL_CALL}\b(?!\(\))", code)
    return (
        LIVE_SMOKE_STEP in tail.group(1)
        and LIVE_SMOKE_STEP not in outside_tail
        and len(references) == 1
        and re.search(rf"^[ \t]*{LIVE_TAIL_CALL}[ \t]*$", then_body, re.M) is not None
        and LIVE_TAIL_CALL not in else_body
    )


def check(root: Path) -> list[str]:
    problems: list[str] = []
    entrypoint = read(root, ENTRYPOINT, problems)
    command = read(root, COMMAND, problems)
    bench = read(root, BENCH, problems)
    docs = read(root, QA_DOCS, problems)
    gates = read(root, QA_GATES, problems)

    if not registered_permission_state(entrypoint):
        problems.append(f"{ENTRYPOINT}: the QA CLI should register the permission-state command (PermissionState.self)")
    for needle in PROBE_MATRIX:
        if needle not in command:
            problems.append(f"{COMMAND}: the no-prompt permission probe matrix lost `{needle}`")

    permission_at = bench.find(PERMISSION_STEP)
    live_at = bench.find(LIVE_SMOKE_STEP)
    if permission_at == -1 or live_at == -1 or permission_at > live_at:
        problems.append(f"{BENCH}: should run `{PERMISSION_STEP}` before `{LIVE_SMOKE_STEP}`")
    if not live_smoke_gated(bench):
        problems.append(
            f"{BENCH}: `{LIVE_SMOKE_STEP}` should run only from `{LIVE_TAIL_CALL}`, called once, inside the "
            "`then` branch of `if run_permission_state; then`, so a blocked preflight cannot reach the live smoke"
        )
    for needle, why in BENCH_PHRASES:
        if needle not in bench:
            problems.append(f"{BENCH}: should {why} (missing `{needle}`)")

    for needle in ("permission-state", "INCOMPLETE", "harness permission blocked"):
        if needle not in docs:
            problems.append(f"{QA_DOCS}: should name permission-state blockers as incomplete (missing `{needle}`)")
    for needle in ("permission_state", "Permission blockers are INCOMPLETE, not green"):
        if needle not in gates:
            problems.append(f"{QA_GATES}: should keep the permission-state boundary (missing `{needle}`)")
    return problems


def run(root: Path) -> int:
    problems = check(root)
    if problems:
        print("QA harness permission-state contract broken:")
        for item in problems:
            print(f"  - {item}")
        return 1
    print("QA harness contract OK: permission-state command, bench ordering, and INCOMPLETE docs agree.")
    return 0


# Written out on purpose, not derived from PROBE_MATRIX: if a probe is dropped from
# the checker, the invariant below fails instead of the fixture shrinking with it.
EXPECTED_PROBES = [
    'commandName: "permission-state"',
    "PermissionStateMode",
    "CGPreflightScreenCaptureAccess",
    "CGPreflightPostEventAccess",
    "CGPreflightListenEventAccess",
    "AXIsProcessTrusted",
    "AVCaptureDevice.authorizationStatus",
    "AEDeterminePermissionToAutomateTarget",
    "PermissionRunningApplication",
]
GOOD_BENCH = (
    f"run_permission_state() {{\n  {PERMISSION_STEP}\n}}\n"
    f"run_live_tail() {{\n  {LIVE_SMOKE_STEP}\n}}\n"
    "if run_permission_state; then\n  run_live_tail\nelse\n"
    "  skip_step 40 skipped after permission-state preflight\nfi\n"
    "INCOMPLETE: harness permission blocked\n"
    "prove a visible state change after each click\n"
    "No duplicate or wrong running Transcripted app instance\n"
)


def self_test() -> None:
    assert sorted(PROBE_MATRIX) == sorted(EXPECTED_PROBES), "PROBE_MATRIX drifted from the expected probes"
    good = {
        ENTRYPOINT: "subcommands: [PermissionState.self]",
        COMMAND: "\n".join(EXPECTED_PROBES),
        BENCH: GOOD_BENCH,
        QA_DOCS: "permission-state INCOMPLETE harness permission blocked",
        QA_GATES: "permission_state Permission blockers are INCOMPLETE, not green",
    }

    def build(files: dict[str, str]) -> Path:
        tmp = Path(tempfile.mkdtemp())
        for rel, text in files.items():
            (tmp / rel).parent.mkdir(parents=True, exist_ok=True)
            (tmp / rel).write_text(text)
        return tmp

    assert check(build(good)) == []
    for rel, old, new in [
        (ENTRYPOINT, "PermissionState.self", "Other.self"),
        (ENTRYPOINT, "PermissionState.self", "// PermissionState.self\n"),
        (ENTRYPOINT, "PermissionState.self", "/* PermissionState.self */ Other.self"),
        (ENTRYPOINT, "subcommands: [PermissionState.self]", 'let example = "PermissionState.self"; subcommands: [Other.self]'),
        (BENCH, f"  {PERMISSION_STEP}\n}}\nrun_live_tail() {{\n  {LIVE_SMOKE_STEP}",
               f"  {LIVE_SMOKE_STEP}\n}}\nrun_live_tail() {{\n  {PERMISSION_STEP}"),
        (BENCH, "if run_permission_state; then", "run_permission_state"),
        # bypass: live smoke called after the gate, or in the else branch, instead of inside the then branch
        (BENCH, "then\n  run_live_tail\nelse", "then\n  :\nelse"),
        (BENCH, "fi\nINCOMPLETE", "fi\nrun_live_tail\nINCOMPLETE"),
        (BENCH, "  skip_step 40", "  run_live_tail\n  skip_step 40"),
        (BENCH, "fi\nINCOMPLETE", "fi\nrun_live_tail || true\nINCOMPLETE"),
        # bypass: smoke command inlined outside run_live_tail, ungated
        (BENCH, "fi\nINCOMPLETE", f"fi\n{LIVE_SMOKE_STEP}\nINCOMPLETE"),
        (BENCH, f"run_live_tail() {{\n  {LIVE_SMOKE_STEP}", "run_live_tail() {\n  :"),
        (BENCH, "INCOMPLETE: harness permission blocked", ""),
        (QA_DOCS, "harness permission blocked", ""),
        (QA_GATES, "Permission blockers are INCOMPLETE, not green", ""),
    ] + [(COMMAND, probe, "x") for probe in EXPECTED_PROBES]:
        broken = dict(good)
        broken[rel] = broken[rel].replace(old, new)
        assert check(build(broken)), (rel, old)
    assert check(build({})), "missing files should fail"
    print("check-qa-harness-contract self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    return run(REPO_ROOT)


if __name__ == "__main__":
    sys.exit(main())

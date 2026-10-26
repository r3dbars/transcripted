"""test-fixed-sleep-sync: a test sleeps a fixed time for async work, then asserts."""

from __future__ import annotations

import re

from lint_rules._base import swift_file

RULE = {
    "id": "test-fixed-sleep-sync",
    "summary": "a test waits a fixed Task.sleep / usleep / Thread.sleep / asyncAfter for async work instead of waiting on a condition",
    "why": "fixed waits go red on a loaded CI runner: 4ca2f83bd, 5ed983633, 9c7ed2698, 9d610b717, 8ddb8082d, 0ab21b49b",
    "fix": "wait on the outcome: poll a condition in a bounded loop (like waitForPromptEvaluation(until:) in "
           "Tests/MeetingPromptDetectorTests.swift), await a gate/continuation the fake signals or a settle hook (MeetingPromptDetector.waitUntilEvaluationsSettle()), or inject a clock "
           "(OrphanedRecordingRecoveryClock + its virtual clock); a deliberate 'nothing happens' wait takes a lint-allow",
    "owner_doc": "Tests/README.md",
    "level": "lint",
    "paths": ["Tests/**/*.swift", "Tools/*/Tests/**/*.swift"],
    "exclude": [],
    "ratchet": True,
    "proof": [
        "b98ba08e39c9:Tests/TranscriptedCoreTests/AudioTests/AudioLevelPublishGateTests.swift",  # parent of 9c7ed2698
        "d6ff96c531fc:Tests/MeetingPromptDetectorTests.swift",  # parent of 5ed983633 (the 20 x 5 ms loop)
    ],
}

SLEEP_RE = re.compile(
    r"\bTask\.sleep\s*\(|(?<![\w.])usleep\s*\(|\bThread\.sleep\s*\(|\.asyncAfter\s*\("
    r"|\b(?:ContinuousClock|SuspendingClock)\s*\(\s*\)\s*\.sleep\s*\("
    r"|\bRunLoop\.(?:current|main)\.run\s*\(\s*until\s*:"
)
LOOP_HEAD_RE = re.compile(r"^\s*(?:for|while|repeat)\b")
FOR_NO_WHERE_RE = re.compile(r"^\s*for\b(?!.*\bwhere\b)")
# A loop body with any of these can stop early, so it polls a condition.
LOOP_EXIT_RE = re.compile(r"\b(?:if|guard|break|return|throw)\b")
# Type names that hold tests. A sleep in a method of any other type (a fake,
# a stub) is simulated slow work, not the test waiting.
TEST_TYPE_RE = re.compile(r"(?:Tests?|Smoke|Benchmark|Suite)$")
FAKE_TYPE_KINDS = ("class", "struct", "actor", "enum")


# Blocks that are statements, not closures.
CONTROL_HEAD_RE = re.compile(r"^\s*(?:\}\s*)?(?:if|else|guard|do|catch|switch|defer|for|while|repeat)\b")
# Closures whose body runs inline as part of the test's own flow (a suite body,
# a task group body, a hop to the main actor). A sleep in one of these is the
# test waiting. Any other closure (a fake's work, a Task the test races or
# cancels, an addTask give-up margin) is simulated slowness, not a wait.
INLINE_CLOSURE_RE = re.compile(
    r"\b(?:runSuite|runAsyncSuite|test|it|withTaskGroup|withThrowingTaskGroup|withDiscardingTaskGroup|"
    r"MainActor\.run|autoreleasepool|runActivity)\s*(?:\(|\{|$)"
)
CLOCK_NAME_RE = re.compile(r"(?i)clock|sleeper|scheduler")
WATCHDOG_RE = re.compile(r"\b(?:exit|fatalError|abort|preconditionFailure)\s*\(")


def _is_watchdog(sf, m) -> bool:
    """`asyncAfter(deadline: .now() + 30) { ...; exit(1) }`: a hard process
    deadline, not a wait."""
    if not m.group(0).startswith(".asyncAfter"):
        return False
    brace = sf.code.find("{", m.end())
    if brace == -1:
        return False
    for s in sf.scopes:
        if s.open_offset == brace and "asyncAfter" in s.head:
            return bool(WATCHDOG_RE.search(sf.code[s.open_offset:s.close_offset]))
    return False


def _is_test_wait(sf, scopes) -> bool:
    """True when the sleep is the test (or a test helper) pausing: not inside a
    polling loop, not inside a closure that simulates slow work, and not inside
    a fake clock or fake type. A `for` loop with no `where` and no way to stop
    early (`for _ in 0..<20 { sleep }`) is a fixed wait written as a loop, so it
    still counts."""
    for s in reversed(scopes):
        if s.kind != "block":
            if s.is_type and CLOCK_NAME_RE.search(s.name):
                return False
            if (s.kind in FAKE_TYPE_KINDS and not TEST_TYPE_RE.search(s.name.split(".")[-1])
                    and "XCTestCase" not in s.inherits):
                return False
            if s.is_function and s.name == "sleep":  # a fake clock's own sleep(for:)
                return False
            continue
        if LOOP_HEAD_RE.match(s.tail):
            body = sf.code[s.open_offset:s.close_offset]
            if FOR_NO_WHERE_RE.match(s.tail) and not LOOP_EXIT_RE.search(body):
                continue
            return False
        if CONTROL_HEAD_RE.match(s.tail):
            continue
        if not INLINE_CLOSURE_RE.search(s.tail):
            return False
    return True


def check(path: str, text: str):
    if not SLEEP_RE.search(text):
        return []
    sf = swift_file(text)
    out = []
    for line, m in sf.find(SLEEP_RE):
        scopes = sf.enclosing(m.start())
        if not _is_test_wait(sf, scopes) or _is_watchdog(sf, m):
            continue
        call = re.sub(r"\s*\(\s*\)\s*", "()", m.group(0)).split("(until")[0].rstrip("( :").lstrip(".")
        out.append((line, f"fixed {call}(...) used to wait for async work; a slow runner outruns it"))
    return out

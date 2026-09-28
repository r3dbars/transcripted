#!/usr/bin/env python3
"""Ratchet guard for the shape of tests (see Tests/README.md, "Test rules").

Two kinds of test go red when nothing broke, so new ones are not allowed:

  source-text  A test that reads production Swift under Sources/ as text and
               asserts on code fragments. It breaks on a rename or a reflow and
               stays green when the behavior breaks but the words remain.
  wall-clock   An assertion that real elapsed time stayed under a limit. It
               fails on a loaded CI runner even when nothing is wrong.

Existing uses are grandfathered in .agents/test-shape-baseline.json with a
count per file. The check fails when a file goes ABOVE its baseline count (a
new file's baseline is 0) and when a file drops BELOW it without the baseline
being shrunk, so the grandfathered pile can only get smaller:

    python3 scripts/dev/check-test-shape.py            # check
    python3 scripts/dev/check-test-shape.py --shrink   # lower the baseline after removing some
    python3 scripts/dev/check-test-shape.py --self-test

--shrink never raises a count or adds a file. Growing the baseline is a human
decision made by editing the JSON in review, not something a tool does.

It also validates Tests/quarantine.txt (benched flaky fast-test suites) and
warns about entries older than 14 days. Old entries only warn: a check that
turns red because the calendar moved would be exactly the kind of noise this
guard exists to remove.

Offline, python3 stdlib only, writes nothing except the baseline on --shrink.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import io
import json
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BASELINE_PATH = REPO_ROOT / ".agents/test-shape-baseline.json"
QUARANTINE_PATH = REPO_ROOT / "Tests/quarantine.txt"
QUARANTINE_WARN_DAYS = 14
RULES_DOC = "Tests/README.md (Test rules)"
KINDS = ("source-text", "wall-clock")

# A string literal naming something under Sources/ ("Sources/Speech/X.swift",
# "Sources/UI"), or a call to one of the read*Source helpers.
SOURCES_LITERAL = re.compile(r'"Sources/[^"\n]*"')
SOURCE_READ_CALL = re.compile(r"(?<![A-Za-z0-9_])read[A-Za-z0-9_]*Source[A-Za-z0-9_]*\(")
FUNC_DECL_PREFIX = re.compile(r"func\s+$")

ASSERTION_CALL = re.compile(
    r"(#expect|#require|XCTAssert[A-Za-z]*|assertTrue|assertFalse|assertEqual|assertLessThan|\bassert)\s*\("
)
CLOCK_READ = re.compile(
    r"timeIntervalSince(?!1970|ReferenceDate)|CFAbsoluteTimeGetCurrent|DispatchTime\.now|uptimeNanoseconds|"
    r"ContinuousClock|SuspendingClock|mach_absolute_time|ProcessInfo\.processInfo\.systemUptime"
)
# A local named like a measured time (elapsed, elapsedMs, duration, latencyMs,
# tookSeconds). Only names that START with the word, so a constant such as
# blurInDuration is not mistaken for a measurement.
ELAPSED_WORD = (
    r"(?<![A-Za-z0-9_.])(?:(?:elapsed|duration|latency|took|waited)[A-Za-z0-9_]*"
    r"|[A-Za-z0-9_]*(?:Elapsed|Latency)[A-Za-z0-9_]*)\b"
)
ELAPSED_NAME = re.compile(ELAPSED_WORD + r"\s*(?:<|<=|>|>=)")
ORDERING_ASSERTION = re.compile(r"(XCTAssert(?:Less|Greater)Than[A-Za-z]*|assertLessThan)\s*\(")
COMPARISON = re.compile(r"(?<![<>=!-])(?:<=?|>=?)(?![<>=])")

QUARANTINE_LINE = re.compile(r"^(\d{4}-\d{2}-\d{2})\s*\|\s*(.+?)\s*\|\s*(.+?)\s*$")


def strip_comments(text: str) -> str:
    """Blank out // and /* */ comments, keeping string literals and line numbers."""
    out: list[str] = []
    i, n = 0, len(text)
    in_string = False
    while i < n:
        ch = text[i]
        if in_string:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if ch == '"' or ch == "\n":
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end == -1 else end + 2
            out.append("".join("\n" if c == "\n" else " " for c in text[i:end]))
            i = end
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def count_source_text(text: str) -> int:
    code = strip_comments(text)
    count = len(SOURCES_LITERAL.findall(code))
    for match in SOURCE_READ_CALL.finditer(code):
        prefix = code[max(0, match.start() - 12) : match.start()]
        if FUNC_DECL_PREFIX.search(prefix):
            continue  # a helper's own declaration, not a use
        count += 1
    return count


STRING_LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"')


def count_wall_clock(text: str) -> int:
    count = 0
    for raw_line in strip_comments(text).splitlines():
        # Judge the code, not the assertion message: "converter latency" in a
        # message string is not a timing check.
        line = STRING_LITERAL.sub('""', raw_line)
        if not ASSERTION_CALL.search(line):
            continue
        if ELAPSED_NAME.search(line):
            count += 1
        elif ORDERING_ASSERTION.search(line) and (re.search(ELAPSED_WORD, line) or CLOCK_READ.search(line)):
            count += 1
        elif CLOCK_READ.search(line) and COMPARISON.search(line):
            count += 1
    return count


def test_files(root: Path) -> list[Path]:
    roots = [root / "Tests"] + sorted((root / "Tools").glob("*/Tests"))
    files: list[Path] = []
    for base in roots:
        if base.is_dir():
            files.extend(p for p in base.rglob("*.swift") if ".build" not in p.parts)
    return sorted(files)


def measure(root: Path) -> dict[str, dict[str, int]]:
    counts: dict[str, dict[str, int]] = {kind: {} for kind in KINDS}
    for path in test_files(root):
        text = path.read_text(encoding="utf-8", errors="replace")
        rel = path.relative_to(root).as_posix()
        for kind, value in (("source-text", count_source_text(text)), ("wall-clock", count_wall_clock(text))):
            if value:
                counts[kind][rel] = value
    return counts


def load_baseline(path: Path) -> dict[str, dict[str, int]]:
    if not path.exists():
        return {kind: {} for kind in KINDS}
    data = json.loads(path.read_text(encoding="utf-8"))
    return {kind: {k: int(v) for k, v in data.get(kind, {}).items()} for kind in KINDS}


def write_baseline(path: Path, baseline: dict[str, dict[str, int]]) -> None:
    lines = ["{"]
    for index, kind in enumerate(KINDS):
        entries = sorted(baseline[kind].items())
        lines.append(f'  "{kind}": {{')
        for i, (rel, value) in enumerate(entries):
            comma = "," if i < len(entries) - 1 else ""
            lines.append(f"    {json.dumps(rel)}: {value}{comma}")
        lines.append("  }" + ("," if index < len(KINDS) - 1 else ""))
    lines.append("}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


WHY = {
    "source-text": (
        "reads app code under Sources/ as text. Test the promise through inputs and outputs "
        "instead: call the function or type and check what it returns or does. If the logic is "
        "stuck inside a big file, pull the decision into a small function and test that."
    ),
    "wall-clock": (
        "asserts that real elapsed time stayed under a limit. That fails on a busy CI runner. "
        "Check the outcome instead (it timed out, it did not wait for the slow part), or inject a clock."
    ),
}


def compare(current, baseline) -> tuple[list[str], list[str]]:
    grew: list[str] = []
    shrank: list[str] = []
    for kind in KINDS:
        for rel in sorted(set(current[kind]) | set(baseline[kind])):
            now, allowed = current[kind].get(rel, 0), baseline[kind].get(rel, 0)
            if now > allowed:
                what = "new file" if allowed == 0 else f"was {allowed}"
                grew.append(f"{rel}: {now} {kind} use(s) ({what}). This test {WHY[kind]}")
            elif now < allowed:
                shrank.append(f"{rel}: {kind} {allowed} -> {now}")
    return grew, shrank


def suite_names(root: Path) -> set[str]:
    names: set[str] = set()
    pattern = re.compile(r'runSuite\(\s*"((?:[^"\\]|\\.)*)"')
    for path in (root / "Tests").glob("*.swift"):
        names.update(pattern.findall(path.read_text(encoding="utf-8", errors="replace")))
    return names


def check_quarantine(root: Path, path: Path, today: dt.date) -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    if not path.exists():
        return errors, warnings
    known = suite_names(root)
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = QUARANTINE_LINE.match(line)
        if not match:
            errors.append(f"{path.name}:{number}: expected 'YYYY-MM-DD | <suite name> | <why and who fixes it>'")
            continue
        date_text, suite, reason = match.groups()
        try:
            benched = dt.date.fromisoformat(date_text)
        except ValueError:
            errors.append(f"{path.name}:{number}: '{date_text}' is not a real date")
            continue
        if suite not in known:
            errors.append(f"{path.name}:{number}: no runSuite named \"{suite}\" in Tests/*.swift (renamed or already fixed? remove the line)")
        if len(reason) < 8:
            errors.append(f"{path.name}:{number}: say why it's benched and who fixes it")
        age = (today - benched).days
        if age > QUARANTINE_WARN_DAYS:
            warnings.append(f"\"{suite}\" has been benched {age} days. Fix it or delete it.")
    return errors, warnings


def run_check(root: Path, baseline_path: Path, quarantine_path: Path, today: dt.date, shrink: bool) -> int:
    current = measure(root)
    baseline = load_baseline(baseline_path)
    grew, shrank = compare(current, baseline)
    q_errors, q_warnings = check_quarantine(root, quarantine_path, today)

    for warning in q_warnings:
        print(f"WARN quarantine: {warning}")

    if shrink:
        if grew:
            print("Refusing to shrink the baseline while these files grew:")
            for item in grew:
                print(f"  - {item}")
            return 1
        write_baseline(baseline_path, {k: dict(current[k]) for k in KINDS})
        print(f"Baseline shrunk ({len(shrank)} change(s)). Commit {baseline_path.relative_to(root).as_posix()}.")
        return 0

    failed = False
    if grew:
        failed = True
        print("New brittle test code (rules: " + RULES_DOC + "):")
        for item in grew:
            print(f"  - {item}")
    if shrank:
        failed = True
        print("Nice, fewer brittle tests. Lock it in so they can't come back:")
        for item in shrank:
            print(f"  - {item}")
        print("  Run: python3 scripts/dev/check-test-shape.py --shrink")
    if q_errors:
        failed = True
        print("Tests/quarantine.txt problems:")
        for item in q_errors:
            print(f"  - {item}")
    if failed:
        return 1
    totals = {kind: sum(current[kind].values()) for kind in KINDS}
    print(
        "test shape OK: "
        f"{totals['source-text']} grandfathered source-text use(s) in {len(current['source-text'])} file(s), "
        f"{totals['wall-clock']} wall-clock assertion(s) in {len(current['wall-clock'])} file(s); none new."
    )
    return 0


def self_test() -> None:
    assert count_source_text('let s = readRepoTextFile("Sources/UI/A.swift")\n') == 1
    assert count_source_text('// readRepoTextFile("Sources/UI/A.swift")\n') == 0
    assert count_source_text('/* "Sources/UI/A.swift" */ let x = 1\n') == 0
    assert count_source_text("let s = readParakeetEngineSource()\n") == 1
    assert count_source_text("func readParakeetEngineSource(file: String) -> String {\n") == 0
    assert count_source_text('let msg = "no sources here"\n') == 0
    assert count_source_text('let a = "Sources/UI"; let b = "Sources/X.swift"\n') == 2

    assert count_wall_clock("#expect(Date().timeIntervalSince(started) < 1.5)\n") == 1
    assert count_wall_clock("assertTrue(elapsed < 0.5, \"fast\")\n") == 1
    assert count_wall_clock("XCTAssertLessThan(duration, 2)\n") == 1
    assert count_wall_clock("XCTAssertLessThan(items.count, 2)\n") == 0
    assert count_wall_clock('XCTAssertGreaterThan(frames, 3600, "less converter latency")\n') == 0
    assert count_wall_clock('assertTrue(elapsed < 0.15, "no \\"wait\\" here")\n') == 1
    assert count_wall_clock("let elapsed = Date().timeIntervalSince(start)\n") == 0
    assert count_wall_clock("#expect(outcome == .timeout)\n") == 0
    assert count_wall_clock("// #expect(elapsed < 1)\n") == 0
    assert count_wall_clock("assertEqual(items.count, 3)\n") == 0
    assert count_wall_clock("assertTrue(Motion.blurInDuration >= Motion.fadeIn)\n") == 0
    assert count_wall_clock("XCTAssertLessThan(try XCTUnwrap(secondPassElapsed), 0.3)\n") == 1
    assert count_wall_clock("XCTAssertGreaterThan(a.timeIntervalSince1970, b.timeIntervalSince1970 + 60)\n") == 0

    with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
        root = Path(tmp)
        (root / "Tests").mkdir()
        (root / ".agents").mkdir()
        test = root / "Tests/FooTests.swift"
        test.write_text(
            'func testFoo() {\n    runSuite("Foo keeps its promise") {\n'
            '        let s = readRepoTextFile("Sources/A.swift")\n    }\n}\n',
            encoding="utf-8",
        )
        base = root / ".agents/test-shape-baseline.json"
        quarantine = root / "Tests/quarantine.txt"
        today = dt.date(2026, 9, 27)

        # A new file with a source-text read fails against an empty baseline.
        assert run_check(root, base, quarantine, today, shrink=False) == 1
        # --shrink refuses to grandfather it.
        assert run_check(root, base, quarantine, today, shrink=True) == 1
        assert not base.exists()

        # A human-approved baseline makes it pass.
        write_baseline(base, {"source-text": {"Tests/FooTests.swift": 1}, "wall-clock": {}})
        assert run_check(root, base, quarantine, today, shrink=False) == 0

        # Removing the read fails until the baseline is shrunk, then passes.
        test.write_text('func testFoo() {\n    runSuite("Foo keeps its promise") {}\n}\n', encoding="utf-8")
        assert run_check(root, base, quarantine, today, shrink=False) == 1
        assert run_check(root, base, quarantine, today, shrink=True) == 0
        assert load_baseline(base)["source-text"] == {}
        assert run_check(root, base, quarantine, today, shrink=False) == 0

        # Quarantine: valid entry passes, unknown suite and bad format fail, old entry only warns.
        quarantine.write_text("# comment\n2026-09-20 | Foo keeps its promise | flaky on CI, Justin fixes\n", encoding="utf-8")
        assert run_check(root, base, quarantine, today, shrink=False) == 0
        quarantine.write_text("2026-01-01 | Foo keeps its promise | flaky on CI, Justin fixes\n", encoding="utf-8")
        assert run_check(root, base, quarantine, today, shrink=False) == 0
        errors, warnings = check_quarantine(root, quarantine, today)
        assert not errors and len(warnings) == 1
        quarantine.write_text("2026-09-20 | Some other suite | flaky on CI, Justin fixes\n", encoding="utf-8")
        assert run_check(root, base, quarantine, today, shrink=False) == 1
        quarantine.write_text("benched: Foo keeps its promise\n", encoding="utf-8")
        assert run_check(root, base, quarantine, today, shrink=False) == 1
    print("check-test-shape self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--shrink", action="store_true", help="lower baseline counts to match the tree (never raises)")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    return run_check(REPO_ROOT, BASELINE_PATH, QUARANTINE_PATH, dt.date.today(), shrink=args.shrink)


if __name__ == "__main__":
    sys.exit(main())

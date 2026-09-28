#!/usr/bin/env python3
"""Find tests that never catch anything, by breaking Swift code on purpose.

Mutation testing makes one small change to production code (a "mutant"), runs
the tests, and checks whether anything went red. KILLED means a test noticed.
SURVIVED means the tests pass with the code broken, which points at a missing
assertion. COMPILE-ERROR means the mutant did not build; it counts as neither.

Usage:
    python3 scripts/dev/mutation-probe.py <Sources/...swift> --test "<shell command>"
        [--max N] [--seed S] [--report build/mutation/<name>.json]
        [--operators a,b] [--lines 12,40-44] [--timeout SECONDS] [--list]
    python3 scripts/dev/mutation-probe.py --self-test

Example:
    python3 scripts/dev/mutation-probe.py Sources/Speech/DictationReadinessWaitPolicy.swift \\
        --test "TZ=America/Chicago bash run-tests.sh --filter DictationReadinessWaitPolicyTests"

Mutants (one site per mutant, never inside comments, strings, or #if lines):
    equality      ==  <-> !=
    less          <   <-> <=
    greater       >   <-> >=
    logical       &&  <-> ||
    bool          true <-> false
    return-bool   return true <-> return false
    int-plus-one  single-digit integer literal n -> n+1
    negate-if     `if cond {` on one line -> `if !(cond) {`

Operators must have whitespace on both sides, which skips generics (`<T>`),
`->`, `...`, `..<`, prefix/postfix operators, and operator declarations.

Safety: the probe edits a real, tracked source file. It refuses paths outside
Sources/, files with unstaged or staged changes, and a red baseline. The
original bytes go back in a finally block, on SIGINT/SIGTERM/SIGHUP, and at
exit. While a run is live, a copy of the original sits in
build/mutation/.backup/. If the probe is SIGKILLed, `git checkout -- <file>`
restores the file. Test commands run with TRANSCRIPTED_FAST_TESTS_NO_CACHE=1
unless you set it, so mutants do not churn the fast-test object cache.

Output: one line per mutant, totals, and a mutation score of
killed / (killed + survived). A JSON report goes to build/mutation/<name>.json
(gitignored) and per-mutant logs to build/mutation/<name>-logs/.

See docs/mutation-testing.md.
"""

from __future__ import annotations

import argparse
import atexit
import datetime
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence, Tuple

DEFAULT_MAX = 25
DEFAULT_SEED = 1
REPORT_DIR = Path("build") / "mutation"
LOCK_NAME = ".probe.lock"
BACKUP_DIR_NAME = ".backup"
OUTPUT_TAIL_LINES = 40

OPERATORS = (
    "equality",
    "less",
    "greater",
    "logical",
    "bool",
    "return-bool",
    "int-plus-one",
    "negate-if",
)

# Maximal operator-character run -> (operator name, replacement).
BINARY_SWAPS: Dict[str, Tuple[str, str]] = {
    "==": ("equality", "!="),
    "!=": ("equality", "=="),
    "<": ("less", "<="),
    "<=": ("less", "<"),
    ">": ("greater", ">="),
    ">=": ("greater", ">"),
    "&&": ("logical", "||"),
    "||": ("logical", "&&"),
}

OPERATOR_CHARS = set("/=-+!*%<>&|^~?.")
WHITESPACE = set(" \t\r\n")

# Lines that are never mutated: compiler directives and availability checks.
SKIP_LINE_RE = re.compile(r"^\s*#(?:if|elseif|else|endif|warning|error|sourceLocation)\b")
AVAILABILITY_RE = re.compile(r"[#@](?:available|unavailable)\b")
DECLARATION_START_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:public|private|fileprivate|internal|open|static|class|final|nonisolated|"
    r"override|mutating|nonmutating|convenience|required|indirect|package)\s+)*"
    r"(?:func|init|extension|struct|class|enum|protocol|actor|typealias|subscript|associatedtype)\b"
)
IF_LINE_RE = re.compile(r"^(?P<head>\s*(?:\}\s*else\s+)?if\s+)(?P<cond>.+?)(?P<tail>\s*\{\s*)$")
IF_COND_REJECT_RE = re.compile(r"[,{}]|\b(?:let|var|case|await|try)\b|#(?:available|unavailable)")
BOOL_RE = re.compile(r"\b(?:true|false)\b")
INT_RE = re.compile(r"(?<![\w.$#])([0-9])(?![\w.])")

COMPILE_ERROR_RE = re.compile(
    r"\.swift:\d+:\d+: error: "
    r"|^(?:<unknown>:0: )?error: (?:compile command failed|link command failed|unable to)"
    r"|^ld: ",
    re.MULTILINE,
)
FAIL_LINE_RE = re.compile(r"FAIL \[([^\]]+)\]")
RUNNING_LINE_RE = re.compile(r"^Running (.+?)\.\.\.\s*$")
# run-tests.sh prints "Running tests..." itself before the suite starts.
NOT_A_TEST_CASE = {"tests"}
XCTEST_FAIL_RE = re.compile(r"Test Case '([^']+)' failed")


class ProbeError(Exception):
    """A refusal or setup problem; printed without a traceback."""


class ProbeInterrupted(Exception):
    """Raised from the signal handler so every finally block runs."""


# --------------------------------------------------------------------------- lexing


def _skip_block_comment(text: str, start: int) -> int:
    """Return the index just past a (possibly nested) /* ... */ comment."""
    depth = 0
    i = start
    n = len(text)
    while i < n:
        if text.startswith("/*", i):
            depth += 1
            i += 2
        elif text.startswith("*/", i):
            depth -= 1
            i += 2
            if depth == 0:
                return i
        else:
            i += 1
    return n


def _skip_interpolation(text: str, open_paren: int) -> int:
    """Return the index just past the `)` that closes an interpolation."""
    depth = 0
    i = open_paren
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"' or c == "#":
            end = _string_end(text, i)
            if end is not None:
                i = end
                continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return n


def _string_end(text: str, start: int) -> Optional[int]:
    """If a string (or #/regex/#) literal starts at `start`, return its end index."""
    n = len(text)
    k = start
    while k < n and text[k] == "#":
        k += 1
    hashes = k - start
    if k >= n:
        return None
    if hashes and text[k] == "/":
        closer = "/" + "#" * hashes
        end = text.find(closer, k + 1)
        return n if end < 0 else end + len(closer)
    if text[k] != '"':
        return None
    multi = text.startswith('"""', k)
    i = k + (3 if multi else 1)
    closer = ('"""' if multi else '"') + "#" * hashes
    escape = "\\" + "#" * hashes
    while i < n:
        if text.startswith(escape, i):
            j = i + len(escape)
            if j < n and text[j] == "(":
                i = _skip_interpolation(text, j)
            else:
                i = j + 1
            continue
        if text.startswith(closer, i):
            return i + len(closer)
        if not multi and text[i] == "\n":
            return i  # unterminated single-line string: stop at the line end
        i += 1
    return n


def code_mask(text: str) -> bytearray:
    """1 for characters that are Swift code, 0 inside comments, string literals
    (interpolations included, to stay conservative), and `backtick` names."""
    n = len(text)
    mask = bytearray(b"\x01") * n

    def clear(a: int, b: int) -> None:
        mask[a:b] = b"\x00" * (b - a)

    i = 0
    while i < n:
        c = text[i]
        if c == "/" and text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            clear(i, end)
            i = end
            continue
        if c == "/" and text.startswith("/*", i):
            end = _skip_block_comment(text, i)
            clear(i, end)
            i = end
            continue
        if c == "`":
            end = text.find("`", i + 1)
            newline = text.find("\n", i + 1)
            if end > 0 and (newline < 0 or end < newline):
                clear(i, end + 1)
                i = end + 1
                continue
        if c == '"' or c == "#":
            end = _string_end(text, i)
            if end is not None:
                clear(i, end)
                i = end
                continue
        i += 1
    return mask


# --------------------------------------------------------------------------- mutants


@dataclass(frozen=True)
class Mutant:
    offset: int
    length: int
    operator: str
    before: str
    after: str
    line: int
    column: int

    def describe(self) -> str:
        return f"{self.before} -> {self.after}"


def _line_starts(text: str) -> List[int]:
    starts = [0]
    for index, char in enumerate(text):
        if char == "\n":
            starts.append(index + 1)
    return starts


def _line_bounds(text: str, starts: List[int], line_index: int) -> Tuple[int, int]:
    begin = starts[line_index]
    end = starts[line_index + 1] - 1 if line_index + 1 < len(starts) else len(text)
    return begin, end


def _all_code(mask: bytearray, a: int, b: int) -> bool:
    return all(mask[a:b])


def find_mutants(text: str, operators: Optional[Sequence[str]] = None) -> List[Mutant]:
    """Every mutation site in `text`, sorted by position. Each mutant is one
    contiguous replacement; applying it never touches any other byte."""
    enabled = set(operators or OPERATORS)
    mask = code_mask(text)
    starts = _line_starts(text)
    mutants: List[Mutant] = []

    for line_index in range(len(starts)):
        begin, end = _line_bounds(text, starts, line_index)
        line = text[begin:end]
        if SKIP_LINE_RE.match(line) or AVAILABILITY_RE.search(line):
            continue

        def add(offset: int, before: str, after: str, operator: str) -> None:
            if operator in enabled:
                mutants.append(
                    Mutant(offset, len(before), operator, before, after, line_index + 1, offset - begin + 1)
                )

        # Binary operator swaps.
        i = begin
        while i < end:
            if not mask[i] or text[i] not in OPERATOR_CHARS:
                i += 1
                continue
            j = i
            while j < end and mask[j] and text[j] in OPERATOR_CHARS:
                j += 1
            run = text[i:j]
            swap = BINARY_SWAPS.get(run)
            spaced = i > 0 and text[i - 1] in WHITESPACE and j < len(text) and text[j] in WHITESPACE
            if swap and spaced:
                prefix = text[begin:i]
                is_declaration = re.search(r"\b(?:func|operator)\s*$", prefix) or re.search(r"\boperator\b", prefix)
                is_type_constraint = run in ("==", "!=") and (
                    re.match(r"^\s*where\b", line)
                    or (re.search(r"\bwhere\b", prefix) and DECLARATION_START_RE.match(line))
                )
                if not is_declaration and not is_type_constraint:
                    add(i, run, swap[1], swap[0])
            i = j

        # Boolean literals.
        for match in BOOL_RE.finditer(line):
            offset = begin + match.start()
            if not mask[offset]:
                continue
            previous = text[offset - 1] if offset > 0 else ""
            if previous in (".", "$", "#", "`"):
                continue
            prefix = text[begin:offset]
            if re.search(r"\bcase\s+$", prefix):
                continue
            word = match.group(0)
            flipped = "false" if word == "true" else "true"
            return_match = re.search(r"\breturn\s+$", prefix)
            if return_match:
                start = begin + return_match.start()
                add(start, text[start:offset] + word, text[start:offset] + flipped, "return-bool")
            else:
                add(offset, word, flipped, "bool")

        # Small integer literals.
        if not (re.search(r"\bcase\b", line) and "=" in line):
            for match in INT_RE.finditer(line):
                offset = begin + match.start(1)
                if not mask[offset]:
                    continue
                digit = match.group(1)
                add(offset, digit, str(int(digit) + 1), "int-plus-one")

        # `if cond {` on one line -> `if !(cond) {`.
        code_end = end
        for k in range(begin, end):
            if not mask[k] and text.startswith("//", k):
                code_end = k
                break
        if_match = IF_LINE_RE.match(text[begin:code_end])
        if if_match:
            cond = if_match.group("cond")
            cond_start = begin + if_match.start("cond")
            cond_end = cond_start + len(cond)
            if (
                _all_code(mask, cond_start, cond_end)
                and not IF_COND_REJECT_RE.search(cond)
                and cond.strip() == cond
            ):
                add(cond_start, cond, f"!({cond})", "negate-if")

    mutants.sort(key=lambda m: (m.offset, OPERATORS.index(m.operator)))
    return mutants


def apply_mutant(text: str, mutant: Mutant) -> str:
    current = text[mutant.offset:mutant.offset + mutant.length]
    if current != mutant.before:
        raise ProbeError(f"mutant at line {mutant.line} no longer matches the source ({current!r} != {mutant.before!r})")
    return text[:mutant.offset] + mutant.after + text[mutant.offset + mutant.length:]


def _sample_rank(seed: int, mutant: Mutant) -> str:
    key = f"{seed}|{mutant.line}|{mutant.column}|{mutant.operator}|{mutant.after}"
    return hashlib.sha256(key.encode("utf-8")).hexdigest()


def select_mutants(mutants: Sequence[Mutant], max_count: int, seed: int) -> List[Mutant]:
    """Deterministic sample: the same file, seed, and max always give the same
    mutants, on any machine or Python version. max_count <= 0 keeps them all."""
    if max_count <= 0 or len(mutants) <= max_count:
        return list(mutants)
    chosen = sorted(mutants, key=lambda m: _sample_rank(seed, m))[:max_count]
    return sorted(chosen, key=lambda m: (m.offset, OPERATORS.index(m.operator)))


def source_line(text: str, line: int) -> str:
    lines = text.split("\n")
    return lines[line - 1] if 0 < line <= len(lines) else ""


# --------------------------------------------------------------------------- target validation


def validate_target(repo_root: Path, target: str) -> str:
    """Return the repo-relative path of a Swift file under Sources/, or raise."""
    root = repo_root.resolve()
    candidate = Path(target)
    if not candidate.is_absolute():
        candidate = Path.cwd() / candidate
        if not candidate.exists():
            candidate = root / target
    try:
        resolved = candidate.resolve(strict=True)
    except (FileNotFoundError, RuntimeError):
        raise ProbeError(f"{target}: file not found")
    sources = root / "Sources"
    try:
        relative = resolved.relative_to(sources)
    except ValueError:
        raise ProbeError(f"{target}: refusing a path outside Sources/ (resolved to {resolved})")
    if resolved.suffix != ".swift" or not resolved.is_file():
        raise ProbeError(f"{target}: only Swift source files can be mutated")
    return str(Path("Sources") / relative)


def _git(repo_root: Path, *args: str, env: Optional[Dict[str, str]] = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args], cwd=str(repo_root), stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env
    )


def git_blob_sha(data: bytes) -> str:
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def ensure_git_clean(repo_root: Path, relative: str, data: bytes, env: Optional[Dict[str, str]] = None) -> None:
    """Refuse unless `relative` is tracked, has no unstaged or staged change,
    and `data` is byte-for-byte the index copy. The last check is what makes
    it safe to call `data` the original: a mutant can never be mistaken for it."""
    hint = (
        f"If an earlier probe was killed mid-run, restore the file with: git checkout -- {relative}"
    )
    tracked = _git(repo_root, "ls-files", "-s", "--", relative, env=env)
    fields = tracked.stdout.decode("utf-8", "replace").split()
    if tracked.returncode != 0 or len(fields) < 2:
        raise ProbeError(f"{relative}: not tracked by git; the probe only mutates committed files")
    if _git(repo_root, "diff", "--quiet", "--", relative, env=env).returncode != 0:
        raise ProbeError(f"{relative}: has uncommitted changes; commit or stash them first. {hint}")
    if _git(repo_root, "diff", "--cached", "--quiet", "--", relative, env=env).returncode != 0:
        raise ProbeError(f"{relative}: has staged changes; commit or unstage them first. {hint}")
    if git_blob_sha(data) != fields[1]:
        raise ProbeError(
            f"{relative}: bytes on disk do not match the git index copy (line-ending filter or a concurrent edit?). {hint}"
        )


# --------------------------------------------------------------------------- the guarded file


def _write_bytes(path: Path, data: bytes) -> None:
    with open(path, "r+b") as handle:
        handle.seek(0)
        handle.write(data)
        handle.truncate()
        handle.flush()
        os.fsync(handle.fileno())


class SourceGuard:
    """Owns the target file for one run. Swaps mutants in and always puts the
    original bytes back. Restoring is idempotent and verified by reading back."""

    def __init__(self, path: Path, original: bytes, backup_path: Optional[Path] = None):
        self.path = path
        self.original = original
        self.backup_path = backup_path
        if backup_path is not None:
            backup_path.parent.mkdir(parents=True, exist_ok=True)
            backup_path.write_bytes(original)

    def write_mutant(self, text: str) -> None:
        _write_bytes(self.path, text.encode("utf-8"))

    def restore(self) -> None:
        if self.path.read_bytes() != self.original:
            _write_bytes(self.path, self.original)
        if self.path.read_bytes() != self.original:
            raise ProbeError(f"could not restore {self.path}; copy is at {self.backup_path}")

    def close(self) -> None:
        self.restore()
        if self.backup_path is not None and self.backup_path.exists():
            self.backup_path.unlink()


def _restore_quietly(guard: SourceGuard) -> None:
    """Restore with the interrupt signals ignored, so a second Ctrl-C cannot
    cut a restore in half."""
    watched = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    previous = {}
    for sig in watched:
        try:
            previous[sig] = signal.signal(sig, signal.SIG_IGN)
        except (ValueError, OSError):
            pass
    try:
        guard.restore()
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def install_interrupt_handlers() -> Dict[int, object]:
    """SIGINT/SIGTERM/SIGHUP raise ProbeInterrupted so the finally blocks run.
    The handler does not touch the file itself: a write in progress must close
    first, or its buffered bytes could land on top of the restored original."""

    def handler(signum, _frame):
        raise ProbeInterrupted(signal.Signals(signum).name)

    previous = {}
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        previous[sig] = signal.signal(sig, handler)
    return previous


def restore_handlers(previous: Dict[int, object]) -> None:
    for sig, handler in previous.items():
        signal.signal(sig, handler)


# --------------------------------------------------------------------------- running tests


@dataclass
class RunResult:
    returncode: int
    output: str
    seconds: float
    timed_out: bool = False


def _kill_group(proc: subprocess.Popen) -> None:
    """SIGTERM the command's process group, give it a few seconds, then
    SIGKILL whatever is left (swiftc children can outlive the shell)."""
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return
    try:
        proc.wait(timeout=5.0)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        proc.wait(timeout=5.0)
    except subprocess.TimeoutExpired:
        pass


def run_shell(command: str, cwd: Path, env: Dict[str, str], timeout: Optional[float]) -> RunResult:
    """Run the test command in its own process group, so a timeout or Ctrl-C
    can stop the whole tree (bash, swiftc, the test binary)."""
    started = time.monotonic()
    proc = subprocess.Popen(
        command,
        shell=True,
        cwd=str(cwd),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    timed_out = False
    try:
        try:
            raw, _ = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            _kill_group(proc)
            raw, _ = proc.communicate()
    finally:
        if proc.poll() is None:
            _kill_group(proc)
    return RunResult(proc.returncode, raw.decode("utf-8", "replace"), time.monotonic() - started, timed_out)


def classify(result: RunResult) -> str:
    if result.timed_out:
        return "timeout"
    if result.returncode == 0:
        return "survived"
    if COMPILE_ERROR_RE.search(result.output):
        return "compile-error"
    return "killed"


def _running_case(line: str) -> Optional[str]:
    running = RUNNING_LINE_RE.match(line)
    if running and running.group(1) not in NOT_A_TEST_CASE:
        return running.group(1)
    return None


def failing_cases(output: str) -> Tuple[List[str], List[str]]:
    """(test cases, assertion locations) that failed, from fast-test output
    ("Running <case>..." then "FAIL [File.swift:12]") or XCTest output."""
    cases: List[str] = []
    asserts: List[str] = []
    current: Optional[str] = None
    for line in output.splitlines():
        running = _running_case(line)
        if running:
            current = running
            continue
        fail = FAIL_LINE_RE.search(line)
        if fail:
            if fail.group(1) not in asserts:
                asserts.append(fail.group(1))
            if current and current not in cases:
                cases.append(current)
        xctest = XCTEST_FAIL_RE.search(line)
        if xctest and xctest.group(1) not in cases:
            cases.append(xctest.group(1))
    return cases, asserts


def last_running_case(output: str) -> Optional[str]:
    last = None
    for line in output.splitlines():
        last = _running_case(line) or last
    return last


def all_cases(output: str) -> List[str]:
    seen: List[str] = []
    for line in output.splitlines():
        running = _running_case(line)
        if running and running not in seen:
            seen.append(running)
    return seen


def first_compile_error(output: str) -> Optional[str]:
    for line in output.splitlines():
        if COMPILE_ERROR_RE.search(line):
            return line.strip()[:300]
    return None


@dataclass
class MutantResult:
    mutant: Mutant
    status: str
    seconds: float
    returncode: int
    original_line: str
    mutated_line: str
    killed_by: List[str] = field(default_factory=list)
    failed_asserts: List[str] = field(default_factory=list)
    compile_error: Optional[str] = None
    log: Optional[str] = None


def run_mutants(
    guard: SourceGuard,
    text: str,
    mutants: Sequence[Mutant],
    runner: Callable[[str], RunResult],
    on_result: Optional[Callable[[int, int, MutantResult], None]] = None,
    log_dir: Optional[Path] = None,
    collected: Optional[List[MutantResult]] = None,
) -> List[MutantResult]:
    """Apply each mutant alone, run the tests, and put the original back before
    the next one. The finally block restores the file on any exit path.
    Results go into `collected` as they land, so an interrupt keeps them."""
    results: List[MutantResult] = collected if collected is not None else []
    try:
        for index, mutant in enumerate(mutants, start=1):
            mutated = apply_mutant(text, mutant)
            try:
                guard.write_mutant(mutated)
                result = runner(f"mutant {index}")
            finally:
                _restore_quietly(guard)
            status = classify(result)
            cases, asserts = failing_cases(result.output)
            if status in ("killed", "timeout") and not cases:
                crashed_in = last_running_case(result.output)
                if crashed_in:
                    cases = [crashed_in]
            log_path = None
            if log_dir is not None:
                log_dir.mkdir(parents=True, exist_ok=True)
                log_path = log_dir / f"{index:02d}-L{mutant.line}-{mutant.operator}.log"
                log_path.write_text(
                    f"# {mutant.operator} at line {mutant.line}: {mutant.describe()}\n"
                    f"# status={status} exit={result.returncode} seconds={result.seconds:.1f}\n\n{result.output}",
                    encoding="utf-8",
                )
            record = MutantResult(
                mutant=mutant,
                status=status,
                seconds=result.seconds,
                returncode=result.returncode,
                original_line=source_line(text, mutant.line),
                mutated_line=source_line(mutated, mutant.line),
                killed_by=cases if status in ("killed", "timeout") else [],
                failed_asserts=asserts if status in ("killed", "timeout") else [],
                compile_error=first_compile_error(result.output) if status == "compile-error" else None,
                log=str(log_path) if log_path else None,
            )
            results.append(record)
            if on_result:
                on_result(index, len(mutants), record)
    finally:
        _restore_quietly(guard)
    return results


def totals(results: Sequence[MutantResult]) -> Dict[str, object]:
    counts = {"killed": 0, "survived": 0, "compile-error": 0, "timeout": 0}
    for result in results:
        counts[result.status] += 1
    killed = counts["killed"] + counts["timeout"]
    scored = killed + counts["survived"]
    return {
        "killed": killed,
        "killed_by_timeout": counts["timeout"],
        "survived": counts["survived"],
        "compile_error": counts["compile-error"],
        "mutation_score": round(killed / scored, 4) if scored else None,
    }


# --------------------------------------------------------------------------- CLI


def _clip(value: str, width: int = 96) -> str:
    value = value.strip()
    return value if len(value) <= width else value[: width - 3] + "..."


def print_plan(relative: str, text: str, found: Sequence[Mutant], chosen: Sequence[Mutant], max_count: int, seed: int) -> None:
    shown = "all" if len(chosen) == len(found) else f"{len(chosen)} (seed {seed}, --max {max_count})"
    print(f"{relative}: {len(found)} mutation sites, planned: {shown}")
    for index, mutant in enumerate(chosen, start=1):
        print(
            f"  {index:>3}. line {mutant.line:<4} {mutant.operator:<13} {_clip(mutant.describe(), 40):<40}"
            f"  | {_clip(source_line(text, mutant.line), 70)}"
        )


def _print_result(index: int, count: int, record: MutantResult) -> None:
    labels = {
        "killed": "KILLED",
        "survived": "SURVIVED",
        "compile-error": "COMPILE-ERROR",
        "timeout": "KILLED (timeout)",
    }
    mutant = record.mutant
    print(
        f"[{index:>2}/{count}] line {mutant.line:<4} {mutant.operator:<13} {_clip(mutant.describe(), 34):<34} "
        f"{labels[record.status]:<16} {record.seconds:6.1f}s",
        flush=True,
    )
    if record.status == "survived":
        print(f"        still green with: {_clip(record.mutated_line, 90)}", flush=True)


def _acquire_lock(lock_path: Path) -> None:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    for _ in range(2):
        try:
            fd = os.open(str(lock_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
        except FileExistsError:
            try:
                pid = int(lock_path.read_text().strip() or "0")
            except (OSError, ValueError):
                pid = 0
            alive = False
            if pid > 0:
                try:
                    os.kill(pid, 0)
                    alive = True
                except ProcessLookupError:
                    alive = False
                except PermissionError:
                    alive = True
            if alive:
                raise ProbeError(f"another mutation probe (pid {pid}) is running in this checkout ({lock_path})")
            lock_path.unlink()
            continue
        with os.fdopen(fd, "w") as handle:
            handle.write(str(os.getpid()))
        return
    raise ProbeError(f"could not take {lock_path}")


def _repo_root() -> Path:
    here = Path(__file__).resolve().parent
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], cwd=str(here), stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    if result.returncode != 0:
        raise ProbeError("not inside a git checkout")
    return Path(result.stdout.decode().strip())


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Dependency-free mutation-testing probe for one Swift file under Sources/.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="See docs/mutation-testing.md.",
    )
    parser.add_argument("target", nargs="?", help="Swift file under Sources/")
    parser.add_argument("--test", help="shell command that runs the tests (exit 0 = green)")
    parser.add_argument("--max", type=int, default=DEFAULT_MAX, help=f"most mutants to run (default {DEFAULT_MAX}; 0 = all)")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED, help=f"sampling seed (default {DEFAULT_SEED})")
    parser.add_argument("--report", help="JSON report path (default build/mutation/<file>.json)")
    parser.add_argument("--operators", help="comma list to limit mutants: " + ",".join(OPERATORS))
    parser.add_argument(
        "--lines",
        help="comma list of source lines or ranges (12,40-44) to limit mutants, e.g. to re-check survivors with a wider --test",
    )
    parser.add_argument("--timeout", type=float, help="seconds per mutant run (default 3x baseline + 60, min 120)")
    parser.add_argument("--list", action="store_true", help="print the planned mutants and exit without running")
    parser.add_argument("--self-test", action="store_true", help="offline checks of mutant generation and restore logic")
    args = parser.parse_args(argv)
    if args.operators:
        chosen = [item.strip() for item in args.operators.split(",") if item.strip()]
        unknown = [item for item in chosen if item not in OPERATORS]
        if unknown:
            parser.error(f"unknown operator(s): {', '.join(unknown)} (known: {', '.join(OPERATORS)})")
        args.operators = chosen
    if args.lines:
        try:
            args.lines = parse_lines(args.lines)
        except ValueError:
            parser.error(f"--lines wants numbers or ranges like 12,40-44, got {args.lines!r}")
    return args


def parse_lines(spec: str) -> List[int]:
    lines: List[int] = []
    for item in spec.split(","):
        item = item.strip()
        if not item:
            continue
        if "-" in item:
            low, high = (int(part) for part in item.split("-", 1))
            if low > high or low < 1:
                raise ValueError(item)
            lines.extend(range(low, high + 1))
        else:
            value = int(item)
            if value < 1:
                raise ValueError(item)
            lines.append(value)
    if not lines:
        raise ValueError(spec)
    return sorted(set(lines))


def plan_mutants(text: str, args: argparse.Namespace) -> List[Mutant]:
    """All sites for this run: operator and line filters applied, before sampling."""
    found = find_mutants(text, args.operators)
    if args.lines:
        wanted = set(args.lines)
        found = [mutant for mutant in found if mutant.line in wanted]
    return found


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return self_test()
    if not args.target:
        print("error: a target file under Sources/ is required (or --self-test)", file=sys.stderr)
        return 2
    try:
        return _probe(args)
    except ProbeError as error:
        sys.stdout.flush()
        print(f"mutation-probe: {error}", file=sys.stderr)
        return 2


def _probe(args: argparse.Namespace) -> int:
    repo_root = _repo_root()
    relative = validate_target(repo_root, args.target)
    path = repo_root / relative

    if args.list:
        text = path.read_bytes().decode("utf-8")
        found = plan_mutants(text, args)
        print_plan(relative, text, found, select_mutants(found, args.max, args.seed), args.max, args.seed)
        return 0
    if not args.test:
        raise ProbeError("--test is required unless --list or --self-test")

    mutation_dir = repo_root / REPORT_DIR
    lock_path = mutation_dir / LOCK_NAME
    _acquire_lock(lock_path)

    def release_lock() -> None:
        try:
            if lock_path.read_text().strip() == str(os.getpid()):
                lock_path.unlink()
        except OSError:
            pass

    atexit.register(release_lock)
    try:
        return _run_probe(args, repo_root, relative, path, mutation_dir)
    finally:
        release_lock()


def _run_probe(args: argparse.Namespace, repo_root: Path, relative: str, path: Path, mutation_dir: Path) -> int:
    report_path = Path(args.report) if args.report else REPORT_DIR / f"{path.stem}.json"
    if not report_path.is_absolute():
        report_path = repo_root / report_path
    log_dir = report_path.with_name(report_path.stem + "-logs")
    backup_path = mutation_dir / BACKUP_DIR_NAME / (relative.replace("/", "__") + ".orig")

    # Read once, then prove these bytes are the committed copy. Everything
    # after this point restores exactly `data`.
    data = path.read_bytes()
    ensure_git_clean(repo_root, relative, data)
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise ProbeError(f"{relative}: not UTF-8")
    found = plan_mutants(text, args)
    chosen = select_mutants(found, args.max, args.seed)
    if not chosen:
        print(f"{relative}: no mutation sites found; nothing to do")
        return 0

    env = dict(os.environ)
    env.setdefault("TRANSCRIPTED_FAST_TESTS_NO_CACHE", "1")
    env.setdefault("TRANSCRIPTED_DISABLE_FILE_LOGGER", "1")
    head = _git(repo_root, "rev-parse", "HEAD").stdout.decode().strip()
    started_at = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()

    print(f"Mutation probe: {relative}")
    filtered = " (after --lines/--operators)" if args.lines or args.operators else ""
    print(f"  sites found{filtered}: {len(found)}, running: {len(chosen)} (seed {args.seed})")
    print(f"  test command: {args.test}")
    print(f"  fast-test cache: TRANSCRIPTED_FAST_TESTS_NO_CACHE={env['TRANSCRIPTED_FAST_TESTS_NO_CACHE']}")

    guard = SourceGuard(path, data, backup_path)
    atexit.register(guard.restore)
    previous_handlers = install_interrupt_handlers()
    results: List[MutantResult] = []
    baseline: Optional[RunResult] = None
    timeout: Optional[float] = None
    baseline_cases: List[str] = []
    interrupted = False
    try:
        print("Baseline (unmutated) run...", flush=True)
        baseline = run_shell(args.test, repo_root, env, None)
        log_dir.mkdir(parents=True, exist_ok=True)
        (log_dir / "baseline.log").write_text(baseline.output, encoding="utf-8")
        if baseline.returncode != 0:
            print("\n".join(baseline.output.splitlines()[-OUTPUT_TAIL_LINES:]))
            raise ProbeError(
                f"baseline must be green: the test command exited {baseline.returncode} on unmutated code "
                f"(log: {log_dir / 'baseline.log'})"
            )
        timeout = args.timeout or max(120.0, baseline.seconds * 3 + 60)
        baseline_cases = all_cases(baseline.output)
        print(
            f"  baseline green in {baseline.seconds:.1f}s; {len(baseline_cases)} test cases seen; "
            f"timeout per mutant {timeout:.0f}s; expect about {baseline.seconds * len(chosen) / 60:.0f} min",
            flush=True,
        )

        def runner(_label: str) -> RunResult:
            return run_shell(args.test, repo_root, env, timeout)

        run_mutants(guard, text, chosen, runner, _print_result, log_dir, collected=results)
    except ProbeInterrupted as signal_name:
        interrupted = True
        print(f"\nInterrupted ({signal_name}); source restored.", file=sys.stderr)
    finally:
        _restore_quietly(guard)
        guard.close()
        restore_handlers(previous_handlers)

    clean = _git(repo_root, "diff", "--quiet", "--", relative).returncode == 0
    summary = totals(results)
    # Assertion locations are exact. Case names are the last "Running <case>..."
    # line before the failure, which is wrong when a suite prints FAIL outside
    # runSuite (it then names the previous case), so treat them as a hint.
    killers: Dict[str, int] = {}
    assert_killers: Dict[str, int] = {}
    for record in results:
        for case in record.killed_by:
            killers[case] = killers.get(case, 0) + 1
        for location in record.failed_asserts:
            assert_killers[location] = assert_killers.get(location, 0) + 1
    quiet_cases = [case for case in baseline_cases if case not in killers] if results else []

    report = {
        "tool": "mutation-probe",
        "version": 1,
        "target": relative,
        "test_command": args.test,
        "git_head": head,
        "started_at": started_at,
        "seed": args.seed,
        "max": args.max,
        "operators": list(args.operators or OPERATORS),
        "lines": args.lines,
        "sites_found": len(found),
        "sites_planned": len(chosen),
        "sites_run": len(results),
        "interrupted": interrupted,
        "baseline_seconds": round(baseline.seconds, 1) if baseline else None,
        "timeout_seconds": round(timeout, 1) if timeout else None,
        "totals": summary,
        "results": [
            {
                "line": record.mutant.line,
                "column": record.mutant.column,
                "operator": record.mutant.operator,
                "before": record.mutant.before,
                "after": record.mutant.after,
                "original_line": record.original_line.strip(),
                "mutated_line": record.mutated_line.strip(),
                "status": record.status,
                "seconds": round(record.seconds, 1),
                "exit_code": record.returncode,
                "killed_by": record.killed_by,
                "failed_asserts": record.failed_asserts,
                "compile_error": record.compile_error,
                "log": record.log,
            }
            for record in results
        ],
        "kills_by_assertion": assert_killers,
        "test_cases_seen": baseline_cases,
        "kills_by_test_case": killers,
        "test_cases_that_killed_nothing": quiet_cases,
        "source_restored_and_clean": clean,
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    score = summary["mutation_score"]
    print("")
    print(f"Summary for {relative}: {len(results)} of {len(chosen)} planned mutants run ({len(found)} sites in the file)")
    timeout_note = f" ({summary['killed_by_timeout']} by timeout)" if summary["killed_by_timeout"] else ""
    print(
        f"  killed {summary['killed']}{timeout_note}, survived {summary['survived']}, "
        f"compile-error {summary['compile_error']}"
    )
    if score is None:
        print("  mutation score: n/a (nothing compiled and ran)")
    else:
        print(f"  mutation score: {summary['killed']} / {summary['killed'] + summary['survived']} = {score * 100:.1f}%")
    survivors = [record for record in results if record.status == "survived"]
    if survivors:
        print("  survivors (tests stayed green with this change):")
        for record in survivors:
            print(f"    line {record.mutant.line}: {record.mutant.describe()}  | {_clip(record.mutated_line, 80)}")
    if assert_killers:
        print(f"  assertions that caught at least one mutant: {len(assert_killers)} (kills_by_assertion in the report)")
    if baseline_cases and results:
        print(
            f"  test cases that killed at least one mutant: {len(killers)} of {len(baseline_cases)} "
            f"(the rest are in the report; one small sample does not prove a test is useless)"
        )
    print(f"  report: {report_path}")
    if clean:
        print(f"  source check: {relative} matches git again (git diff is clean)")
    else:
        print(f"  WARNING: {relative} differs from git after the run. Restore it with: git checkout -- {relative}")
        return 3
    return 130 if interrupted else 0


# --------------------------------------------------------------------------- self-test

SELF_TEST_SWIFT = '''// Sample for mutation-probe self-test. a == b && c < d in a comment.
/* block with true and false and x >= y
   /* nested && still comment */ || still comment */
import Foundation

#if DEBUG && !TESTING
let flag = true
#endif

struct Box<T: Equatable>: Equatable {
    let value: T
    static func == (lhs: Box<T>, rhs: Box<T>) -> Bool { lhs.value == rhs.value }
}

func pick<Element>(_ items: [Element], limit: Int) -> [Element] where Element: Comparable {
    let text = "if a == b && c < d { return true }"
    let interp = "count: \\(items.count > 3 ? "many == lots" : "few") done"
    let raw = #"raw "quoted" x != y \\#(limit > 2)"#
    let multi = """
        a <= b || c >= d "quoted" true
        """
    let `default` = false
    for i in 0..<limit where i > 1 { _ = i }
    _ = (1...3).map { $0 }
    if items.count > limit {
        return Array(items.prefix(limit))
    }
    return items.count >= 2 && limit != 0 ? items : []
}

func isReady(count: Int) -> Bool {
    if count == 0 { return false }
    return true
}

extension Array where Element == Int {
    var total: Int { reduce(0, +) }
}

enum Level: Int { case low = 1, high = 2 }

func check(_ flag: Bool, _ a: Bool, _ b: Bool) -> Bool {
    switch flag {
    case true: return a
    case false: break
    }
    if #available(macOS 26, *) { _ = 5 }
    } else if a && b { // trailing comment with == inside
    return a
        || b
}
'''

SELF_TEST_EXPECTED = [
    (7, "bool", "true", "false"),
    (12, "equality", "==", "!="),
    (22, "bool", "false", "true"),
    (23, "greater", ">", ">="),
    (23, "int-plus-one", "1", "2"),
    (25, "negate-if", "items.count > limit", "!(items.count > limit)"),
    (25, "greater", ">", ">="),
    (28, "greater", ">=", ">"),
    (28, "int-plus-one", "2", "3"),
    (28, "logical", "&&", "||"),
    (28, "equality", "!=", "=="),
    (28, "int-plus-one", "0", "1"),
    (32, "equality", "==", "!="),
    (32, "int-plus-one", "0", "1"),
    (32, "return-bool", "return false", "return true"),
    (33, "return-bool", "return true", "return false"),
    (37, "int-plus-one", "0", "1"),
    (48, "negate-if", "a && b", "!(a && b)"),
    (48, "logical", "&&", "||"),
    (50, "logical", "||", "&&"),
]


def self_test() -> int:
    failures: List[str] = []

    def check(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    text = SELF_TEST_SWIFT
    mutants = find_mutants(text)
    got = [(m.line, m.operator, m.before, m.after) for m in mutants]
    check(got == SELF_TEST_EXPECTED, "mutant plan mismatch:\n  got      " + repr(got) + "\n  expected " + repr(SELF_TEST_EXPECTED))

    # Nothing inside comments, strings, interpolations, backticks, #if, or availability lines.
    mask = code_mask(text)
    for mutant in mutants:
        check(all(mask[mutant.offset:mutant.offset + mutant.length]), f"mutant in non-code at line {mutant.line}")
    for line_number in (1, 2, 3, 6, 10, 15, 16, 17, 18, 19, 20, 21, 24, 36, 40, 44, 45, 47):
        check(all(m.line != line_number for m in mutants), f"line {line_number} should have no mutants")
    check(not mask[text.index("default")], "backtick identifier should be masked")
    check(mask[text.index("let multi")], "code after a raw string with interpolation should be code again")

    # Generics, arrows, ranges, and operator declarations are skipped.
    check(all("<T" not in m.before and m.before not in ("->", "...", "..<") for m in mutants), "generic/arrow/range mutated")
    check(not any(m.line == 12 and m.column < 25 for m in mutants), "operator declaration `static func ==` mutated")
    check(not any(m.line == 36 for m in mutants), "type constraint `where Element == Int` mutated")
    check(not any(m.line == 40 for m in mutants), "enum raw values mutated")

    # Each mutant changes exactly one contiguous region and nothing else.
    original = text.encode("utf-8")
    for mutant in mutants:
        mutated = apply_mutant(text, mutant).encode("utf-8")
        prefix = 0
        while prefix < min(len(original), len(mutated)) and original[prefix] == mutated[prefix]:
            prefix += 1
        suffix = 0
        while (
            suffix < min(len(original), len(mutated)) - prefix
            and original[-1 - suffix] == mutated[-1 - suffix]
        ):
            suffix += 1
        old_region = original[prefix:len(original) - suffix].decode()
        new_region = mutated[prefix:len(mutated) - suffix].decode()
        check(old_region in mutant.before and new_region in mutant.after, f"line {mutant.line}: unexpected diff {old_region!r}->{new_region!r}")
        check(original.count(b"\n") == mutated.count(b"\n"), f"line {mutant.line}: line count changed")
        check(apply_mutant(apply_mutant(text, mutant), Mutant(
            mutant.offset, len(mutant.after), mutant.operator, mutant.after, mutant.before, mutant.line, mutant.column
        )) == text, f"line {mutant.line}: mutant does not invert cleanly")
    try:
        apply_mutant("a != b", mutants[1])
        check(False, "apply_mutant should refuse a stale mutant")
    except ProbeError:
        pass

    # Operator filtering.
    only_logical = find_mutants(text, ["logical"])
    check({m.operator for m in only_logical} == {"logical"} and len(only_logical) == 3, "--operators filter")
    check(parse_lines("33, 28-29,28") == [28, 29, 33], "--lines parsing")
    for bad_spec in ("", "x", "5-2", "0"):
        try:
            parse_lines(bad_spec)
            check(False, f"--lines should reject {bad_spec!r}")
        except ValueError:
            pass
    planned = plan_mutants(text, argparse.Namespace(operators=["logical", "return-bool"], lines=[28, 33]))
    check(
        [(m.line, m.operator) for m in planned] == [(28, "logical"), (33, "return-bool")],
        f"--lines with --operators: {[(m.line, m.operator) for m in planned]}",
    )

    # Deterministic sampling.
    first = select_mutants(mutants, 7, 1)
    check(first == select_mutants(mutants, 7, 1), "same seed should give the same sample")
    check(len(first) == 7, "--max should cap the sample")
    check(first == sorted(first, key=lambda m: (m.offset, OPERATORS.index(m.operator))), "sample should be in file order")
    check(any(select_mutants(mutants, 7, seed) != first for seed in range(2, 6)), "other seeds should change the sample")
    check(select_mutants(mutants, 0, 1) == mutants, "--max 0 keeps every mutant")
    check(select_mutants(mutants, 500, 1) == mutants, "a large --max keeps every mutant")

    # Classification.
    check(classify(RunResult(0, "ALL TESTS PASSED", 1.0)) == "survived", "exit 0 is survived")
    check(classify(RunResult(1, "  FAIL [FooTests.swift:12] expected x", 1.0)) == "killed", "test failure is killed")
    check(
        classify(RunResult(1, "Sources/A/B.swift:10:5: error: cannot convert value", 1.0)) == "compile-error",
        "swiftc error is compile-error",
    )
    check(
        classify(RunResult(133, "Swift/Array.swift:405: Fatal error: Index out of range", 1.0)) == "killed",
        "runtime trap is killed, not compile-error",
    )
    check(classify(RunResult(-9, "", 1.0, timed_out=True)) == "timeout", "timeout")
    cases, asserts = failing_cases(
        "Running Suite A...\nRunning Suite B...\n  FAIL [BTests.swift:9] boom\n  FAIL [BTests.swift:9] boom\nRunning Suite C...\n"
    )
    check(cases == ["Suite B"] and asserts == ["BTests.swift:9"], f"failure attribution: {cases} {asserts}")
    runner_output = "Compiling tests...\nRunning tests...\n\nRunning Suite A...\nRunning Suite B...\n"
    check(all_cases(runner_output) == ["Suite A", "Suite B"], f"runner banner is not a test case: {all_cases(runner_output)}")
    check(last_running_case("Running tests...\nFatal error: boom") is None, "a crash before any case names no case")
    summary = totals(
        [
            MutantResult(mutants[0], "killed", 1, 1, "", ""),
            MutantResult(mutants[1], "timeout", 1, -9, "", ""),
            MutantResult(mutants[2], "survived", 1, 0, "", ""),
            MutantResult(mutants[3], "compile-error", 1, 1, "", ""),
        ]
    )
    check(summary["killed"] == 2 and summary["survived"] == 1 and summary["compile_error"] == 1, f"totals {summary}")
    check(summary["mutation_score"] == round(2 / 3, 4), f"score {summary['mutation_score']}")

    with tempfile.TemporaryDirectory(prefix="mutation-probe-self-test-") as scratch:
        root = Path(scratch)
        (root / "Sources" / "Speech").mkdir(parents=True)
        (root / "Tests").mkdir()
        target = root / "Sources" / "Speech" / "Sample.swift"
        target.write_bytes(original)
        (root / "Tests" / "SampleTests.swift").write_text("// test\n")
        (root / "Sources" / "notes.txt").write_text("x\n")
        outside = root / "Outside.swift"
        outside.write_text("let x = 1\n")
        os.symlink(str(outside), str(root / "Sources" / "Link.swift"))

        # Target validation.
        check(validate_target(root, str(target)) == "Sources/Speech/Sample.swift", "valid Sources/ path")
        for bad in ("Tests/SampleTests.swift", "Sources/../Tests/SampleTests.swift", "Sources/notes.txt",
                    "Sources/Missing.swift", "Sources/Link.swift", str(outside)):
            try:
                validate_target(root, str(root / bad) if not bad.startswith("/") else bad)
                check(False, f"validate_target should refuse {bad}")
            except ProbeError:
                pass

        # Restore after every mutant, after an exception, and after a signal.
        backup = root / "build" / "mutation" / ".backup" / "Sample.swift.orig"
        guard = SourceGuard(target, original, backup)
        check(backup.read_bytes() == original, "backup copy written")
        seen_on_disk: List[bytes] = []

        def fake_runner(_label: str) -> RunResult:
            data = target.read_bytes()
            seen_on_disk.append(data)
            body = data.decode()
            if "count != 0" in body:
                return RunResult(1, "Sources/Speech/Sample.swift:32:15: error: nope", 0.1)
            if "return false\n}" in body.split("func isReady", 1)[1]:
                return RunResult(1, "Running isReady...\n  FAIL [SampleTests.swift:3] expected true", 0.1)
            return RunResult(0, "ALL TESTS PASSED", 0.1)

        chosen = [m for m in mutants if m.line in (32, 33)]
        results = run_mutants(guard, text, chosen, fake_runner)
        check(target.read_bytes() == original, "file restored after a full run")
        check(len(seen_on_disk) == len(chosen), "runner called once per mutant")
        for data, mutant in zip(seen_on_disk, chosen):
            check(data == apply_mutant(text, mutant).encode(), f"disk held exactly mutant line {mutant.line} during its run")
        statuses = [r.status for r in results]
        check(statuses == ["compile-error", "survived", "survived", "killed"], f"statuses {statuses}")
        check(results[-1].killed_by == ["isReady"], f"killed_by {results[-1].killed_by}")

        def exploding_runner(_label: str) -> RunResult:
            raise RuntimeError("runner blew up")

        try:
            run_mutants(guard, text, chosen, exploding_runner)
            check(False, "exception should propagate")
        except RuntimeError:
            pass
        check(target.read_bytes() == original, "file restored after an exception")

        previous = install_interrupt_handlers()
        try:
            def interrupting_runner(_label: str) -> RunResult:
                check(target.read_bytes() != original, "mutant on disk before the signal")
                os.kill(os.getpid(), signal.SIGINT)
                time.sleep(1)  # the handler raises before this finishes
                return RunResult(0, "", 0.0)

            try:
                run_mutants(guard, text, chosen, interrupting_runner)
                check(False, "SIGINT should raise ProbeInterrupted")
            except ProbeInterrupted:
                pass
            check(target.read_bytes() == original, "file restored after SIGINT")
        finally:
            restore_handlers(previous)

        # A half-applied mutant on disk (as if killed between runs) is repaired by restore().
        target.write_bytes(apply_mutant(text, mutants[0]).encode())
        guard.close()
        check(target.read_bytes() == original, "restore repairs a stray mutant")
        check(not backup.exists(), "backup removed on a clean close")

        # Real shell runs: exit codes and the timeout path.
        env = dict(os.environ)
        check(run_shell("exit 0", root, env, 10).returncode == 0, "shell exit 0")
        check(run_shell("exit 3", root, env, 10).returncode == 3, "shell exit 3")
        slow = run_shell("sleep 30", root, env, 0.5)
        check(slow.timed_out and slow.seconds < 15, f"timeout path (took {slow.seconds:.1f}s)")

        # Git cleanliness, if git is available: clean passes; unstaged, staged,
        # untracked, and bytes-that-are-not-the-index-copy are refused.
        git_env = dict(os.environ)
        git_env.update({"HOME": str(root), "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull})
        if _git(root, "--version", env=git_env).returncode == 0:
            base = ["-c", "user.name=probe", "-c", "user.email=probe@example.invalid",
                    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=" + os.devnull]
            _git(root, "init", "-q", env=git_env)
            _git(root, "add", "Sources/Speech/Sample.swift", env=git_env)
            _git(root, *base, "commit", "-q", "-m", "fixture", env=git_env)
            relative = "Sources/Speech/Sample.swift"
            try:
                ensure_git_clean(root, relative, target.read_bytes(), env=git_env)
            except ProbeError as error:
                check(False, f"clean tracked file refused: {error}")
            for label, action in (
                ("unstaged", lambda: target.write_bytes(original + b"// edit\n")),
                ("staged", lambda: _git(root, "add", relative, env=git_env)),
            ):
                action()
                try:
                    ensure_git_clean(root, relative, target.read_bytes(), env=git_env)
                    check(False, f"{label} change should be refused")
                except ProbeError:
                    pass
            _git(root, "reset", "-q", "--", relative, env=git_env)
            target.write_bytes(original)
            try:
                ensure_git_clean(root, relative, original + b"x", env=git_env)
                check(False, "bytes that differ from the index copy should be refused")
            except ProbeError:
                pass
            (root / "Sources" / "New.swift").write_text("let y = 2\n")
            try:
                ensure_git_clean(root, "Sources/New.swift", b"let y = 2\n", env=git_env)
                check(False, "untracked file should be refused")
            except ProbeError:
                pass
        else:
            print("  (git not available: skipped the git cleanliness checks)")

        # Lock: a live holder blocks, a dead one is replaced.
        lock = root / "build" / "mutation" / LOCK_NAME
        _acquire_lock(lock)
        try:
            _acquire_lock(lock)
            check(False, "second lock by a live pid should be refused")
        except ProbeError:
            pass
        lock.write_text("999999999")
        _acquire_lock(lock)
        check(lock.read_text() == str(os.getpid()), "stale lock replaced")

    if failures:
        print("mutation-probe self-test: FAILED")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(f"mutation-probe self-test: OK ({len(SELF_TEST_EXPECTED)} planned mutants, restore and safety checks passed)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

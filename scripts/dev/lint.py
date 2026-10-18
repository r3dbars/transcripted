#!/usr/bin/env python3
"""Repo lint runner: one command, many small rules, each with an error that names the fix.

Every agent that edits this repo sees only the files it opened, copies the
nearest example, and takes the shortest path that compiles. So a mistake that
happened once tends to happen again. The fix order (from pstack's /correct
skill): change the architecture so there's one way, then the types, then a lint
whose error message says what to do instead, then a test, and docs last. This
runner is the "lint" step. A rule is a small module in `scripts/dev/lint_rules/`
(see that package's docstring and docs/lint-rules.md); this file finds them,
runs them, applies suppressions and the per-file ratchet, and proves each rule
still catches the real past mistake it was written for.

The same command runs everywhere: the Claude Code PostToolUse hook (`--hook`),
the Stop hook (`--changed`), pre-push (`--range`, committed content only), and linux-checks.sh / repo-hygiene CI
(`--self-test`, `--all`).

    python3 scripts/dev/lint.py --all              # whole tree
    python3 scripts/dev/lint.py --changed          # vs merge-base with origin/main, plus uncommitted and untracked
    python3 scripts/dev/lint.py --range A..B       # files B changed since merge-base(A, B), read at B (pre-push)
    python3 scripts/dev/lint.py --files A.swift B.swift
    python3 scripts/dev/lint.py --hook < hook.json # Claude Code hook: exit 2 + stderr on new findings
    python3 scripts/dev/lint.py --list
    python3 scripts/dev/lint.py --explain <rule-id>
    python3 scripts/dev/lint.py --self-test        # runner cases, every rule's fixtures, every proof
    python3 scripts/dev/lint.py --shrink           # lower baseline counts that dropped (never raises)
    python3 scripts/dev/lint.py --write-baseline --rule <id>   # grandfather one new ratchet rule

Ratchet. A rule with `"ratchet": True` is for patterns already common in the
tree: `.agents/lint-baseline.json` holds `{rule_id: {path: count}}` and a file
passes while its count is at or under that number. Over it, every finding in the
file is printed with "N new; baseline M". `--shrink` lowers counts that dropped
and removes files that are gone; it never raises one. `--write-baseline` only
touches the rule ids named with `--rule`, and refuses (exit 1, nothing written)
when it would raise or add an entry for a rule that already has a baseline,
unless `--allow-raise` says that's the reviewed intent. Non-ratchet rules fail
on any finding.

Suppression. On the finding's line or the line right above it (stacked
suppressions for different rules may sit on consecutive lines):

    // lint-allow(<rule-id>): <reason> — expires YYYY-MM-DD, approved <handle>

(`#` instead of `//` outside Swift; `--` works in place of the dash.) The
built-in rule `lint-allow-format` flags any lint-allow comment that is
malformed, names an unknown rule, lacks a reason, expiry or approver, is
expired, expires more than a year out, or suppresses nothing. "Today" is
`datetime.date.today()`, or `LINT_TODAY=YYYY-MM-DD`. Rule fixtures are checked
with today pinned to FIXTURE_TODAY (unless LINT_TODAY is set) so a fixture's
suppression example doesn't expire under it.

Hook mode never breaks the hook: any internal error prints a note on stderr and
exits 0. Python 3.9+ stdlib only; runs on Linux CI and macOS; writes nothing
except the baseline under --shrink / --write-baseline.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import importlib
import io
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

DEV_DIR = Path(__file__).resolve().parent
REPO_ROOT = DEV_DIR.parents[1]
RULES_DIR = DEV_DIR / "lint_rules"
FIXTURES_DIR = RULES_DIR / "fixtures"
BASELINE_PATH = REPO_ROOT / ".agents/lint-baseline.json"
FIXTURE_TODAY = _dt.date(2026, 10, 18)
MAX_SUPPRESSION_DAYS = 366

if str(DEV_DIR) not in sys.path:
    sys.path.insert(0, str(DEV_DIR))

from lint_rules import _base  # noqa: E402

# Never linted by any rule: build output, prebuilt deps, and rule fixtures
# (fixtures are checked by --self-test only).
GLOBAL_EXCLUDE = (
    "scripts/dev/lint_rules/fixtures/**",
    "build/**",
    "**/.build/**",
    "deps-libs/**",
    "deps-modules/**",
    "**/node_modules/**",
)

REQUIRED_KEYS = ("id", "summary", "why", "fix", "owner_doc", "level", "paths", "ratchet", "proof")
RULE_ID_RE = re.compile(r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*\Z")

ALLOW_FORMAT_ID = "lint-allow-format"
ALLOW_FORMAT_RULE = {
    "id": ALLOW_FORMAT_ID,
    "summary": "every lint-allow comment names a known rule, a reason, an expiry within a year and an approver, and hides a real finding",
    "why": "a suppression without an owner or end date is a permanent hole; one that hides nothing is stale noise that teaches agents to paste them",
    "fix": "write `// lint-allow(<rule-id>): <reason> — expires YYYY-MM-DD, approved <handle>` (`#` outside Swift) on the finding line or the line above, or delete it",
    "owner_doc": "AGENTS.md",
    "level": "lint",
    "paths": ["**/*.swift", "**/*.py", "**/*.sh", "**/*.rb", "**/*.js", "**/*.ts"],
    "exclude": ["scripts/dev/lint.py", "scripts/dev/lint_rules/**"],
    "ratchet": False,
    "proof": ["self-test"],
}

# Detect anything that looks like a suppression, strictly parse it afterwards.
ALLOW_LOOSE_RE = re.compile(r"(?:^|[\s;])(?://+|#|/\*+)\s*lint-allow\b(?P<rest>.*)$")
ALLOW_IDS_RE = re.compile(r"\A\((?P<ids>[^)]*)\)(?P<tail>.*)\Z")
ALLOW_TAIL_RE = re.compile(
    r"\A\s*:\s*(?P<reason>\S.*?)\s+(?:—|–|--|-)\s*expires\s+(?P<date>\d{4}-\d{2}-\d{2})"
    r"\s*,?\s*approved\s+(?P<who>@?[A-Za-z0-9][\w.-]*)\s*\Z"
)
FIXTURE_PATH_RE = re.compile(r"lint-fixture-path:\s*(\S+)")


# ---------------------------------------------------------------- model

class Rule:
    def __init__(self, meta: dict, check, source: str = "", builtin: bool = False):
        self.meta = meta
        self.check = check
        self.source = source
        self.builtin = builtin
        self.id = meta["id"]
        self.paths = list(meta.get("paths") or [])
        self.exclude = list(meta.get("exclude") or [])
        self.ratchet = bool(meta.get("ratchet"))

    def applies(self, path: str) -> bool:
        if _base.path_matches(path, GLOBAL_EXCLUDE):
            return False
        return _base.path_matches(path, self.paths, self.exclude)


class Finding:
    __slots__ = ("path", "line", "rule", "message", "error")

    def __init__(self, path: str, line: int, rule: str, message: str, error: bool = False):
        self.path, self.line, self.rule, self.message, self.error = path, line, rule, message, error

    def key(self):
        return (self.path, self.line, self.rule, self.message)


class Suppression:
    __slots__ = ("line", "rule", "problem", "covers", "used")

    def __init__(self, line: int):
        self.line = line
        self.rule = ""
        self.problem = ""
        self.covers: set = set()
        self.used = False


class FileResult:
    def __init__(self, path: str):
        self.path = path
        self.findings: list = []
        self.suppressed = 0


ALLOW_RULE = Rule(ALLOW_FORMAT_RULE, None, "scripts/dev/lint.py", builtin=True)


def today() -> _dt.date:
    raw = os.environ.get("LINT_TODAY", "").strip()
    if raw:
        return _dt.date.fromisoformat(raw)
    return _dt.date.today()


# ---------------------------------------------------------------- rule loading

def validate_meta(meta, stem: str, root: Path = REPO_ROOT) -> list:
    if not isinstance(meta, dict):
        return [f"{stem}: RULE must be a dict"]
    errors = []
    for key in REQUIRED_KEYS:
        if key not in meta:
            errors.append(f"{stem}: RULE is missing {key!r}")
    if errors:
        return errors
    rid = meta["id"]
    if not isinstance(rid, str) or not RULE_ID_RE.match(rid):
        errors.append(f"{stem}: id {rid!r} must be kebab-case")
    elif rid.replace("-", "_") != stem:
        errors.append(f"{stem}: module must be named {rid.replace('-', '_')}.py after its id {rid!r}")
    if rid == ALLOW_FORMAT_ID:
        errors.append(f"{stem}: id {rid!r} is reserved for the built-in rule")
    for key in ("summary", "why", "fix", "owner_doc"):
        if not isinstance(meta[key], str) or not meta[key].strip():
            errors.append(f"{stem}: {key} must be a non-empty string")
    if isinstance(meta.get("owner_doc"), str) and meta["owner_doc"] and not (root / meta["owner_doc"]).is_file():
        errors.append(f"{stem}: owner_doc {meta['owner_doc']!r} does not exist")
    if meta["level"] != "lint":
        errors.append(f"{stem}: level must be 'lint' (other levels go in .agents/rules.json)")
    for key in ("paths", "exclude"):
        val = meta.get(key, [])
        if not isinstance(val, list) or not all(isinstance(g, str) and g for g in val):
            errors.append(f"{stem}: {key} must be a list of glob strings")
    if not meta["paths"]:
        errors.append(f"{stem}: paths must name at least one glob")
    if not isinstance(meta["ratchet"], bool):
        errors.append(f"{stem}: ratchet must be True or False")
    proof = meta["proof"]
    if not isinstance(proof, list) or not proof:
        errors.append(f"{stem}: proof must list at least one '<bad sha>:<path>' from a real past mistake")
    else:
        for entry in proof:
            if not isinstance(entry, str) or not re.match(r"[0-9a-f]{7,40}:\S+\Z", entry):
                errors.append(f"{stem}: proof entry {entry!r} must look like '<sha>:<repo path>'")
    return errors


def load_rules(rules_dir: Path = RULES_DIR, root: Path = REPO_ROOT):
    """Import every rule module. Returns (rules, errors); rules with errors are
    left out."""
    rules, errors, seen = [], [], {}
    for path in sorted(rules_dir.glob("*.py")):
        stem = path.stem
        if stem.startswith("_"):
            continue
        try:
            module = importlib.import_module(f"lint_rules.{stem}")
        except Exception as error:  # a broken rule must not take the runner down
            errors.append(f"{stem}: import failed: {error.__class__.__name__}: {error}")
            continue
        meta = getattr(module, "RULE", None)
        check = getattr(module, "check", None)
        problems = validate_meta(meta, stem, root)
        if not callable(check):
            problems.append(f"{stem}: module must define check(path, text)")
        if not problems and meta["id"] in seen:
            problems.append(f"{stem}: id {meta['id']!r} already used by {seen[meta['id']]}")
        if problems:
            errors.extend(problems)
            continue
        seen[meta["id"]] = stem
        rules.append(Rule(meta, check, path.relative_to(root).as_posix() if path.is_relative_to(root) else str(path)))
    return rules, errors


# ---------------------------------------------------------------- suppressions

def parse_suppressions(text: str, known_ids, day: _dt.date) -> list:
    if "lint-allow" not in text:
        return []
    lines = text.split("\n")
    sups = []
    for idx, raw in enumerate(lines, start=1):
        m = ALLOW_LOOSE_RE.search(raw)
        if not m:
            continue
        sup = Suppression(idx)
        rest = re.sub(r"\*/\s*\Z", "", m.group("rest")).rstrip()
        im = ALLOW_IDS_RE.match(rest)
        if not im:
            sup.problem = "malformed: expected lint-allow(<rule-id>): <reason> — expires YYYY-MM-DD, approved <handle>"
        else:
            rid = im.group("ids").strip()
            sup.rule = rid
            tail = ALLOW_TAIL_RE.match(im.group("tail"))
            if not RULE_ID_RE.match(rid):
                sup.problem = f"names {rid!r}; name exactly one rule id"
            elif rid == ALLOW_FORMAT_ID:
                sup.problem = f"{ALLOW_FORMAT_ID} can't be suppressed; fix the comment"
            elif rid not in known_ids:
                sup.problem = f"names unknown rule {rid!r} (see `python3 scripts/dev/lint.py --list`)"
            elif not tail:
                sup.problem = "needs ': <reason> — expires YYYY-MM-DD, approved <handle>' after the rule id"
            else:
                try:
                    expires = _dt.date.fromisoformat(tail.group("date"))
                except ValueError:
                    sup.problem = f"expiry {tail.group('date')} is not a real date"
                else:
                    if expires < day:
                        sup.problem = f"expired on {expires.isoformat()}; fix the code or get a new approval"
                    elif (expires - day).days > MAX_SUPPRESSION_DAYS:
                        sup.problem = f"expiry {expires.isoformat()} is more than a year out; pick a nearer date"
        sups.append(sup)
    # Coverage: the comment's own line, and the next line that isn't another
    # lint-allow comment line (so suppressions for two rules can stack).
    allow_only = {s.line for s in sups if lines[s.line - 1].strip().startswith(("//", "#", "/*"))}
    for sup in sups:
        sup.covers.add(sup.line)
        nxt = sup.line + 1
        while nxt in allow_only:
            nxt += 1
        sup.covers.add(nxt)
    return sups


# ---------------------------------------------------------------- linting

def run_check(rule: Rule, path: str, text: str) -> list:
    """Run one rule's check() and normalize its output. A crash or bad output
    becomes an error finding instead of an exception."""
    try:
        out = []
        for item in rule.check(path, text) or ():
            line, message = item
            out.append(Finding(path, int(line), rule.id, str(message)))
        return out
    except Exception as error:
        return [Finding(path, 1, rule.id, f"internal error in rule: {error.__class__.__name__}: {error}", error=True)]


def lint_text(rules, path: str, text: str, day: _dt.date, known_ids=None) -> FileResult:
    result = FileResult(path)
    known = set(known_ids if known_ids is not None else (r.id for r in rules))
    raw = []
    for rule in rules:
        if rule.applies(path):
            raw.extend(run_check(rule, path, text))
    sups = parse_suppressions(text, known, day)
    valid = [s for s in sups if not s.problem]
    for finding in raw:
        hit = None
        if not finding.error:
            for sup in valid:
                if sup.rule == finding.rule and finding.line in sup.covers:
                    hit = sup
                    break
        if hit is not None:
            hit.used = True
            result.suppressed += 1
        else:
            result.findings.append(finding)
    if ALLOW_RULE.applies(path):
        for sup in sups:
            if sup.problem:
                result.findings.append(Finding(path, sup.line, ALLOW_FORMAT_ID, f"lint-allow {sup.problem}"))
            elif not sup.used:
                result.findings.append(Finding(
                    path, sup.line, ALLOW_FORMAT_ID,
                    f"lint-allow({sup.rule}) suppresses nothing: no [{sup.rule}] finding on this line or the next; delete it"))
    result.findings.sort(key=lambda f: (f.line, f.rule))
    return result


class Report:
    def __init__(self):
        self.failing: list = []      # findings to print, in order
        self.over_notes: dict = {}   # (path, rule) -> "N new; baseline M"
        self.grandfathered = 0
        self.suppressed = 0
        self.shrinkable: list = []   # (rule, path, count, baseline)
        self.files = 0


def evaluate(results, rules_by_id: dict, baseline: dict) -> Report:
    report = Report()
    for path in sorted(results):
        res = results[path]
        report.files += 1
        report.suppressed += res.suppressed
        by_rule: dict = {}
        for f in res.findings:
            by_rule.setdefault(f.rule, []).append(f)
        ratchet_ids = [rid for rid, r in rules_by_id.items() if r.ratchet]
        for rid in ratchet_ids:
            allowed = int(baseline.get(rid, {}).get(path, 0))
            count = len([f for f in by_rule.get(rid, []) if not f.error])
            if count < allowed:
                report.shrinkable.append((rid, path, count, allowed))
        for rid, found in by_rule.items():
            rule = rules_by_id.get(rid)
            errors = [f for f in found if f.error]
            plain = [f for f in found if not f.error]
            report.failing.extend(errors)
            if rule is not None and rule.ratchet and plain:
                allowed = int(baseline.get(rid, {}).get(path, 0))
                if len(plain) <= allowed:
                    report.grandfathered += len(plain)
                    continue
                report.over_notes[(path, rid)] = f"{len(plain) - allowed} new; baseline {allowed}"
            report.failing.extend(plain)
    report.failing.sort(key=lambda f: (f.path, f.line, f.rule))
    return report


def format_report(report: Report, rules_by_id: dict) -> str:
    out = []
    noted = set()
    for f in report.failing:
        key = (f.path, f.rule)
        if key in report.over_notes and key not in noted:
            noted.add(key)
            out.append(f"{f.path}: [{f.rule}] {report.over_notes[key]} (all findings in this file below)")
        out.append(f"{f.path}:{f.line}: [{f.rule}] {f.message}")
        rule = rules_by_id.get(f.rule)
        if rule is not None and not f.error:
            out.append(f"    fix: {rule.meta['fix']}")
            out.append(f"    why: {rule.meta['why']} (see {rule.meta['owner_doc']})")
    return "\n".join(out)


def summary_line(report: Report, rule_count: int) -> str:
    over = len(report.failing)
    files = len({f.path for f in report.failing})
    state = "FAIL" if over else "ok"
    text = (f"lint: {state}: {over} finding(s) over baseline in {files} file(s); "
            f"{report.grandfathered} grandfathered, {report.suppressed} suppressed; "
            f"{rule_count} rule(s) over {report.files} file(s)")
    if report.shrinkable:
        text += f"\nlint: {len(report.shrinkable)} baseline entr(ies) can shrink: python3 scripts/dev/lint.py --shrink"
    return text


# ---------------------------------------------------------------- file selection

def _git(args, root: Path = REPO_ROOT):
    proc = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or f"git {' '.join(args)} failed")
    return proc.stdout


def all_files(root: Path = REPO_ROOT) -> list:
    try:
        names = _git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], root).split("\0")
    except (RuntimeError, OSError):
        names = [p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file() and ".git" not in p.parts]
    return sorted({n for n in names if n and (root / n).is_file()})


def changed_files(root: Path = REPO_ROOT) -> list:
    try:
        base = _git(["merge-base", "origin/main", "HEAD"], root).strip()
    except (RuntimeError, OSError):
        base = "HEAD"
    names = _git(["diff", "--name-only", "-z", "--diff-filter=d", base], root).split("\0")
    names += _git(["ls-files", "-z", "--others", "--exclude-standard"], root).split("\0")
    return sorted({n for n in names if n and (root / n).is_file()})


def parse_range(spec: str) -> tuple:
    if "..." in spec or spec.count("..") != 1:
        raise ValueError(f"--range wants A..B, got {spec!r}")
    a, b = spec.split("..")
    if not a or not b:
        raise ValueError(f"--range wants A..B with both ends, got {spec!r}")
    return a, b


def range_files(a: str, b: str, root: Path = REPO_ROOT) -> list:
    """Files added or modified on b since its merge-base with a (deletions
    skipped), so commits that only a has (a moved main, a rewritten remote tip)
    don't pull in files this push doesn't touch."""
    names = _git(["diff", "--name-only", "-z", "--diff-filter=d", f"{a}...{b}"], root).split("\0")
    return sorted({n for n in names if n})


def git_reader(rev: str, root: Path = REPO_ROOT):
    """read(root, rel) -> the file's text at `rev`, or None (binary, missing)."""
    def read(_root: Path, rel: str):
        proc = subprocess.run(["git", "show", f"{rev}:{rel}"], cwd=root, capture_output=True)
        if proc.returncode != 0:
            return None
        try:
            return proc.stdout.decode("utf-8")
        except UnicodeDecodeError:
            return None
    return read


def disk_reader(root: Path, rel: str):
    return read_text(root / rel)


def rel_path(raw: str, root: Path = REPO_ROOT, cwd: Path | None = None) -> str | None:
    p = Path(raw)
    if not p.is_absolute():
        p = (cwd or Path.cwd()) / p
    try:
        return p.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return None


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def lint_paths(paths, rules, day, root: Path = REPO_ROOT, reader=None) -> dict:
    known = {r.id for r in rules}
    read = reader or disk_reader
    results = {}
    for rel in paths:
        if not (ALLOW_RULE.applies(rel) or any(r.applies(rel) for r in rules)):
            continue
        text = read(root, rel)
        if text is None:
            continue
        results[rel] = lint_text(rules, rel, text, day, known)
    return results


# ---------------------------------------------------------------- baseline

def load_baseline(path: Path = BASELINE_PATH) -> dict:
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8") or "{}")
    if not isinstance(data, dict):
        raise ValueError(f"{path}: expected a JSON object of {{rule_id: {{path: count}}}}")
    return {k: {p: int(c) for p, c in v.items()} for k, v in data.items() if isinstance(v, dict)}


def write_baseline(data: dict, path: Path = BASELINE_PATH) -> None:
    clean = {rid: dict(sorted((p, c) for p, c in files.items() if c > 0))
             for rid, files in sorted(data.items())}
    clean = {rid: files for rid, files in clean.items() if files}
    path.write_text(json.dumps(clean, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def counts_by_rule(results: dict, rules) -> dict:
    ratchet = {r.id for r in rules if r.ratchet}
    counts: dict = {}
    for path, res in results.items():
        for f in res.findings:
            if f.rule in ratchet and not f.error:
                counts.setdefault(f.rule, {}).setdefault(path, 0)
                counts[f.rule][path] += 1
    return counts


def shrink_baseline(baseline: dict, counts: dict, rules, root: Path = REPO_ROOT) -> dict:
    """Lower every count to what the tree has now; drop dead files and rules.
    Never raises a count or adds an entry."""
    live = {r.id for r in rules if r.ratchet}
    out = {}
    for rid, files in baseline.items():
        if rid not in live:
            continue
        for path, old in files.items():
            if not (root / path).is_file():
                continue
            new = min(int(old), counts.get(rid, {}).get(path, 0))
            if new > 0:
                out.setdefault(rid, {})[path] = new
    return out


def plan_baseline_write(baseline: dict, counts: dict, rule_ids, scanned, full: bool) -> tuple:
    """New baseline for `--write-baseline --rule ...`: only the named rule ids
    change. In full mode each named rule is rebuilt from `counts`; otherwise
    only the scanned files are replaced. Returns (new_baseline, raised) where
    `raised` lists (rule, path, old, new) for every entry that went up or was
    added under a rule that already had a baseline. A rule with no entries yet
    (a new rule being grandfathered) may add freely."""
    merged = {rid: dict(files) for rid, files in baseline.items()}
    for rid in rule_ids:
        if full:
            merged[rid] = {}
        else:
            for path in scanned:
                merged.setdefault(rid, {}).pop(path, None)
        merged.setdefault(rid, {}).update(counts.get(rid, {}))
    raised = []
    for rid in rule_ids:
        old_files = baseline.get(rid, {})
        if not any(c > 0 for c in old_files.values()):
            continue
        for path, new in sorted(merged.get(rid, {}).items()):
            old = old_files.get(path, 0)
            if new > old:
                raised.append((rid, path, old, new))
    return merged, raised


# ---------------------------------------------------------------- hook

def hook(stdin_text: str, root: Path = REPO_ROOT, rules=None, baseline=None, day=None, err=sys.stderr) -> int:
    """Claude Code PostToolUse hook. Exit 2 with findings on stderr when the
    edited file has new findings; 0 otherwise, including on any internal error."""
    try:
        data = json.loads(stdin_text or "{}")
        tool_input = data.get("tool_input") or {}
        raw = tool_input.get("file_path") or tool_input.get("notebook_path") or (data.get("tool_response") or {}).get("filePath")
        if not raw or not isinstance(raw, str):
            return 0
        cwd = Path(data["cwd"]) if isinstance(data.get("cwd"), str) else root
        rel = rel_path(raw, root, cwd)
        if rel is None:
            return 0
        if rules is None:
            rules, _errors = load_rules(RULES_DIR, root)
        if not (ALLOW_RULE.applies(rel) or any(r.applies(rel) for r in rules)):
            return 0
        text = read_text(root / rel)
        if text is None:
            return 0
        day = day or today()
        result = lint_text(rules, rel, text, day, {r.id for r in rules})
        by_id = {r.id: r for r in rules}
        by_id[ALLOW_FORMAT_ID] = ALLOW_RULE
        report = evaluate({rel: result}, by_id, baseline if baseline is not None else load_baseline(root / ".agents/lint-baseline.json"))
        if not report.failing:
            return 0
        print(f"lint.py: {len(report.failing)} new finding(s) in {rel}. Fix them now; each line says how. "
              "A lint-allow needs a reason, an expiry and a human approver.", file=err)
        print(format_report(report, by_id), file=err)
        return 2
    except Exception as error:  # never break the edit loop
        print(f"lint.py --hook: internal error, skipped ({error.__class__.__name__}: {error})", file=err)
        return 0


# ---------------------------------------------------------------- self-test

def _fixture_files(rule_id: str, fixtures_dir: Path = FIXTURES_DIR) -> list:
    folder = fixtures_dir / rule_id
    if not folder.is_dir():
        return []
    return sorted(p for p in folder.iterdir() if p.is_file() and p.name.startswith(("bad", "good")))


def check_fixtures(rule: Rule, all_ids, fixtures_dir: Path = FIXTURES_DIR) -> tuple:
    """Returns (failures, fixture_count)."""
    failures = []
    files = _fixture_files(rule.id, fixtures_dir)
    bad = [p for p in files if p.name.startswith("bad")]
    good = [p for p in files if p.name.startswith("good")]
    if not bad or not good:
        failures.append(f"[{rule.id}] needs at least one bad* and one good* fixture in "
                        f"scripts/dev/lint_rules/fixtures/{rule.id}/ (has {len(bad)} bad, {len(good)} good)")
    day = _dt.date.fromisoformat(os.environ["LINT_TODAY"]) if os.environ.get("LINT_TODAY") else FIXTURE_TODAY
    for fx in files:
        text = read_text(fx)
        if text is None:
            failures.append(f"[{rule.id}] {fx.name}: not readable as UTF-8")
            continue
        first = text.split("\n", 1)[0]
        m = FIXTURE_PATH_RE.search(first)
        path = m.group(1) if m else _base.example_path(rule.paths, rule.exclude)
        if path is None:
            failures.append(f"[{rule.id}] {fx.name}: can't derive a path from {rule.paths}; add "
                            "'lint-fixture-path: <path>' on line 1")
            continue
        if not _base.path_matches(path, rule.paths, rule.exclude) or _base.path_matches(path, GLOBAL_EXCLUDE):
            failures.append(f"[{rule.id}] {fx.name}: fixture path {path} doesn't match the rule's paths/exclude")
            continue
        res = lint_text([rule], path, text, day, all_ids)
        mine = [f for f in res.findings if f.rule == rule.id]
        crashed = [f for f in mine if f.error]
        if crashed:
            failures.append(f"[{rule.id}] {fx.name}: {crashed[0].message}")
        elif fx.name.startswith("bad") and not mine:
            failures.append(f"[{rule.id}] {fx.name}: expected at least one finding as {path}, got none")
        elif fx.name.startswith("good") and mine:
            lines = ", ".join(f"line {f.line}: {f.message}" for f in mine[:3])
            failures.append(f"[{rule.id}] {fx.name}: expected no findings as {path}, got {len(mine)} ({lines})")
    return failures, len(files)


def check_proofs(rule: Rule, root: Path = REPO_ROOT) -> tuple:
    """Returns (failures, warnings, verified_count)."""
    failures, warnings, verified = [], [], 0
    for entry in rule.meta.get("proof", []):
        sha, _, path = entry.partition(":")
        try:
            have = subprocess.run(["git", "cat-file", "-e", f"{sha}:{path}"], cwd=root,
                                  capture_output=True).returncode == 0
        except OSError:
            have = False
        if not have:
            warnings.append(f"[{rule.id}] proof {entry}: object not available (shallow clone?), skipped")
            continue
        text = subprocess.run(["git", "show", f"{sha}:{path}"], cwd=root, capture_output=True).stdout.decode("utf-8", "replace")
        found = [f for f in run_check(rule, path, text) if not f.error]
        errs = [f for f in run_check(rule, path, text) if f.error] if not found else []
        if errs:
            failures.append(f"[{rule.id}] proof {entry}: {errs[0].message}")
        elif not found:
            failures.append(f"[{rule.id}] proof {entry}: the rule finds nothing in that past version; "
                            "it no longer catches the mistake it was written for")
        else:
            verified += 1
    return failures, warnings, verified


def _fake_rule(rid: str, pattern: str, ratchet: bool = False, paths=("Sources/**/*.swift",)) -> Rule:
    rx = re.compile(pattern)

    def check(_path, text):
        return [(i, f"found {pattern}") for i, ln in enumerate(text.split("\n"), 1) if rx.search(ln)]

    meta = {"id": rid, "summary": "s", "why": "w", "fix": "f", "owner_doc": "AGENTS.md", "level": "lint",
            "paths": list(paths), "ratchet": ratchet, "proof": ["0000000:x"]}
    return Rule(meta, check)


def runner_self_test() -> list:
    failures = []

    def expect(cond, label):
        if not cond:
            failures.append(f"runner: {label}")

    failures.extend(f"_base: {f}" for f in _base.self_test())
    day = _dt.date(2026, 10, 18)
    bang = _fake_rule("no-bang", r"!\s*$")
    boom = _fake_rule("no-boom", r"BOOM", ratchet=True)
    rules = [bang, boom]
    ids = {"no-bang", "no-boom"}
    P = "Sources/UI/A.swift"

    def run(text, path=P, d=day):
        return lint_text(rules, path, text, d, ids)

    def rule_hits(res, rid):
        return [f for f in res.findings if f.rule == rid]

    ok = "// lint-allow(no-bang): legacy API — expires 2026-12-01, approved @owner"
    expect(len(rule_hits(run("let a = b!\n"), "no-bang")) == 1, "plain finding reported")
    r = run(f"{ok}\nlet a = b!\n")
    expect(r.findings == [] and r.suppressed == 1, "suppression on the line above hides the finding")
    r = run("let a = b // lint-allow(no-bang): x — expires 2026-12-01, approved owner\nlet c = d!\n")
    expect(r.findings == [] and r.suppressed == 1, "trailing suppression covers the next line")
    r = run("BOOM // lint-allow(no-boom): x -- expires 2026-12-01, approved owner\n")
    expect(r.findings == [] and r.suppressed == 1, "same-line suppression, -- as the dash")
    stacked = ("// lint-allow(no-bang): x — expires 2026-12-01, approved owner\n"
               "// lint-allow(no-boom): y — expires 2026-12-01, approved owner\n"
               "BOOM!\n")
    r = run(stacked)
    expect(r.findings == [] and r.suppressed == 2, f"stacked suppressions: {[f.message for f in r.findings]}")
    r = run("// lint-allow(no-bang): x — expires 2026-10-17, approved owner\nlet a = b!\n")
    expect(len(rule_hits(r, "no-bang")) == 1 and any("expired" in f.message for f in rule_hits(r, ALLOW_FORMAT_ID)),
           "expired suppression hides nothing and is flagged")
    r = run("// lint-allow(no-bang): x — expires 2026-10-18, approved owner\nlet a = b!\n")
    expect(r.findings == [], "suppression is valid through its expiry day")
    r = run("// lint-allow(no-bang): x — expires 2028-01-01, approved owner\nlet a = b!\n")
    expect(any("more than a year" in f.message for f in r.findings), "expiry too far out is flagged")
    for bad, label in [
        ("// lint-allow(no-bang) legacy\nlet a = b!\n", "missing reason/expiry/approver"),
        ("// lint-allow(no-bang): legacy — expires 2026-12-01\nlet a = b!\n", "missing approver"),
        ("// lint-allow(no-bang): — expires 2026-12-01, approved owner\nlet a = b!\n", "missing reason"),
        ("// lint-allow no-bang: x — expires 2026-12-01, approved owner\nlet a = b!\n", "no parens"),
        ("// lint-allow(no-bang): x — expires 2026-02-30, approved owner\nlet a = b!\n", "impossible date"),
        ("// lint-allow(no-bang, no-boom): x — expires 2026-12-01, approved owner\nlet a = b!\n", "two ids"),
    ]:
        r = run(bad)
        expect(len(rule_hits(r, "no-bang")) == 1 and len(rule_hits(r, ALLOW_FORMAT_ID)) == 1, f"malformed: {label}")
    r = run("// lint-allow(no-such-rule): x — expires 2026-12-01, approved owner\nlet a = b\n")
    expect(any("unknown rule" in f.message for f in r.findings), "unknown rule id flagged")
    r = run("// lint-allow(lint-allow-format): x — expires 2026-12-01, approved owner\nlet a = b\n")
    expect(any("can't be suppressed" in f.message for f in r.findings), "allow-format can't be suppressed")
    r = run("// lint-allow(no-bang): x — expires 2026-12-01, approved owner\nlet a = b\n")
    expect(any("suppresses nothing" in f.message for f in r.findings), "unused suppression flagged")
    r = run("# lint-allow(no-bang): x — expires 2026-12-01, approved owner\n", path="scripts/x.py")
    expect(any("suppresses nothing" in f.message for f in r.findings), "# comments parsed outside Swift")
    r = run("// lint-allow(no-bang): x — expires 2026-12-01, approved owner\n", path="docs/x.md")
    expect(r.findings == [], "lint-allow-format ignores docs")
    r = run("// lint-allow(no-bang): x — expires 2026-10-01, approved owner\nlet a = b!\n", d=_dt.date(2026, 9, 1))
    expect(r.findings == [], "today is injectable")

    # Crashing rule -> error finding, never an exception; errors ignore the ratchet.
    crash = Rule(dict(bang.meta, id="crashy", ratchet=True), lambda p, t: 1 / 0)
    r = lint_text([crash], P, "x\n", day, {"crashy"})
    expect(len(r.findings) == 1 and r.findings[0].error, "crashing rule becomes an error finding")
    rep = evaluate({P: r}, {"crashy": crash}, {"crashy": {P: 5}})
    expect(len(rep.failing) == 1, "error findings are never grandfathered")

    # Ratchet math.
    by_id = {r_.id: r_ for r_ in rules}
    by_id[ALLOW_FORMAT_ID] = ALLOW_RULE
    two = run("BOOM\nBOOM\n")
    rep = evaluate({P: two}, by_id, {"no-boom": {P: 2}})
    expect(rep.failing == [] and rep.grandfathered == 2, "count at baseline passes")
    rep = evaluate({P: two}, by_id, {"no-boom": {P: 1}})
    expect(len(rep.failing) == 2 and rep.over_notes.get((P, "no-boom")) == "1 new; baseline 1",
           "over baseline prints every finding in the file with N new; baseline M")
    rep = evaluate({P: two}, by_id, {})
    expect(len(rep.failing) == 2 and rep.over_notes[(P, "no-boom")] == "2 new; baseline 0", "no baseline = 0")
    rep = evaluate({P: run("BOOM\n")}, by_id, {"no-boom": {P: 3}})
    expect(rep.failing == [] and rep.shrinkable == [("no-boom", P, 1, 3)], "dropped count is shrinkable")
    rep = evaluate({P: run("let a = b!\n")}, by_id, {"no-bang": {P: 9}})
    expect(len(rep.failing) == 1, "non-ratchet rules ignore the baseline")
    text = format_report(evaluate({P: two}, by_id, {"no-boom": {P: 1}}), by_id)
    expect("Sources/UI/A.swift:1: [no-boom] found BOOM\n    fix: f\n    why: w (see AGENTS.md)" in text, "output format")

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "Sources").mkdir()
        (root / "Sources/A.swift").write_text("BOOM\n")
        shrunk = shrink_baseline({"no-boom": {"Sources/A.swift": 4, "Sources/Gone.swift": 2}, "dead-rule": {"Sources/A.swift": 1}},
                                 {"no-boom": {"Sources/A.swift": 1}}, rules, root)
        expect(shrunk == {"no-boom": {"Sources/A.swift": 1}}, f"shrink lowers, drops gone files and dead rules: {shrunk}")
        shrunk = shrink_baseline({"no-boom": {"Sources/A.swift": 1}}, {"no-boom": {"Sources/A.swift": 3}}, rules, root)
        expect(shrunk == {"no-boom": {"Sources/A.swift": 1}}, "shrink never raises")
        bl = root / "bl.json"
        write_baseline({"no-boom": {"b": 2, "a": 0}}, bl)
        expect(json.loads(bl.read_text()) == {"no-boom": {"b": 2}}, "write_baseline drops zeros")

        # Range mode reads committed content, not the working tree.
        git = lambda *a: subprocess.run(["git", *a], cwd=root, capture_output=True, text=True, check=True).stdout.strip()
        try:
            git("init", "-q")
            git("config", "user.email", "t@example.invalid")
            git("config", "user.name", "Test")
            (root / "Sources/A.swift").write_text("let a = b\n")
            git("add", "Sources/A.swift")
            git("-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", "one")
            c1 = git("rev-parse", "HEAD")
            (root / "Sources/A.swift").write_text("let a = b!\n")
            (root / "Sources/B.swift").write_text("let c = d\n")
            git("add", "Sources")
            git("-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", "two")
            c2 = git("rev-parse", "HEAD")
            (root / "Sources/A.swift").write_text("let a = b\n")      # uncommitted fix
            (root / "Sources/Scratch.swift").write_text("let x = y!\n")  # untracked scratch
            files = range_files(c1, c2, root)
            expect(files == ["Sources/A.swift", "Sources/B.swift"], f"range lists committed files only: {files}")
            res = lint_paths(files, rules, day, root, git_reader(c2, root))
            expect(len(rule_hits(res["Sources/A.swift"], "no-bang")) == 1, "range reads text at the pushed commit")
            expect(not res["Sources/B.swift"].findings, "range: clean committed file passes")
            expect(git_reader(c1, root)(root, "Sources/B.swift") is None, "git_reader: missing path is None")
        except (OSError, subprocess.CalledProcessError) as error:
            print(f"warning: range self-test skipped ({error.__class__.__name__})")
        for spec, ok_ in [("a..b", True), ("a...b", False), ("ab", False), ("..b", False)]:
            try:
                parse_range(spec)
                got = True
            except ValueError:
                got = False
            expect(got == ok_, f"parse_range({spec!r})")

        # Hook: fake Claude Code JSON on stdin.
        (root / "Sources/A.swift").write_text("let a = b!\n")
        (root / "Sources/Clean.swift").write_text("let a = b\n")
        err = io.StringIO()
        code = hook(json.dumps({"tool_input": {"file_path": str(root / "Sources/A.swift")}}), root, rules, {}, day, err)
        expect(code == 2 and "Sources/A.swift:1: [no-bang]" in err.getvalue(), f"hook flags new finding ({code})")
        code = hook(json.dumps({"tool_input": {"file_path": "Sources/Clean.swift"}, "cwd": str(root)}), root, rules, {}, day, io.StringIO())
        expect(code == 0, "hook passes clean file (relative path + cwd)")
        code = hook(json.dumps({"tool_input": {"file_path": "/elsewhere/A.swift"}}), root, rules, {}, day, io.StringIO())
        expect(code == 0, "hook ignores files outside the repo")
        err = io.StringIO()
        code = hook("{not json", root, rules, {}, day, err)
        expect(code == 0 and "internal error" in err.getvalue(), "hook fails open on bad JSON")
        code = hook(json.dumps({"tool_name": "Bash", "tool_input": {"command": "ls"}}), root, rules, {}, day, io.StringIO())
        expect(code == 0, "hook ignores tools without file_path")

    # --write-baseline planning: scoped to named rules, refuses silent raises.
    base = {"no-boom": {"a": 2, "b": 1}, "other": {"x": 1}}
    new, raised = plan_baseline_write(base, {"no-boom": {"a": 2, "b": 1}, "other": {"x": 5, "y": 3}}, ["no-boom"], [], True)
    expect(new["other"] == {"x": 1}, "write-baseline leaves rules not named with --rule alone")
    expect(raised == [], "unchanged counts raise nothing")
    new, raised = plan_baseline_write(base, {"no-boom": {"a": 3, "c": 1}}, ["no-boom"], [], True)
    expect(raised == [("no-boom", "a", 2, 3), ("no-boom", "c", 0, 1)], f"raise and add on an existing rule are reported: {raised}")
    expect(new["no-boom"] == {"a": 3, "c": 1}, "full mode rebuilds the named rule")
    new, raised = plan_baseline_write(base, {"fresh": {"a": 4}}, ["fresh"], [], True)
    expect(raised == [] and new["fresh"] == {"a": 4}, "a brand-new rule may be grandfathered")
    new, raised = plan_baseline_write(base, {"no-boom": {"a": 1}}, ["no-boom"], ["a"], False)
    expect(raised == [] and new["no-boom"] == {"a": 1, "b": 1}, "partial mode replaces only scanned files")

    # Rule metadata validation.
    good_meta = dict(bang.meta, id="no-bang", proof=["abc1234:Sources/A.swift"])
    expect(validate_meta(good_meta, "no_bang") == [], f"valid meta passes: {validate_meta(good_meta, 'no_bang')}")
    expect(any("module must be named" in e for e in validate_meta(good_meta, "other")), "module name must follow id")
    expect(any("proof" in e for e in validate_meta(dict(good_meta, proof=[]), "no_bang")), "proof required")
    expect(any("owner_doc" in e for e in validate_meta(dict(good_meta, owner_doc="nope.md"), "no_bang")), "owner_doc must exist")
    expect(any("level" in e for e in validate_meta(dict(good_meta, level="test"), "no_bang")), "level must be lint")
    expect(any("reserved" in e for e in validate_meta(dict(good_meta, id=ALLOW_FORMAT_ID), "lint_allow_format")), "reserved id")
    return failures


def self_test() -> int:
    failures = runner_self_test()
    rules, load_errors = load_rules()
    failures.extend(f"load: {e}" for e in load_errors)
    all_ids = {r.id for r in rules}
    fixtures = proofs = 0
    warnings = []
    for rule in rules:
        fx_fail, count = check_fixtures(rule, all_ids)
        failures.extend(fx_fail)
        fixtures += count
        pf_fail, pf_warn, verified = check_proofs(rule)
        failures.extend(pf_fail)
        warnings.extend(pf_warn)
        proofs += verified
    if FIXTURES_DIR.is_dir():
        for folder in sorted(p for p in FIXTURES_DIR.iterdir() if p.is_dir()):
            if folder.name not in all_ids:
                failures.append(f"fixtures/{folder.name}/ has no matching rule module")
    for w in warnings:
        print(f"warning: {w}")
    if failures:
        print("lint.py self-test FAILED:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"lint.py self-test passed: runner cases, {len(rules)} rule(s), {fixtures} fixture(s), "
          f"{proofs} proof(s) verified, {len(warnings)} proof(s) skipped")
    return 0


# ---------------------------------------------------------------- list / explain

def list_rules(rules) -> int:
    rows = [ALLOW_RULE] + sorted(rules, key=lambda r: r.id)
    for r in rows:
        kind = "ratchet" if r.ratchet else "strict"
        tag = " (built-in)" if r.builtin else ""
        print(f"{r.id}{tag}  [{kind}]  {', '.join(r.paths)}")
        print(f"    {r.meta['summary']}")
    return 0


def explain(rules, rule_id: str, baseline: dict) -> int:
    by_id = {r.id: r for r in rules}
    by_id[ALLOW_FORMAT_ID] = ALLOW_RULE
    rule = by_id.get(rule_id)
    if rule is None:
        print(f"unknown rule {rule_id!r}; known: {', '.join(sorted(by_id))}")
        return 1
    m = rule.meta
    print(f"{rule.id}{' (built-in, in scripts/dev/lint.py)' if rule.builtin else ''}")
    print(f"  forbids:   {m['summary']}")
    print(f"  why:       {m['why']}")
    print(f"  fix:       {m['fix']}")
    print(f"  owner doc: {m['owner_doc']}")
    print(f"  paths:     {', '.join(rule.paths)}" + (f"  (exclude: {', '.join(rule.exclude)})" if rule.exclude else ""))
    print(f"  mode:      {'ratchet (per-file counts in .agents/lint-baseline.json)' if rule.ratchet else 'strict (any finding fails)'}")
    if rule.source:
        print(f"  source:    {rule.source}")
    print(f"  proof:     {', '.join(m.get('proof', [])) or '-'}")
    fixtures = _fixture_files(rule.id)
    if fixtures:
        print(f"  fixtures:  {', '.join(p.name for p in fixtures)}")
    if rule.ratchet:
        entries = baseline.get(rule.id, {})
        print(f"  baseline:  {sum(entries.values())} finding(s) in {len(entries)} file(s)")
    if not rule.builtin:
        print("  suppress:  // lint-allow(%s): <reason> — expires YYYY-MM-DD, approved <handle>" % rule.id)
    return 0


# ---------------------------------------------------------------- main

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Repo lint runner (scripts/dev/lint_rules).")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--all", action="store_true", help="lint the whole tree")
    mode.add_argument("--changed", action="store_true",
                      help="lint files changed vs merge-base with origin/main, plus uncommitted and untracked (Stop hook)")
    mode.add_argument("--range", metavar="A..B", help="lint files B changed since its merge-base with A, as committed at B (pre-push)")
    mode.add_argument("--files", nargs="+", metavar="PATH", help="lint these files")
    mode.add_argument("--hook", action="store_true", help="Claude Code hook: read hook JSON on stdin")
    mode.add_argument("--self-test", action="store_true")
    mode.add_argument("--explain", metavar="RULE_ID")
    mode.add_argument("--list", action="store_true")
    mode.add_argument("--shrink", action="store_true", help="lower baseline counts that dropped")
    parser.add_argument("--write-baseline", action="store_true",
                        help="record current counts for the --rule ids (with --files/--changed: only those files)")
    parser.add_argument("--rule", action="append", default=[], metavar="RULE_ID",
                        help="ratchet rule id --write-baseline may touch (repeatable; required)")
    parser.add_argument("--allow-raise", action="store_true",
                        help="let --write-baseline raise or add entries for a rule that already has a baseline")
    args = parser.parse_args(argv)

    if args.hook:
        try:
            stdin_text = sys.stdin.read()
        except Exception:
            stdin_text = ""
        return hook(stdin_text)
    if args.self_test:
        return self_test()

    rules, load_errors = load_rules()
    for e in load_errors:
        print(f"lint.py: rule error: {e}", file=sys.stderr)
    try:
        baseline = load_baseline()
    except (ValueError, json.JSONDecodeError) as error:
        print(f"lint.py: bad baseline: {error}", file=sys.stderr)
        return 1

    if args.list:
        return list_rules(rules)
    if args.explain:
        return explain(rules, args.explain, baseline)

    if args.write_baseline:
        ratchet_ids = {r.id for r in rules if r.ratchet}
        if args.range:
            print("lint.py: --write-baseline doesn't take --range", file=sys.stderr)
            return 1
        if not args.rule:
            print("lint.py: --write-baseline needs --rule <rule-id> (repeatable) so it only touches the rule "
                  "you're grandfathering", file=sys.stderr)
            return 1
        unknown = sorted(set(args.rule) - ratchet_ids)
        if unknown:
            print(f"lint.py: not a ratchet rule: {', '.join(unknown)}; ratchet rules: "
                  f"{', '.join(sorted(ratchet_ids)) or '-'}", file=sys.stderr)
            return 1
    elif args.rule or args.allow_raise:
        print("lint.py: --rule and --allow-raise only go with --write-baseline", file=sys.stderr)
        return 1

    day = today()
    reader = None
    if args.range:
        try:
            a, b = parse_range(args.range)
            paths = range_files(a, b)
        except (ValueError, RuntimeError, OSError) as error:
            print(f"lint.py: bad --range: {error}", file=sys.stderr)
            return 1
        reader = git_reader(b)
    elif args.files:
        paths = sorted({p for p in (rel_path(f) for f in args.files) if p})
    elif args.changed:
        try:
            paths = changed_files()
        except (RuntimeError, OSError) as error:
            print(f"lint.py: can't list changed files ({error}); falling back to --all", file=sys.stderr)
            paths = all_files()
    else:
        paths = all_files()
    full = not (args.files or args.changed or args.range)
    results = lint_paths(paths, rules, day, reader=reader)

    if args.shrink:
        if not full:
            print("lint.py: --shrink always scans the whole tree", file=sys.stderr)
            results = lint_paths(all_files(), rules, day)
        new = shrink_baseline(baseline, counts_by_rule(results, rules), rules)
        if new != baseline:
            write_baseline(new)
            print(f"lint.py: baseline shrunk ({sum(map(len, baseline.values()))} -> {sum(map(len, new.values()))} file entries)")
        else:
            print("lint.py: baseline already tight")
        return 1 if load_errors else 0

    if args.write_baseline:
        rule_ids = sorted(set(args.rule))
        merged, raised = plan_baseline_write(baseline, counts_by_rule(results, rules), rule_ids, list(results), full)
        if raised and not args.allow_raise:
            print(f"lint.py: refusing to write: {len(raised)} baseline entr(ies) would go up for a rule that "
                  "already has a baseline:", file=sys.stderr)
            for rid, p, old, new in raised:
                print(f"  {rid}  {p}: {old} -> {new}", file=sys.stderr)
            print("Fix the new findings instead. If raising is the reviewed intent, rerun with --allow-raise "
                  "and say why in the commit.", file=sys.stderr)
            return 1
        write_baseline(merged)
        print(f"lint.py: wrote {BASELINE_PATH.relative_to(REPO_ROOT)} for {', '.join(rule_ids)} "
              f"({sum(map(len, merged.values()))} file entries total)")
        if raised:
            print(f"lint.py: {len(raised)} entr(ies) raised with --allow-raise; that's a reviewed human edit, say why in the commit")
        return 1 if load_errors else 0

    by_id = {r.id: r for r in rules}
    by_id[ALLOW_FORMAT_ID] = ALLOW_RULE
    report = evaluate(results, by_id, baseline)
    text = format_report(report, by_id)
    if text:
        print(text)
    print(summary_line(report, len(rules) + 1))
    return 1 if (report.failing or load_errors) else 0


if __name__ == "__main__":
    sys.exit(main())

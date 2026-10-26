"""native-launch-without-isolation-guard: harnesses launch the real app only
after proving they run in an isolated macOS account.

A temporary HOME (or CFFIXED_USER_HOME) doesn't isolate a launched app:
CFPreferences still resolves `UserDefaults.standard` through the console user's
cfprefsd session, and TCC is per account. So a smoke or benchmark that launches
Transcripted from the owner's own login can read and write the owner's real
settings. `scripts/ops/native-smoke-isolation.py` (shell, Python) and
`NativeSmokeIsolation.isAllowed()` (TranscriptedQA) allow only a separate OS
account or a verified CI runner. Two fixes had to add it after the fact:
8d4685290 (four TranscriptedQA smokes, build.sh's launch smoke and
packaged-app-smoke.py) and 9ea264468 (bench-launch-latency.sh).

What counts as a launch of the app:
  shell   `open` / `/usr/bin/open` whose arguments resolve to `Transcripted.app`
          (or `-a Transcripted`), or a command whose program resolves to
          `.../Contents/MacOS/Transcripted`. Variables resolve by spelling
          through the file's own assignments, a few levels deep.
  Python  a subprocess-style call whose argv starts with a `*binary*` /
          `app_*` name, in a file that builds a `Contents/MacOS` path, or an
          `["open", "-<flag>", ...]` argv in a file that names `Transcripted.app`.
  Swift   `.executableURL =` (not a literal tool path) or `openApplication(` in
          a file that builds the `Contents/MacOS/Transcripted` path.

The guard is file-level: any non-comment mention of `native-smoke-isolation`
(shell, Python) or `NativeSmokeIsolation` (Swift) counts. A launch helper split
into a file that never names the app path (it takes the URL as a parameter) is
missed; its caller is the one that has to guard. `scripts/vm/` is excluded:
those launches run inside a throwaway guest VM. It's a heuristic, ratcheted per
file.
"""

from __future__ import annotations

import re

from lint_rules._base import swift_file

RULE = {
    "id": "native-launch-without-isolation-guard",
    "summary": "a harness, smoke or benchmark launches Transcripted without first checking native account isolation",
    "why": "a temp HOME doesn't isolate CFPreferences or TCC, so launches from the owner's login could touch his real "
           "settings; guards were added after the fact in 8d4685290 (QA smokes, build.sh, packaged-app-smoke.py) "
           "and 9ea264468 (bench-launch-latency.sh)",
    "fix": "check isolation before staging state and before each launch, and skip (exit 3 / incomplete) when it "
           "fails: shell, `/usr/bin/python3 \"$REPO_ROOT/scripts/ops/native-smoke-isolation.py\" || return $?` "
           "(see native_launch_ready in scripts/dev/bench-launch-latency.sh); Python, run "
           "scripts/ops/native-smoke-isolation.py first (see scripts/ops/packaged-app-smoke.py); Swift, "
           "`guard NativeSmokeIsolation.isAllowed() else { ... NativeSmokeIsolation.blockedMessage ... }` "
           "(Tools/TranscriptedQA/Sources/TranscriptedQA/Utilities/NativeSmokeIsolation.swift). Also mark the launch "
           "as a harness (TRANSCRIPTED_AUTOMATED_HARNESS=1, see Sources/Support/AutomatedLaunchEnvironment.swift)",
    "owner_doc": "Tools/TranscriptedQA/AGENTS.md",
    "level": "lint",
    "paths": [
        "scripts/**/*.sh",
        "scripts/**/*.py",
        "Tools/**/*.sh",
        "Tools/**/*.py",
        "Tools/*/Sources/**/*.swift",
    ],
    "exclude": [
        "scripts/vm/**",
        "**/test-*.py",
        "**/test_*.py",
        "scripts/ops/native-smoke-isolation.py",
    ],
    "ratchet": True,
    "proof": [
        # 9ea264468^: the launch benchmark ran 20 launches from the owner's login.
        "86f4ce9724f96241c9fa9789ed33617653d95f0e:scripts/dev/bench-launch-latency.sh",
        # 8d4685290^: QA smokes, build.sh's launch smoke and the packaged-app smoke had no account check.
        "2bc967ccc889cd0eb7adac6248bf31452769904c:scripts/entrypoints/build.sh",
        "2bc967ccc889cd0eb7adac6248bf31452769904c:scripts/ops/packaged-app-smoke.py",
        "2bc967ccc889cd0eb7adac6248bf31452769904c:Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/UISmoke.swift",
        "2bc967ccc889cd0eb7adac6248bf31452769904c:Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/SparkleUpdateSmoke.swift",
        "2bc967ccc889cd0eb7adac6248bf31452769904c:Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/ImportedAudioNativeSmoke.swift",
    ],
}

SHELL_MSG = ("launches Transcripted with no account-isolation check in this script: a temp HOME doesn't isolate "
             "UserDefaults or TCC. Before staging and before each launch run "
             "`/usr/bin/python3 \"$REPO_ROOT/scripts/ops/native-smoke-isolation.py\" || return $?` and treat exit 3 "
             "as a skip (see native_launch_ready in scripts/dev/bench-launch-latency.sh)")
PY_MSG = ("launches Transcripted with no account-isolation check in this file: a temp HOME doesn't isolate "
          "UserDefaults or TCC. Run scripts/ops/native-smoke-isolation.py first and skip when it exits non-zero "
          "(see scripts/ops/packaged-app-smoke.py)")
SWIFT_MSG = ("launches Transcripted with no `NativeSmokeIsolation.isAllowed()` check in this file: a temp HOME doesn't "
             "isolate UserDefaults or TCC. Add `guard NativeSmokeIsolation.isAllowed() else { ...report incomplete with "
             "NativeSmokeIsolation.blockedMessage... }` before staging state (Tools/TranscriptedQA/.../NativeSmokeIsolation.swift)")

_APP_BUNDLE = re.compile(r"(?<![\w-])Transcripted\.app\b|(?:^|\s)-a\s+[\"']?Transcripted[\"']?(?:\s|$)")
_APP_BINARY = re.compile(r"Contents/MacOS/Transcripted[\"']?\Z")


# ---------------------------------------------------------------- shell

_SH_ASSIGN = re.compile(r"^\s*(?:export\s+|local\s+|readonly\s+|declare\s+(?:-\w+\s+)*)?([A-Za-z_]\w*)=(\S.*|)$")
_SH_VAR = re.compile(r"\$\{([A-Za-z_]\w*)(?:[:#%/][^}]*)?\}|\$([A-Za-z_]\w*)")
_SH_CMD_START = re.compile(r"(?:^|[;&|(]|\bthen\b|\bdo\b|\belse\b|\{)\s*")
_SH_ENV_PREFIX = re.compile(r"(?:[A-Za-z_]\w*=(?:\"[^\"]*\"|'[^']*'|\S*)(?:\s+|\Z))*(?:(?:exec|nohup|env|command|caffeinate(?:\s+-\w+)*)\s+)*")
_SH_OPEN = re.compile(r"(?:/usr/bin/)?open\s+(.*)")
_SH_WORD = re.compile(r"(\"[^\"]*\"|'[^']*'|[^\s;&|)]+)")


def _shell_logical_lines(text: str):
    """(first line number, joined text) for each logical line, `\\` continuations
    joined, full-line comments dropped."""
    out, buf, start = [], [], 0
    for i, raw in enumerate(text.splitlines(), 1):
        if not buf and raw.lstrip().startswith("#"):
            continue
        if not buf:
            start = i
        stripped = raw.rstrip()
        if stripped.endswith("\\"):
            buf.append(stripped[:-1])
            continue
        buf.append(stripped)
        out.append((start, " ".join(part.strip() for part in buf)))
        buf = []
    if buf:
        out.append((start, " ".join(part.strip() for part in buf)))
    return out


def _shell_resolver(lines):
    values: dict = {}
    for _, line in lines:
        m = _SH_ASSIGN.match(line)
        if m:
            values.setdefault(m.group(1), []).append(m.group(2).strip())

    def resolve(text: str, depth: int = 0) -> list:
        if depth > 4:
            return [text]
        m = _SH_VAR.search(text)
        if not m:
            return [text]
        name = m.group(1) or m.group(2)
        out = []
        for value in values.get(name, [""])[:6]:
            for rest in resolve(text[m.end():], depth + 1):
                for v in resolve(value.strip("\"'"), depth + 1):
                    out.append(text[:m.start()] + v + rest)
        return out[:24]

    return resolve


def _check_shell(text: str):
    lines = _shell_logical_lines(text)
    if any("native-smoke-isolation" in line for _, line in lines):
        return []
    resolve = _shell_resolver(lines)
    hits = []
    for number, line in lines:
        whole = _SH_ENV_PREFIX.match(line)
        if _SH_ASSIGN.match(line) and whole and not line[whole.end():].strip():
            continue  # a plain assignment, not a command
        for start in _SH_CMD_START.finditer(line):
            pos = start.end()
            prefix = _SH_ENV_PREFIX.match(line, pos)
            pos = prefix.end() if prefix else pos
            rest = line[pos:]
            opened = _SH_OPEN.match(rest)
            if opened and any(_APP_BUNDLE.search(v) for w in _SH_WORD.findall(opened.group(1))
                              for v in resolve(w.strip("\"'"))):
                hits.append((number, SHELL_MSG))
                break
            word = _SH_WORD.match(rest)
            if word and any(_APP_BINARY.search(v.strip("\"'")) for v in resolve(word.group(1).strip("\"'"))):
                hits.append((number, SHELL_MSG))
                break
    return hits


# ---------------------------------------------------------------- Python

_PY_ARGV_BINARY = re.compile(
    r"\b(?:subprocess\s*\.\s*)?(?:Popen|run|call|check_call|check_output|run_group)\s*\(\s*\[\s*(?:str\(\s*)?"
    r"(?:\w*binary\w*|app_\w+|executable)\b"
)
# `["open", "-n", "-a", app]`; a flag must follow, so `["open", "today"]` (a CLI word) doesn't count.
_PY_ARGV_OPEN = re.compile(r"\[\s*[\"'](?:/usr/bin/)?open[\"']\s*,\s*[\"']-")


def _check_python(text: str):
    code = "\n".join("" if l.lstrip().startswith("#") else l for l in text.splitlines())
    if "native-smoke-isolation" in code or "native_smoke_isolation" in code:
        return []
    hits = []
    if "Contents/MacOS" in code:
        hits += [(code.count("\n", 0, m.start()) + 1, PY_MSG) for m in _PY_ARGV_BINARY.finditer(code)]
    if _APP_BUNDLE.search(code):
        hits += [(code.count("\n", 0, m.start()) + 1, PY_MSG) for m in _PY_ARGV_OPEN.finditer(code)]
    return sorted(set(hits))


# ---------------------------------------------------------------- Swift

# An executableURL set to a literal tool path (`URL(fileURLWithPath: "/usr/bin/codesign")`) isn't the app;
# the string is blanked in sanitized code, so the literal shows up as spaces before `)`.
_SWIFT_LAUNCH = re.compile(r"\.\s*executableURL\s*=(?!\s*URL\s*\(\s*fileURLWithPath\s*:\s*\))|\bopenApplication\s*\(")


def _check_swift(text: str):
    if "Contents/MacOS/Transcripted\"" not in text and "Contents/MacOS/Transcripted\\\"" not in text:
        return []
    sf = swift_file(text)
    if "NativeSmokeIsolation" in sf.code:
        return []
    return [(line, SWIFT_MSG) for line, _ in sf.find(_SWIFT_LAUNCH)]


def check(path: str, text: str):
    if path.endswith(".sh"):
        return _check_shell(text)
    if path.endswith(".py"):
        return _check_python(text)
    if path.endswith(".swift"):
        return _check_swift(text)
    return []

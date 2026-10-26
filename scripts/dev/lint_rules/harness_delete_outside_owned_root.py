"""harness-delete-outside-owned-root: a harness deletes a path built from input
without first proving it sits under the root the harness owns.

What counts as a delete: Swift `removeItem(at:)` / `removeItem(atPath:)`, bash
`rm` with both recursive and force flags, Python `shutil.rmtree`, `os.remove`,
`os.unlink` and `.unlink()`.

The target expression is classified by following names through assignments,
innermost scope first (bash also reads the in-repo files it `source`s):

  const   literals, or the script's own location (`#filePath`, `__file__`,
          `dirname "$0"`, `BASH_SOURCE`, `git rev-parse --show-toplevel`, `pwd`),
          hashes and timestamps
  temp    made from `temporaryDirectory`, `NSTemporaryDirectory`, `mktemp`,
          `tempfile`, pytest `tmp_path`
  param   the enclosing function's own parameter (`$1` inside a bash function):
          deleting it bare is the caller's call, so it isn't flagged
  root    a bare outside input: env var (`${X:-default}` included), CLI args
          (`@Option`, `parse_args`, `$1` at script level), `$HOME`, command
          output, a loop variable over input, a name never assigned in the file
  rooted  an input root plus only literal path parts (`$OUT/report.json`), or a
          bash root that a function resolved and checked before reassigning it
  mixed   input used as a path part under something else: `<root>/<id>`,
          `$OUT/$LABEL`, `setDir.appendingPathComponent(id)`, a param id

`root` and `mixed` targets are flagged (for a single-file Python unlink, only
`mixed`), unless the enclosing function (Swift braces, Python indentation, bash
function body; top-level code: the 15 lines above) also runs a containment
check: `isInside`, `isContained`, `hasPrefix(... root ...)`,
`resolvingSymlinksInPath`, a symlink type check, `realpath`, `pwd -P`,
`readlink -f`, `commonpath`, `is_relative_to` / `relative_to`, a
`case "$x" in "$root"/*)` arm, `[[ "$x" == "$root"/* ]]`,
`[[ "$(dirname "$x")" == ... ]]`, or the `.transcripted-vm` marker folder.

It's a heuristic, not a data-flow analysis: names resolve by spelling, values
aren't tracked across calls, and an id from a hard-coded list still counts as
an id. Ratcheted per file; a delete that really is fine takes a `lint-allow`
with the reason.
"""

from __future__ import annotations

import re

from lint_rules._base import REPO_ROOT, swift_file

RULE = {
    "id": "harness-delete-outside-owned-root",
    "summary": "a harness, lab, QA or script delete removes a path built from input (ids, args, env, reused output "
               "dirs) without first proving it resolves under the root the harness owns",
    "why": "ids with `..`, symlinked folders and env or CLI overrides let harness cleanup delete outside its root: "
           "4e6942113, 5b84fe3d2, 291a0eec4, ef308af42",
    "fix": "check containment in the same function before deleting: Swift, LabSharedSpeakerDB.reset(_:workRoot:) or "
           "removeFinishedResults(_:setDirectory:) in Tools/SpeakerEvalHarness, FirstRunPathCheck.isInside(_:root:) in "
           "Tools/TranscriptedQA, or resolvingSymlinksInPath() + hasPrefix(root + \"/\") and refuse .typeSymbolicLink; "
           "bash, resolve with `pwd -P` and guard with `case \"$target\" in \"$root\"/*)`; Python, "
           "Path.resolve().is_relative_to(root); or build the target from temporaryDirectory/mktemp/tempfile",
    "owner_doc": "Tools/TranscriptedQA/AGENTS.md",
    "level": "lint",
    "paths": [
        "Tools/TranscriptedQA/Sources/**/*.swift",
        "Tools/SpeakerEvalHarness/Sources/**/*.swift",
        "scripts/**/*.sh",
        "scripts/**/*.py",
    ],
    "exclude": [],
    "ratchet": True,
    "proof": [
        "b01cb2e8ab84840fe2d841cc87913d42abf802a8:Tools/SpeakerEvalHarness/Sources/speaker-eval-harness/MeetingLab.swift",
        "540ed48310539d53e961ffefa970905c607f8b5b:Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/SparkleUpdateSmoke.swift",
        "fc4a91ad2e38b8aa6fdd94c10638deee8a637a03:scripts/vm/transcripted-vm.sh",
    ],
}

FALLBACK_LINES = 15
MAX_DEPTH = 8

CONST, ROOTED, PARAM, ROOT, MIXED, TEMP = "const", "rooted", "param", "root", "mixed", "temp"
FLAGGED = (ROOT, MIXED)
_SEVERITY = {CONST: 0, ROOTED: 1, PARAM: 2, ROOT: 3, MIXED: 4, TEMP: 5}

# A term of a path expression, in source order:
#   ("lit", has_path_part)   a literal piece
#   ("name", name)           a variable to resolve
#   ("cls", class)           something already classified (env, $1, mktemp ...)


def _worst(classes) -> str:
    classes = list(classes)
    return max(classes, key=_SEVERITY.__getitem__) if classes else CONST


def _combine(terms, classify_name, depth, seen) -> str:
    resolved = []
    named = set()
    for term in terms:
        kind, value = term[0], term[1]
        if kind == "name":
            key = term[2] if len(term) > 2 else value
            if key in named:
                continue  # `cmd[cmd.index("--out")]`: one input, read twice
            named.add(key)
        if kind == "name":
            resolved.append(("cls", classify_name(value, depth + 1, seen)))
        else:
            resolved.append((kind, value))
    classes = [v for k, v in resolved if k == "cls"]
    if TEMP in classes:
        return TEMP
    if MIXED in classes:
        return MIXED
    inputs = [i for i, (k, v) in enumerate(resolved) if k == "cls" and v in (ROOT, ROOTED, PARAM)]
    if not inputs:
        return CONST
    if len(inputs) > 1:
        return MIXED
    first = inputs[0]

    def path_part(item):
        k, v = item
        return (k == "lit" and v) or (k == "cls" and v == CONST)

    if any(path_part(t) for t in resolved[:first]):
        return MIXED  # an input used as a path part under something else
    if any(path_part(t) for t in resolved[first + 1:]):
        return ROOTED
    return resolved[first][1]


class _Resolver:
    """Resolve names to classes through assignments; one subclass per language."""

    def __init__(self):
        self.memo: dict = {}
        self._assign_cache: dict = {}

    def assignments(self, name: str) -> list:  # pragma: no cover - overridden
        return []

    def terms(self, expr, depth=0, seen=frozenset()) -> list:  # pragma: no cover - overridden
        return []

    def unassigned(self, name: str) -> str:
        return ROOT

    def classify_expr(self, expr, depth: int = 0, seen=frozenset()) -> str:
        return _combine(self.terms(expr, depth, seen), self.classify_name, depth, seen)

    def classify_name(self, name: str, depth: int, seen) -> str:
        if name in self.memo:
            return self.memo[name]
        if name in seen:
            return CONST  # a cycle adds nothing; the other assignments decide
        if depth > MAX_DEPTH:
            return ROOT
        rhs_list = self.cached_assignments(name)
        if not rhs_list:
            result = self.unassigned(name)
        else:
            classes = [self.classify_expr(r, depth, seen | {name}) for r in rhs_list]
            result = TEMP if TEMP in classes else _worst(classes)
        self.memo[name] = result
        return result

    def cached_assignments(self, name: str) -> list:
        if name not in self._assign_cache:
            self._assign_cache[name] = self.assignments(name)
        return self._assign_cache[name]


_HOME_RE = re.compile(r"homeDirectory|NSHomeDirectory|Path\.home\(|expanduser|(?<![\w/])~/")
_ENV_ARGS_RE = re.compile(r"\benvironment\b|CommandLine|\bargv\b|os\.environ|\bgetenv\b|\bparse_args\b|"
                          r"\bargValue\b|\binput\(")

def _mask_receivers(code: str, starts) -> str:
    """Blank the dotted receiver chain in front of each offset (`parser.` in
    `parser.parse_args()`), so it isn't read as a path part before the input."""
    out = list(code)
    for start, end in starts:
        i = start
        while i > 0 and (code[i - 1].isalnum() or code[i - 1] in "_."):
            i -= 1
            out[i] = " "
        for k in range(start, end):
            out[k] = " "
        # ... and the call/subscript right after it (`parse_args(argv)`,
        # `environment["X"]`): that's the input itself, not more path.
        j = end
        while j < len(code) and code[j].isspace():
            j += 1
        if j < len(code) and code[j] in "([":
            close = _balanced_end(code, j + 1)
            for k in range(j, min(close + 1, len(code))):
                if code[k] != "\n":
                    out[k] = " "
    return "".join(out)


# ---------------------------------------------------------------- Swift

SWIFT_DELETE_RE = re.compile(r"\.removeItem\(\s*(?:at|atPath)\s*:")
SWIFT_CONTAIN_RE = re.compile(
    r"isInside|isContained|hasPrefix\([^\n]*[Rr]oot|resolvingSymlinksInPath|typeSymbolicLink|"
    r"destinationOfSymbolicLink"
)
SWIFT_TEMP_RE = re.compile(r"temporaryDirectory|NSTemporaryDirectory|\.itemReplacementDirectory")
SWIFT_ANCHOR_RE = re.compile(r"#filePath|#file\b")
SWIFT_NEUTRAL = frozenset("""
try let var self Self true false nil as is in isDirectory await some any if else guard return case
fm fileManager default
""".split())
_SWIFT_TOKEN_RE = re.compile(r"(?<![\w.#$])([A-Za-z_]\w*)")


def _balanced_end(code: str, start: int) -> int:
    """Offset of the `)` closing the `(` just before `start`."""
    depth = 1
    i = start
    n = len(code)
    while i < n:
        c = code[i]
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return n


def _swift_rhs_end(code: str, start: int) -> int:
    """End of the statement starting at `start`: a newline at paren depth 0 not
    followed by a `.` continuation line."""
    depth = 0
    i = start
    n = len(code)
    while i < n:
        c = code[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return i
            depth -= 1
        elif c == "\n" and depth == 0:
            nxt = code[i + 1:i + 200].lstrip(" \t")
            if not nxt.startswith((".", "?", "+")):
                return i
        elif c == ";" and depth == 0:
            return i
        i += 1
    return n


class _SwiftResolver(_Resolver):
    def __init__(self, text: str, code: str):
        super().__init__()
        self.text = text
        self.code = code

    def unassigned(self, name: str) -> str:
        return PARAM  # a parameter or closure argument: the caller decides

    def assignments(self, name: str) -> list:
        code = self.code
        spans = []
        n = re.escape(name)
        pat = re.compile(r"\b(?:let|var)\s+" + n + r"\b\s*(?::[^=\n{]*)?=(?!=)|"
                         r"(?<![\w.])(?:self\.)?" + n + r"\s*=(?!=)")
        for m in pat.finditer(code):
            spans.append((m.end(), _swift_rhs_end(code, m.end())))
            # `@Option var output = "/tmp/x"`: the default is the least of it.
            before = code[max(0, m.start() - 300):m.start()]
            if re.search(r"@(?:Option|Argument)\b[^\n]*\n?[^\n]*\Z", before):
                spans.append("cli")
        for m in re.finditer(r"\bfor\s+(?:case\s+)?(?:let\s+)?\(?[\w\s,]*?\b" + n + r"\b[\w\s,)]*?\bin\b", code):
            end = code.find("{", m.end())
            spans.append((m.end(), end if end > 0 else _swift_rhs_end(code, m.end())))
        return spans

    def terms(self, span, depth=0, seen=frozenset()) -> list:
        if span == "cli":
            return [("cls", ROOT)]
        a, b = span
        code, text = self.code[a:b], self.text[a:b]
        if SWIFT_TEMP_RE.search(code):
            return [("cls", TEMP)]
        if SWIFT_ANCHOR_RE.search(text):
            return [("cls", CONST)]
        events = []
        sources = list(_HOME_RE.finditer(code)) + list(_ENV_ARGS_RE.finditer(code))
        if sources:  # one input, however many tokens name it (`parse_args(argv)`)
            events.append((min(m.start() for m in sources), ("cls", ROOT)))
        code = _mask_receivers(code, [(m.start(), m.end()) for m in sources])
        # String literal content: blank in the sanitized code, not blank in text.
        i = 0
        while i < len(code):
            if code[i] == " " and not text[i].isspace():
                j = i
                while j < len(code) and code[j] == " " and text[j] != "\n":
                    j += 1
                events.append((i, ("lit", bool(text[i:j].strip().strip('"').strip()))))
                i = j
            else:
                i += 1
        for m in _SWIFT_TOKEN_RE.finditer(code):
            name = m.group(1)
            rest = code[m.end():]
            if name in SWIFT_NEUTRAL or name[0].isupper():
                continue
            if re.match(r"\s*:(?!:)", rest):  # argument label
                continue
            if re.match(r"\s*\(", rest):  # a call: its arguments carry the input
                continue
            chain = re.match(r"(?:\??\.\w+(?!\s*\())*", rest).group(0)
            events.append((m.start(), ("name", name, name + chain)))
        events.sort(key=lambda e: e[0])
        return [t for _, t in events]


def _check_swift(text: str) -> list:
    sf = swift_file(text)
    code = sf.code
    resolver = _SwiftResolver(text, code)
    out = []
    for line, m in sf.find(SWIFT_DELETE_RE):
        fn = sf.function_at(m.start())
        if fn is not None:
            scope = code[sf.offset_of_line(fn.decl_line):fn.close_offset + 1]
        else:
            first = max(1, line - FALLBACK_LINES)
            scope = "\n".join(sf.code_lines[first - 1:line])
        if SWIFT_CONTAIN_RE.search(scope):
            continue
        end = _balanced_end(code, m.end())
        kind = resolver.classify_expr((m.end(), end))
        if kind not in FLAGGED:
            continue
        shown = re.sub(r"\s+", " ", text[m.end():end]).strip()
        if len(shown) > 60:
            shown = shown[:57] + "..."
        what = "an input path" if kind == ROOT else "a path with an input-named part"
        out.append((line, f"removeItem({shown}) deletes {what} with no containment check in this function; "
                          f"a `..` id, a symlinked folder or a bad --output deletes outside the owned root"))
    return out


# ---------------------------------------------------------------- Python

PY_DELETE_RE = re.compile(r"\bshutil\.rmtree\(|(?<![\w.])rmtree\(|\bos\.remove\(|\bos\.unlink\(|\.unlink\(")
PY_CONTAIN_RE = re.compile(r"realpath|commonpath|is_relative_to|\.relative_to\(|isInside|is_inside|is_contained")
PY_TEMP_RE = re.compile(r"\btempfile\b|mkdtemp|mkstemp|TemporaryDirectory|NamedTemporaryFile|"
                        r"\btmp_path(?:_factory)?\b|\btmpdir\b|gettempdir")
PY_NEUTRAL = frozenset("""
os sys shutil pathlib Path PurePath str bytes int len list dict set tuple sorted reversed True False None
not and or in is if else for lambda await self cls glob subprocess re json repr min max
""".split())
_PY_STR_RE = re.compile(r"(?P<prefix>(?<!\w)[rRbBuUfF]{0,2})(?P<q>'''|\"\"\"|'|\")(?P<body>.*?)(?<!\\)(?P=q)", re.S)
_PY_NAME_RE = re.compile(r"(?<![\w.])([A-Za-z_]\w*)")
_PY_PATH_CALLS = frozenset({"Path", "PurePath", "PosixPath", "join", "joinpath", "with_suffix", "with_name",
                            "with_stem", "str", "fspath", "resolve", "absolute", "expanduser"})


def _py_code_lines(text: str) -> list:
    """Lines with `#` comments removed."""
    out = []
    for raw in text.split("\n"):
        if raw.lstrip().startswith("#"):
            out.append("")
            continue
        masked = _PY_STR_RE.sub(lambda m: "x" * len(m.group(0)), raw)
        cut = masked.find("#")
        out.append(raw[:cut] if cut >= 0 else raw)
    return out


_PY_PARAM = "\0param"


def _py_index(lines: list) -> dict:
    """name -> right-hand sides, from plain/annotated/augmented assignment,
    `with ... as`, `for ... in` and imports (imports map to a constant)."""
    index: dict = {}
    assign = re.compile(r"^\s*([A-Za-z_][\w, ]*?)\s*(?::\s*[^=\n]+?)?\s*\+?=(?!=)\s*(.*)$")
    for line in lines:
        m = assign.match(line)
        if m:
            for target in m.group(1).split(","):
                index.setdefault(target.strip(), []).append(m.group(2))
        for m in re.finditer(r"\bwith\b(.*?)\bas\s+([A-Za-z_]\w*)", line):
            index.setdefault(m.group(2), []).append(m.group(1))
        m = re.match(r"\s*(?:async\s+)?for\s+([\w, ()]+?)\s+in\s+(.*?):?\s*$", line)
        if m:
            for target in re.split(r"[,()\s]+", m.group(1)):
                if target:
                    index.setdefault(target, []).append(m.group(2))
        m = re.match(r"\s*(?:from\s+\S+\s+)?import\s+(.*)$", line)
        if m:
            for part in m.group(1).replace("(", " ").replace(")", " ").split(","):
                words = part.split()
                if words:
                    index[words[-1]] = ['""']
    return index


def _py_params(scope: list) -> set:
    """Parameter names of the `def` that opens `scope` (empty for module code)."""
    if not scope or not re.match(r"\s*(?:async\s+)?def\s", scope[0]):
        return set()
    head = []
    for line in scope:
        head.append(line)
        if re.search(r"\)\s*(?:->[^:]*)?:\s*$", line):
            break
    sig = " ".join(head)
    sig = sig[sig.find("(") + 1:]
    params = set()
    depth = 0
    cur = ""
    for c in sig:
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                break
            depth -= 1
        if c == "," and depth == 0:
            params.add(cur)
            cur = ""
        else:
            cur += c
    params.add(cur)
    names = set()
    for p in params:
        m = re.match(r"\s*\**([A-Za-z_]\w*)", p)
        if m and m.group(1) not in ("self", "cls"):
            names.add(m.group(1))
    return names


class _PyResolver(_Resolver):
    """Names resolve in the enclosing function first (its parameters count as
    input), then at module level."""

    def __init__(self, module_index: dict, scope: list = ()):
        super().__init__()
        self.module = module_index
        self.local = _py_index(list(scope)[1:]) if scope and _py_params(scope) is not None else {}
        self.params = _py_params(list(scope))

    def assignments(self, name: str) -> list:
        if name.startswith("__") and name.endswith("__"):
            return ['""']
        found = list(self.local.get(name, []))
        if name in self.params:
            return found + [_PY_PARAM]
        return found or list(self.module.get(name, []))

    def unassigned(self, name: str) -> str:
        return TEMP if PY_TEMP_RE.fullmatch(name) else ROOT

    def terms(self, expr: str, depth=0, seen=frozenset()) -> list:
        if expr == _PY_PARAM:
            return [("cls", PARAM)]
        if PY_TEMP_RE.search(expr):
            return [("cls", TEMP)]
        if "__file__" in expr:
            return [("cls", CONST)]
        events = []
        sources = list(_HOME_RE.finditer(expr)) + list(_ENV_ARGS_RE.finditer(expr))
        if sources:  # one input, however many tokens name it (`parse_args(argv)`)
            events.append((min(m.start() for m in sources), ("cls", ROOT)))
        masked = list(_mask_receivers(expr, [(m.start(), m.end()) for m in sources]))
        self._fold_calls(expr, masked, events, depth, seen)
        for m in _PY_STR_RE.finditer(expr):
            if masked[m.start()] == " " and expr[m.start()] != " ":
                continue  # inside a folded call
            body = m.group("body")
            if "f" in m.group("prefix").lower():
                pos = m.start("body")
                last = 0
                for fm in re.finditer(r"\{([^{}]*)\}", body):
                    if body[last:fm.start()].strip():
                        events.append((pos + last, ("lit", True)))
                    for nm in _PY_NAME_RE.finditer(fm.group(1)):
                        if nm.group(1) not in PY_NEUTRAL:
                            events.append((pos + fm.start(1) + nm.start(), ("name", nm.group(1))))
                            break
                    last = fm.end()
                if body[last:].strip():
                    events.append((pos + last, ("lit", True)))
            else:
                events.append((m.start(), ("lit", bool(body.strip()))))
            for k in range(m.start(), m.end()):
                masked[k] = " "
        code = "".join(masked)
        bound = set()
        for m in re.finditer(r"\bfor\s+([\w\s,()]+?)\s+in\b", code):
            bound.update(re.findall(r"[A-Za-z_]\w*", m.group(1)))  # comprehension variables
        for m in _PY_NAME_RE.finditer(code):
            name = m.group(1)
            rest = code[m.end():]
            if name in PY_NEUTRAL or name in bound or re.match(r"\s*=(?!=)", rest) or re.match(r"\s*\(", rest):
                continue
            chain = re.match(r"(?:\s*\.\s*\w+\b(?!\s*\())*", rest).group(0)
            events.append((m.start(), ("name", name, name + re.sub(r"\s", "", chain))))
        events.sort(key=lambda e: e[0])
        return [t for _, t in events]

    def _fold_calls(self, expr: str, masked: list, events: list, depth, seen) -> None:
        """Calls that don't build a path: a method's arguments (`.replace("/", "-")`)
        are not path parts, so they're dropped; a plain function's result
        (`write_command(root, ...)`) is one opaque value, input if any argument is."""
        shape = list(expr)
        for m in _PY_STR_RE.finditer(expr):
            for k in range(m.start(), m.end()):
                shape[k] = "x"
        shape = "".join(shape)
        i = 0
        while i < len(shape):
            if shape[i] != "(" or masked[i] == " ":
                i += 1
                continue
            j = i
            while j > 0 and (shape[j - 1].isalnum() or shape[j - 1] == "_"):
                j -= 1
            callee = shape[j:i]
            close = _balanced_end(shape, i + 1)
            method = j > 0 and shape[j - 1] == "."
            if not callee or callee in _PY_PATH_CALLS or (not method and callee in PY_NEUTRAL):
                i += 1
                continue
            if method:
                for k in range(j - 1, min(close + 1, len(masked))):
                    masked[k] = " "
            else:
                inner = self.classify_expr(expr[i + 1:close], depth + 1, seen)
                events.append((j, ("cls", inner if inner in (TEMP, CONST) else ROOT)))
                for k in range(j, min(close + 1, len(masked))):
                    masked[k] = " "
            i = close + 1


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" \t"))


def _py_scope(lines: list, idx: int) -> list:
    """Lines of the innermost `def` around line `idx` (0-based), or the
    fallback window for module-level code."""
    my_indent = _indent(lines[idx])
    j = idx
    while j > 0:
        j -= 1
        ln = lines[j]
        if not ln.strip():
            continue
        if ln.lstrip().startswith(")"):
            # The end of a wrapped signature or call: jump to the line that opened it.
            depth = 0
            for k in range(j, -1, -1):
                depth += lines[k].count(")") - lines[k].count("(")
                if depth <= 0:
                    j = k
                    break
            ln = lines[j]
        ind = _indent(ln)
        if ind < my_indent and re.match(r"\s*(?:async\s+)?def\s", ln):
            end = len(lines)
            for k in range(idx + 1, len(lines)):
                if lines[k].strip() and _indent(lines[k]) <= ind:
                    end = k
                    break
            return lines[j:end]
        if ind < my_indent:
            my_indent = ind
        if ind == 0:
            break
    return lines[max(0, idx - FALLBACK_LINES):idx + 1]


def _py_target(line: str, m) -> str:
    if m.group(0) == ".unlink(":
        i = m.start()
        depth = 0
        while i > 0:
            c = line[i - 1]
            if c == ")":
                depth += 1
            elif c == "(":
                if depth == 0:
                    break
                depth -= 1
            elif depth == 0 and not (c.isalnum() or c in "_./ \"'"):
                break
            i -= 1
        return line[i:m.start()]
    return line[m.end():_balanced_end(line, m.end())]


def _check_python(text: str) -> list:
    if not PY_DELETE_RE.search(text):
        return []
    lines = _py_code_lines(text)
    module_index = _py_index([ln for ln in lines if ln[:1].strip() or re.match(r"\s*(?:from|import)\s", ln)])
    out = []
    for idx, line in enumerate(lines):
        for m in PY_DELETE_RE.finditer(line):
            scope = _py_scope(lines, idx)
            if PY_CONTAIN_RE.search("\n".join(scope)):
                break
            target = _py_target(line, m)
            kind = _PyResolver(module_index, scope).classify_expr(target)
            recursive = "rmtree" in m.group(0)
            # A single-file unlink of a bare input (a helper's own parameter) is
            # the caller's call; only an input-named part is flagged there.
            if kind not in FLAGGED or (kind == ROOT and not recursive):
                continue
            call = m.group(0).rstrip("(").lstrip(".")
            what = "an input path" if kind == ROOT else "a path with an input-named part"
            out.append((idx + 1, f"{call}({target.strip()[:50]}) deletes {what} with no containment check in this "
                                 f"function; `..`, a symlink or a bad --out deletes outside the owned root"))
            break
    return out


# ---------------------------------------------------------------- bash

SH_DELETE_RE = re.compile(r"(?<![\w$\\-])rm\s+(?P<flags>(?:-[A-Za-z]+\s+)+)(?:--\s+)?(?P<args>[^;&|\n]*)")
SH_CONTAIN_RE = re.compile(
    r"realpath|pwd\s+-P|readlink\s+-f|\.transcripted-vm|"
    r"\bcase\s+\"?\$\{?\w+[^\"\n]*\"?\s+in\b[^\n]*\"\$\{?\w+\}?\"/[^\s)]*\*|"
    r"^\s*\"\$\{?\w+\}?\"/[^\s)]*\*\)|"
    r"\[\[\s*\"?\$\{?\w+\}?\"?\s*==\s*\"\$\{?\w+\}?\"/\*|"
    r"\[\[\s*\"?\$\(dirname\b[^\n]*==",
    re.M,
)
SH_ANCHOR_RE = re.compile(r"dirname\s+\"?\$\{?0|BASH_SOURCE|rev-parse\s+--show-toplevel|\bpwd\b")
SH_INPUT_VARS = frozenset({"HOME", "OPTARG", "REPLY", "PWD", "OLDPWD", "TMPDIR", "USER"})
_SH_FUNC_RE = re.compile(r"^(?P<ind>[ \t]*)(?:function\s+)?[A-Za-z_][\w:.-]*\s*\(\)\s*\{")
_SH_SUBST_RE = re.compile(r"\$\(([^()]*(?:\([^()]*(?:\([^()]*\)[^()]*)*\)[^()]*)*)\)")
_SH_BRACED_RE = re.compile(r"\$\{([A-Za-z_]\w*)(?:\[[^\]]*\])?(?:(:?[-=+?])((?:[^{}]|\{[^{}]*\})*))?\}")
_SH_SIMPLE_RE = re.compile(r"\$([A-Za-z_]\w*)")
_SH_POSITIONAL_RE = re.compile(r"\$(?:[0-9@*#]|\{[0-9@*#][^}]*\})")
_SH_SOURCE_RE = re.compile(r"^\s*(?:source|\.)\s+\"?([^\"\s]+\.sh)\"?", re.M)
_SH_ANCHOR_STRIP_RE = re.compile(r"dirname\s+\"?\$\{?0\}?\"?|\$\{?BASH_SOURCE[^}\s\"]*\}?")


def _sh_code_lines(text: str) -> list:
    return ["" if raw.lstrip().startswith("#") else raw for raw in text.split("\n")]


def _sh_recursive_force(flags: str) -> bool:
    letters = "".join(f.lstrip("-") for f in flags.split())
    return ("r" in letters or "R" in letters) and "f" in letters


def _sh_function_spans(lines: list) -> list:
    """(start, end) 0-based line spans of every bash function, nested ones too."""
    spans = []
    for j, line in enumerate(lines):
        m = _SH_FUNC_RE.match(line)
        if not m:
            continue
        if re.search(r"\}\s*;?\s*$", line[m.end():]):  # one-line function
            spans.append((j, j))
            continue
        end = len(lines) - 1
        for k in range(j + 1, len(lines)):
            if re.match(re.escape(m.group("ind")) + r"\}", lines[k]):
                end = k
                break
        spans.append((j, end))
    return spans


def _sh_enclosing(spans: list, idx: int) -> list:
    """Function spans around line `idx`, innermost first."""
    return sorted((s for s in spans if s[0] <= idx <= s[1]), key=lambda s: s[1] - s[0])


def _sourced_text(path: str, text: str) -> str:
    """Text of in-repo files this script sources (one level), for assignments."""
    if not path:
        return ""
    here = (REPO_ROOT / path).parent
    out = []
    for m in _SH_SOURCE_RE.finditer(text):
        tail = re.sub(r"^.*\$\{?\w+\}?/", "", m.group(1))
        if "$" in tail:
            continue
        for base in (here, REPO_ROOT):
            candidate = base / tail
            try:
                if candidate.is_file() and REPO_ROOT in candidate.resolve().parents:
                    out.append(candidate.read_text(encoding="utf-8", errors="replace"))
                    break
            except OSError:
                continue
    return "\n".join(out)


def _sh_split_args(args: str) -> list:
    """Shell words that reference a variable, quoted parts and `$(...)` kept whole."""
    words, cur, quote, depth = [], "", "", 0
    for c in args:
        if quote:
            cur += c
            if c == quote:
                quote = ""
            continue
        if c in "\"'":
            quote = c
            cur += c
        elif c == "(":
            depth += 1
            cur += c
        elif c == ")":
            depth = max(0, depth - 1)
            cur += c
        elif c.isspace() and depth == 0:
            if cur:
                words.append(cur)
            cur = ""
        else:
            cur += c
    if cur:
        words.append(cur)
    return [w for w in words if "$" in w]


def _sh_function_lines(lines: list) -> set:
    """0-based line numbers inside a bash function body."""
    inside = set()
    for a, b in _sh_function_spans(lines):
        inside.update(range(a, b + 1))
    return inside


def _sh_mark_params(lines: list) -> list:
    """Inside functions, `$1`/`${2}`/`$@` are the caller's arguments: rewrite
    them to `$__param__` so they classify as parameters, not CLI input."""
    inside = _sh_function_lines(lines)
    return [re.sub(r"\$(?:[1-9@*]|\{[1-9@*]\})", "$__param__", ln) if i in inside else ln
            for i, ln in enumerate(lines)]


def _sh_find(text: str, name: str, positions=None) -> list:
    n = re.escape(name)
    rhs = []
    for m in re.finditer(r"(?:^|[\s;(&|])(?:local\s+|export\s+|readonly\s+|declare\s+(?:-\w+\s+)*)?"
                         r"(?:\w+=\S*\s+)*" + n + r"(?:\[[^\]]*\])?\+?=(.*)$", text, re.M):
        # `local a="$1" b=...`: keep only this name's value.
        rhs.append(re.split(r"\s+(?=[A-Za-z_]\w*=)", m.group(1).strip(), maxsplit=1)[0])
        if positions is not None:
            positions.append(m.start(1))
    for m in re.finditer(r"\bfor\s+" + n + r"\s+in\s+(.*?)(?:;\s*do\b|$)", text, re.M):
        rhs.append(m.group(1))
    if re.search(r"\b(?:read|getopts)\b[^\n]*\b" + n + r"\b", text) or \
            re.search(r"\bfor\s+" + n + r"\s*(?:;|$|do\b)", text, re.M):
        rhs.append("$1")
    return rhs


class _ShResolver(_Resolver):
    """Names resolve in the enclosing functions first (innermost out), then in
    the whole file plus the in-repo files it sources."""

    def __init__(self, file_text: str, scopes=(), guarded=()):
        super().__init__()
        self.text = file_text
        self.scopes = list(scopes)
        self.guarded = list(guarded)  # (start, end) offsets of functions that run a containment check

    def assignments(self, name: str) -> list:
        for scope in self.scopes:
            local = _sh_find(scope, name)
            if local:
                return local
        positions: list = []
        found = _sh_find(self.text, name, positions)
        # `TVM_HOME="$resolved"` inside a function that resolved and checked it
        # (`pwd -P`, the marker folder): from then on the name is an owned root.
        if any(a <= pos <= b for pos in positions for a, b in self.guarded):
            return ["\0guarded"]
        return found

    def classify_name(self, name: str, depth: int, seen) -> str:
        if name == "__param__":
            return PARAM
        if name in SH_INPUT_VARS:
            return ROOT
        return super().classify_name(name, depth, seen)

    def _subst_class(self, sub: str, depth, seen) -> str:
        if re.search(r"\bmktemp\b", sub):
            return TEMP
        if re.search(r"\b(?:shasum|sha1sum|sha256sum|md5|md5sum|openssl\s+dgst|date|uuidgen)\b", sub):
            return CONST  # a hash, a timestamp or a fresh id: no path tricks in it
        simple = re.match(r"\s*(?:basename|dirname|echo|printf\s+['\"]?%s['\"]?)\s+([^|;&<>`]*)$", sub)
        if simple and "$(" not in simple.group(1):
            return self.classify_expr(simple.group(1), depth + 1, seen)  # as good as its argument
        if SH_ANCHOR_RE.search(sub):
            rest = _SH_ANCHOR_STRIP_RE.sub("", sub)
            if not re.search(r"\$\{?[A-Za-z_0-9]", rest.replace("$(", "")):
                return CONST
            # `$(cd "$X/.." && pwd)`: as good as X.
            first = re.sub(r"^\s*cd\s+", "", sub.split("&&")[0]).strip()
            return self.classify_expr(first, depth + 1, seen) if "$" in first else ROOT
        return ROOT  # command output

    def terms(self, expr: str, depth=0, seen=frozenset()) -> list:
        if expr == "\0guarded":
            return [("cls", ROOTED)]
        events = []
        masked = list(expr)

        def mask(a, b):
            for k in range(a, b):
                masked[k] = " "

        for m in _SH_SUBST_RE.finditer(expr):
            events.append((m.start(), ("cls", self._subst_class(m.group(1), depth, seen))))
            mask(m.start(), m.end())
        code = "".join(masked)
        if "`" in code:
            events.append((code.index("`"), ("cls", ROOT)))
        for m in _SH_POSITIONAL_RE.finditer(code):
            events.append((m.start(), ("cls", ROOT)))
            mask(m.start(), m.end())
        code = "".join(masked)
        for m in _SH_BRACED_RE.finditer(code):
            name, op, default = m.group(1), m.group(2), m.group(3)
            if op and op.lstrip(":") in ("-", "="):
                # `${X:-default}`: X may come from the environment.
                own = [r for r in self.cached_assignments(name) if not re.search(r"\$\{" + re.escape(name) + r"\b", r)]
                if name in seen or depth > MAX_DEPTH:
                    own = []
                inner = seen | {name}
                alt = [_worst(self.classify_expr(r, depth + 1, inner) for r in own) if own else ROOT,
                       self.classify_expr(default or "", depth + 1, inner)]
                cls = TEMP if TEMP in alt else _worst(alt)
                events.append((m.start(), ("cls", ROOT if cls == CONST else cls)))
            else:
                events.append((m.start(), ("name", name)))
            mask(m.start(), m.end())
        code = "".join(masked)
        for m in _SH_SIMPLE_RE.finditer(code):
            events.append((m.start(), ("name", m.group(1))))
            mask(m.start(), m.end())
        code = "".join(masked)
        starts_with_literal = bool(re.match(r"\s*[\"']?[\w./~-]", code)) and not re.match(r"\s*[\"']?\s", code)
        for m in re.finditer(r"[^\s\"'$]+", code):
            piece = m.group(0)
            leading = starts_with_literal and m.start() == code.find(piece)
            events.append((m.start(), ("lit", bool(re.search(r"/[\w.-]*[\w-]", piece)) or leading)))
        events.sort(key=lambda e: e[0])
        return [t for _, t in events]


def _check_bash(path: str, text: str) -> list:
    if not re.search(r"\brm\s+-", text):
        return []
    lines = _sh_code_lines(text)
    spans = None
    marked = None
    guarded = None
    file_text = None
    resolvers: dict = {}
    out = []
    for idx, line in enumerate(lines):
        for m in SH_DELETE_RE.finditer(line):
            if not _sh_recursive_force(m.group("flags")):
                continue
            args = m.group("args")
            if line[:m.start()].count("'") % 2:
                args = args.split("'")[0]  # inside a single-quoted trap string
            args = re.split(r"\s*\)\s*$|\s+(?:2?>|\|\||&&)|\s*;;", args)[0]
            if "$" not in args or "\\$" in args:
                continue  # a literal path, or `\$` written into a heredoc for another shell
            if spans is None:
                spans = _sh_function_spans(lines)
            enclosing = _sh_enclosing(spans, idx)
            if enclosing:
                a, b = enclosing[0]
                scope = "\n".join(lines[a:b + 1])
            else:
                scope = "\n".join(lines[max(0, idx - FALLBACK_LINES):idx + 1])
            if SH_CONTAIN_RE.search(scope):
                continue
            if file_text is None:
                marked = _sh_mark_params(lines)
                sourced = _sh_mark_params(_sh_code_lines(_sourced_text(path, text)))
                file_text = "\n".join(marked) + "\n" + "\n".join(sourced)
            key = tuple(enclosing)
            if key not in resolvers:
                if guarded is None:
                    starts = [0]
                    for ln in marked:
                        starts.append(starts[-1] + len(ln) + 1)
                    guarded = [(starts[a], starts[b + 1]) for a, b in spans
                               if SH_CONTAIN_RE.search("\n".join(lines[a:b + 1]))]
                resolvers[key] = _ShResolver(file_text, ["\n".join(marked[a:b + 1]) for a, b in enclosing], guarded)
            resolver = resolvers[key]
            if enclosing:
                args = re.sub(r"\$(?:[1-9@*]|\{[1-9@*]\})", "$__param__", args)
            bad = [k for k in (resolver.classify_expr(a) for a in _sh_split_args(args)) if k in FLAGGED]
            if not bad:
                continue
            what = "an input path" if bad[0] == ROOT else "a path with an input-named part"
            out.append((idx + 1, f"rm {m.group('flags').strip()} {args.strip()[:50]} deletes {what} with no "
                                 f"containment check here; `..`, a symlink or an env/CLI override deletes outside "
                                 f"the owned root"))
            break
    return out


# ---------------------------------------------------------------- entry

def check(path: str, text: str):
    if path.endswith(".swift"):
        if ".removeItem(" not in text:
            return []
        return _check_swift(text)
    if path.endswith(".py"):
        return _check_python(text)
    if path.endswith(".sh"):
        return _check_bash(path, text)
    return []

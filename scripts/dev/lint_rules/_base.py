"""Shared helpers for lint.py rules: path globs and a small Swift scope lexer.

Every rule module in this folder used to need the same three things: match a
repo-relative path against globs, ignore code that sits inside a comment or a
string literal, and know what encloses a line (which type, which func, whether
it's on the main actor). Writing that per rule is how you get five slightly
different lexers that disagree. So it lives here, once.

    from lint_rules._base import swift_file, path_matches

    def check(path, text):
        sf = swift_file(text)
        for line, match in sf.find(r"\\bData\\(contentsOf:"):
            if sf.isolation_at(match.start()) == "main":
                yield ...

The comment/string blanking reuses `sanitize()` from
`scripts/dev/check-duplicate-declarations.py` (the same one
`check-module-boundaries.py` loads), so all three checks agree on what is code.
The scope tracking is a heuristic, tuned for this repo's Swift: it reads brace
pairs, takes the statement in front of each `{`, and classifies it as a type,
extension, func, accessor or plain block (closure, `if`, `for` ...). It's not a
parser. When braces don't balance (the lexer got confused, or a `#if` opened a
brace in only one branch) `SwiftFile.balanced` is False; rules should treat
scope answers as unreliable then.

Python 3.9 stdlib only.
"""

from __future__ import annotations

import bisect
import functools
import importlib.util
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
_DEV_DIR = Path(__file__).resolve().parents[1]


# ---------------------------------------------------------------- globs

@functools.lru_cache(maxsize=512)
def glob_regex(pattern: str) -> "re.Pattern[str]":
    """Compile an fnmatch-style repo glob. `**/` matches zero or more folders,
    `**` at the end matches anything, `*` and `?` never cross a `/`."""
    i, n, out = 0, len(pattern), []
    while i < n:
        c = pattern[i]
        if pattern.startswith("**/", i):
            out.append("(?:[^/]+/)*")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif c == "*":
            out.append("[^/]*")
            i += 1
        elif c == "?":
            out.append("[^/]")
            i += 1
        elif c == "[":
            end = pattern.find("]", i + 1)
            if end == -1:
                out.append(re.escape(c))
                i += 1
            else:
                body = pattern[i + 1:end]
                if body.startswith("!"):
                    body = "^" + body[1:]
                out.append("[" + body.replace("\\", "\\\\") + "]")
                i = end + 1
        else:
            out.append(re.escape(c))
            i += 1
    return re.compile("".join(out) + r"\Z")


def glob_match(path: str, pattern: str) -> bool:
    return glob_regex(pattern).match(path) is not None


def path_matches(path: str, globs, exclude=()) -> bool:
    """True when `path` (repo-relative, `/` separators) matches any glob in
    `globs` and none in `exclude`."""
    if not any(glob_match(path, g) for g in globs):
        return False
    return not any(glob_match(path, g) for g in exclude)


def example_path(globs, exclude=()) -> str | None:
    """A fake path that matches the first usable glob, for fixtures that don't
    declare `lint-fixture-path`. `Sources/**/*.swift` -> `Sources/Fixture.swift`."""
    for g in globs:
        candidate = re.sub(r"\[!?([^\]])[^\]]*\]", r"\1", g)
        candidate = candidate.replace("**/", "").replace("**", "Fixture").replace("*", "Fixture").replace("?", "x")
        if path_matches(candidate, globs, exclude):
            return candidate
    return None


# ---------------------------------------------------------------- comment/string blanking

@functools.lru_cache(maxsize=1)
def _sanitizer():
    spec = importlib.util.spec_from_file_location(
        "check_duplicate_declarations", _DEV_DIR / "check-duplicate-declarations.py"
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module.sanitize


def sanitize_swift(text: str) -> str:
    """Same-length copy of `text` with Swift comment and string-literal content
    replaced by spaces (newlines kept, `\\(...)` interpolations kept as code)."""
    return _sanitizer()(text)


# ---------------------------------------------------------------- Swift scopes

TYPE_KINDS = ("class", "struct", "enum", "protocol", "actor", "extension")
FUNC_KINDS = ("func", "init", "deinit", "subscript", "var", "accessor")

MODIFIERS = (
    "private", "fileprivate", "internal", "public", "open", "package",
    "static", "class", "final", "override", "dynamic", "lazy", "weak", "unowned",
    "mutating", "nonmutating", "convenience", "required", "optional", "indirect",
    "nonisolated", "isolated", "distributed", "borrowing", "consuming",
    "prefix", "postfix", "infix", "unsafe", "sending",
)

# Types whose subclasses / conformers are main-actor isolated in the macOS 26
# SDK. A type that names one of these in its inheritance clause counts as
# @MainActor even without the attribute.
MAIN_ACTOR_SUPERTYPES = frozenset({
    "View", "App", "Scene", "Commands", "NSViewRepresentable", "NSViewControllerRepresentable",
    "NSView", "NSViewController", "NSWindowController", "NSWindow", "NSPanel",
    "NSApplicationDelegate", "NSWindowDelegate", "NSHostingView", "NSHostingController",
    "NSStatusItem", "NSMenu", "NSTableView", "NSTextView", "NSButton",
})

_ATTR = r"@[A-Za-z_][\w.]*(?:\([^()]*(?:\([^()]*\)[^()]*)*\))?"
_DECL_RE = re.compile(
    r"\A\s*(?P<attrs>(?:" + _ATTR + r"\s*)*)"
    r"(?P<mods>(?:(?:" + "|".join(MODIFIERS) + r")(?:\([^)]*\))?\s+)*)"
    r"(?P<kw>class|struct|enum|protocol|actor|extension|func|init[?!]?|deinit|subscript|var|let"
    r"|get|set|willSet|didSet|_modify|_read)\b"
)
_ATTR_ONLY_LINE = re.compile(r"\A\s*(?:" + _ATTR + r"\s*)+\Z")
_CONTINUES_NEXT = re.compile(r"(?:[(\[,=:&|+\-*/<.?]|->)\s*\Z")
_CONTINUES_PREV = re.compile(r"\A\s*(?:\.|->|where\b|throws\b|rethrows\b|async\b|:|,|&&|\|\||\?\?|else\b|[)\]])")
_QUEUE_HOP = re.compile(r"\.(?:async|sync|asyncAfter|asyncAndWait|concurrentPerform)\b")
_PP = re.compile(r"^[ \t]*#(if|elseif|else|endif)\b", re.M)


class Scope:
    """One `{ ... }` pair.

    kind      class/struct/enum/protocol/actor/extension, func/init/deinit/
              subscript/var (computed property)/accessor (get, set, didSet ...),
              or "block" for everything else (closures, if/for/switch bodies).
    name      the declared name (`Foo`, `bar`, `Outer.Inner` for extensions); ""
              for blocks.
    attrs     attribute names without `@` (`MainActor`, `objc`, `ViewBuilder`).
              Closures that open with `{ @MainActor in` get `MainActor`.
    modifiers e.g. ["private", "nonisolated", "static"].
    inherits  names from a type's inheritance clause, generics stripped.
    head      the statement in front of `{` (sanitized, may span lines).
    tail      the last non-empty line of `head`; for closures this is the call
              that takes it (`DispatchQueue.global().async`, `Task.detached`).
    """

    __slots__ = ("kind", "name", "attrs", "modifiers", "inherits", "head", "tail",
                 "open_offset", "close_offset", "decl_line", "open_line", "close_line",
                 "parent", "depth")

    def __init__(self):
        self.kind = "block"
        self.name = ""
        self.attrs: list = []
        self.modifiers: list = []
        self.inherits: list = []
        self.head = ""
        self.tail = ""
        self.open_offset = 0
        self.close_offset = -1
        self.decl_line = 0
        self.open_line = 0
        self.close_line = 0
        self.parent: Scope | None = None
        self.depth = 0

    @property
    def is_type(self) -> bool:
        return self.kind in TYPE_KINDS

    @property
    def is_function(self) -> bool:
        return self.kind in FUNC_KINDS

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        attrs = "".join(f"@{a} " for a in self.attrs)
        return f"<Scope {attrs}{' '.join(self.modifiers)} {self.kind} {self.name} L{self.open_line}-{self.close_line}>"


def _split_logical(head: str) -> list:
    """(start, end) spans of `head`'s lines, split at newlines outside ()/[],
    blank ones dropped."""
    spans, depth, start = [], 0, 0
    for i, c in enumerate(head):
        if c in "([":
            depth += 1
        elif c in ")]":
            depth = max(0, depth - 1)
        elif c == "\n" and depth == 0:
            spans.append((start, i))
            start = i + 1
    spans.append((start, len(head)))
    return [(a, b) for a, b in spans if head[a:b].strip()]


def _last_statement(head: str) -> int:
    """Start offset (in `head`) of the statement right before a `{`: the last
    logical line, plus earlier lines it continues (attribute lines, wrapped
    signatures). `head` should be the string-shaped code (see _shape)."""
    spans = _split_logical(head)
    if not spans:
        return len(head)
    first, end = spans[-1]
    k = len(spans) - 2
    while k >= 0:
        prev = head[spans[k][0]:spans[k][1]]
        stmt = head[first:end]
        if _ATTR_ONLY_LINE.match(prev) or _CONTINUES_NEXT.search(prev) or _CONTINUES_PREV.match(stmt):
            first = spans[k][0]
            k -= 1
            continue
        break
    stmt = head[first:end]
    return first + (len(stmt) - len(stmt.lstrip()))


def _top_level_has(text: str, ch: str) -> bool:
    depth = 0
    for i, c in enumerate(text):
        if c in "([<":
            depth += 1
        elif c in ")]>":
            if c == ">" and i and text[i - 1] == "-":
                continue
            depth = max(0, depth - 1)
        elif c == ch and depth == 0:
            if ch == "=" and (text[i + 1:i + 2] == "=" or text[i - 1:i] in "=!<>"):
                continue
            return True
    return False


def _classify(scope: Scope, stmt: str, body_start: str = "") -> None:
    scope.head = stmt
    tails = [ln for ln in stmt.split("\n") if ln.strip()]
    scope.tail = tails[-1].strip() if tails else ""
    m = _DECL_RE.match(stmt)
    if not m:
        return
    kw = m.group("kw")
    rest = stmt[m.end():]
    scope.attrs = re.findall(r"@([A-Za-z_][\w.]*)", m.group("attrs"))
    scope.modifiers = re.findall(r"[a-z]+", m.group("mods"))
    if kw in ("let", "var"):
        # `var x: Int {` is computed; `let x = foo {` / `var y = { }()` is a closure.
        observed = re.match(r"\s*(?:willSet|didSet)\b", body_start)
        if kw == "let" or (_top_level_has(rest, "=") and not observed):
            scope.attrs, scope.modifiers = [], []
            return
        scope.kind = "var"
        nm = re.match(r"\s*([A-Za-z_]\w*)", rest)
        scope.name = nm.group(1) if nm else ""
        return
    if kw in ("get", "set", "willSet", "didSet", "_modify", "_read"):
        if rest.strip() and not re.match(r"\s*(?:\(\s*\w+\s*\)|async\b|throws\b)", rest):
            scope.attrs, scope.modifiers = [], []
            return
        scope.kind, scope.name = "accessor", kw
        return
    if kw.startswith("init"):
        scope.kind, scope.name = "init", "init"
        return
    scope.kind = kw
    if kw in ("deinit", "subscript"):
        scope.name = kw
        return
    if kw == "func":
        nm = re.match(r"\s*([^\s(<]+)", rest)
        scope.name = nm.group(1) if nm else ""
        return
    nm = re.match(r"\s*([A-Za-z_][\w.]*)", rest)
    scope.name = nm.group(1) if nm else ""
    after = rest[nm.end():] if nm else rest
    after = re.sub(r"\A\s*<[^{]*?>", "", after)
    inh = re.match(r"\s*:\s*(.*?)(?:\bwhere\b|\Z)", after, re.S)
    if inh:
        names = []
        for part in re.sub(r"<[^<>]*>", "", inh.group(1)).split(","):
            part = part.strip().split("&")[0].strip()
            part = part.split(".")[-1] if part else part
            if re.match(r"[A-Za-z_]\w*\Z", part):
                names.append(part)
        scope.inherits = names


def _shape(text: str, code: str) -> str:
    """`code` with string-literal content filled with `x` instead of spaces, so a
    line ending in a string doesn't look like it ends in `=` or `,`. Comments stay
    blank. Same length as `code`."""
    out = list(code)
    n = len(code)
    i = 0
    while i < n:
        if code[i] == " " and not text[i].isspace():
            j = i
            while j < n and code[j] == " " and text[j] != "\n":
                j += 1
            if not text.startswith(("//", "/*"), i):
                for k in range(i, j):
                    if not text[k].isspace():
                        out[k] = "x"
            i = j
        else:
            i += 1
    return "".join(out)


class SwiftFile:
    """Scope-aware view of one Swift source. Build it with `swift_file(text)`
    (cached), not directly, so several rules on one file lex it once."""

    def __init__(self, text: str):
        self.text = text
        self.code = sanitize_swift(text)
        self.lines = text.split("\n")
        self.code_lines = self.code.split("\n")
        self._line_starts = [0]
        for i, c in enumerate(text):
            if c == "\n":
                self._line_starts.append(i + 1)
        self.scopes: list = []
        self.balanced = True
        self._build()
        types = {s.name for s in self.scopes if s.kind in TYPE_KINDS and s.kind != "extension"
                 and ("MainActor" in s.attrs or MAIN_ACTOR_SUPERTYPES.intersection(s.inherits))}
        self.main_actor_types = frozenset(types)

    # -------------------------------------------------------- positions
    def line_of(self, offset: int) -> int:
        """1-based line number of a character offset."""
        return bisect.bisect_right(self._line_starts, offset)

    def offset_of_line(self, line: int) -> int:
        """Offset of the first code character on 1-based `line` (or its start)."""
        start = self._line_starts[line - 1]
        code = self.code_lines[line - 1] if line - 1 < len(self.code_lines) else ""
        stripped = len(code) - len(code.lstrip())
        return start + (stripped if code.strip() else 0)

    def find(self, pattern, flags: int = 0):
        """Yield (line, match) for each regex match in the sanitized code, so
        nothing inside a comment or string literal matches. Match offsets index
        both `self.code` and `self.text`."""
        rx = re.compile(pattern, flags) if isinstance(pattern, str) else pattern
        for m in rx.finditer(self.code):
            yield self.line_of(m.start()), m

    # -------------------------------------------------------- scope build
    def _build(self) -> None:
        code = self.code
        shape = _shape(self.text, code)
        stack: list = []
        pp: list = []  # per #if: [snapshot_of_stack, stack_after_first_branch or None]
        pp_marks = {m.start(): m.group(1) for m in _PP.finditer(code)}
        boundary = 0  # offset just after the previous { } or ;
        for i, c in enumerate(code):
            if i in pp_marks:
                kind = pp_marks[i]
                if kind == "if":
                    pp.append([list(stack), None])
                elif kind in ("elseif", "else") and pp:
                    if pp[-1][1] is None:
                        pp[-1][1] = list(stack)
                    for orphan in stack[len(pp[-1][0]):]:
                        orphan.close_offset, orphan.close_line = orphan.open_offset, orphan.open_line
                    stack = list(pp[-1][0])
                elif kind == "endif" and pp:
                    snap, first = pp.pop()
                    if first is not None:
                        for orphan in stack[len(snap):]:
                            orphan.close_offset, orphan.close_line = orphan.open_offset, orphan.open_line
                        stack = first
            if c == "{":
                s = Scope()
                s.open_offset = i
                s.open_line = self.line_of(i)
                head = code[boundary:i]
                rel = _last_statement(shape[boundary:i])
                stmt = code[boundary + rel:i]
                _classify(s, stmt, code[i + 1:i + 120])
                s.decl_line = self.line_of(boundary + rel)
                if s.kind == "block" and re.match(r"\s*@MainActor\b", code[i + 1:i + 200]):
                    s.attrs = ["MainActor"]
                s.parent = stack[-1] if stack else None
                s.depth = len(stack)
                stack.append(s)
                self.scopes.append(s)
                boundary = i + 1
            elif c == "}":
                if stack:
                    s = stack.pop()
                    s.close_offset = i
                    s.close_line = self.line_of(i)
                else:
                    self.balanced = False
                boundary = i + 1
            elif c == ";":
                boundary = i + 1
        if stack:
            self.balanced = False
            end = len(code)
            for s in stack:
                s.close_offset, s.close_line = end, self.line_of(end)

    # -------------------------------------------------------- scope queries
    def enclosing(self, offset: int) -> list:
        """Scopes containing `offset`, outermost first."""
        found = [s for s in self.scopes if s.open_offset < offset <= s.close_offset]
        found.sort(key=lambda s: s.depth)
        return found

    def enclosing_line(self, line: int) -> list:
        return self.enclosing(self.offset_of_line(line))

    def function_at(self, offset: int) -> Scope | None:
        """Innermost func/init/deinit/subscript/computed var/accessor around offset."""
        for s in reversed(self.enclosing(offset)):
            if s.is_function:
                return s
        return None

    def type_at(self, offset: int) -> Scope | None:
        """Innermost type or extension around offset."""
        for s in reversed(self.enclosing(offset)):
            if s.is_type:
                return s
        return None

    def isolation_at(self, offset: int, main_actor_types=()) -> str | None:
        """Best guess at the actor isolation of code at `offset`.

        Returns "main", "nonisolated", "actor", or None (no isolation found).
        Walks inner to outer and stops at the first scope that decides it:
          - `nonisolated` modifier                      -> "nonisolated"
          - `@MainActor` (decl, or closure `{ @MainActor in`) -> "main"
          - `Task.detached { }`                          -> "nonisolated"
          - `queue.async { }` and friends: "main" if the call names `.main`,
            else "nonisolated"
          - an `actor` type                              -> "actor"
          - a type (or extension of one) that is @MainActor in this file, in
            `main_actor_types`, or inherits a main-actor SDK type (View, NSView,
            NSWindowController ...)                    -> "main"
        Other closures inherit their context, which is right for `Task { }` and
        SwiftUI modifiers and wrong for escaping callbacks run elsewhere.
        """
        known = self.main_actor_types.union(main_actor_types)
        for s in reversed(self.enclosing(offset)):
            if "nonisolated" in s.modifiers:
                return "nonisolated"
            if "MainActor" in s.attrs:
                return "main"
            if s.kind == "block":
                if re.search(r"\bTask\.detached\b", s.tail):
                    return "nonisolated"
                if _QUEUE_HOP.search(s.tail):
                    return "main" if re.search(r"(?:\bDispatchQueue)?\.main\b", s.tail) else "nonisolated"
                continue
            if s.kind == "actor":
                return "actor"
            if s.is_type:
                base = s.name.split(".")[-1] if s.kind == "extension" else s.name
                if base in known or s.name in known or MAIN_ACTOR_SUPERTYPES.intersection(s.inherits):
                    return "main"
        return None


@functools.lru_cache(maxsize=16)
def swift_file(text: str) -> SwiftFile:
    """Cached SwiftFile for `text` (several rules on one file share it)."""
    return SwiftFile(text)


# ---------------------------------------------------------------- self-test

def self_test() -> list:
    """Return a list of failure strings (empty when everything holds)."""
    failures = []

    def expect(cond, label):
        if not cond:
            failures.append(label)

    expect(glob_match("Sources/UI/A.swift", "Sources/**/*.swift"), "glob ** spans folders")
    expect(glob_match("Sources/A.swift", "Sources/**/*.swift"), "glob **/ matches zero folders")
    expect(not glob_match("Sources/UI/A.swift", "Sources/*.swift"), "glob * stays in one folder")
    expect(glob_match(".claude/hooks/x/y.sh", ".claude/hooks/**"), "glob trailing **")
    expect(not path_matches("Sources/UI/A.swift", ["Sources/**"], ["Sources/UI/**"]), "exclude wins")
    expect(example_path(["Sources/**/*.swift"]) == "Sources/Fixture.swift", "example path")

    src = '''import Foundation

// func notReal() {
@MainActor
final class Model: ObservableObject {
    let s = "func alsoNotReal() {"
    func load() {
        let d = try? Data(contentsOf: url)
        Task.detached {
            work()
        }
        DispatchQueue.main.async {
            ui()
        }
    }

    nonisolated func off() {
        hop()
    }

    var title: String {
        get { "x" }
    }
}

struct Row: View {
    var body: some View {
        Text("hi")
    }
}

actor Store {
    func put() { save() }
}

extension Model {
    func more() {
        again()
    }
}

#if DEBUG
func dbg() {
#else
func dbg() async {
#endif
    inside()
}
'''
    sf = SwiftFile(src)
    expect(sf.balanced, "sample balances")
    names = [(s.kind, s.name) for s in sf.scopes if s.kind != "block"]
    expect(("class", "Model") in names, f"class Model found: {names}")
    expect(("func", "notReal") not in names and ("func", "alsoNotReal") not in names, "comment/string decls ignored")
    expect(("var", "title") in names and ("accessor", "get") in names, "computed var + accessor")
    expect(("struct", "Row") in names and ("actor", "Store") in names, "struct + actor")
    model = next(s for s in sf.scopes if s.name == "Model" and s.kind == "class")
    expect(model.attrs == ["MainActor"] and model.inherits == ["ObservableObject"], f"attrs/inherits {model.attrs} {model.inherits}")
    expect(model.decl_line == 4, f"decl line includes attribute line ({model.decl_line})")

    def iso(needle):
        return sf.isolation_at(src.index(needle))

    expect(iso("Data(contentsOf") == "main", "@MainActor class body is main")
    expect(iso("work()") == "nonisolated", "Task.detached is nonisolated")
    expect(iso("ui()") == "main", "DispatchQueue.main.async is main")
    expect(iso("hop()") == "nonisolated", "nonisolated func")
    expect(iso('Text("hi")') == "main", "View conformer is main")
    expect(iso("save()") == "actor", "actor body")
    expect(iso("again()") == "main", "extension of @MainActor type in same file")
    expect(iso("import Foundation") is None, "top level is unisolated")
    fn = sf.function_at(src.index("Data(contentsOf"))
    expect(fn is not None and fn.name == "load", "function_at")
    expect(sf.type_at(src.index("again()")).kind == "extension", "type_at extension")
    dbg = sf.function_at(src.index("inside()"))
    expect(dbg is not None and dbg.name == "dbg", "#if/#else brace in both branches keeps scope")
    lines = [ln for ln, _ in sf.find(r"\bfunc\s+\w*[Nn]otReal")]
    expect(lines == [], "find() skips comments and strings")
    expect(sf.line_of(src.index("hop()")) == 18, "line_of")

    sf4 = SwiftFile("final class A {\n  var n = 0 {\n    didSet { tick() }\n  }\n}\n")
    expect([(x.kind, x.name) for x in sf4.scopes][1:] == [("var", "n"), ("accessor", "didSet")], "stored var with observer")

    sf2 = SwiftFile("func a() {\n  if x {\n}\n")
    expect(not sf2.balanced, "unbalanced braces are reported")

    sf3 = SwiftFile("final class W: NSWindowController {\n  func f() {\n    DispatchQueue.global().async {\n      io()\n    }\n  }\n}\n")
    expect(sf3.isolation_at(sf3.text.index("io()")) == "nonisolated", "global queue hop leaves main")
    expect(sf3.isolation_at(sf3.text.index("DispatchQueue")) == "main", "NSWindowController subclass is main")
    return failures

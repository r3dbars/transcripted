#!/usr/bin/env python3
"""Check Swift "source-text contract" pins without a Swift toolchain.

Many Swift tests read a repo file as text (``readSourceFixture("...")``,
``String(contentsOf: repoFixtureURL("..."))``, ``readParakeetEngineSource()``,
``#filePath``-relative URL chains, per-file reader helpers) and then assert
``text.contains("literal")`` / ``text.range(of: "literal")``. Editing the pinned
file breaks those tests, but only a macOS machine with Swift finds out.

This is a best-effort static extractor, tuned for zero false positives:

* It lexes each test file (comments, ``"..."``, ``\"\"\"...\"\"\"`` and raw ``#"..."#``
  literals, Swift escapes), tracks ``let``/``var`` bindings per brace scope, and
  resolves a binding to a repo file only when the expression is a recognised
  pure read. Anything it cannot prove (transforms like ``lowercased()``,
  ``replacingOccurrences``, unknown helpers, parameters, closure arguments) is
  counted as *unresolved* and skipped.
* A binding derived from a resolved file by subscripting or a slice-style helper
  (``sourceSlice(source, from:, to:)``) is a *slice*. Positive needles on a slice
  are still checked against the whole file (if the needle is absent from the
  file it is absent from any substring), negative needles on a slice are
  skipped (the needle may legitimately live outside the slice).
* Only assertion arguments count: ``assertTrue``/``XCTAssertTrue``/``XCTAssert``
  (must hold), ``assertFalse``/``XCTAssertFalse`` (must not hold),
  ``assertNotNil``/``XCTAssertNotNil``/``XCTUnwrap`` and ``assertNil``/``XCTAssertNil``
  around ``range(of:)``, plus ``guard let r = text.range(of: "x") else { XCTFail(..) }``
  (else blocks that fail the test). ``&&`` / ``||`` / ``!`` / ``!= nil`` / ``== nil``
  are handled; any other shape inside the assertion makes that atom unresolved.
  ``range(of:range:)`` counts only as a must-exist pin (a sub-range of the file).
* ``for needle in ["a", "b"]`` and ``for (needle, why) in [("a", "..."), ...]``
  expand to one pin per literal; ``for text in [fileA, fileB]`` pins every file.
* Helpers are discovered per test file (``private`` ones stay file-local): pure
  readers (``f("rel/path")`` / ``f()``), URL helpers, and slice helpers whose body
  provably returns a substring of their text parameter.

Output separates file-backed assertions (resolved / unresolved) from assertions
whose receiver never came from a repo file (runtime strings, temp files), which
are ignored.

Usage:

    python3 scripts/dev/check-source-pins.py                 # whole tree
    python3 scripts/dev/check-source-pins.py --changed-only  # pins whose target or test changed vs origin/main
    python3 scripts/dev/check-source-pins.py --changed-only main
    python3 scripts/dev/check-source-pins.py --verbose       # also list unresolved reasons
    python3 scripts/dev/check-source-pins.py --self-test

Exit status: 0 when no pin is broken, 1 when a pin is broken, 2 on usage errors.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass, field, replace as dc_replace
from pathlib import Path
from typing import Callable, Optional

REPO_ROOT = Path(__file__).resolve().parents[2]

# --------------------------------------------------------------------------- lexer


@dataclass
class Tok:
    kind: str  # "str", "ident", "num", "op"
    value: Optional[str]
    line: int
    nl_before: bool = False  # first token on its source line


class LexError(Exception):
    pass


_SIMPLE_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "'": "'", "\\": "\\", "0": "\0"}
_OPS = ["...", "..<", "&&", "||", "==", "!=", "??", "->", "<=", ">=", "+=", "-="]
_IDENT_START = re.compile(r"[A-Za-z_$#@`]")
_IDENT_CHARS = re.compile(r"[A-Za-z0-9_$`]")


def _decode_escapes(body: str, hashes: int) -> Optional[str]:
    """Decode a single-line string body. Returns None when it interpolates."""
    esc = "\\" + "#" * hashes
    out: list[str] = []
    i = 0
    while i < len(body):
        if body.startswith(esc, i):
            j = i + len(esc)
            if j >= len(body):
                return None
            ch = body[j]
            if ch == "(":
                return None
            if ch in _SIMPLE_ESCAPES:
                out.append(_SIMPLE_ESCAPES[ch])
                i = j + 1
                continue
            if ch == "u" and j + 1 < len(body) and body[j + 1] == "{":
                end = body.find("}", j)
                if end < 0:
                    return None
                try:
                    out.append(chr(int(body[j + 2 : end], 16)))
                except ValueError:
                    return None
                i = end + 1
                continue
            return None
        out.append(body[i])
        i += 1
    return "".join(out)


def _decode_multiline(raw: str, hashes: int) -> Optional[str]:
    """``raw`` is everything between the opening and closing triple quotes."""
    if not raw.startswith("\n"):
        # Content on the opening-delimiter line is a Swift compile error; bail.
        return None
    lines = raw[1:].split("\n")
    indent_line = lines[-1]
    if indent_line.strip():
        return None
    indent = indent_line
    body_lines = lines[:-1]
    stripped: list[str] = []
    for line in body_lines:
        if line.strip() == "":
            stripped.append("")
        elif line.startswith(indent):
            stripped.append(line[len(indent) :])
        else:
            return None
    # Line continuation: a line ending in an unescaped backslash joins the next.
    esc = "\\" + "#" * hashes
    joined: list[str] = []
    pending = ""
    for idx, line in enumerate(stripped):
        is_last = idx == len(stripped) - 1
        trail = len(line) - len(line.rstrip("\\"))
        if hashes == 0 and trail % 2 == 1 and not is_last:
            pending += line[:-1]
            continue
        if hashes and line.endswith(esc) and not is_last:
            pending += line[: -len(esc)]
            continue
        joined.append(pending + line)
        pending = ""
    if pending:
        joined.append(pending)
    return _decode_escapes("\n".join(joined), hashes)


def lex(src: str) -> list[Tok]:
    toks: list[Tok] = []
    i = 0
    n = len(src)
    line = 1
    line_has_tok = False

    def push(kind: str, value: Optional[str], at_line: int) -> None:
        nonlocal line_has_tok
        toks.append(Tok(kind, value, at_line, nl_before=not line_has_tok))
        line_has_tok = True

    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            line_has_tok = False
            i += 1
            continue
        if c in " \t\r":
            i += 1
            continue
        if src.startswith("//", i):
            end = src.find("\n", i)
            i = n if end < 0 else end
            continue
        if src.startswith("/*", i):
            depth = 0
            while i < n:
                if src.startswith("/*", i):
                    depth += 1
                    i += 2
                elif src.startswith("*/", i):
                    depth -= 1
                    i += 2
                    if depth == 0:
                        break
                else:
                    if src[i] == "\n":
                        line += 1
                    i += 1
            continue
        # string literals (optionally raw: #"..."#)
        hashes = 0
        j = i
        while j < n and src[j] == "#":
            hashes += 1
            j += 1
        if j < n and src[j] == '"':
            start_line = line
            close_hash = "#" * hashes
            if src.startswith('"""', j):
                k = j + 3
                close = '"""' + close_hash
                # find a closing delimiter not escaped
                search = k
                while True:
                    end = src.find(close, search)
                    if end < 0:
                        raise LexError(f"unterminated multi-line string at line {start_line}")
                    back = end - 1
                    slashes = 0
                    while back >= k and src[back] == "\\":
                        slashes += 1
                        back -= 1
                    if hashes == 0 and slashes % 2 == 1:
                        search = end + 1
                        continue
                    break
                raw = src[k:end]
                value = _decode_multiline(raw, hashes)
                line += raw.count("\n")
                push("str", value, start_line)
                i = end + len(close)
                continue
            k = j + 1
            close = '"' + close_hash
            while k < n:
                if src[k] == "\n":
                    raise LexError(f"newline in string literal at line {start_line}")
                if src[k] == "\\" and src.startswith("\\" + close_hash, k):
                    k += 1 + hashes
                    if k < n and src[k] == "(":
                        # interpolation: skip balanced parens (may contain strings)
                        depth = 0
                        while k < n:
                            if src[k] == "(":
                                depth += 1
                            elif src[k] == ")":
                                depth -= 1
                                if depth == 0:
                                    k += 1
                                    break
                            elif src[k] == '"':
                                k += 1
                                while k < n and src[k] != '"':
                                    k += 2 if src[k] == "\\" else 1
                            k += 1
                        continue
                    k += 1
                    continue
                if src.startswith(close, k):
                    break
                k += 1
            body = src[j + 1 : k]
            push("str", _decode_escapes(body, hashes), start_line)
            i = k + len(close)
            continue
        if c == "#" and hashes:
            # #filePath, #file, #if, #selector ...
            m = re.match(r"#[A-Za-z_][A-Za-z0-9_]*", src[i:])
            if m:
                push("ident", m.group(0), line)
                i += len(m.group(0))
                continue
            push("op", "#", line)
            i += 1
            continue
        if c.isdigit():
            m = re.match(r"[0-9][0-9_]*(\.[0-9_]+)?([eE][+-]?[0-9]+)?|0x[0-9A-Fa-f_]+", src[i:])
            push("num", m.group(0), line)
            i += len(m.group(0))
            continue
        if _IDENT_START.match(c):
            m = re.match(r"[A-Za-z_$@`][A-Za-z0-9_$`]*", src[i:])
            push("ident", m.group(0).strip("`"), line)
            i += len(m.group(0))
            continue
        for op in _OPS:
            if src.startswith(op, i):
                push("op", op, line)
                i += len(op)
                break
        else:
            push("op", c, line)
            i += 1
    return toks


# --------------------------------------------------------------------------- values


@dataclass(frozen=True)
class FileText:
    paths: tuple[str, ...]
    slice: bool = False  # a substring of the file(s), not the whole text
    each: bool = False  # a loop variable: the assertion runs once per path


@dataclass(frozen=True)
class UrlVal:
    path: Path  # absolute


@dataclass(frozen=True)
class StrVal:
    values: tuple[str, ...]  # one value, or several for a loop variable


@dataclass(frozen=True)
class Unknown:
    reason: str
    file: bool = False  # True when a resolved repo file fed into this value


@dataclass(frozen=True)
class Pieces:
    """``text.components(separatedBy:)`` of a file: every element is a substring."""

    paths: tuple[str, ...]
    each: bool = False


@dataclass(frozen=True)
class SliceHelper:
    """A test helper proven to return a substring of one String parameter."""

    text_index: int
    labels: tuple[Optional[str], ...]  # external labels, None for `_`


Value = object

# Identifiers that make a helper body something other than a pure substring.
NON_SLICE_IDENTS = {
    "joined", "replacingOccurrences", "replacing", "lowercased", "uppercased", "capitalized",
    "filter", "map", "compactMap", "flatMap", "reduce", "append", "appending", "insert",
    "applyingTransform", "folding", "reversed", "sorted", "removeAll", "removeFirst", "removeLast",
    "remove", "trimmingPrefix", "precomposedStringWithCanonicalMapping", "description",
}
TRY_WORDS = {"try", "await"}
PASSTHROUGH_CALLS = {"XCTUnwrap"}
KNOWN_ROOT_READERS = {"readSourceFixture"}  # (relativePath: String, ...) -> String


class Resolver:
    """Evaluates small Swift expressions to FileText / UrlVal / StrVal / Unknown."""

    def __init__(self, repo_root: Path, test_file: Path, readers_path: dict, readers_fixed: dict, url_funcs: dict, slice_helpers: Optional[dict] = None):
        self.root = repo_root
        self.test_file = test_file
        self.readers_path = readers_path  # name -> "root"
        self.readers_fixed = readers_fixed  # name -> FileText
        self.url_funcs = url_funcs  # name -> UrlVal
        self.slice_helpers = slice_helpers if slice_helpers is not None else {}  # name -> SliceHelper

    # -- helpers
    def _file(self, url: UrlVal) -> Value:
        try:
            rel = url.path.resolve().relative_to(self.root.resolve())
        except ValueError:
            return Unknown("url outside repo")
        if not url.path.is_file():
            return Unknown("url is not an existing repo file")
        return FileText((rel.as_posix(),))

    def _root_rel(self, rel: str) -> Value:
        return self._file(UrlVal(self.root / rel))

    @staticmethod
    def strip_wrappers(toks: list[Tok]) -> list[Tok]:
        changed = True
        while changed and toks:
            changed = False
            while toks and toks[0].kind == "ident" and toks[0].value in TRY_WORDS:
                toks = toks[1:]
                if toks and toks[0].kind == "op" and toks[0].value in ("?", "!"):
                    toks = toks[1:]
                changed = True
            # trailing `?? ""`
            if len(toks) >= 2 and toks[-2].kind == "op" and toks[-2].value == "??" and toks[-1].kind == "str" and toks[-1].value == "":
                toks = toks[:-2]
                changed = True
            # trailing force-unwrap
            if toks and toks[-1].kind == "op" and toks[-1].value == "!":
                toks = toks[:-1]
                changed = True
            if toks and toks[0].kind == "op" and toks[0].value == "(" and matching(toks, 0) == len(toks) - 1:
                toks = toks[1:-1]
                changed = True
        return toks

    def eval(self, toks: list[Tok], scope: "Scopes") -> Value:
        toks = self.strip_wrappers(list(toks))
        if not toks:
            return Unknown("empty expression")
        # string literal concatenation
        parts = split_top(toks, "+")
        if len(parts) > 1:
            vals = [self.eval(p, scope) for p in parts]
            if all(isinstance(v, StrVal) and len(v.values) == 1 for v in vals):
                return StrVal(("".join(v.values[0] for v in vals),))
            if all(isinstance(v, FileText) and not v.each for v in vals):
                paths: list[str] = []
                for v in vals:
                    paths.extend(v.paths)
                return FileText(tuple(dict.fromkeys(paths)), slice=True)
            return Unknown("binary + expression", file=any(is_fileish(v) for v in vals))
        if has_top_level_operator(toks):
            return Unknown("operator expression", file=self.mentions_file(toks, scope))
        # primary
        val, pos = self._primary(toks, scope)
        # postfix chain
        while pos < len(toks) and not isinstance(val, Unknown):
            t = toks[pos]
            if t.kind == "op" and t.value in ("!", "?"):
                pos += 1
                continue
            if t.kind == "op" and t.value == "[":
                end = matching(toks, pos)
                if end < 0:
                    return Unknown("unbalanced subscript")
                if isinstance(val, FileText):
                    val = dc_replace(val, slice=True)
                elif isinstance(val, Pieces):
                    val = FileText(val.paths, slice=True, each=val.each)
                else:
                    return Unknown("subscript of non-file value", file=is_fileish(val))
                pos = end + 1
                continue
            if t.kind == "op" and t.value == "." and pos + 1 < len(toks) and toks[pos + 1].kind == "ident":
                name = toks[pos + 1].value
                pos += 2
                args: list[list[Tok]] = []
                if pos < len(toks) and toks[pos].kind == "op" and toks[pos].value == "(":
                    end = matching(toks, pos)
                    if end < 0:
                        return Unknown("unbalanced call")
                    args = split_top(toks[pos + 1 : end], ",") if end > pos + 1 else []
                    pos = end + 1
                val = self._member(val, name, args, scope)
                continue
            return Unknown(f"unsupported postfix {t.value!r}", file=is_fileish(val))
        return val

    def mentions_file(self, toks: list[Tok], scope: "Scopes") -> bool:
        for t in toks:
            if t.kind == "ident":
                bound = scope.lookup(t.value)
                if bound is not None and is_fileish(bound):
                    return True
        return False

    def _member(self, val: Value, name: str, args: list[list[Tok]], scope: "Scopes") -> Value:
        if isinstance(val, UrlVal):
            if name == "deletingLastPathComponent" and not args:
                return UrlVal(val.path.parent)
            if name in ("appendingPathComponent", "appending") and args:
                arg = strip_label(args[0], ("path", "component"))
                s = self.eval(arg, scope)
                if isinstance(s, StrVal) and len(s.values) == 1:
                    return UrlVal(val.path / s.values[0])
                return Unknown("non-literal path component")
            if name in ("standardizedFileURL", "resolvingSymlinksInPath", "absoluteURL") and not args:
                return val
            if name == "path" and not args:
                return val  # treat URL.path as URL for contentsOfFile
            return Unknown(f"unsupported URL member {name}")
        if isinstance(val, FileText):
            if name == "components" and len(args) == 1 and arg_label(args[0])[0] == "separatedBy":
                return Pieces(val.paths, val.each)
            return Unknown(f"transform .{name} on file text", file=True)
        if isinstance(val, Pieces):
            if name in ("dropFirst", "dropLast", "prefix", "suffix") and len(args) <= 1:
                return val
            if name in ("first", "last") and not args:
                return FileText(val.paths, slice=True, each=val.each)
            return Unknown(f"transform .{name} on file pieces", file=True)
        return Unknown(f"member .{name} on unresolved value", file=is_fileish(val))

    def _primary(self, toks: list[Tok], scope: "Scopes") -> tuple[Value, int]:
        t = toks[0]
        if t.kind == "str":
            if t.value is None:
                return Unknown("interpolated literal"), 1
            return StrVal((t.value,)), 1
        if t.kind == "op" and t.value == "(":
            end = matching(toks, 0)
            if end < 0:
                return Unknown("unbalanced paren"), len(toks)
            return self.eval(toks[1:end], scope), end + 1
        if t.kind == "op" and t.value == "[":
            end = matching(toks, 0)
            items = split_top(toks[1:end], ",") if end > 1 else []
            vals = [self.eval(it, scope) for it in items]
            if vals and all(isinstance(v, StrVal) and len(v.values) == 1 for v in vals):
                return ("strlist", tuple(v.values[0] for v in vals)), end + 1  # type: ignore[return-value]
            return Unknown("array literal"), end + 1
        if t.kind != "ident":
            return Unknown(f"unsupported token {t.value!r}"), len(toks)
        name = t.value
        # call?
        if len(toks) > 1 and toks[1].kind == "op" and toks[1].value == "(":
            end = matching(toks, 1)
            if end < 0:
                return Unknown("unbalanced call"), len(toks)
            args = split_top(toks[2:end], ",") if end > 2 else []
            return self._call(name, args, scope), end + 1
        if name == "#filePath" or name == "#file":
            return Unknown("bare #filePath"), 1
        bound = scope.lookup(name)
        if bound is None:
            if name in self.url_funcs:
                return self.url_funcs[name], 1  # computed property
            if name in self.readers_fixed:
                return self.readers_fixed[name], 1
            return Unknown(f"unbound identifier {name}"), 1
        return bound, 1

    def _call(self, name: str, args: list[list[Tok]], scope: "Scopes") -> Value:
        if name == "repoFixtureURL" and args:
            s = self.eval(args[0], scope)
            if isinstance(s, StrVal) and len(s.values) == 1:
                return UrlVal(self.root / s.values[0])
            return Unknown("repoFixtureURL non-literal")
        if name == "URL" and args:
            label, rest = arg_label(args[0])
            if label == "fileURLWithPath":
                if len(rest) == 1 and rest[0].kind == "ident" and rest[0].value in ("#filePath", "#file"):
                    return UrlVal(self.test_file)
                text = " ".join(str(x.value) for x in rest)
                if text.replace(" ", "") == "FileManager.default.currentDirectoryPath":
                    return UrlVal(self.root)
                s = self.eval(rest, scope)
                if isinstance(s, StrVal) and len(s.values) == 1 and not s.values[0].startswith("/"):
                    return UrlVal(self.root / s.values[0])
            return Unknown("unsupported URL(...)")
        if name == "String" and args:
            label, rest = arg_label(args[0])
            if label in ("contentsOf", "contentsOfFile"):
                u = self.eval(rest, scope)
                if isinstance(u, StrVal) and len(u.values) == 1 and label == "contentsOfFile":
                    return self._root_rel(u.values[0])
                if isinstance(u, UrlVal):
                    return self._file(u)
                return Unknown("String(contentsOf:) of unresolved URL")
            if label is None and len(args) == 1:
                inner = self.eval(rest, scope)
                if isinstance(inner, FileText):
                    return dc_replace(inner, slice=True)
                return Unknown("unsupported String(...)", file=is_fileish(inner))
            return Unknown("unsupported String(...)")
        if name in PASSTHROUGH_CALLS and len(args) == 1 and arg_label(args[0])[0] is None:
            return self.eval(args[0], scope)
        if name in KNOWN_ROOT_READERS or self.readers_path.get(name) == "root":
            if args:
                s = self.eval(strip_label(args[0], ()), scope)
                if isinstance(s, StrVal) and len(s.values) == 1:
                    return self._root_rel(s.values[0])
                if isinstance(s, StrVal) and len(s.values) > 1:
                    files = [self._root_rel(v) for v in s.values]
                    if all(isinstance(f, FileText) for f in files):
                        return FileText(tuple(f.paths[0] for f in files), each=True)
            return Unknown(f"{name} with non-literal path")
        if name in self.readers_fixed and all(arg_label(a)[0] in ("file", "line") for a in args):
            return self.readers_fixed[name]
        if name in self.url_funcs and not args:
            return self.url_funcs[name]
        helper = self.slice_helpers.get(name)
        if helper is not None and helper.text_index < len(args):
            arg = args[helper.text_index]
            label, rest = arg_label(arg)
            if label == helper.labels[helper.text_index] or (label is None and helper.labels[helper.text_index] is None):
                inner = self.eval(rest, scope)
                if isinstance(inner, FileText):
                    return dc_replace(inner, slice=True)
                return Unknown(f"slice helper {name} of unresolved text", file=is_fileish(inner))
        arg_vals = [self.eval(arg_label(a)[1], scope) for a in args]
        return Unknown(f"call to {name}", file=any(is_fileish(v) for v in arg_vals))


BINARY_OPS = {"&&", "||", "==", "!=", "??", "?", ":", "<", ">", "...", "..<", "-", "*", "/"}


def has_top_level_operator(toks: list[Tok]) -> bool:
    depth = 0
    for idx, t in enumerate(toks):
        if t.kind == "op" and t.value in OPEN:
            depth += 1
        elif t.kind == "op" and t.value in CLOSE:
            depth -= 1
        elif depth == 0 and t.kind == "op" and t.value in BINARY_OPS:
            nxt = toks[idx + 1] if idx + 1 < len(toks) else None
            if t.value == "?" and nxt is not None and nxt.kind == "op" and nxt.value in (".", "[", "("):
                continue  # optional chaining, not a ternary
            if t.value == "?" and nxt is None:
                continue
            return True
    return False


def is_fileish(val: Value) -> bool:
    return isinstance(val, (FileText, Pieces)) or (isinstance(val, Unknown) and val.file)


def arg_label(arg: list[Tok]) -> tuple[Optional[str], list[Tok]]:
    if len(arg) >= 2 and arg[0].kind == "ident" and arg[1].kind == "op" and arg[1].value == ":":
        return arg[0].value, arg[2:]
    return None, arg


def strip_label(arg: list[Tok], labels) -> list[Tok]:
    label, rest = arg_label(arg)
    if label is not None and (not labels or label in labels):
        return rest
    return arg


OPEN = {"(": ")", "[": "]", "{": "}"}
CLOSE = {v: k for k, v in OPEN.items()}


def matching(toks: list[Tok], start: int) -> int:
    opener = toks[start].value
    closer = OPEN[opener]
    depth = 0
    for i in range(start, len(toks)):
        t = toks[i]
        if t.kind != "op":
            continue
        if t.value in OPEN:
            depth += 1
        elif t.value in CLOSE:
            depth -= 1
            if depth == 0:
                return i if t.value == closer else -1
    return -1


def depth_at(toks: list[Tok], idx: int) -> int:
    depth = 0
    for i in range(idx):
        t = toks[i]
        if t.kind == "op" and t.value in OPEN:
            depth += 1
        elif t.kind == "op" and t.value in CLOSE:
            depth -= 1
    return depth


def split_top(toks: list[Tok], sep: str) -> list[list[Tok]]:
    parts: list[list[Tok]] = [[]]
    depth = 0
    for t in toks:
        if t.kind == "op" and t.value in OPEN:
            depth += 1
        elif t.kind == "op" and t.value in CLOSE:
            depth -= 1
        if depth == 0 and t.kind == "op" and t.value == sep:
            parts.append([])
            continue
        parts[-1].append(t)
    return parts


# --------------------------------------------------------------------------- scopes


class Scopes:
    def __init__(self, globals_: dict):
        self.stack: list[dict] = [dict(globals_)]

    def push(self, bindings: Optional[dict] = None) -> None:
        self.stack.append(dict(bindings or {}))

    def pop(self) -> None:
        if len(self.stack) > 1:
            self.stack.pop()

    def bind(self, name: str, value: Value) -> None:
        self.stack[-1][name] = value

    def lookup(self, name: str) -> Optional[Value]:
        for frame in reversed(self.stack):
            if name in frame:
                return frame[name]
        return None


# --------------------------------------------------------------------------- pins


@dataclass
class Pin:
    test_file: str
    line: int
    target_paths: tuple[str, ...]
    needle: str
    positive: bool
    slice: bool
    each: bool = False


@dataclass
class Stats:
    resolved: int = 0
    unresolved: Counter = field(default_factory=Counter)  # file-backed receivers we could not prove
    runtime: Counter = field(default_factory=Counter)  # receivers never read from a repo file
    skipped_negative_slice: int = 0

    @property
    def unresolved_total(self) -> int:
        return sum(self.unresolved.values())

    @property
    def runtime_total(self) -> int:
        return sum(self.runtime.values())


ASSERT_POS = {"assertTrue", "XCTAssertTrue", "XCTAssert", "precondition"}
ASSERT_NEG = {"assertFalse", "XCTAssertFalse"}
ASSERT_NONNIL = {"assertNotNil", "XCTAssertNotNil", "XCTUnwrap"}
ASSERT_NIL = {"assertNil", "XCTAssertNil"}
ASSERT_ALL = ASSERT_POS | ASSERT_NEG | ASSERT_NONNIL | ASSERT_NIL


def statement_end(toks: list[Tok], start: int, stop_at_brace: bool = False) -> int:
    """Index one past the end of the expression starting at ``start``."""
    depth = 0
    i = start
    cont_ops = {".", "??", "+", "&&", "||", "-", "*", "==", "!=", "?", ":", "..<", "..."}
    while i < len(toks):
        t = toks[i]
        if t.kind == "op" and t.value in OPEN:
            if t.value == "{" and depth == 0 and stop_at_brace:
                return i
            depth += 1
        elif t.kind == "op" and t.value in CLOSE:
            if depth == 0:
                return i
            depth -= 1
        elif depth == 0:
            if t.kind == "op" and t.value == ";":
                return i
            if stop_at_brace and ((t.kind == "op" and t.value == ",") or (t.kind == "ident" and t.value == "else")):
                return i
            if i > start and t.nl_before:
                prev = toks[i - 1]
                continues = (t.kind == "op" and t.value in cont_ops) or (
                    prev.kind == "op" and prev.value in cont_ops | {"=", ",", "("}
                )
                if not continues:
                    return i
        i += 1
    return i


PATTERN_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


@dataclass
class Registry:
    """Helpers discovered in one test file."""

    readers_path: dict = field(default_factory=dict)  # name -> "root": f("rel/path") reads <root>/rel/path
    readers_fixed: dict = field(default_factory=dict)  # name -> FileText: f() reads one fixed file
    url_funcs: dict = field(default_factory=dict)  # name -> UrlVal: f() / computed property returning a URL
    slice_helpers: dict = field(default_factory=dict)  # name -> SliceHelper
    rejected: set = field(default_factory=set)
    private: set = field(default_factory=set)

    def names(self) -> set:
        return set(self.readers_path) | set(self.readers_fixed) | set(self.url_funcs) | set(self.slice_helpers)


class Extractor:
    def __init__(self, repo_root: Path):
        self.root = repo_root
        self.stats = Stats()
        self.pins: list[Pin] = []
        self.unresolved_detail: list[tuple[str, int, str]] = []
        self.regs: dict[Path, Registry] = {}
        self.definitions: Counter = Counter()  # helper name -> number of files defining it

    def view(self, path: Path) -> Registry:
        """Own-file helpers, plus non-private helpers defined in exactly one other file."""
        merged = Registry()
        for other, reg in self.regs.items():
            if other == path:
                continue
            for attr in ("readers_path", "readers_fixed", "url_funcs", "slice_helpers"):
                for name, value in getattr(reg, attr).items():
                    if self.definitions[name] == 1 and name not in reg.private:
                        getattr(merged, attr)[name] = value
        own = self.regs.get(path)
        if own is not None:
            # A same-named helper in this file always shadows the global one.
            for name in own.names() | own.rejected:
                for attr in ("readers_path", "readers_fixed", "url_funcs", "slice_helpers"):
                    getattr(merged, attr).pop(name, None)
            for attr in ("readers_path", "readers_fixed", "url_funcs", "slice_helpers"):
                getattr(merged, attr).update(getattr(own, attr))
        return merged

    def resolver(self, path: Path) -> "Resolver":
        v = self.view(path)
        return Resolver(self.root, path, v.readers_path, v.readers_fixed, v.url_funcs, v.slice_helpers)

    # -- helper discovery (functions and computed properties across all test files)
    def discover_helpers(self, files: list[Path], sources: dict[Path, list[Tok]]) -> None:
        for path in files:
            self.regs[path] = Registry()
            seen: set[str] = set()
            for name, _private in self._declarations(sources[path]):
                seen.add(name)
                if _private:
                    self.regs[path].private.add(name)
            for name in seen:
                self.definitions[name] += 1
        for _ in range(2):  # second pass lets helpers call helpers defined later
            for path in files:
                self._discover_in(path, sources[path])

    @staticmethod
    def _declarations(toks: list[Tok]):
        for i, t in enumerate(toks[:-1]):
            if t.kind == "ident" and t.value in ("func", "var") and toks[i + 1].kind == "ident":
                private = False
                k = i
                while k > 0 and not toks[k].nl_before:  # modifiers on the same line
                    k -= 1
                    if toks[k].kind == "ident" and toks[k].value in ("private", "fileprivate"):
                        private = True
                yield toks[i + 1].value, private

    def _discover_in(self, path: Path, toks: list[Tok]) -> None:
        reg = self.regs[path]
        i = 0
        while i < len(toks):
            t = toks[i]
            is_func = t.kind == "ident" and t.value == "func" and i + 2 < len(toks) and toks[i + 1].kind == "ident"
            is_prop = (
                t.kind == "ident" and t.value == "var" and i + 3 < len(toks) and toks[i + 1].kind == "ident"
                and toks[i + 2].kind == "op" and toks[i + 2].value == ":"
            )
            if not (is_func or is_prop):
                i += 1
                continue
            name = toks[i + 1].value
            j = i + 2
            params: list[tuple[str, bool, bool, Optional[str]]] = []  # (internal, is_string, has_default, label)
            if is_func:
                if j < len(toks) and toks[j].kind == "op" and toks[j].value == "<":
                    while j < len(toks) and not (toks[j].kind == "op" and toks[j].value == ">"):
                        j += 1
                    j += 1
                if j >= len(toks) or toks[j].value != "(":
                    i += 1
                    continue
                pend = matching(toks, j)
                if pend < 0:
                    i += 1
                    continue
                for p in split_top(toks[j + 1 : pend], ","):
                    colon = next((k for k, x in enumerate(p) if x.kind == "op" and x.value == ":"), None)
                    if colon is None or colon == 0:
                        continue
                    internal = p[colon - 1].value
                    external = p[colon - 2].value if colon >= 2 and p[colon - 2].kind == "ident" else internal
                    type_toks = p[colon + 1 :]
                    has_default = any(x.kind == "op" and x.value == "=" for x in type_toks)
                    is_string = bool(type_toks) and type_toks[0].value in ("String", "Substring")
                    params.append((internal, is_string, has_default, None if external == "_" else external))
                j = pend + 1
            returns_string = False
            k = j
            while k < len(toks) and not (toks[k].kind == "op" and toks[k].value in ("{", "}")):
                if toks[k].kind == "op" and toks[k].value == "->" and k + 1 < len(toks):
                    returns_string = toks[k + 1].value in ("String", "Substring")
                k += 1
            # find body
            while j < len(toks) and not (toks[j].kind == "op" and toks[j].value == "{"):
                if toks[j].kind == "op" and toks[j].value in ("}", "="):
                    break
                j += 1
            if j >= len(toks) or toks[j].value != "{":
                i += 1
                continue
            bend = matching(toks, j)
            if bend < 0:
                i += 1
                continue
            body = toks[j + 1 : bend]
            self._classify_helper(path, reg, name, params, body, is_prop)
            if returns_string and is_func:
                self._classify_slice_helper(reg, name, params, body)
            i = bend + 1

    def _classify_slice_helper(self, reg: Registry, name: str, params, body: list[Tok]) -> None:
        """Record helpers that provably return a substring of one String parameter.

        Pure means: no identifier from NON_SLICE_IDENTS, no ``+``/``+=``, no
        non-empty string literal in any returned expression, no other parameter
        in a returned expression, and exactly one String parameter is the
        receiver of ``range(of:)`` / ``components`` / a subscript.
        """
        if name in reg.slice_helpers or name in reg.rejected:
            return

        def reject() -> None:
            reg.rejected.add(name)

        string_params = [idx for idx, p in enumerate(params) if p[1]]
        if not string_params:
            return
        if any(t.kind == "ident" and t.value in NON_SLICE_IDENTS for t in body) or any(
            t.kind == "op" and t.value in ("+", "+=") for t in body
        ):
            return reject()
        text_candidates = []
        for idx in string_params:
            pname = params[idx][0]
            for k, t in enumerate(body[:-1]):
                if t.kind == "ident" and t.value == pname:
                    nxt = body[k + 1]
                    if (nxt.kind == "op" and nxt.value == "[") or (
                        nxt.value == "." and k + 2 < len(body) and body[k + 2].value in ("range", "components", "firstRange", "index", "endIndex", "startIndex")
                    ):
                        text_candidates.append(idx)
                        break
        if len(text_candidates) != 1:
            return reject()
        text_idx = text_candidates[0]
        stmts = split_statements(body)
        returns = [st[1:] for st in iter_returns(body)]
        if not returns and len(stmts) == 1:
            returns = [stmts[0]]
        if not returns:
            return reject()
        other_params = {params[i][0] for i in range(len(params)) if i != text_idx}
        for ret in returns:
            if any(t.kind == "str" and t.value != "" for t in ret):
                return reject()
            if {t.value for t in ret if t.kind == "ident"} & other_params:
                return reject()
        reg.slice_helpers[name] = SliceHelper(text_idx, tuple(p[3] for p in params))

    def _classify_helper(self, path: Path, reg: Registry, name: str, params, body: list[Tok], is_prop: bool) -> None:
        if name in reg.readers_path or name in reg.readers_fixed or name in reg.url_funcs:
            return
        required = [p for p in params if not p[2]]
        # Evaluate the body statements with parameters left unbound.
        resolver = self.resolver(path)
        scopes = Scopes({})
        param_names = {p[0] for p in params}
        stmts = []
        for stmt in split_statements(body):
            if not stmt:
                continue
            if is_memo_lookup(stmt, param_names) or is_memo_store(stmt, param_names):
                continue  # `if let hit = cache[path] { return hit }` / `cache[path] = text`
            if stmt[0].kind == "ident" and stmt[0].value in ("do", "guard", "if", "catch", "switch", "for", "while", "defer"):
                return  # control flow: too clever for us, stay unresolved
            stmts.append(stmt)
        ret: Optional[list[Tok]] = None
        for idx, stmt in enumerate(stmts):
            if stmt[0].kind == "ident" and stmt[0].value in ("let", "var") and len(stmt) > 3 and stmt[2].value in ("=", ":"):
                eq = next((k for k, x in enumerate(stmt) if x.kind == "op" and x.value == "="), None)
                if eq is None:
                    return
                scopes.bind(stmt[1].value, resolver.eval(stmt[eq + 1 :], scopes))
            elif stmt[0].kind == "ident" and stmt[0].value == "return":
                if idx != len(stmts) - 1:
                    return
                ret = stmt[1:]
            elif len(stmts) == 1:
                ret = stmt  # implicit return of a single expression
            else:
                return  # an unknown statement could mutate what we return
        if ret is None:
            return
        if not required:
            val = resolver.eval(ret, scopes)
            if isinstance(val, FileText) and not val.slice and not val.each:
                reg.readers_fixed[name] = val
            elif isinstance(val, UrlVal):
                reg.url_funcs[name] = val
            return
        if len(required) == 1 and required[0][1] and not is_prop:
            param = required[0][0]
            # Evaluate with the param bound to a sentinel path; the helper is a
            # root-relative reader if it reads exactly <root>/<sentinel>.
            sentinel = "__PIN_SENTINEL__/x.txt"
            probe = SentinelResolver(resolver, sentinel)
            pscopes = Scopes({param: StrVal((sentinel,))})
            for stmt in stmts:
                if stmt and stmt[0].kind == "ident" and stmt[0].value in ("let", "var"):
                    eq = next((k for k, x in enumerate(stmt) if x.kind == "op" and x.value == "="), None)
                    if eq is not None:
                        pscopes.bind(stmt[1].value, probe.eval(stmt[eq + 1 :], pscopes))
            val = probe.eval(ret, pscopes)
            if isinstance(val, FileText) and val.paths == (sentinel,) and not val.slice:
                reg.readers_path[name] = "root"


class SentinelResolver(Resolver):
    """Resolver that accepts one fake path so helper bodies can be probed."""

    def __init__(self, base: Resolver, sentinel: str):
        super().__init__(base.root, base.test_file, base.readers_path, base.readers_fixed, base.url_funcs, base.slice_helpers)
        self.sentinel = sentinel

    def _file(self, url: UrlVal) -> Value:
        try:
            rel = url.path.relative_to(self.root)
        except ValueError:
            return Unknown("outside")
        if rel.as_posix() == self.sentinel:
            return FileText((self.sentinel,))
        return super()._file(url)


def iter_returns(body: list[Tok]):
    """Yield every ``return ...`` statement anywhere in a body (nested blocks too)."""
    for k, t in enumerate(body):
        if t.kind == "ident" and t.value == "return":
            end = statement_end(body, k + 1) if k + 1 < len(body) else k + 1
            if k + 1 < len(body) and body[k + 1].nl_before:
                end = k + 1  # bare `return` followed by a new statement
            yield body[k:end]


def is_memo_lookup(stmt: list[Tok], param_names: set[str]) -> bool:
    """``if let hit = cache[param] { return hit }``"""
    vals = [t.value for t in stmt]
    return (
        len(vals) == 12
        and vals[0] == "if" and vals[1] == "let" and vals[3] == "=" and vals[5] == "["
        and vals[6] in param_names and vals[7] == "]" and vals[8] == "{" and vals[9] == "return"
        and vals[10] == vals[2] and vals[11] == "}"
    )


def is_memo_store(stmt: list[Tok], param_names: set[str]) -> bool:
    """``cache[param] = value``"""
    vals = [t.value for t in stmt]
    return len(vals) == 6 and vals[1] == "[" and vals[2] in param_names and vals[3] == "]" and vals[4] == "=" and stmt[5].kind == "ident"


def split_statements(body: list[Tok]) -> list[list[Tok]]:
    stmts: list[list[Tok]] = []
    i = 0
    while i < len(body):
        end = statement_end(body, i)
        if end == i:
            end = i + 1
        stmts.append(body[i:end])
        i = end
        if i < len(body) and body[i].kind == "op" and body[i].value == ";":
            i += 1
    return stmts


# --------------------------------------------------------------------------- per-file walk


class FileWalker:
    def __init__(self, ex: Extractor, path: Path, toks: list[Tok]):
        self.ex = ex
        self.path = path
        self.rel = path.relative_to(ex.root).as_posix() if path.is_relative_to(ex.root) else path.name
        self.toks = toks
        self.resolver = ex.resolver(path)
        self.scopes = Scopes({})
        self.pending: dict = {}

    def unresolved(self, line: int, reason: str, file: bool = True) -> None:
        if file:
            self.ex.stats.unresolved[reason] += 1
        else:
            self.ex.stats.runtime[reason] += 1
        self.ex.unresolved_detail.append((self.rel, line, reason if file else "runtime: " + reason))

    def walk(self) -> None:
        toks = self.toks
        i = 0
        while i < len(toks):
            t = toks[i]
            if t.kind == "op" and t.value == "{":
                self.scopes.push(self.pending)
                self.pending = {}
                # closure parameters: `{ a, b in` / `{ (a: T) in` / `{ [weak self] x in`
                k = i + 1
                names: list[str] = []
                while k < len(toks) and k - i < 40:
                    x = toks[k]
                    if x.nl_before:
                        break  # closure parameters sit on the `{` line
                    if x.kind == "ident" and x.value == "in":
                        for nm in names:
                            self.scopes.bind(nm, Unknown("closure parameter"))
                        break
                    if x.kind == "ident":
                        names.append(x.value)
                    elif not (x.kind == "op" and x.value in "()[],:_?<>!."):
                        break
                    k += 1
                i += 1
                continue
            if t.kind == "op" and t.value == "}":
                self.scopes.pop()
                i += 1
                continue
            if t.kind == "ident" and t.value == "func":
                i = self._func_params(i)
                continue
            if t.kind == "ident" and t.value == "for" and self._starts_statement(i):
                i = self._for_loop(i)
                continue
            if t.kind == "ident" and t.value == "guard" and self._starts_statement(i):
                self._guard_pins(i)
                i += 1
                continue
            if t.kind == "ident" and t.value in ("let", "var") and not self._is_label(i):
                i = self._binding(i)
                continue
            if t.kind == "ident" and t.value in ASSERT_ALL and i + 1 < len(toks) and toks[i + 1].value == "(":
                i = self._assertion(i)
                continue
            i += 1

    def _is_label(self, i: int) -> bool:
        """`for:` / `in:` / `let:` used as an argument label, not a keyword."""
        nxt = self.toks[i + 1] if i + 1 < len(self.toks) else None
        return nxt is not None and nxt.kind == "op" and nxt.value == ":"

    def _starts_statement(self, i: int) -> bool:
        if self._is_label(i):
            return False
        t = self.toks[i]
        if t.nl_before or i == 0:
            return True
        prev = self.toks[i - 1]
        return prev.kind == "op" and prev.value in ("{", ";", "}")

    def _func_params(self, i: int) -> int:
        toks = self.toks
        j = i + 2
        while j < len(toks) and not (toks[j].kind == "op" and toks[j].value in ("(", "{")):
            j += 1
        if j >= len(toks) or toks[j].value != "(":
            return i + 1
        end = matching(toks, j)
        if end < 0:
            return i + 1
        for p in split_top(toks[j + 1 : end], ","):
            colon = next((k for k, x in enumerate(p) if x.kind == "op" and x.value == ":"), None)
            if colon:
                self.pending[p[colon - 1].value] = Unknown("function parameter")
        return end + 1

    def _for_loop(self, i: int) -> int:
        toks = self.toks
        j = i + 1
        if j < len(toks) and toks[j].kind == "ident" and toks[j].value == "case":
            return i + 1
        pat_start = j
        while j < len(toks) and not (toks[j].kind == "ident" and toks[j].value == "in"):
            if toks[j].nl_before or (toks[j].kind == "op" and toks[j].value in ("{", "=", "}")):
                return i + 1  # not a for-in header we understand
            j += 1
        if j >= len(toks):
            return i + 1
        pattern = toks[pat_start:j]
        seq_start = j + 1
        k = seq_start
        depth = 0
        while k < len(toks):
            x = toks[k]
            if x.kind == "op" and x.value in ("(", "["):
                depth += 1
            elif x.kind == "op" and x.value in (")", "]"):
                depth -= 1
            elif x.kind == "op" and x.value == "{" and depth == 0:
                break
            elif x.kind == "ident" and x.value == "where" and depth == 0:
                break
            k += 1
        seq = toks[seq_start:k]
        names = [x.value for x in pattern if x.kind == "ident"]
        bindings: dict = {nm: Unknown("loop variable") for nm in names}
        if len(seq) >= 2 and seq[0].value == "[" and matching(seq, 0) == len(seq) - 1:
            items = split_top(seq[1:-1], ",")
            items = [it for it in items if it]
            if len(names) == 1 and pattern[0].kind == "ident":
                vals = [self.resolver.eval(it, self.scopes) for it in items]
                bound = self._loop_column(vals)
                if bound is not None:
                    bindings[names[0]] = bound
            elif pattern and pattern[0].value == "(":
                slots = split_top(pattern[1:-1], ",")
                columns: list[list[Value]] = [[] for _ in slots]
                ok = True
                for it in items:
                    if not it or it[0].value != "(" or matching(it, 0) != len(it) - 1:
                        ok = False
                        break
                    fields = split_top(it[1:-1], ",")
                    if len(fields) != len(slots):
                        ok = False
                        break
                    for idx, fld in enumerate(fields):
                        columns[idx].append(self.resolver.eval(strip_label(fld, ()), self.scopes))
                if ok:
                    for idx, slot in enumerate(slots):
                        slot_names = [x.value for x in slot if x.kind == "ident"]
                        if len(slot_names) != 1:
                            continue
                        bound = self._loop_column(columns[idx])
                        if bound is not None:
                            bindings[slot_names[0]] = bound
        self.pending.update(bindings)
        return k

    @staticmethod
    def _loop_column(vals: list) -> Optional[Value]:
        """A loop variable over literals is a multi-valued StrVal; over file texts, an `each` FileText."""
        if vals and all(isinstance(v, StrVal) and len(v.values) == 1 for v in vals):
            return StrVal(tuple(v.values[0] for v in vals))
        if vals and all(isinstance(v, FileText) and not v.each for v in vals):
            if any(len(v.paths) != 1 for v in vals):
                return None
            return FileText(tuple(v.paths[0] for v in vals), slice=any(v.slice for v in vals), each=True)
        return None

    def _binding(self, i: int) -> int:
        toks = self.toks
        prev = toks[i - 1] if i else None
        conditional = prev is not None and prev.kind == "ident" and prev.value in ("if", "guard", "while", "case")
        if prev is not None and prev.kind == "op" and prev.value == ",":
            conditional = True
        j = i + 1
        if j >= len(toks):
            return j
        if toks[j].kind == "op" and toks[j].value == "(":
            end = matching(toks, j)
            for x in toks[j:end]:
                if x.kind == "ident":
                    self.scopes.bind(x.value, Unknown("tuple binding"))
            return end + 1 if end > 0 else j + 1
        if toks[j].kind != "ident":
            return j
        name = toks[j].value
        k = j + 1
        # optional type annotation
        if k < len(toks) and toks[k].kind == "op" and toks[k].value == ":":
            k += 1
            depth = 0
            while k < len(toks):
                x = toks[k]
                if x.kind == "op" and x.value in ("<", "[", "("):
                    depth += 1
                elif x.kind == "op" and x.value in (">", "]", ")"):
                    depth -= 1
                elif depth <= 0 and x.kind == "op" and x.value in ("=", "{"):
                    break
                elif depth <= 0 and x.nl_before:
                    break
                k += 1
        if k >= len(toks) or not (toks[k].kind == "op" and toks[k].value == "="):
            # declaration without initializer, or computed property
            if k < len(toks) and toks[k].kind == "op" and toks[k].value == "{":
                bend = matching(toks, k)
                body = toks[k + 1 : bend] if bend > 0 else []
                val = self.resolver.eval(body, self.scopes) if body else Unknown("empty getter")
                self.scopes.bind(name, val)
                return k  # walk into the body normally so scopes stay balanced
            self.scopes.bind(name, Unknown("uninitialised declaration"))
            return k
        start = k + 1
        end = statement_end(toks, start, stop_at_brace=conditional)
        expr = toks[start:end]
        val = self.resolver.eval(expr, self.scopes)
        if isinstance(val, tuple):
            val = StrVal(val[1]) if val[0] == "strlist" else Unknown("array")
        if conditional and prev is not None and prev.kind == "ident" and prev.value == "if":
            self.pending[name] = val
        else:
            self.scopes.bind(name, val)
        # keep walking inside the expression (nested closures, assertions)
        return start

    GUARD_FAILURE_MARKERS = ("XCTFail", "fatalError", "preconditionFailure", "assertionFailure")

    def _guard_pins(self, i: int) -> None:
        """``guard let r = text.range(of: "x") else { XCTFail(...) }`` pins "x"."""
        toks = self.toks
        depth = 0
        k = i + 1
        while k < len(toks):
            x = toks[k]
            if x.kind == "op" and x.value in OPEN:
                depth += 1
            elif x.kind == "op" and x.value in CLOSE:
                depth -= 1
                if depth < 0:
                    return
            elif depth == 0 and x.kind == "ident" and x.value == "else":
                break
            k += 1
        else:
            return
        if k + 1 >= len(toks) or toks[k + 1].value != "{":
            return
        bend = matching(toks, k + 1)
        if bend < 0:
            return
        block = toks[k + 2 : bend]
        fails = False
        for idx, x in enumerate(block):
            if x.kind == "ident" and x.value in self.GUARD_FAILURE_MARKERS:
                fails = True
            if x.kind == "ident" and x.value in ("assertTrue", "assertFalse") and idx + 2 < len(block):
                if block[idx + 2].value == ("false" if x.value == "assertTrue" else "true"):
                    fails = True
        if not fails:
            return
        for clause in split_top(toks[i + 1 : k], ","):
            if not clause:
                continue
            if clause[0].kind == "ident" and clause[0].value in ("let", "var"):
                if len(clause) < 4 or clause[2].value != "=":
                    continue
                self._range_atom(self.resolver.strip_wrappers(clause[3:]), must_exist=True)
            elif clause[0].kind == "ident" and clause[0].value == "case":
                continue
            else:
                self._bool(clause, True)

    # -- assertions
    def _assertion(self, i: int) -> int:
        toks = self.toks
        fn = toks[i].value
        end = matching(toks, i + 1)
        if end < 0:
            return i + 1
        args = split_top(toks[i + 2 : end], ",")
        if not args or not args[0]:
            return i + 2
        first = args[0]
        if fn in ASSERT_POS:
            self._bool(first, True)
        elif fn in ASSERT_NEG:
            self._bool(first, False)
        elif fn in ASSERT_NONNIL:
            self._range_atom(self.resolver.strip_wrappers(first), must_exist=True)
        elif fn in ASSERT_NIL:
            self._range_atom(self.resolver.strip_wrappers(first), must_exist=False)
        return i + 2  # continue walking inside (nested closures / bindings)

    def _bool(self, expr: list[Tok], must: bool) -> None:
        expr = self.resolver.strip_wrappers(expr)
        if not expr:
            return
        ors = split_top(expr, "||")
        if len(ors) > 1:
            if must:
                self._count_needles_unresolved(expr, "|| under a must-hold assertion")
            else:
                for part in ors:
                    self._bool(part, False)
            return
        ands = split_top(expr, "&&")
        if len(ands) > 1:
            if must:
                for part in ands:
                    self._bool(part, True)
            else:
                self._count_needles_unresolved(expr, "&& under a must-not-hold assertion")
            return
        if expr[0].kind == "op" and expr[0].value == "!":
            self._bool(expr[1:], not must)
            return
        if expr[0].kind == "op" and expr[0].value == "(" and matching(expr, 0) == len(expr) - 1:
            self._bool(expr[1:-1], must)
            return
        # `X.range(of: s) != nil` / `== nil`
        for op, exists in (("!=", True), ("==", False)):
            parts = split_top(expr, op)
            if len(parts) == 2 and len(parts[1]) == 1 and parts[1][0].value == "nil":
                self._range_atom(parts[0], must_exist=exists if must else not exists)
                return
        self._contains_atom(expr, must)

    def _receiver_call(self, expr: list[Tok], method: str) -> Optional[tuple[list[Tok], list[list[Tok]], int]]:
        """Split `RECV.method(ARGS)` (the call must end the expression)."""
        if len(expr) < 4 or not (expr[-1].kind == "op" and expr[-1].value == ")"):
            return None
        # find the '(' matching the final ')'
        depth = 0
        for k in range(len(expr) - 1, -1, -1):
            x = expr[k]
            if x.kind == "op" and x.value in CLOSE:
                depth += 1
            elif x.kind == "op" and x.value in OPEN:
                depth -= 1
                if depth == 0:
                    break
        else:
            return None
        if k < 2 or expr[k - 1].kind != "ident" or expr[k - 1].value != method or expr[k - 2].value != ".":
            return None
        recv = expr[: k - 2]
        args = split_top(expr[k + 1 : -1], ",")
        return recv, args, expr[k - 1].line

    def _contains_atom(self, expr: list[Tok], must: bool) -> None:
        call = self._receiver_call(expr, "contains")
        if call is None:
            if self._mentions_needle_call(expr):
                self._count_needles_unresolved(expr, "unsupported assertion shape")
            return
        recv, args, line = call
        if len(args) != 1 or arg_label(args[0])[0] is not None:
            return  # contains(where:) etc. — not a text pin
        self._record(recv, args[0], must, line)

    def _range_atom(self, expr: list[Tok], must_exist: bool) -> None:
        call = self._receiver_call(expr, "range")
        if call is None:
            if self._mentions_needle_call(expr):
                self._count_needles_unresolved(expr, "unsupported assertion shape")
            return
        recv, args, line = call
        if not args or arg_label(args[0])[0] != "of":
            return
        narrowed = False
        for extra in args[1:]:
            label, value = arg_label(extra)
            text = "".join(str(t.value) for t in value)
            if label == "range":
                narrowed = True  # a sub-range of the file: still sound for must-exist
            elif label == "options" and text in (".backwards", ".literal", "[.backwards]", "[.literal]", "[.backwards,.literal]", "[.literal,.backwards]"):
                continue
            else:
                self.unresolved(line, f"range(of:) with {label or 'unlabelled'} argument")
                return
        if narrowed and not must_exist:
            self.unresolved(line, "range(of:range:) must-not-exist")
            return
        self._record(recv, strip_label(args[0], ("of",)), must_exist, line)

    @staticmethod
    def _mentions_needle_call(expr: list[Tok]) -> bool:
        for k in range(len(expr) - 2):
            if expr[k].value == "." and expr[k + 1].value in ("contains", "range") and expr[k + 2].value == "(":
                return True
        return False

    def _count_needles_unresolved(self, expr: list[Tok], reason: str) -> None:
        file = self.resolver.mentions_file(expr, self.scopes) or any(
            t.kind == "ident" and (t.value in KNOWN_ROOT_READERS or t.value in self.resolver.readers_path or t.value in self.resolver.readers_fixed)
            for t in expr
        )
        for k in range(len(expr) - 2):
            if expr[k].value == "." and expr[k + 1].value in ("contains", "range") and expr[k + 2].value == "(":
                self.unresolved(expr[k].line, reason, file=file)

    def _record(self, recv: list[Tok], needle_toks: list[Tok], positive: bool, line: int) -> None:
        target = self.resolver.eval(recv, self.scopes)
        if isinstance(target, tuple):
            target = Unknown("array receiver")
        if not isinstance(target, FileText):
            reason = target.reason if isinstance(target, Unknown) else "receiver is not file text"
            self.unresolved(line, "receiver: " + reason, file=is_fileish(target))
            return
        needle = self.resolver.eval(needle_toks, self.scopes)
        if isinstance(needle, tuple):
            needle = Unknown("array needle")
        if not isinstance(needle, StrVal):
            reason = needle.reason if isinstance(needle, Unknown) else "needle is not a literal"
            self.unresolved(line, "needle: " + reason)
            return
        if not positive and target.slice:
            self.ex.stats.skipped_negative_slice += len(needle.values)
            return
        for value in needle.values:
            self.ex.stats.resolved += 1
            self.ex.pins.append(Pin(self.rel, line, target.paths, value, positive, target.slice, target.each))


# --------------------------------------------------------------------------- driver


def test_files(root: Path) -> list[Path]:
    out = []
    for path in sorted((root / "Tests").rglob("*.swift")):
        parts = path.relative_to(root).parts
        if ".build" in parts:
            continue
        out.append(path)
    return out


def extract(root: Path, files: list[Path]) -> Extractor:
    ex = Extractor(root)
    lexed: dict[Path, list[Tok]] = {}
    for path in files:
        try:
            lexed[path] = lex(path.read_text(encoding="utf-8", errors="replace"))
        except LexError as error:
            ex.stats.unresolved[f"lex error ({error})"] += 1
    ex.discover_helpers(list(lexed), lexed)
    for path, toks in lexed.items():
        FileWalker(ex, path, toks).walk()
    return ex


@dataclass
class Failure:
    pin: Pin
    kind: str  # "MISSING" or "PRESENT"


def evaluate(root: Path, pins: list[Pin], read: Callable[[str], Optional[str]]) -> list[Failure]:
    failures: list[Failure] = []
    cache: dict[str, Optional[str]] = {}
    for pin in pins:
        texts = []
        for p in pin.target_paths:
            if p not in cache:
                cache[p] = read(p)
            texts.append(cache[p])
        hits = [t is not None and pin.needle in t for t in texts]
        if pin.positive:
            missing = not all(hits) if pin.each else not any(hits)
            if missing:
                failures.append(Failure(pin, "MISSING"))
        elif any(hits):
            failures.append(Failure(pin, "PRESENT"))
    return failures


def changed_files(root: Path, base: str) -> Optional[set[str]]:
    def git(*args: str) -> Optional[str]:
        try:
            return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True, text=True).stdout
        except (subprocess.CalledProcessError, FileNotFoundError):
            return None

    merge_base = git("merge-base", base, "HEAD")
    if merge_base is None:
        return None
    diff = git("diff", "--name-only", merge_base.strip())
    untracked = git("ls-files", "--others", "--exclude-standard") or ""
    if diff is None:
        return None
    return {line.strip() for line in (diff + untracked).splitlines() if line.strip()}


def show(needle: str) -> str:
    text = needle.replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t").replace('"', '\\"')
    if len(text) > 160:
        text = text[:157] + "..."
    return f'"{text}"'


def run(root: Path, changed_only: Optional[str], verbose: bool) -> int:
    files = test_files(root)
    ex = extract(root, files)
    pins = ex.pins
    scope_note = "whole tree"
    if changed_only is not None:
        changed = changed_files(root, changed_only)
        if changed is None:
            print(f"check-source-pins: could not diff against {changed_only!r} (missing ref?)", file=sys.stderr)
            return 2
        pins = [p for p in pins if p.test_file in changed or any(t in changed for t in p.target_paths)]
        scope_note = f"changed vs {changed_only} ({len(changed)} changed files)"

    def read(rel: str) -> Optional[str]:
        try:
            return (root / rel).read_text(encoding="utf-8", errors="replace")
        except OSError:
            return None

    failures = evaluate(root, pins, read)
    targets = {t for p in ex.pins for t in p.target_paths}
    file_backed = ex.stats.resolved + ex.stats.unresolved_total + ex.stats.skipped_negative_slice
    pct = (100.0 * ex.stats.resolved / file_backed) if file_backed else 0.0
    print(
        f"check-source-pins: {len(files)} test files; {ex.stats.resolved} pins resolved across {len(targets)} target files "
        f"({pct:.0f}% of {file_backed} file-backed contains/range assertions); "
        f"{ex.stats.unresolved_total} file-backed unresolved, {ex.stats.skipped_negative_slice} negative-on-slice skipped; "
        f"{ex.stats.runtime_total} assertions on runtime values ignored"
    )
    print(f"  checked {len(pins)} pins ({scope_note})")
    if verbose:
        print("  file-backed but unresolved, by reason:")
        for reason, count in ex.stats.unresolved.most_common():
            print(f"    {count:5d}  {reason}")
        print("  ignored (receiver never read from a repo file), by reason:")
        for reason, count in ex.stats.runtime.most_common(15):
            print(f"    {count:5d}  {reason}")
    if failures:
        print(f"FAIL: {len(failures)} source pin(s) broken:")
        for f in failures:
            what = "needle missing from" if f.kind == "MISSING" else "forbidden needle now present in"
            print(f"  {f.kind}: {f.pin.test_file}:{f.pin.line} -> {what} {', '.join(f.pin.target_paths)}: {show(f.pin.needle)}")
        return 1
    print("PASS: every resolved source pin still holds.")
    return 0


# --------------------------------------------------------------------------- self-test

SELF_TEST_TARGET = """import Foundation
func startCapture() {
    let marker = "quoted \\"value\\""
    settleRoute()
    installTap()
}
"""

SELF_TEST_HELPERS = '''
func repoFixtureURL(_ relativePath: String) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(relativePath)
}

func readTargetSource(file: String = #file, line: Int = #line) -> String {
    readSourceFixture("Sources/Target.swift", description: "Target", file: file, line: line)
}

'''

SELF_TEST_TESTS = r'''
func testSelf() {
    let source = readSourceFixture("Sources/Target.swift")
    runSuite("positive pins") {
        assertTrue(source.contains("settleRoute()"), "ok")
        assertTrue(source.contains("settleRoute()\n    installTap()"), "multi-line escape ok")
        assertTrue(source.contains("let marker = \"quoted \\\"value\\\"\""), "escaped quotes ok")
        assertTrue(source.contains("MISSING_ONE"), "should be reported")
        XCTAssertNotNil(source.range(of: "installTap()"))
        XCTAssertTrue(source.range(of: "MISSING_TWO") != nil)
        assertTrue(source.contains("settle") && source.contains("MISSING_THREE"))
        assertTrue(source.contains("anything") || source.contains("else"), "or is unresolved")
        assertTrue(source.contains("""
            settleRoute()
                installTap()
            """.replacingOccurrences(of: "x", with: "y")), "transform unresolved")
        assertTrue(source.contains("""
        func startCapture() {
            let marker
        """), "multi-line literal ok")
        assertTrue(source.contains(#"let marker = "quoted \"value\"""#), "raw literal ok")
    }
    runSuite("negative pins") {
        assertFalse(source.contains("forbiddenCall()"), "ok")
        assertFalse(source.contains("installTap()"), "should be reported as present")
        assertTrue(!source.contains("settleRoute()"), "negated positive: present")
        XCTAssertNil(source.range(of: "nope"))
        assertFalse(source.contains("zzz") || source.contains("startCapture"), "or under false: each must be false")
    }
    runSuite("scoping and helpers") {
        let source = "shadowed text"
        assertTrue(source.contains("NOT_A_PIN"), "shadowed binding must not resolve to the file")
    }
    runSuite("outer binding visible again") {
        assertTrue(source.contains("MISSING_FOUR"))
        let fixed = readTargetSource()
        assertTrue(fixed.contains("MISSING_FIVE"))
        let local = localReader("Sources/Target.swift")
        assertTrue(local.contains("MISSING_SIX"))
        let viaURL = (try? String(contentsOf: repoFixtureURL("Sources/Target.swift"), encoding: .utf8)) ?? ""
        assertTrue(viaURL.contains("MISSING_SEVEN"))
        let stripped = stripComments(source)
        assertTrue(stripped.contains("TRANSFORMED_NOT_CHECKED"))
        let slice = sourceSlice(source, from: "a", to: "b")
        assertTrue(slice.contains("MISSING_EIGHT"))
        assertTrue(markerBlock(named: "func", in: source).contains("MISSING_TWELVE"))
        assertTrue(sneakyBlock(source, from: "x").contains("SNEAKY_NOT_CHECKED"))
        let pieces = source.components(separatedBy: "func startCapture()").dropFirst().first ?? ""
        assertTrue(pieces.contains("MISSING_THIRTEEN"))
        assertFalse(slice.contains("installTap()"), "negative on slice is skipped")
        for needle in ["settleRoute()", "MISSING_NINE"] {
            assertTrue(source.contains(needle), "loop needles")
        }
        for (needle, why) in [("installTap()", "a"), ("MISSING_TEN", "b")] {
            assertTrue(source.contains(needle), why)
        }
        let lowered = source.lowercased()
        assertTrue(lowered.contains("LOWER_NOT_CHECKED"))
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let chained = (try? String(contentsOf: root.appendingPathComponent("Sources/Target.swift"), encoding: .utf8)) ?? ""
        assertTrue(chained.contains("MISSING_ELEVEN"))
        assertTrue(source.contains("interp \(1)"), "interpolated needle is unresolved")
    }
}

private func localReader(_ relativePath: String) -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func stripComments(_ text: String) -> String {
    text.components(separatedBy: "|").map { $0 }.joined(separator: "|")
}
private func sourceSlice(_ text: String, from start: String, to end: String) -> String {
    guard let lower = text.range(of: start) else { return "" }
    let rest = text[lower.lowerBound...]
    guard let upper = rest.range(of: end) else { return String(rest) }
    return String(rest[..<upper.lowerBound])
}
private func markerBlock(named marker: String, in text: String) -> String {
    guard let lower = text.range(of: marker) else { return "" }
    return String(text[lower.lowerBound...])
}
private func sneakyBlock(_ text: String, from start: String) -> String {
    guard let lower = text.range(of: start) else { return "" }
    return String(text[lower.lowerBound...]) + start
}
'''


def self_test() -> int:
    import tempfile

    failures: list[str] = []
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "Sources").mkdir()
        (root / "Tests").mkdir()
        (root / "Sources" / "Target.swift").write_text(SELF_TEST_TARGET, encoding="utf-8")
        (root / "Tests" / "TestHelpers.swift").write_text(SELF_TEST_HELPERS, encoding="utf-8")
        (root / "Tests" / "SelfTests.swift").write_text(SELF_TEST_TESTS, encoding="utf-8")
        ex = extract(root, test_files(root))
        got = evaluate(root, ex.pins, lambda rel: (root / rel).read_text(encoding="utf-8") if (root / rel).exists() else None)
        got_set = sorted((f.kind, f.pin.needle) for f in got)
        want = sorted(
            [("MISSING", f"MISSING_{w}") for w in ["ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE", "TEN", "ELEVEN", "TWELVE", "THIRTEEN"]]
            + [("PRESENT", "installTap()"), ("PRESENT", "settleRoute()"), ("PRESENT", "startCapture")]
        )
        if got_set != want:
            failures.append(f"failures mismatch:\n    got  {got_set}\n    want {want}")
        resolved = [p.needle for p in ex.pins]
        failed = {n for _, n in got_set}
        for expected_ok, count in [
            ("settleRoute()\n    installTap()", 1),
            ('let marker = "quoted \\"value\\""', 2),  # escaped + raw literal
            ("func startCapture() {\n    let marker", 1),
            ("forbiddenCall()", 1),
            ("nope", 1),
            ("zzz", 1),
        ]:
            if resolved.count(expected_ok) != count or expected_ok in failed:
                failures.append(f"expected {count} resolved, passing pin(s) for {expected_ok!r}; got {resolved.count(expected_ok)}")
        for must_not in ["NOT_A_PIN", "TRANSFORMED_NOT_CHECKED", "LOWER_NOT_CHECKED", "SNEAKY_NOT_CHECKED", "anything", "else"]:
            if any(p.needle == must_not for p in ex.pins):
                failures.append(f"{must_not!r} should have stayed unresolved")
        if ex.stats.skipped_negative_slice != 1:
            failures.append(f"expected 1 negative-on-slice skip, got {ex.stats.skipped_negative_slice}")
        if ex.stats.unresolved_total < 5:
            failures.append(f"expected several unresolved atoms, got {dict(ex.stats.unresolved)}")

    # Lexer unit checks.
    toks = lex('let a = "x\\ny\\u{41}" // c "no"\nlet b = #"raw \\n"#')
    strs = [t.value for t in toks if t.kind == "str"]
    if strs != ["x\nyA", "raw \\n"]:
        failures.append(f"lexer strings: {strs}")
    ml = lex('let s = """\n    one \\\n    two\n      three\n    """\n')
    mls = [t.value for t in ml if t.kind == "str"]
    if mls != ["one two\n  three"]:
        failures.append(f"multi-line decode: {mls}")

    if failures:
        print("check-source-pins self-test FAILED:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("check-source-pins self-test passed.")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Check Swift source-text contract pins without Swift.")
    parser.add_argument("--self-test", action="store_true", help="run inline fixture tests")
    parser.add_argument(
        "--changed-only",
        nargs="?",
        const="origin/main",
        default=None,
        metavar="BASE",
        help="only check pins whose target or test file changed vs BASE (default origin/main)",
    )
    parser.add_argument("--verbose", "-v", action="store_true", help="list unresolved counts by reason")
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    return run(args.root.resolve(), args.changed_only, args.verbose)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Fast static check for same-scope duplicate Swift declarations.

Git auto-merges have repeatedly produced files that declare the same symbol
twice at the same scope -- e.g. `let remindSize = ...` bound twice in one
function, or a duplicate `@objc private func remindTapped()`. Those are real
Swift compile errors, but `swift -frontend -parse` (syntax-only) does NOT catch
them, so they slipped past the fast checks and only surfaced in the 15-25 min
Xcode build. This script is a heuristic, high-precision static scan that flags
the two most common merge-collision shapes in seconds:

  1. A `let`/`var` binding with an identical name declared twice in the *same*
     brace scope (same function body, same type body, etc.).
  2. A `func` declaration with an identical *full signature* at the same type
     scope.

It is deliberately tuned for precision over recall: it must never cry wolf on a
legitimate overload or a protocol-requirement/implementation pair, or it will be
disabled within a day. It is fine to miss exotic collisions. See the
"Known limitations" section at the bottom for exactly what it does and does not
catch.

Usage:
    check-duplicate-declarations.py                # scan all Sources/ + Tests/
    check-duplicate-declarations.py FILE [FILE...] # scan specific .swift files

Exit status is non-zero if any likely duplicate is found.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]

# Modifiers / attributes that can legally precede a `let`/`var`/`func` keyword.
# We strip these from the front of a line before deciding whether the line is a
# plain declaration, so `private static let x` is recognised the same as `let x`.
LEADING_MODIFIERS = {
    "private", "fileprivate", "internal", "public", "open",
    "static", "class", "final", "override", "dynamic",
    "lazy", "weak", "unowned", "mutating", "nonmutating",
    "convenience", "required", "optional", "indirect",
    "nonisolated", "isolated", "distributed", "async", "borrowing",
    "consuming", "package", "prefix", "postfix", "infix",
    "unsafe", "sending",
}

_IDENT = r"[A-Za-z_][A-Za-z0-9_]*"
_WS_RE = re.compile(r"\s+")
# Tokens that, when they open the next line, mean a func signature is still
# continuing (the return clause / effect specifiers wrapped onto a new line).
_RETURN_CONTINUATION_RE = re.compile(r"(->|where\b|async\b|throws\b|rethrows\b)")


def sanitize(src: str) -> str:
    """Blank out comment and string-literal *content* so the detection pass sees
    only real code. Newlines are preserved so reported line numbers stay exact,
    and braces/parens are preserved except where they live inside a string or
    comment. String interpolation segments (`\\(...)`) are kept as live code so
    their braces stay balanced.

    Returns a string the same length as `src`. If the lexer ever gets confused
    the caller's brace-balance check will notice and the file is skipped rather
    than mis-reported.
    """
    out = []
    i = 0
    n = len(src)
    # Stack of lexical contexts. Each entry is a dict:
    #   {'t': 'code',  'paren': int}                 -- code / interpolation
    #   {'t': 'block', 'depth': int}                 -- /* ... */ (nestable)
    #   {'t': 'line'}                                -- // ...
    #   {'t': 'str',  'multi': bool, 'pounds': int}  -- string literal
    stack = [{"t": "code", "paren": 0}]

    def push(ctx):
        stack.append(ctx)

    def pop():
        stack.pop()

    while i < n:
        ctx = stack[-1]
        ch = src[i]
        kind = ctx["t"]

        if kind == "code":
            two = src[i:i + 2]
            if two == "//":
                push({"t": "line"})
                out.append(" ")
                out.append(" ")
                i += 2
                continue
            if two == "/*":
                push({"t": "block", "depth": 1})
                out.append(" ")
                out.append(" ")
                i += 2
                continue
            # Raw string: one or more '#' then '"'.
            if ch == "#":
                m = re.match(r"#+\"", src[i:])
                if m:
                    pounds = len(m.group(0)) - 1
                    multi = src[i:i + pounds + 3] == "#" * pounds + '"""'
                    push({"t": "str", "multi": multi, "pounds": pounds})
                    consumed = pounds + (3 if multi else 1)
                    out.append(" " * consumed)
                    i += consumed
                    continue
            if ch == '"':
                multi = src[i:i + 3] == '"""'
                push({"t": "str", "multi": multi, "pounds": 0})
                consumed = 3 if multi else 1
                out.append(" " * consumed)
                i += consumed
                continue
            # Track paren depth of an interpolation frame so we know when it ends.
            if len(stack) > 1 and ctx["paren"] >= 0:
                if ch == "(":
                    ctx["paren"] += 1
                elif ch == ")":
                    ctx["paren"] -= 1
                    if ctx["paren"] < 0:
                        # End of a `\(...)` interpolation -- back to the string.
                        pop()
                        out.append(" ")
                        i += 1
                        continue
            out.append(ch)
            i += 1
            continue

        if kind == "line":
            if ch == "\n":
                pop()
                out.append("\n")
            else:
                out.append(" ")
            i += 1
            continue

        if kind == "block":
            two = src[i:i + 2]
            if two == "/*":
                ctx["depth"] += 1
                out.append("  ")
                i += 2
                continue
            if two == "*/":
                ctx["depth"] -= 1
                out.append("  ")
                i += 2
                if ctx["depth"] == 0:
                    pop()
                continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue

        if kind == "str":
            pounds = ctx["pounds"]
            # Escape handling: `\` (or `\#...#` in raw strings) escapes the next
            # char, and `\(` / `\#(` opens an interpolation.
            esc = "\\" + ("#" * pounds)
            if src.startswith(esc + "(", i):
                push({"t": "code", "paren": 0})
                out.append(" " * (len(esc) + 1))
                i += len(esc) + 1
                continue
            if src.startswith(esc, i):
                # Escaped char (e.g. \" or \\). Blank the escape marker and the
                # escaped char so an escaped quote can't close the string. Keep a
                # one-char-in / one-char-out mapping and never swallow a newline
                # (a `\`-line-continuation in a multiline string), so `out` stays
                # the same length as `src` and line numbers stay exact.
                out.append(" " * len(esc))
                i += len(esc)
                if i < n:
                    out.append("\n" if src[i] == "\n" else " ")
                    i += 1
                continue
            # Closing delimiter.
            if ctx["multi"]:
                close = '"""' + "#" * pounds
                if src.startswith(close, i):
                    pop()
                    out.append(" " * len(close))
                    i += len(close)
                    continue
            else:
                close = '"' + "#" * pounds
                if src.startswith(close, i):
                    pop()
                    out.append(" " * len(close))
                    i += len(close)
                    continue
            out.append("\n" if ch == "\n" else " ")
            i += 1
            continue

    return "".join(out)


class Frame:
    __slots__ = ("lets", "funcs")

    def __init__(self):
        # name -> (line, pp_path). Duplicate iff same name AND same pp_path.
        self.lets = {}
        # normalized signature -> line.
        self.funcs = {}


def _extract_func_signature(sanitized: str, start: int):
    """From the index of a `func` keyword, return (normalized_signature, end).

    The signature runs from `func` through the end of the return clause. We stop
    at the body-opening `{` (first `{` seen at bracket-depth 0) or, for a
    protocol requirement with no body, at the first newline that occurs after the
    parameter list has closed. Nested `()[]<>` are tracked so default arguments
    and generic clauses don't terminate early.
    """
    n = len(sanitized)
    depth = 0
    seen_close_paren = False
    saw_open_paren = False
    i = start
    end = start
    while i < n:
        c = sanitized[i]
        # The `->` return arrow is not a generic close-bracket; skip it whole so
        # its `>` doesn't unbalance the angle-bracket depth.
        if c == "-" and sanitized[i:i + 2] == "->":
            end = i + 2
            i += 2
            continue
        if c in "([<":
            depth += 1
            if c == "(":
                saw_open_paren = True
        elif c in ")]>":
            depth -= 1
            if depth < 0:
                depth = 0  # tolerate a stray comparison operator
            elif c == ")" and depth == 0:
                seen_close_paren = True
        elif c == "{" and depth == 0:
            end = i
            break
        elif c == "\n" and depth == 0 and (seen_close_paren or not saw_open_paren):
            # A bare newline after a closed parameter list ends the signature
            # (a bodyless protocol requirement, or the body `{` sits on the next
            # line). But the return clause and effect specifiers can also wrap
            # onto the next line, so don't cut when the accumulated text ends on a
            # continuation token or the next line opens with one -- otherwise two
            # differently-constrained overloads could collapse to one key.
            stripped = sanitized[start:i].rstrip()
            trailer = sanitized[i:].lstrip()
            if (stripped and stripped[-1] not in ",-&|=<>+*/:?."
                    and not _RETURN_CONTINUATION_RE.match(trailer)):
                end = i
                break
        end = i + 1
        i += 1
    signature = _WS_RE.sub(" ", sanitized[start:end]).strip()
    return signature, end


def analyze_file(path: Path):
    """Return a list of finding strings for one Swift file. Empty if clean or if
    the file could not be lexed cleanly (skipped for safety)."""
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as error:
        return [f"{path}: could not read ({error})"]
    return analyze_text(_rel(path), raw)


def analyze_text(label: str, raw: str):
    """Core analysis over source text. `label` is used in finding messages."""
    sanitized = sanitize(raw)

    findings = []
    root = Frame()
    stack = [root]
    # Each entry is a branch token like "3#0" -- a globally-unique id per #if
    # block, then the branch index within it. Two *different* #if blocks get
    # different ids so their bodies never collide; the branches of one block
    # (#if / #elseif / #else) differ in the index, so they don't collide either.
    pp_stack = []
    pp_seq = [0]  # monotonic counter so every #if block is uniquely identified

    # We walk the char stream once, tracking scope, and handle each declaration
    # at its statement start.
    n = len(sanitized)
    i = 0
    line_no = 1
    at_stmt_start = True  # first meaningful token of a statement / line

    def pp_path():
        return "|".join(pp_stack)

    def pp_bump_branch():
        if pp_stack:
            block, branch = pp_stack[-1].split("#")
            pp_stack[-1] = block + "#" + str(int(branch) + 1)

    while i < n:
        c = sanitized[i]

        if c == "\n":
            line_no += 1
            i += 1
            at_stmt_start = True
            continue

        if c in " \t":
            i += 1
            continue

        # Preprocessor directives control which declarations are mutually
        # exclusive. Detect them at statement start.
        if at_stmt_start and c == "#":
            rest = sanitized[i:]
            if re.match(r"#if\b", rest):
                pp_seq[0] += 1
                pp_stack.append(str(pp_seq[0]) + "#0")
                i += 2
                at_stmt_start = False
                continue
            if re.match(r"#elseif\b", rest):
                pp_bump_branch()
                i += 7
                at_stmt_start = False
                continue
            if re.match(r"#else\b", rest):
                pp_bump_branch()
                i += 5
                at_stmt_start = False
                continue
            if re.match(r"#endif\b", rest):
                if pp_stack:
                    pp_stack.pop()
                i += 6
                at_stmt_start = False
                continue

        if c == "{":
            stack.append(Frame())
            i += 1
            at_stmt_start = True
            continue

        if c == "}":
            if len(stack) > 1:
                stack.pop()
            else:
                # Unbalanced -- lexer confusion. Bail out for safety.
                return []
            i += 1
            at_stmt_start = True
            continue

        if c == ";":
            i += 1
            at_stmt_start = True
            continue

        # A `switch` case (`case ...:` / `default:`) shares the switch's braces
        # but opens a fresh binding scope: `let x` in two arms is legal. Reset the
        # frame's bindings at each case label so sibling arms don't collide. This
        # only ever removes findings, so it can never introduce a false positive.
        if at_stmt_start and (c == "c" or c == "d"):
            if re.match(r"case\b", sanitized[i:]) or re.match(r"default\b", sanitized[i:]):
                stack[-1].lets.clear()

        # A `func` declaration: match as a whole word.
        if c == "f" and re.match(r"func\b", sanitized[i:]):
            frame = stack[-1]
            signature, end = _extract_func_signature(sanitized, i)
            # `static`/`class` methods live on the metatype and legally coexist
            # with a same-signature instance method, so fold that into the label.
            # A trailing `where` clause stays in the signature: two decls that
            # differ only in constraints are distinct, not duplicates.
            sig_label = ("static " + signature) if _decl_is_static(sanitized, i) else signature
            # Two funcs in different conditional-compilation branches (the common
            # #if os(iOS)/#else cross-platform pair) are mutually exclusive, so
            # the pp_path is part of the key -- same signature under different
            # #if branches is NOT a duplicate.
            key = (sig_label, pp_path())
            if key in frame.funcs:
                findings.append(
                    f"{label}:{line_no}: duplicate func signature "
                    f"`{sig_label}` (first declared at line {frame.funcs[key]})"
                )
            else:
                frame.funcs[key] = line_no
            # Advance line_no across any newlines consumed by the signature.
            line_no += sanitized.count("\n", i, end)
            i = end
            at_stmt_start = False
            continue

        # A `let`/`var` binding, only at statement start, only plain bindings.
        if at_stmt_start and c in "lv":
            # Re-read the whole logical line head (with leading modifiers already
            # behind us at this offset since we're at the keyword). Confirm the
            # keyword and pull the bound identifier.
            m = re.match(r"(let|var)\s+(" + _IDENT + r")\s*([:=,{]|$)", sanitized[i:])
            if m and _is_plain_binding(sanitized, i):
                name = m.group(2)
                frame = stack[-1]
                key = (name, pp_path())
                if key in frame.lets:
                    findings.append(
                        f"{label}:{line_no}: duplicate binding "
                        f"`{m.group(1)} {name}` in the same scope "
                        f"(first declared at line {frame.lets[key]})"
                    )
                else:
                    frame.lets[key] = line_no
            # fall through; keep scanning this line for braces etc.

        at_stmt_start = False
        i += 1

    return findings


_CONDITION_KEYWORDS = {"if", "guard", "while", "case", "catch"}


def _is_plain_binding(sanitized: str, i: int) -> bool:
    """True when the `let`/`var` at offset i is a real declaration and not an
    optional-binding condition clause.

    The confusing case is a multi-line `if`/`guard`/`while let` chain, where a
    binding clause can start its own line:

        guard fileManager.fileExists(...),
              let values = try? ...          # <- starts a line with `let`

    A plain declaration is separated from the previous statement by a terminator
    (`{`, `}`, `;`, or a newline ending a complete statement). A condition clause
    is instead preceded by a `,` (the previous clause) or by the introducing
    keyword. So we walk back over whitespace *and* newlines to the real preceding
    token and reject those two shapes."""
    j = i - 1
    while j >= 0 and sanitized[j] in " \t\r\n":
        j -= 1
    if j < 0:
        return True
    prev = sanitized[j]
    if prev == ",":
        return False  # continuation of an `if/guard/while let a, let b` chain
    # If the preceding token is a condition-introducing keyword on its own line,
    # this binding is still part of that condition.
    end = j + 1
    start = end
    while start > 0 and (sanitized[start - 1].isalnum() or sanitized[start - 1] == "_"):
        start -= 1
    word = sanitized[start:end]
    if word in _CONDITION_KEYWORDS:
        return False
    return True


def _decl_is_static(sanitized: str, idx: int) -> bool:
    """True when the declaration at `idx` (a `func` keyword) carries a `static`
    or `class` modifier. Walks backward over only modifier/attribute tokens, so
    it stops the moment it hits a non-modifier word and never bleeds into the
    previous statement."""
    j = idx
    while j > 0:
        while j > 0 and sanitized[j - 1] in " \t\n":
            j -= 1
        k = j
        while k > 0 and (sanitized[k - 1].isalnum() or sanitized[k - 1] == "_"):
            k -= 1
        word = sanitized[k:j]
        if not word:
            return False  # hit a non-identifier boundary char
        if word in ("static", "class"):
            return True
        if word in LEADING_MODIFIERS:
            j = k
            continue
        return False
    return False


def _rel(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def _default_targets():
    files = []
    for root in ("Sources", "Tests"):
        base = REPO_ROOT / root
        if base.is_dir():
            files.extend(sorted(base.rglob("*.swift")))
    return files


# ---------------------------------------------------------------------------
# Self-test. Fixtures live inline (not under Sources/ or Tests/, so the default
# scan never trips over them). The false-positive cases -- a legitimate overload
# pair and a protocol-requirement/implementation pair -- are the ones that keep
# this check from being disabled, so they are asserted explicitly.
# ---------------------------------------------------------------------------

_TRUE_POSITIVE_FIXTURE = '''\
import AppKit

final class CapturePillController {
    @objc private func remindTapped() {}
    @objc private func remindTapped() {}   // duplicate func -- bad merge

    func layout() {
        let remindSize = CGSize(width: 10, height: 10)
        let padding = 4
        let remindSize = CGSize(width: 20, height: 20)   // duplicate let -- bad merge
        _ = padding
        _ = remindSize
    }
}
'''

_LEGIT_FIXTURE = '''\
import Foundation

protocol Renderer {
    func render(_ value: Int) -> String        // protocol requirement -- NOT a dup
    var title: String { get }
}

struct TextRenderer: Renderer {
    var title: String { "text" }

    // Legitimate overloads: same name, different signatures. MUST NOT flag.
    func render(_ value: Int) -> String { "\\(value)" }
    func render(_ value: String) -> String { value }
    func render(_ value: Int, radix: Int) -> String { String(value, radix: radix) }

    // static and instance methods with the same signature legally coexist.
    static func reset() {}
    func reset() {}

    func shadowing() {
        let x = 1
        if x > 0 {
            let x = 2   // shadowing in a nested scope -- legal, NOT a dup
            _ = x
        }
        _ = x
    }

    // switch arms share the switch's braces but are separate binding scopes.
    func classify(_ value: Any) -> String {
        switch value {
        case let s as String:
            let cleaned = s
            return cleaned
        case let n as Int:
            let cleaned = String(n)   // same name, different arm -- NOT a dup
            return cleaned
        default:
            let cleaned = "?"          // same name, default arm -- NOT a dup
            return cleaned
        }
    }

    // multi-line optional-binding chains repeat clause names across lines.
    func lookup(_ a: [String: String], _ b: [String: String]) -> String? {
        guard let value = a["k"],
              let other = a["j"] else { return nil }
        if let value = b["k"],
           let other = b["j"] {        // `value`/`other` reused -- NOT a dup
            return value + other
        }
        return value + other
    }

    #if os(macOS)
    let platformName = "macOS"
    #else
    let platformName = "other"   // conditional-compilation sibling -- NOT a dup
    #endif

    // Cross-platform func pair under #if/#else -- mutually exclusive, NOT a dup.
    #if os(iOS)
    func openSettings() {}
    #else
    func openSettings() {}
    #endif

    // Two *separate* #if blocks that happen to bind the same name -- also
    // mutually exclusive, NOT a dup (each #if block gets a distinct id).
    #if DEBUG
    let logLevel = 2
    #endif
    #if BETA
    let logLevel = 1
    #endif
}
'''


def _self_test() -> int:
    ok = True

    tp = analyze_text("fixture-duplicates.swift", _TRUE_POSITIVE_FIXTURE)
    want_lines = {5, 10}  # duplicate func, duplicate let
    got_lines = {int(f.split(":")[1]) for f in tp}
    if got_lines != want_lines:
        ok = False
        print(f"[FAIL] true-positive fixture: expected duplicates on lines "
              f"{sorted(want_lines)}, got {sorted(got_lines)}", file=sys.stderr)
        for f in tp:
            print(f"       {f}", file=sys.stderr)
    else:
        print("[PASS] true-positive fixture: flagged the duplicate func and let")
        for f in tp:
            print(f"       {f}")

    fp = analyze_text("fixture-legit.swift", _LEGIT_FIXTURE)
    if fp:
        ok = False
        print("[FAIL] false-positive fixture: flagged legitimate code "
              "(overloads / protocol reqs / shadowing / #if branches):", file=sys.stderr)
        for f in fp:
            print(f"       {f}", file=sys.stderr)
    else:
        print("[PASS] false-positive fixture: stayed silent on overloads, "
              "protocol requirement+impl, static-vs-instance methods, switch "
              "arms, multi-line if/guard-let chains, nested shadowing, "
              "#if/#else func pairs, and separate #if blocks")

    print("\nSelf-test PASSED." if ok else "\nSelf-test FAILED.")
    return 0 if ok else 1


def main(argv) -> int:
    if argv and argv[0] == "--self-test":
        return _self_test()
    if argv:
        targets = []
        for arg in argv:
            p = Path(arg)
            if not p.is_absolute():
                p = REPO_ROOT / arg
            if p.suffix == ".swift" and p.is_file():
                targets.append(p)
    else:
        targets = _default_targets()

    findings = []
    for path in targets:
        findings.extend(analyze_file(path))

    if findings:
        print("Duplicate-declaration check failed:", file=sys.stderr)
        for finding in findings:
            print(f"- {finding}", file=sys.stderr)
        print(
            f"\n{len(findings)} likely duplicate declaration(s) found. "
            "These are Swift compile errors that a syntax-only parse misses; "
            "they are usually the residue of a bad git auto-merge.",
            file=sys.stderr,
        )
        return 1

    print(f"Duplicate-declaration check passed ({len(targets)} file(s) scanned).")
    return 0


# ---------------------------------------------------------------------------
# Known limitations (by design -- this is a precision-first heuristic, not a
# Swift parser). It favours never crying wolf over perfect recall:
#
#   * Only two collision shapes are checked: same-scope `let`/`var` bindings and
#     same-type-scope `func` declarations with identical signatures. `init`,
#     `subscript`, `typealias`, `case`, and stored/computed property *type*
#     collisions on non-func members beyond simple let/var are not checked.
#   * "Same scope" means the same brace block. A member declared once in a type
#     body and again in a same-file `extension` of that type is a real compile
#     error but sits in two different brace blocks, so it is NOT flagged.
#   * Func duplicates are only reported when the *entire* normalized signature
#     (params, labels, return type, generics, where-clause) matches. Two decls
#     that differ only by return type -- also an error in most contexts -- are
#     treated as distinct and not flagged.
#   * Tuple-destructuring bindings (`let (a, b) = ...`) and second-and-later
#     comma bindings (`let a = 1, b = 2`) are not tracked.
#   * Declarations inside conditional-compilation branches only collide with
#     declarations in the exact same branch; a decl before an `#if` never
#     collides with one inside it.
#   * If the lexer cannot balance a file's braces (exotic string/interpolation
#     nesting it mis-handles), that file is skipped rather than mis-reported.
#
# When in doubt it stays silent. The full Xcode build remains the backstop; this
# just moves the *common* merge-collision failures from a 20-minute feedback loop
# to a few seconds.
# ---------------------------------------------------------------------------


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

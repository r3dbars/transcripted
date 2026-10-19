#!/usr/bin/env python3
"""Owner commits carry the owner's credit only: no AI author, no AI co-author.

AGENTS.md ("Owner's commit credit"): when an agent commits work for the owner,
author and committer are `r3dbars <r3dbars@users.noreply.github.com>`, with no
AI `Co-authored-by` trailer. Agents kept adding the trailer anyway (their
harness asks for one), so this checks it where the commit is made and again
before a push.

    python3 scripts/dev/check-commit-credit.py --message-file .git/COMMIT_EDITMSG
        commit-msg hook: checks the message and the author git is about to use,
        but only when the committer is the owner's noreply identity.
    python3 scripts/dev/check-commit-credit.py --range origin/main..HEAD
        pre-push: every commit in the range committed as the owner.
    python3 scripts/dev/check-commit-credit.py --self-test

Commits by anyone else (outside contributors, GitHub's own merge commits) are
left alone, and so are human co-authors. Python 3 stdlib only.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys

OWNER_EMAIL = "r3dbars@users.noreply.github.com"
OWNER_IDENT = f"r3dbars <{OWNER_EMAIL}>"

# An identity that belongs to a coding agent, not a person. Model names, not bare
# first names: a human co-author called Claude must pass.
_AI_IDENT = re.compile(
    r"noreply@anthropic\.com|@openai\.com|cursoragent@|\bClaude (?:Opus|Sonnet|Haiku|Fable|Code)\b|"
    r"\bCodex\b|\bChatGPT\b|\bCursor Agent\b|\bGitHub Copilot\b|\[bot\]",
    re.IGNORECASE,
)
# Unindented, like git's own trailer parsing; an indented example in the body isn't one.
_TRAILER = re.compile(r"^co-authored-by[ \t]*:[ \t]*(.+?)[ \t]*$", re.IGNORECASE | re.MULTILINE)

FIX = (f"Owner commits carry only the owner's credit (AGENTS.md, \"Owner's commit credit\"): delete the AI "
       f"Co-authored-by line and keep author and committer as {OWNER_IDENT}.")
REPAIR = ("To repair the last commit: git -c user.name=r3dbars -c user.email=" + OWNER_EMAIL +
          " commit --amend --reset-author (and drop the trailer in the editor); reword older ones the same way "
          "before pushing.")


def problems(message: str, author: str) -> list:
    out = []
    if _AI_IDENT.search(author or ""):
        out.append(f"author is an agent identity ({author.strip()}); use {OWNER_IDENT}")
    for value in _TRAILER.findall(message):
        if _AI_IDENT.search(value):
            out.append(f"AI co-author trailer: Co-authored-by: {value}")
    return out


def _git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def _ident_email(ident: str) -> str:
    m = re.search(r"<([^>]*)>", ident)
    return m.group(1).strip().lower() if m else ""


def check_message_file(path: str) -> int:
    try:
        committer = _git("var", "GIT_COMMITTER_IDENT")
        author = _git("var", "GIT_AUTHOR_IDENT")
    except (OSError, subprocess.CalledProcessError):
        return 0  # fail open: no identity, nothing to check
    if _ident_email(committer) != OWNER_EMAIL:
        return 0
    with open(path, encoding="utf-8", errors="replace") as handle:
        # Git drops `#` lines from the final message.
        message = "".join(line for line in handle if not line.startswith("#"))
    author = re.sub(r"\s+\d+\s+[+-]\d{4}\s*$", "", author)
    found = problems(message, author)
    for problem in found:
        print(f"check-commit-credit: {problem}", file=sys.stderr)
    if found:
        print(f"check-commit-credit: {FIX} Nothing was committed; fix the message and commit again.",
              file=sys.stderr)
    return 1 if found else 0


def check_range(rev_range: str) -> int:
    sep, end = "\x1f", "\x1e"
    try:
        log = _git("log", f"--format=%H{sep}%an <%ae>{sep}%ce{sep}%B{end}", rev_range)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"check-commit-credit: can't read {rev_range}: {error}", file=sys.stderr)
        return 2
    bad = 0
    for record in log.split(end):
        record = record.strip("\n")
        if not record:
            continue
        sha, author, committer_email, message = record.split(sep, 3)
        if committer_email.strip().lower() != OWNER_EMAIL:
            continue
        for problem in problems(message, author):
            print(f"check-commit-credit: {sha[:10]}: {problem}", file=sys.stderr)
            bad += 1
    if bad:
        print(f"check-commit-credit: {FIX} {REPAIR}", file=sys.stderr)
        return 1
    print(f"check-commit-credit: ok ({rev_range})")
    return 0


def self_test() -> int:
    failures = []

    def expect(cond: bool, label: str) -> None:
        if not cond:
            failures.append(label)

    owner = OWNER_IDENT
    expect(not problems("fix: a thing\n\nBody.\n", owner), "clean owner commit passes")
    expect(problems("fix\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n", owner),
           "Claude trailer flagged")
    expect(problems("fix\n\nco-authored-by: Cursor Agent <cursoragent@cursor.com>\n", owner),
           "Cursor trailer flagged (any case)")
    expect(problems("fix\n\nCo-authored-by: Codex <codex@openai.com>\n", owner), "Codex trailer flagged")
    expect(not problems("fix\n\nCo-authored-by: Dana Reyes <dana@example.com>\n", owner),
           "human co-author kept")
    expect(problems("fix\n", "Claude <noreply@anthropic.com>"), "AI author flagged")
    expect(not problems("fix\n\nCo-authored-by: Claude Martin <claude.martin@example.com>\n", owner),
           "a human named Claude passes")
    expect(not problems("fix\n\nExample:\n    Co-authored-by: Claude Opus 5.5 <noreply@anthropic.com>\n", owner),
           "an indented example in the body passes")
    expect(not problems("Mention Claude Code in the docs\n", owner),
           "the word Claude in the body isn't a trailer")
    expect(_ident_email("r3dbars <R3DBARS@users.noreply.github.com> 1700000000 -0500") == OWNER_EMAIL,
           "ident email parsed and lowercased")
    if failures:
        for label in failures:
            print(f"check-commit-credit self-test FAILED: {label}", file=sys.stderr)
        return 1
    print("check-commit-credit: self-test passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--message-file")
    group.add_argument("--range")
    group.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.message_file:
        return check_message_file(args.message_file)
    return check_range(args.range)


if __name__ == "__main__":
    os.environ.setdefault("GIT_PAGER", "cat")
    sys.exit(main())

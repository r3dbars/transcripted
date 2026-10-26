#!/usr/bin/env python3
"""Pre-push guard: keep private terms out of the public repo.

Reads git's pre-push stdin ("<local ref> <local sha> <remote ref> <remote sha>"
per line) and checks everything the push would publish: every line added by
every outgoing commit (history is public too, so a term added and then removed
still counts), every outgoing commit message, and the remote branch name. For
a merge commit, only the text the merge itself introduces (a conflict
resolution or an edited merge, read from git's combined `--cc` diff) is
scanned; lines the merge brings in from its parents are scanned in the commits
that added them, and anything already on the remote isn't flagged again.

The terms come from a private file OUTSIDE the repo, one per line, matched
case-insensitively as substrings; blank lines and lines starting with `#` are
ignored:

    ~/.config/transcripted/public-repo-denylist.txt
    (override with TRANSCRIPTED_PUBLIC_DENYLIST=/path, used by the self-test)

No file, or no terms in it, means nothing to check: exit 0. On a match it
prints where (path:line and commit, or "commit message", or "branch name") and
never which term, so the hook output itself doesn't leak the list. Exit 1 on a
match or on an internal error (this guard fails closed; `git push --no-verify`
skips it once).

    printf '%s\\n' "$refs" | python3 .githooks/public-repo-guard.py --remote origin
    python3 .githooks/public-repo-guard.py --self-test

Python 3.9+ stdlib only.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

DEFAULT_DENYLIST = Path.home() / ".config/transcripted/public-repo-denylist.txt"
HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")
CC_HUNK_RE = re.compile(r"^(@{3,}) (?:-\d+(?:,\d+)? )+\+(\d+)(?:,\d+)? @{3,}")
COMMIT_MARK = "\x00commit "


def denylist_path() -> Path:
    override = os.environ.get("TRANSCRIPTED_PUBLIC_DENYLIST")
    return Path(override).expanduser() if override else DEFAULT_DENYLIST


def load_terms(path: Path) -> list:
    if not path.is_file():
        return []
    terms = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        term = raw.strip()
        if term and not term.startswith("#"):
            terms.append(term.casefold())
    return terms


def git(args, cwd: Path) -> str:
    proc = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    if proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {proc.stderr.strip()}")
    return proc.stdout


def is_zero(sha: str) -> bool:
    return bool(sha) and set(sha) == {"0"}


def has_object(sha: str, cwd: Path) -> bool:
    return subprocess.run(["git", "cat-file", "-e", f"{sha}^{{commit}}"], cwd=cwd,
                          capture_output=True).returncode == 0


def outgoing_range(local_sha: str, remote_sha: str, remote: str, cwd: Path) -> list:
    """`git log` revision arguments for the commits this push publishes: the
    local tip minus the remote's old tip (when we have it) and minus every
    remote-tracking ref of this remote."""
    args = [local_sha]
    if remote_sha and not is_zero(remote_sha) and has_object(remote_sha, cwd):
        args.append(f"^{remote_sha}")
    return [*args, "--not", f"--remotes={remote}"]


def scan_diff(patch: str, matches) -> list:
    """Find added lines in `git log -p -U0` output; return (commit, path, line)."""
    hits = []
    commit = path = None
    line_no = 0
    in_header = False
    for line in patch.split("\n"):
        if line.startswith(COMMIT_MARK):
            commit = line[len(COMMIT_MARK):].strip()
            path, in_header = None, False
            continue
        if line.startswith("diff --git "):
            in_header, path = True, None
            continue
        if in_header:
            if line.startswith("+++ "):
                target = line[4:]
                path = None if target == "/dev/null" else (target[2:] if target.startswith("b/") else target)
            elif line.startswith("@@"):
                in_header = False
            else:
                continue
        if line.startswith("@@"):
            m = HUNK_RE.match(line)
            line_no = int(m.group(1)) if m else 0
            continue
        if path is None:
            continue
        if line.startswith("+"):
            if matches(line[1:]):
                hits.append((commit, path, line_no))
            line_no += 1
    return hits


def scan_combined_diff(patch: str, matches) -> list:
    """Find merge-only lines in `git log -p -U0 --cc --merges` output: a line
    whose every parent column is '+' appears in no parent, so the merge itself
    wrote it. Returns (commit, path, line)."""
    hits = []
    commit = path = None
    parents = line_no = 0
    in_header = False
    for line in patch.split("\n"):
        if line.startswith(COMMIT_MARK):
            commit = line[len(COMMIT_MARK):].strip()
            path, in_header, parents = None, False, 0
            continue
        if line.startswith("diff --cc ") or line.startswith("diff --combined "):
            in_header, path, parents = True, None, 0
            continue
        if line.startswith("diff --git "):
            in_header, path, parents = True, None, 0
            continue
        if in_header:
            if line.startswith("+++ "):
                target = line[4:]
                path = None if target == "/dev/null" else (target[2:] if target.startswith("b/") else target)
                continue
            if not line.startswith("@@"):
                continue
            in_header = False
        if line.startswith("@@@"):
            m = CC_HUNK_RE.match(line)
            if m:
                parents = len(m.group(1)) - 1
                line_no = int(m.group(2))
            else:
                parents = 0
            continue
        if path is None or parents < 2 or len(line) < parents:
            continue
        cols = line[:parents]
        if "-" in cols:
            continue  # removed from a parent; not in the result
        if set(cols) == {"+"} and matches(line[parents:]):
            hits.append((commit, path, line_no))
        line_no += 1
    return hits


def check_push(stdin_text: str, terms: list, remote: str, cwd: Path) -> list:
    if not terms:
        return []

    def matches(text: str) -> bool:
        folded = text.casefold()
        return any(t in folded for t in terms)

    problems = []
    for raw in stdin_text.splitlines():
        parts = raw.split()
        if len(parts) != 4:
            continue
        local_ref, local_sha, remote_ref, remote_sha = parts
        if is_zero(local_sha):
            continue  # deleting a remote branch publishes nothing
        if matches(remote_ref):
            problems.append("remote branch name being pushed matches a denylist term")
        rng = outgoing_range(local_sha, remote_sha, remote, cwd)
        log = git(["log", "--no-color", "--format=%x00commit %H%n%B", *rng], cwd)
        commit = None
        msg_line = 0
        for line in log.split("\n"):
            if line.startswith(COMMIT_MARK):
                commit, msg_line = line[len(COMMIT_MARK):].strip(), 0
                continue
            msg_line += 1
            if commit and matches(line):
                problems.append(f"commit {commit[:10]} message line {msg_line} matches a denylist term")
        patch = git(["log", "-p", "-U0", "--no-color", "--no-ext-diff", "--no-renames",
                     "--no-merges", "--format=%x00commit %H", *rng], cwd)
        for commit_sha, path, line_no in scan_diff(patch, matches):
            problems.append(f"{path}:{line_no} (added in commit {(commit_sha or '?')[:10]}) matches a denylist term")
        merges = git(["log", "-p", "-U0", "--cc", "--merges", "--no-color", "--no-ext-diff", "--no-renames",
                      "--format=%x00commit %H", *rng], cwd)
        for commit_sha, path, line_no in scan_combined_diff(merges, matches):
            problems.append(f"{path}:{line_no} (added in merge commit {(commit_sha or '?')[:10]}) "
                            "matches a denylist term")
    # keep order, drop duplicates (two refs pushing the same commits)
    return list(dict.fromkeys(problems))


def report(problems: list, err=sys.stderr) -> None:
    print("public-repo-guard: this push would publish text that matches your private denylist "
          f"({denylist_path()}):", file=err)
    for p in problems:
        print(f"  {p}", file=err)
    print("Reword it (fictional names, neutral descriptions), amend or rebase the commits, and push again.",
          file=err)


# ---------------------------------------------------------------- self-test

def self_test() -> int:
    failures = []

    def expect(cond, label):
        if not cond:
            failures.append(label)

    with tempfile.TemporaryDirectory(prefix="public-repo-guard-") as tmp:
        repo = Path(tmp) / "repo"
        repo.mkdir()
        env_git = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                   "-c", "commit.gpgsign=false", "-c", "core.hooksPath=" + os.devnull]

        def run(*args):
            return git([*env_git, *args], repo)

        def commit(files: dict, message: str) -> str:
            for name, body in files.items():
                p = repo / name
                p.parent.mkdir(parents=True, exist_ok=True)
                if body is None:
                    p.unlink()
                else:
                    p.write_text(body, encoding="utf-8")
            run("add", "-A")
            run("commit", "-q", "-m", message)
            return run("rev-parse", "HEAD").strip()

        run("init", "-q")
        base = commit({"a.txt": "zebra mention in old history\nplain\n"}, "base")
        terms = ["zebra", "quokka"]
        zero = "0" * 40

        def push(local, remote_sha=zero, ref="refs/heads/topic"):
            return check_push(f"refs/heads/x {local} {ref} {remote_sha}\n", terms, "origin", repo)

        c1 = commit({"a.txt": "zebra mention in old history\nplain\nnew QUOKKA line\n"}, "add line")
        out = push(c1, base)
        expect(any(p.startswith("a.txt:3 ") for p in out), f"added line flagged with path:line ({out})")
        expect(not any("old history" in p or "a.txt:1 " in p for p in out), "old (already pushed) line not flagged")
        expect(all("quokka" not in p.casefold() for p in out), "report never names the term")

        c2 = commit({"a.txt": "zebra mention in old history\nplain\n"}, "remove it again")
        out = push(c2, base)
        expect(any(p.startswith("a.txt:3 ") for p in out), "added-then-removed still flagged (history is public)")
        out = push(c2, c1)
        expect(out == [], f"removal-only push passes ({out})")

        c3 = commit({"b/c.txt": "clean\n"}, "mention Zebra in message")
        out = push(c3, c2)
        expect(any("message line 1" in p for p in out), f"commit message flagged ({out})")
        expect(not any(p.startswith("b/c.txt") for p in out), "clean file not flagged")

        out = push(c3, c2, ref="refs/heads/zebra-notes")
        expect(any(p.startswith("remote branch name") for p in out), "branch name flagged")
        expect(all("zebra" not in p.casefold() for p in out), "branch report never names the term")

        out = check_push(f"refs/heads/x {zero} refs/heads/gone {c3}\n", terms, "origin", repo)
        expect(out == [], "branch deletion passes")
        expect(check_push(f"refs/heads/x {c3} refs/heads/t {base}\n", [], "origin", repo) == [], "no terms passes")

        c4 = commit({"b/c.txt": None, "d.txt": "+++ zebra looks like a header\n"}, "tricky")
        out = push(c4, c3)
        expect(any(p.startswith("d.txt:1 ") for p in out), f"added line starting with ++ flagged ({out})")

        out = push(c4)  # new branch, no remotes: everything outgoing
        expect(any(p.startswith("a.txt:1 ") for p in out), "new branch with no remote scans full history")

        # Merge-only content: a conflict resolution that writes the term.
        run("checkout", "-q", "-b", "side", c4)
        commit({"m.txt": "side line\n"}, "side edit")
        run("checkout", "-q", "-b", "trunk", c4)
        commit({"m.txt": "trunk line\n"}, "trunk edit")
        subprocess.run(["git", *env_git, "merge", "-q", "--no-ff", "side", "-m", "merge side"], cwd=repo,
                       capture_output=True)  # conflicts; resolved below
        (repo / "m.txt").write_text("resolved with quokka\n", encoding="utf-8")
        run("add", "m.txt")
        run("commit", "-q", "--no-edit")
        merge = run("rev-parse", "HEAD").strip()
        out = push(merge, c4)
        expect(any(p.startswith("m.txt:1 ") and "merge commit" in p for p in out),
               f"term written by a merge's conflict resolution flagged ({out})")
        expect(all("quokka" not in p.casefold() for p in out), "merge report never names the term")

        # A clean merge that only brings in a side commit's line: flagged once, in the side commit.
        run("checkout", "-q", "-b", "side2", merge)
        side2 = commit({"s.txt": "zebra from side\n"}, "side2 edit")
        run("checkout", "-q", "trunk")
        commit({"t.txt": "trunk only\n"}, "trunk edit 2")
        run("merge", "-q", "--no-ff", "side2", "-m", "merge side2")
        merge2 = run("rev-parse", "HEAD").strip()
        out = push(merge2, merge)
        hits = [p for p in out if p.startswith("s.txt:1 ")]
        expect(len(hits) == 1 and side2[:10] in hits[0], f"clean merge: side line flagged once, in its own commit ({out})")

        deny = Path(tmp) / "deny.txt"
        deny.write_text("# comment\n\n  Quokka  \n", encoding="utf-8")
        expect(load_terms(deny) == ["quokka"], f"load_terms strips and skips comments ({load_terms(deny)})")
        expect(load_terms(Path(tmp) / "missing.txt") == [], "missing denylist = no terms")

    if failures:
        for f in failures:
            print(f"public-repo-guard self-test FAIL: {f}", file=sys.stderr)
        return 1
    print("public-repo-guard self-test: ok")
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--remote", default="origin")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    try:
        terms = load_terms(denylist_path())
        if not terms:
            return 0
        stdin_text = sys.stdin.read()
        root = Path(git(["rev-parse", "--show-toplevel"], Path.cwd()).strip())
        problems = check_push(stdin_text, terms, args.remote, root)
    except Exception as error:  # fail closed: this guard protects privacy
        print(f"public-repo-guard: internal error, blocking the push ({error.__class__.__name__}: {error}). "
              "Check by hand, then `git push --no-verify` if it's clean.", file=sys.stderr)
        return 1
    if problems:
        report(problems)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

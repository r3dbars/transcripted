#!/usr/bin/env python3
"""Auto-merge gate: merge low-risk cleanup PRs without waiting on the owner.

Reads `.agents/auto-merge-lanes.json` and checks every open PR. A PR is merged
only when ALL of these hold:

  - main is healthy: the latest finished Swift CI run on main succeeded
  - it's from an allowed author, on a branch in this repo (no forks)
  - its branch starts with an enabled lane's prefix
  - it has the lane's labels and none of the blocking labels
  - every changed path, including both ends of a rename, matches the lane's
    allow globs, none match deny_always or the lane's own deny
  - its size (additions + deletions) is within the lane's limit
  - every required check succeeded on the PR's head commit
  - GitHub reports it mergeable (no conflicts)
  - no review requests changes, and no review thread is unresolved
  - every reviewer the lane requires (Codex by default) reviewed the head
    commit, or reacted +1 to the PR after the head commit was pushed
  - lanes with require_test_change: it changes at least one test file
  - lanes with require_verify: the PR body holds a verify-change.sh summary
    for the head commit with no FAIL, nothing uncovered and no live check owed

At most `max_merges_per_run` PRs merge per run, and at most one per lane, so
main's CI runs between batches; a red main stops every merge until it's green.
A draft in a lane is marked ready for review as soon as everything but the
review passes, so Codex reviews it; a later run merges it once that review is in.
Merges use a merge commit, never squash or rebase.

    python3 scripts/ops/auto-merge-gate.py            # dry run: print decisions
    python3 scripts/ops/auto-merge-gate.py --apply    # merge what qualifies
    python3 scripts/ops/auto-merge-gate.py --pr 2040  # explain one PR
    python3 scripts/ops/auto-merge-gate.py --self-test

Needs `gh` signed in as the owner. Python stdlib only. See docs/auto-merge-gate.md.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CONFIG_PATH = REPO_ROOT / ".agents/auto-merge-lanes.json"
PR_FIELDS = ",".join([
    "number", "title", "headRefName", "headRefOid", "isDraft", "isCrossRepository",
    "labels", "author", "additions", "deletions", "mergeable", "changedFiles",
    "statusCheckRollup", "reviews", "commits", "url", "body",
])


def gh(*args: str) -> str:
    out = subprocess.run(["gh", *args], cwd=REPO_ROOT, capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args)} failed: {out.stderr.strip()}")
    return out.stdout


def gh_json(*args: str):
    return json.loads(gh(*args) or "null")


def bare_login(login: str) -> str:
    return login.removesuffix("[bot]")


def matches(path: str, globs: list[str]) -> bool:
    return any(fnmatch.fnmatchcase(path, g) for g in globs)


def find_lane(branch: str, config: dict) -> dict | None:
    for lane in config["lanes"]:
        if branch.startswith(lane["branch_prefix"]):
            return lane
    return None


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


TEST_GLOBS = ["Tests/**", "Tools/*/Tests/**"]


def changed_paths(records: object, expected_count: object) -> tuple[list[str], list[str]]:
    """Validate REST PR files and include a rename's removed and added paths."""
    if not isinstance(records, list):
        return [], ["changed-file metadata is missing or malformed"]
    if type(expected_count) is not int or expected_count != len(records):
        return [], ["changed-file metadata is incomplete or changed during fetch"]
    paths: list[str] = []
    destinations: set[str] = set()
    statuses = {"added", "removed", "modified", "renamed", "copied", "changed", "unchanged"}

    def valid_path(path: object) -> bool:
        return (isinstance(path, str) and bool(path) and not path.startswith("/")
                and not any(part in ("", ".", "..") for part in path.split("/")))

    for record in records:
        if (not isinstance(record, dict) or not isinstance(record.get("status"), str)
                or record["status"] not in statuses):
            return [], ["changed-file metadata has an invalid status"]
        destination = record.get("filename")
        if not valid_path(destination) or destination in destinations:
            return [], ["changed-file metadata has an invalid or duplicate filename"]
        destinations.add(destination)
        paths.append(destination)
        previous = record.get("previous_filename")
        if record["status"] == "renamed" or "previous_filename" in record:
            if (record["status"] not in ("renamed", "copied")
                    or not valid_path(previous) or previous == destination):
                return [], ["changed-file metadata has malformed rename paths"]
            paths.append(previous)
    return list(dict.fromkeys(paths)), []


def verify_problems(body: str, head: str) -> list[str]:
    """Check the `## App verification` block verify-change.sh writes."""
    if "## App verification" not in body:
        return ["no app verification summary in the PR body"]
    block = body.split("## App verification", 1)[1]
    problems = []
    shas = re.findall(r"head: `([0-9a-f]{7,40})`", block)
    if not shas or not head.startswith(shas[0]):
        problems.append("app verification is not for the head commit")
    rows = [r for r in re.findall(r"^\|([^|\n]+)\|([^|\n]+)\|", block, re.M)
            if r[1].strip() in ("PASS", "FAIL", "SKIP")]
    if not any(r[1].strip() == "PASS" for r in rows):
        problems.append("app verification has no passing check")
    if any(r[1].strip() == "FAIL" for r in rows):
        problems.append("app verification has a FAIL")
    if "Not covered by any check" in block:
        problems.append("app verification left files uncovered")
    if "Needs a live check by Justin" in block:
        problems.append("app verification needs a live check by Justin")
    return problems


def evaluate(pr: dict, extra: dict, config: dict) -> tuple[dict | None, list[str]]:
    """Return (lane, reasons). No reasons means the PR may merge.

    `extra` carries what `gh pr view` doesn't: paginated REST changed_files
    (including previous_filename), unresolved_threads (int), and
    reviewer_reactions (list of {login, created_at}).
    """
    reasons: list[str] = []
    lane = find_lane(pr["headRefName"], config)
    if lane is None:
        return None, ["branch is not in an auto-merge lane"]
    if not lane.get("enabled", False):
        reasons.append(f"lane {lane['id']} is disabled")

    if pr.get("isCrossRepository"):
        reasons.append("PR comes from a fork")
    if bare_login(pr["author"]["login"]) not in config["allowed_authors"]:
        reasons.append(f"author {pr['author']['login']} is not allowed")

    labels = {label["name"] for label in pr.get("labels", [])}
    for needed in lane.get("labels_required", []):
        if needed not in labels:
            reasons.append(f"missing label '{needed}'")
    blocked = sorted(labels & set(config["blocking_labels"]))
    if blocked:
        reasons.append(f"blocking label: {', '.join(blocked)}")

    files, file_problems = changed_paths(extra.get("changed_files"), pr.get("changedFiles"))
    reasons.extend(file_problems)
    if not files:
        reasons.append("no changed files reported")
    denied = [p for p in files if matches(p, config["deny_always"] + lane.get("deny", []))]
    if denied:
        reasons.append(f"touches protected files: {', '.join(denied[:3])}")
    outside = [p for p in files if not matches(p, lane["allow"]) and p not in denied]
    if outside:
        reasons.append(f"files outside lane {lane['id']}: {', '.join(outside[:3])}")
    if lane.get("require_test_change") and not any(matches(p, TEST_GLOBS) for p in files):
        reasons.append("bug fix without a test change")
    if lane.get("require_verify"):
        reasons.extend(verify_problems(pr.get("body") or "", pr["headRefOid"]))

    size = pr.get("additions", 0) + pr.get("deletions", 0)
    if size > lane["max_changed_lines"]:
        reasons.append(f"{size} changed lines, lane limit is {lane['max_changed_lines']}")

    checks = {c.get("name") or c.get("context"): c for c in pr.get("statusCheckRollup", [])}
    for name in config["required_checks"]:
        check = checks.get(name)
        if check is None:
            reasons.append(f"check {name} hasn't reported")
            continue
        result = check.get("conclusion") or check.get("state")
        if result != "SUCCESS":
            reasons.append(f"check {name} is {result or check.get('status') or 'pending'}")

    if pr.get("mergeable") != "MERGEABLE":
        reasons.append(f"GitHub says mergeable={pr.get('mergeable')}")

    reviews = pr.get("reviews", [])
    if any(r.get("state") == "CHANGES_REQUESTED" for r in reviews):
        reasons.append("a review requests changes")
    if extra.get("unresolved_threads", 0):
        reasons.append(f"{extra['unresolved_threads']} unresolved review thread(s)")

    head = pr["headRefOid"]
    commits = pr.get("commits", [])
    pushed_at = parse_time(commits[-1]["committedDate"]) if commits else None
    for reviewer in lane.get("reviewers_required", config["default_reviewers"]):
        reviewed_head = any(
            bare_login(r["author"]["login"]) == reviewer and (r.get("commit") or {}).get("oid") == head
            for r in reviews
        )
        thumbs_up = pushed_at is not None and any(
            bare_login(x["login"]) == reviewer and parse_time(x["created_at"]) >= pushed_at
            for x in extra.get("reviewer_reactions", [])
        )
        if not (reviewed_head or thumbs_up):
            reasons.append(f"waiting for a {reviewer} review of the latest commit")

    return lane, reasons


def waiting_only_on_review(reasons: list[str]) -> bool:
    """True when the review is the only thing missing."""
    return bool(reasons) and all(r.startswith("waiting for a ") for r in reasons)


def main_is_healthy(config: dict) -> tuple[bool, str]:
    runs = gh_json("run", "list", "--workflow", config["main_ci_workflow"], "--branch", "main",
                   "--event", "push", "--limit", "10", "--json", "status,conclusion,headSha")
    finished = [r for r in runs if r["status"] == "completed" and r["conclusion"] not in ("cancelled", "skipped")]
    if not finished:
        return False, "no finished Swift CI run on main"
    latest = finished[0]
    if latest["conclusion"] != "success":
        return False, f"main's latest Swift CI run is {latest['conclusion']} ({latest['headSha'][:7]})"
    return True, f"main is green ({latest['headSha'][:7]})"


def fetch_extra(number: int, config: dict) -> dict:
    owner, name = gh("repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner").strip().split("/")
    query = (
        "query($o:String!,$n:String!,$p:Int!){repository(owner:$o,name:$n){pullRequest(number:$p)"
        "{reviewThreads(first:100){nodes{isResolved}}}}}"
    )
    data = gh_json("api", "graphql", "-f", f"query={query}", "-F", f"o={owner}", "-F", f"n={name}",
                   "-F", f"p={number}")
    threads = data["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"]
    reactions = gh_json("api", f"repos/{owner}/{name}/issues/{number}/reactions",
                        "-H", "Accept: application/vnd.github+json")
    file_pages = gh_json("api", f"repos/{owner}/{name}/pulls/{number}/files?per_page=100",
                         "--paginate", "--slurp", "-H", "Accept: application/vnd.github+json")
    if not isinstance(file_pages, list) or not all(isinstance(page, list) for page in file_pages):
        raise RuntimeError("PR files API returned malformed pages; refusing to merge")
    return {
        "changed_files": [record for page in file_pages for record in page],
        "unresolved_threads": sum(1 for t in threads if not t["isResolved"]),
        "reviewer_reactions": [
            {"login": r["user"]["login"], "created_at": r["created_at"]}
            for r in reactions if r["content"] == "+1"
        ],
    }


def merge(pr: dict, lane: dict) -> None:
    number = str(pr["number"])
    if pr.get("isDraft"):
        gh("pr", "ready", number)
    gh("pr", "merge", number, "--merge", "--match-head-commit", pr["headRefOid"])
    gh("pr", "comment", number, "--body",
       f"Merged by the auto-merge gate (lane `{lane['id']}`, level {lane.get('level', 1)}): required "
       f"checks green, required reviewers reviewed the head commit, no open threads, every file "
       f"inside the lane. See docs/auto-merge-gate.md.")


def run(apply: bool, only: int | None) -> int:
    config = json.loads(CONFIG_PATH.read_text())
    healthy, why = main_is_healthy(config)
    print(f"main: {why}")
    if only is not None:
        numbers = [only]
    else:
        listed = gh_json("pr", "list", "--state", "open", "--limit", "200", "--json", "number,headRefName")
        numbers = [p["number"] for p in listed if find_lane(p["headRefName"], config)]
    merged = 0
    merged_lanes: set[str] = set()
    for number in sorted(numbers):
        pr = gh_json("pr", "view", str(number), "--json", PR_FIELDS)
        lane, reasons = evaluate(pr, fetch_extra(number, config), config)
        if lane is not None and not reasons:
            if not healthy:
                reasons = ["main is red, merging nothing"]
            elif merged >= config["max_merges_per_run"]:
                reasons = ["run's merge limit reached, next run"]
            elif lane["id"] in merged_lanes:
                reasons = [f"already merged one {lane['id']} PR this run, next run"]
        label = lane["id"] if lane else "-"
        if reasons:
            if lane is not None and pr.get("isDraft") and waiting_only_on_review(reasons):
                if apply:
                    gh("pr", "ready", str(number))
                print(f"#{number} [{label}] {'marked' if apply else 'would mark'} ready for review; "
                      f"merges after: {'; '.join(reasons)}")
                continue
            print(f"#{number} [{label}] wait: {'; '.join(reasons)}")
            continue
        if apply:
            merge(pr, lane)
            print(f"#{number} [{label}] MERGED: {pr['title']}")
        else:
            print(f"#{number} [{label}] would merge: {pr['title']}")
        merged += 1
        merged_lanes.add(lane["id"])
    print(f"{'merged' if apply else 'would merge'} {merged} PR(s)")
    return 0


def self_test() -> int:
    config = json.loads(CONFIG_PATH.read_text())
    head = "abc1234def5678"
    base_pr = {
        "number": 1, "title": "t", "headRefName": "cleanup/test-shape/foo", "headRefOid": head,
        "isDraft": True, "isCrossRepository": False, "labels": [{"name": "cleanup"}],
        "author": {"login": "r3dbars"}, "additions": 40, "deletions": 30, "mergeable": "MERGEABLE",
        "files": [{"path": "Tests/FooTests.swift"}, {"path": ".agents/test-shape-baseline.json"}],
        "changedFiles": 2,
        "statusCheckRollup": [{"name": "build-and-test", "conclusion": "SUCCESS"},
                              {"name": "repo-hygiene", "conclusion": "SUCCESS"}],
        "reviews": [{"author": {"login": "chatgpt-codex-connector"}, "state": "COMMENTED",
                     "commit": {"oid": head}}],
        "commits": [{"committedDate": "2026-10-07T10:00:00Z"}],
    }
    extra = {"unresolved_threads": 0, "reviewer_reactions": [],
             "changed_files": [{"filename": f["path"], "status": "modified"} for f in base_pr["files"]]}

    def case(name: str, expect_ok: bool, pr_patch: dict | None = None, extra_patch: dict | None = None,
             expect_text: str = "") -> bool:
        pr = {**base_pr, **(pr_patch or {})}
        # Existing fixtures use paths; evaluation itself requires REST metadata.
        files = pr.pop("files")
        pr["changedFiles"] = len(files)
        ex = {**extra, "changed_files": [{"filename": f["path"], "status": "modified"} for f in files],
              **(extra_patch or {})}
        if pr_patch and "changedFiles" in pr_patch:
            pr["changedFiles"] = pr_patch["changedFiles"]
        _, reasons = evaluate(pr, ex, config)
        ok = not reasons
        passed = ok == expect_ok and (not expect_text or any(expect_text in r for r in reasons))
        print(f"{'PASS' if passed else 'FAIL'} {name}: {reasons or 'ok'}")
        return passed

    results = [
        case("clean test-shape PR merges", True),
        case("thumbs-up after push counts as review", True,
             {"reviews": []}, {"reviewer_reactions": [{"login": "chatgpt-codex-connector[bot]",
                                                       "created_at": "2026-10-07T10:05:00Z"}]}),
        case("thumbs-up before push doesn't count", False,
             {"reviews": []}, {"reviewer_reactions": [{"login": "chatgpt-codex-connector[bot]",
                                                       "created_at": "2026-10-07T09:00:00Z"}]},
             "waiting for a chatgpt-codex-connector review"),
        case("review of an older commit doesn't count", False,
             {"reviews": [{"author": {"login": "chatgpt-codex-connector"}, "state": "COMMENTED",
                           "commit": {"oid": "old"}}]}, None, "waiting for a chatgpt-codex-connector review"),
        case("branch outside lanes", False, {"headRefName": "claude/feature"}, None, "not in an auto-merge lane"),
        case("protected engine file", False,
             {"headRefName": "cleanup/file-size/x", "files": [{"path": "Sources/TranscriptedCore/Audio/A.swift"}]},
             None, "protected files"),
        case("root AGENTS.md is protected", False,
             {"headRefName": "cleanup/file-size/x", "files": [{"path": "AGENTS.md"}]}, None, "protected files"),
        case("folder AGENTS.md allowed in file-size lane", True,
             {"headRefName": "cleanup/file-size/x",
              "files": [{"path": "Sources/UI/AGENTS.md"}, {"path": "Sources/UI/Home/HomeView.swift"}]}),
        case("Sources file outside test-shape lane", False,
             {"files": [{"path": "Sources/UI/Home/HomeView.swift"}]}, None, "outside lane"),
        case("rename from protected source blocks", False,
             {"files": [{"path": "Tests/FooTests.swift"}]},
             {"changed_files": [{"filename": "Tests/FooTests.swift", "status": "renamed",
                                 "previous_filename": "Sources/TranscriptedCore/Audio/A.swift"}]},
             "protected files"),
        case("rename protected threat model to allowed docs blocks", False,
             {"headRefName": "garden/docs/x", "labels": [{"name": "gardener"}],
              "files": [{"path": "docs/x.md"}]},
             {"changed_files": [{"filename": "docs/x.md", "status": "renamed",
                                 "previous_filename": "docs/threat-model.md"}]}, "protected files"),
        case("rename protected playbook to allowed docs blocks", False,
             {"headRefName": "garden/docs/x", "labels": [{"name": "gardener"}],
              "files": [{"path": "docs/x.md"}]},
             {"changed_files": [{"filename": "docs/x.md", "status": "renamed",
                                 "previous_filename": "docs/automations/finding-responder.md"}]},
             "protected files"),
        case("rename to protected destination blocks", False,
             {"files": [{"path": "Sources/TranscriptedCore/Audio/A.swift"}]},
             {"changed_files": [{"filename": "Sources/TranscriptedCore/Audio/A.swift", "status": "renamed",
                                 "previous_filename": "Tests/FooTests.swift"}]}, "protected files"),
        case("rename from outside lane blocks", False,
             {"files": [{"path": "Tests/FooTests.swift"}]},
             {"changed_files": [{"filename": "Tests/FooTests.swift", "status": "renamed",
                                 "previous_filename": "Sources/Support/Foo.swift"}]}, "outside lane"),
        case("rename inside lane merges", True,
             {"files": [{"path": "Tests/FooTests.swift"}]},
             {"changed_files": [{"filename": "Tests/FooTests.swift", "status": "renamed",
                                 "previous_filename": "Tests/OldFooTests.swift"}]}),
        case("protected deletion blocks", False,
             {"files": [{"path": "AGENTS.md"}]},
             {"changed_files": [{"filename": "AGENTS.md", "status": "removed"}]}, "protected files"),
        case("allowed deletion merges", True,
             {"files": [{"path": "Tests/FooTests.swift"}]},
             {"changed_files": [{"filename": "Tests/FooTests.swift", "status": "removed"}]}),
        case("rename without source fails closed", False,
             {"files": [{"path": "Tests/FooTests.swift"}]},
             {"changed_files": [{"filename": "Tests/FooTests.swift", "status": "renamed"}]},
             "malformed rename"),
        case("rename with invalid source fails closed", False,
             {"files": [{"path": "Tests/FooTests.swift"}]},
             {"changed_files": [{"filename": "Tests/FooTests.swift", "status": "renamed",
                                 "previous_filename": "../AGENTS.md"}]}, "malformed rename"),
        case("unexpected rename metadata fails closed", False,
             {"files": [{"path": "Tests/FooTests.swift"}]},
             {"changed_files": [{"filename": "Tests/FooTests.swift", "status": "modified",
                                 "previous_filename": "AGENTS.md"}]}, "malformed rename"),
        case("missing REST metadata fails closed", False, None, {"changed_files": None}, "metadata"),
        case("truncated files fail closed", False, {"changedFiles": 3}, None, "incomplete"),
        case("owner-review label blocks", False,
             {"labels": [{"name": "cleanup"}, {"name": "needs owner review"}]}, None, "blocking label"),
        case("missing cleanup label", False, {"labels": []}, None, "missing label"),
        case("too big", False, {"additions": 500}, None, "lane limit"),
        case("failing check", False,
             {"statusCheckRollup": [{"name": "build-and-test", "conclusion": "FAILURE"},
                                    {"name": "repo-hygiene", "conclusion": "SUCCESS"}]}, None, "build-and-test"),
        case("missing check", False,
             {"statusCheckRollup": [{"name": "build-and-test", "conclusion": "SUCCESS"}]}, None, "repo-hygiene"),
        case("conflict", False, {"mergeable": "CONFLICTING"}, None, "mergeable"),
        case("changes requested", False,
             {"reviews": base_pr["reviews"] + [{"author": {"login": "r3dbars"}, "state": "CHANGES_REQUESTED",
                                                "commit": {"oid": head}}]}, None, "requests changes"),
        case("unresolved thread", False, None, {"unresolved_threads": 2}, "unresolved"),
        case("fork", False, {"isCrossRepository": True}, None, "fork"),
        case("other author", False, {"author": {"login": "someone"}}, None, "not allowed"),
    ]
    verify_body = (f"Fixes #12\n\n## App verification\n\nBase: `origin/main` · head: `{head[:7]}`\n\n"
                   "| Check | Result | Detail |\n|---|---|---|\n| ui | PASS | opened Home |\n")
    both_reviews = [{"author": {"login": "chatgpt-codex-connector"}, "state": "COMMENTED", "commit": {"oid": head}},
                    {"author": {"login": "claude"}, "state": "COMMENTED", "commit": {"oid": head}}]
    bug = {"headRefName": "codex/issue-12-fix", "labels": [{"name": "bug"}], "body": verify_body,
           "files": [{"path": "Sources/Support/Foo.swift"}, {"path": "Tests/FooTests.swift"}],
           "reviews": both_reviews}
    results += [
        case("bug fix with proof and two reviews merges", True, bug),
        case("bug fix without a test", False, {**bug, "files": [{"path": "Sources/Support/Foo.swift"}]},
             None, "without a test change"),
        case("bug fix without verify summary", False, {**bug, "body": "Fixes #12"}, None, "no app verification"),
        case("bug fix verify for old commit", False, {**bug, "body": verify_body.replace(head[:7], "0ff0ff0")},
             None, "not for the head commit"),
        case("bug fix verify FAIL", False, {**bug, "body": verify_body + "| paste | FAIL | nope |\n"},
             None, "has a FAIL"),
        case("bug fix owes a live check", False,
             {**bug, "body": verify_body + "\n**Needs a live check by Justin:** audio changed.\n"},
             None, "live check"),
        case("bug fix with only Codex review merges", True, {**bug, "reviews": both_reviews[:1]}),
        case("bug fix without Codex review", False, {**bug, "reviews": both_reviews[1:]}, None,
             "chatgpt-codex-connector review"),
        case("bug fix in UI is owner-only", False,
             {**bug, "files": [{"path": "Sources/UI/Home/HomeView.swift"}, {"path": "Tests/FooTests.swift"}]},
             None, "protected files"),
        case("bug fix missing bug label", False, {**bug, "labels": []}, None, "missing label 'bug'"),
        case("module-edges lane", True,
             {"headRefName": "cleanup/module-edges/x",
              "files": [{"path": "Sources/Dictation/Foo.swift"}, {"path": ".agents/module-boundary-baseline.json"}]}),
        case("docs lane merges folder docs", True,
             {"headRefName": "garden/docs/ui", "labels": [{"name": "gardener"}],
              "files": [{"path": "Sources/UI/AGENTS.md"}, {"path": "docs/storage-paths.md"}]}),
        case("docs lane can't touch release docs", False,
             {"headRefName": "garden/docs/x", "labels": [{"name": "gardener"}],
              "files": [{"path": "docs/release-packaging.md"}]}, None, "protected files"),
    ]
    ready_cases = [
        (["waiting for a chatgpt-codex-connector review of the latest commit"], True),
        (["check build-and-test is pending", "waiting for a chatgpt-codex-connector review of the latest commit"], False),
        ([], False),
    ]
    for reasons_in, expected in ready_cases:
        ok = waiting_only_on_review(reasons_in) == expected
        results.append(ok)
        print(f"{'PASS' if ok else 'FAIL'} ready-for-review when only waiting on review={expected}: {reasons_in}")
    disabled = json.loads(json.dumps(config))
    disabled["lanes"][0]["enabled"] = False
    _, reasons = evaluate(base_pr, extra, disabled)
    results.append(any("disabled" in r for r in reasons))
    print(f"{'PASS' if results[-1] else 'FAIL'} disabled lane blocks: {reasons}")

    failed = results.count(False)
    print(f"{len(results) - failed}/{len(results)} passed")
    return 1 if failed else 0


def cli() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apply", action="store_true", help="merge qualifying PRs (default is a dry run)")
    parser.add_argument("--pr", type=int, help="evaluate only this PR")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    return run(apply=args.apply, only=args.pr)


if __name__ == "__main__":
    sys.exit(cli())

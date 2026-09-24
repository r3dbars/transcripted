#!/usr/bin/env python3
"""Pick where Swift CI's `checks` and `spm-tests` jobs run.

They go to the owner's Mac (a self-hosted runner labelled transcripted-mac,
running under its own standard macOS account) only when all of these hold:

  * the MAC_RUNNER_MODE repo variable is not "off"
  * the run is a push, a workflow_dispatch, or a pull_request whose head
    branch lives in this repo (fork PRs always stay hosted)
  * the MAC_RUNNER_HEARTBEAT repo variable is a Unix timestamp at most
    MAX_AGE_SECONDS old; the Mac writes a timestamp only while its runner is
    up and idle and nobody is using a microphone, and a word (busy, paused,
    battery, mic, offline) otherwise
  * no other run already has a transcripted-mac job queued or running, so a
    burst of pushes can't pile up behind one Mac while hosted slots sit free

Anything else, including any GitHub API error, picks hosted macos-26.

Env inputs: HEARTBEAT, MODE, EVENT, HEAD_REPO, REPO, GITHUB_TOKEN,
GITHUB_RUN_ID, GITHUB_API_URL, and optionally NOW and MAX_AGE_SECONDS.
Writes runs-on=<JSON> to $GITHUB_OUTPUT.

Usage: python3 scripts/ci/pick-ci-runner.py [--self-test]
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.request

HOSTED = '"macos-26"'
MAC = '["transcripted-mac"]'
MAC_LABEL = "transcripted-mac"
ROUTED_EVENTS = {"push", "workflow_dispatch", "pull_request"}


def decide(
    *,
    event: str,
    repo: str,
    head_repo: str,
    heartbeat: str,
    mode: str,
    now: int,
    max_age: int,
    busy_mac_jobs: int | None,
) -> tuple[str, str]:
    """Return ("mac" | "hosted", reason). busy_mac_jobs None = lookup failed."""
    if mode.strip().lower() == "off":
        return "hosted", "MAC_RUNNER_MODE is off"
    if event not in ROUTED_EVENTS:
        return "hosted", f"event {event or 'unset'} is not routed to the Mac"
    if event == "pull_request" and (not head_repo or head_repo != repo):
        # The Mac's job-started hook refuses these too, since a fork can edit
        # this workflow.
        return "hosted", "pull request comes from a fork"
    if not re.fullmatch(r"[0-9]+", heartbeat or ""):
        return "hosted", f"Mac heartbeat is '{heartbeat or 'unset'}'"
    age = now - int(heartbeat)
    # Allow a little clock skew in the Mac's favour, no more.
    if age < -30 or age > max_age:
        return "hosted", f"Mac heartbeat is {age}s old"
    if busy_mac_jobs is None:
        return "hosted", "could not count jobs already waiting for the Mac"
    if busy_mac_jobs > 0:
        return "hosted", f"{busy_mac_jobs} job(s) already queued or running on the Mac"
    return "mac", f"Mac reported idle {age}s ago"


def _get(url: str, token: str) -> dict:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def count_busy_mac_jobs(api: str, repo: str, token: str, this_run: str) -> int | None:
    """Jobs in other runs that target the Mac and are queued or running."""
    if not token:
        return None
    try:
        busy = 0
        for status in ("queued", "in_progress"):
            runs = _get(f"{api}/repos/{repo}/actions/runs?status={status}&per_page=50", token)
            for run in runs.get("workflow_runs", []):
                if str(run.get("id")) == this_run:
                    continue
                jobs = _get(f"{api}/repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100", token)
                for job in jobs.get("jobs", []):
                    if job.get("status") in ("queued", "in_progress") and MAC_LABEL in (job.get("labels") or []):
                        busy += 1
        return busy
    except Exception as error:  # noqa: BLE001 - any failure means "use hosted"
        print(f"job lookup failed: {error}", file=sys.stderr)
        return None


def self_test() -> int:
    now = 1_000_000
    r = "r3dbars/transcripted"
    base = dict(event="pull_request", repo=r, head_repo=r, heartbeat=str(now - 10),
                mode="", now=now, max_age=60, busy_mac_jobs=0)
    cases = [
        ("mac", {}),
        ("mac", dict(event="push", head_repo="")),
        ("mac", dict(event="workflow_dispatch", head_repo="")),
        ("mac", dict(heartbeat=str(now - 60))),
        ("mac", dict(heartbeat=str(now + 30))),
        ("hosted", dict(head_repo="someone/fork")),
        ("hosted", dict(head_repo="")),
        ("hosted", dict(event="pull_request_target")),
        ("hosted", dict(event="workflow_run")),
        ("hosted", dict(event="")),
        ("hosted", dict(heartbeat=str(now - 61))),
        ("hosted", dict(heartbeat=str(now + 31))),
        ("hosted", dict(heartbeat="")),
        ("hosted", dict(heartbeat="busy")),
        ("hosted", dict(heartbeat="mic")),
        ("hosted", dict(heartbeat="12 34")),
        ("hosted", dict(heartbeat="-5")),
        ("hosted", dict(mode="off")),
        ("hosted", dict(mode="OFF")),
        ("hosted", dict(busy_mac_jobs=1)),
        ("hosted", dict(busy_mac_jobs=None)),
    ]
    failures = 0
    for want, overrides in cases:
        args = {**base, **overrides}
        got, reason = decide(**args)
        if got != want:
            print(f"FAIL: {overrides} -> {got} ({reason}), want {want}", file=sys.stderr)
            failures += 1
    if count_busy_mac_jobs("https://api.github.invalid", r, "", "1") is not None:
        print("FAIL: missing token should mean the lookup failed", file=sys.stderr)
        failures += 1
    if failures:
        print(f"pick-ci-runner self-test: {failures} failure(s)", file=sys.stderr)
        return 1
    print("pick-ci-runner self-test: ok")
    return 0


def main() -> int:
    if sys.argv[1:] == ["--self-test"]:
        return self_test()

    env = os.environ.get
    repo = env("REPO", "")
    event = env("EVENT", "")
    head_repo = env("HEAD_REPO", "")
    heartbeat = env("HEARTBEAT", "")
    mode = env("MODE", "")
    now = int(env("NOW") or time.time())
    max_age = int(env("MAX_AGE_SECONDS") or 60)

    # Only spend API calls once everything else already says "Mac".
    choice, reason = decide(event=event, repo=repo, head_repo=head_repo, heartbeat=heartbeat,
                            mode=mode, now=now, max_age=max_age, busy_mac_jobs=0)
    if choice == "mac":
        busy = count_busy_mac_jobs(env("GITHUB_API_URL", "https://api.github.com"), repo,
                                   env("GITHUB_TOKEN", ""), env("GITHUB_RUN_ID", ""))
        choice, reason = decide(event=event, repo=repo, head_repo=head_repo, heartbeat=heartbeat,
                                mode=mode, now=now, max_age=max_age, busy_mac_jobs=busy)

    runs_on = MAC if choice == "mac" else HOSTED
    print(f"checks + spm-tests -> {runs_on} ({reason})")
    if env("GITHUB_OUTPUT"):
        with open(env("GITHUB_OUTPUT"), "a", encoding="utf-8") as handle:
            handle.write(f"runs-on={runs_on}\n")
    if env("GITHUB_STEP_SUMMARY"):
        with open(env("GITHUB_STEP_SUMMARY"), "a", encoding="utf-8") as handle:
            handle.write(f"checks + spm-tests run on `{runs_on}`: {reason}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

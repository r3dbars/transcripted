#!/usr/bin/env python3
"""Pick where Swift CI's `checks` and `spm-tests` jobs run.

They go to the owner's Mac (a one-job runner labelled transcripted-mac, in a
fresh throwaway macOS VM) only when all of these hold:

  * the MAC_RUNNER_MODE repo variable is not "off"
  * the run is a push, a workflow_dispatch, or a pull_request whose head
    branch lives in this repo (fork PRs always stay hosted)
  * the MAC_RUNNER_HEARTBEAT repo variable is a bare Unix timestamp at most
    MAX_AGE_SECONDS old. The Mac writes a bare timestamp only while it is
    free, and "<word>:<timestamp>" (busy, paused, battery, disk, vms, mic,
    offline) otherwise
  * no other Swift CI run already has a transcripted-mac job queued or
    running, so a burst of pushes can't pile up behind one Mac

Anything else, including any GitHub API error, picks hosted macos-26.

With --reroute (run from main by .github/workflows/mac-runner-sweep.yml,
with an actions: write token), it instead sends stranded runs back to
GitHub: when the Mac's heartbeat has not changed for SERVICE_ALIVE_SECONDS
(it is asleep, off, or its service died) and a run's Mac job has been queued
for STRANDED_SECONDS, that run is cancelled and re-run, and the re-run picks
hosted because the heartbeat is stale. A live Mac handles its own stuck jobs
(scripts/ci/mac-runner.sh).

Env inputs: HEARTBEAT, MODE, EVENT, HEAD_REPO, REPO, GITHUB_TOKEN,
GITHUB_RUN_ID, GITHUB_API_URL, and optionally NOW and MAX_AGE_SECONDS.
Writes runs-on=<JSON> to $GITHUB_OUTPUT.

Usage: python3 scripts/ci/pick-ci-runner.py [--self-test | --reroute]
"""

from __future__ import annotations

import calendar
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
SERVICE_ALIVE_SECONDS = 600
STRANDED_SECONDS = 900


def parse_heartbeat(heartbeat: str) -> tuple[str, int | None]:
    """("", ts) when free, (word, ts) when not, (heartbeat, None) if unreadable."""
    value = (heartbeat or "").strip()
    if re.fullmatch(r"[0-9]+", value):
        return "", int(value)
    match = re.fullmatch(r"([a-z]+):([0-9]+)", value)
    if match:
        return match.group(1), int(match.group(2))
    return value or "unset", None


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
    word, stamp = parse_heartbeat(heartbeat)
    if word or stamp is None:
        # Logs are public: never say why (a call, battery, paused).
        return "hosted", "the Mac is not free" if stamp is not None else "no Mac heartbeat"
    age = now - stamp
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


def _post(url: str, token: str) -> None:
    request = urllib.request.Request(
        url,
        method="POST",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=20):
        pass


def list_mac_jobs(api: str, repo: str, token: str, this_run: str, now: int) -> list[dict] | None:
    """Mac jobs in other Swift CI runs that are queued or running.

    Each is {"run": id, "status": ..., "age": seconds since it was queued}.
    None means the lookup failed.
    """
    if not token:
        return None
    try:
        found = []
        runs = []
        for page in range(1, 6):
            batch = _get(f"{api}/repos/{repo}/actions/workflows/swift-ci.yml/runs"
                         f"?status=in_progress&per_page=100&page={page}", token).get("workflow_runs", [])
            runs.extend(batch)
            if len(batch) < 100:
                break
        for run in runs:
            if str(run.get("id")) == this_run:
                continue
            jobs = _get(f"{api}/repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100", token)
            for job in jobs.get("jobs", []):
                if job.get("status") not in ("queued", "in_progress") or MAC_LABEL not in (job.get("labels") or []):
                    continue
                created = job.get("created_at") or ""
                try:
                    age = now - calendar.timegm(time.strptime(created, "%Y-%m-%dT%H:%M:%SZ"))
                except ValueError:
                    age = 0
                found.append({"run": run["id"], "status": job.get("status"), "age": age})
        return found
    except Exception as error:  # noqa: BLE001 - any failure means "use hosted"
        print(f"job lookup failed: {error}", file=sys.stderr)
        return None


def runs_to_reroute(jobs: list[dict], heartbeat: str, now: int) -> list[int]:
    """Runs whose Mac job is stuck because the Mac stopped answering."""
    _, stamp = parse_heartbeat(heartbeat)
    if stamp is not None and now - stamp <= SERVICE_ALIVE_SECONDS:
        return []  # the Mac is alive and deals with its own queue
    return sorted({job["run"] for job in jobs if job["status"] == "queued" and job["age"] > STRANDED_SECONDS})


def reroute(api: str, repo: str, token: str, run: int) -> None:
    """Cancel a run, wait for it to stop, and re-run all of its jobs."""
    try:
        print(f"run {run} has waited too long for the owner's Mac; re-running it on GitHub's runners")
        _post(f"{api}/repos/{repo}/actions/runs/{run}/cancel", token)
        for attempt in range(30):
            if _get(f"{api}/repos/{repo}/actions/runs/{run}", token).get("status") == "completed":
                break
            if attempt == 11:
                # build-and-test runs even after a cancel (if: always()).
                try:
                    _post(f"{api}/repos/{repo}/actions/runs/{run}/force-cancel", token)
                except Exception:  # noqa: BLE001 - e.g. 409 once it already stopped
                    pass
            time.sleep(5)
        for attempt in range(3):
            try:
                _post(f"{api}/repos/{repo}/actions/runs/{run}/rerun", token)
                return
            except Exception:  # noqa: BLE001 - the run may still be finishing
                if attempt == 2:
                    raise
                time.sleep(10)
    except Exception as error:  # noqa: BLE001 - never fail this run over another one
        print(f"could not re-run {run}: {error}", file=sys.stderr)


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
        ("hosted", dict(heartbeat=f"busy:{now}")),
        ("hosted", dict(heartbeat=f"mic:{now}")),
        ("hosted", dict(heartbeat=f"paused:{now - 5}")),
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

    stuck = [{"run": 7, "status": "queued", "age": STRANDED_SECONDS + 1},
             {"run": 7, "status": "queued", "age": STRANDED_SECONDS + 5},
             {"run": 8, "status": "queued", "age": STRANDED_SECONDS - 1},
             {"run": 9, "status": "in_progress", "age": STRANDED_SECONDS * 3}]
    reroutes = [
        ([7], stuck, f"busy:{now - SERVICE_ALIVE_SECONDS - 1}"),  # Mac went quiet
        ([7], stuck, str(now - SERVICE_ALIVE_SECONDS - 1)),
        ([7], stuck, "garbled"),  # unreadable heartbeat
        ([], stuck, f"busy:{now - 30}"),  # Mac alive: it handles its own queue
        ([], stuck, str(now - 5)),
        ([], [], f"busy:{now - 10_000}"),
    ]
    for want, jobs, heartbeat in reroutes:
        got = runs_to_reroute(jobs, heartbeat, now)
        if got != want:
            print(f"FAIL: reroute with heartbeat {heartbeat!r} -> {got}, want {want}", file=sys.stderr)
            failures += 1
    if list_mac_jobs("https://api.github.invalid", r, "", "1", now) is not None:
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
    heartbeat = env("HEARTBEAT", "")
    now = int(env("NOW") or time.time())
    api = env("GITHUB_API_URL", "https://api.github.com")
    token = env("GITHUB_TOKEN", "")

    if sys.argv[1:] == ["--reroute"]:
        # With no heartbeat the Mac was never set up, so nothing can be stuck.
        if not heartbeat:
            print("no Mac heartbeat; nothing to do")
            return 0
        jobs = list_mac_jobs(api, repo, token, "", now)
        stuck = runs_to_reroute(jobs or [], heartbeat, now)
        print(f"{len(jobs or [])} Mac job(s) queued or running; {len(stuck)} run(s) stuck")
        # A few per sweep, so this job stays well inside its time limit.
        for run in stuck[:3]:
            reroute(api, repo, token, run)
        return 0

    event = env("EVENT", "")
    head_repo = env("HEAD_REPO", "")
    mode = env("MODE", "")
    max_age = int(env("MAX_AGE_SECONDS") or 60)

    # Only spend API calls once everything else already says "Mac".
    choice, reason = decide(event=event, repo=repo, head_repo=head_repo, heartbeat=heartbeat,
                            mode=mode, now=now, max_age=max_age, busy_mac_jobs=0)
    if choice == "mac":
        jobs = list_mac_jobs(api, repo, token, env("GITHUB_RUN_ID", ""), now)
        busy = None if jobs is None else len(jobs)
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

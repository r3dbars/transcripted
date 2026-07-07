#!/usr/bin/env python3
"""Crash-free-rate release gate for Transcripted.

Queries Sentry's Release Health (Sessions) API for a release's crash-free
session rate and crash-free user rate, then decides a go/no-go verdict:

    green  (exit 0)  crash-free-sessions >= threshold on enough data
    red    (exit 1)  crash-free-sessions <  threshold           -> blocks ship
    yellow (exit 3)  cannot verify (creds absent, API error, or
                     too little session data)                    -> never auto-green

Both red and yellow exit non-zero: a release is not "cleared to ship" if the
crash-free rate is below threshold OR unverifiable. This mirrors how
`docs/release-guardrails.md` treats missing proof (YELLOW/UNKNOWN, never green).

Auth reuses the ops-script convention: SENTRY_AUTH_TOKEN from the environment or
one of the ops env files (see load_env). Org/project default to r3dbars /
apple-macos and can be overridden by SENTRY_ORG / SENTRY_PROJECT. The release
name matches scripts/release/sentry-release-metadata.py: `transcripted@<version>`.

This script is read-only. It never tags, notarizes, publishes, or mutates any
release surface. It only reports a gate verdict.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


# Verdict -> process exit code. Matches scripts/ops/release-gate-report.py so a
# wrapper sees the same red=1 / yellow=3 semantics across the ops toolkit.
EXIT_CODES = {"green": 0, "red": 1, "yellow": 3}

DEFAULT_ORG = "r3dbars"
DEFAULT_PROJECT = "apple-macos"
DEFAULT_RELEASE_PREFIX = "transcripted"
SENTRY_BASE = "https://sentry.io/api/0"
HTTP_HEADERS = {"User-Agent": "TranscriptedCrashFreeGate/1.0"}

# Threshold reasoning (all overridable by flag or env):
#
# * 99.5% crash-free sessions is the widely used release-health ship gate:
#   Sentry's own default release-health alert target is 99.5%, and Google Play's
#   "bad behavior" line sits at ~1.1% crash rate (~98.9% crash-free). 99.5%
#   gives a little headroom above that floor without demanding perfection.
# * Crash-free USERS is gated looser (99.0%) and treated as a secondary signal:
#   one crashing user with many sessions can drag the user rate down hard on a
#   low-volume desktop app, so a red there alone should not block on its own.
#   It is reported and can gate if you tighten --user-threshold.
# * --min-sessions guards against false-green on thin data. A 100% rate from 3
#   sessions is not proof of health. Below the floor the verdict is YELLOW
#   (unknown), never green. 25 is a low but non-trivial default; widen the
#   window with --stats-period for low-volume releases instead of trusting a
#   handful of sessions.
DEFAULT_SESSION_THRESHOLD = 99.5
DEFAULT_USER_THRESHOLD = 99.0
DEFAULT_MIN_SESSIONS = 25
# 24h reflects "the release right now". Low-volume releases should widen this
# (e.g. --stats-period 14d) rather than ship on a thin 24h sample; the
# min-sessions guard turns a thin sample into YELLOW, not a false green.
DEFAULT_STATS_PERIOD = "24h"


def load_env() -> None:
    """Populate os.environ from the ops env files, matching release-health-card.py.

    Existing environment values win, so an explicit export is never clobbered.
    """
    for path in (
        Path.cwd() / ".env.local",
        Path.cwd() / ".env",
        Path.home() / ".transcripted-ops.env",
        Path.home() / ".hermes" / ".env",
        Path.home() / ".hermes" / "profiles" / "ops" / ".env",
    ):
        if not path.is_file():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip().removeprefix("export ").strip()
            value = value.strip().strip('"').strip("'")
            if key and value and key not in os.environ:
                os.environ[key] = value


def info_plist_version(root: Path) -> str | None:
    plist_path = root / "Info.plist"
    if not plist_path.is_file():
        return None
    with plist_path.open("rb") as handle:
        plist = plistlib.load(handle)
    version = str(plist.get("CFBundleShortVersionString") or "").strip()
    return version or None


def info_plist_release_prefix(root: Path) -> str:
    plist_path = root / "Info.plist"
    if not plist_path.is_file():
        return DEFAULT_RELEASE_PREFIX
    with plist_path.open("rb") as handle:
        plist = plistlib.load(handle)
    prefix = str(plist.get("TranscriptedSentryReleasePrefix") or DEFAULT_RELEASE_PREFIX).strip()
    return prefix or DEFAULT_RELEASE_PREFIX


def resolve_release(root: Path, args: argparse.Namespace) -> str | None:
    """Resolve the Sentry release string, e.g. transcripted@1.1.47."""
    if args.release:
        return args.release.strip()
    env_release = os.environ.get("SENTRY_RELEASE")
    if env_release:
        return env_release.strip()
    version = args.version or info_plist_version(root)
    if not version:
        return None
    return f"{info_plist_release_prefix(root)}@{version}"


def interval_for_period(period: str) -> str:
    """Coarse interval so totals queries don't trip Sentry's bucket-count limit."""
    return "1h" if period.strip().lower().endswith("h") else "1d"


def sentry_get(url: str, token: str, timeout: int = 20) -> tuple[int, Any]:
    """GET a Sentry API URL. Returns (status_code, parsed_json_or_None).

    status_code is 0 for a transport-level failure (DNS, timeout, TLS).
    """
    request = urllib.request.Request(
        url,
        headers={**HTTP_HEADERS, "Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8", errors="replace")
            return response.status, json.loads(body)
    except urllib.error.HTTPError as exc:
        try:
            payload = json.loads(exc.read().decode("utf-8", errors="replace"))
        except (ValueError, OSError):
            payload = None
        return exc.code, payload
    except (urllib.error.URLError, TimeoutError, ValueError, OSError):
        return 0, None


def project_numeric_id(org: str, project: str, token: str) -> str | None:
    status, payload = sentry_get(f"{SENTRY_BASE}/projects/{org}/{project}/", token)
    if status == 200 and isinstance(payload, dict) and payload.get("id"):
        return str(payload["id"])
    return None


def fetch_session_totals(
    org: str,
    project_id: str,
    release: str,
    period: str,
    token: str,
) -> tuple[str | None, dict[str, Any]]:
    """Fetch crash-free totals for a release. Returns (error, totals).

    error is None on success; a human-readable string otherwise. On success,
    totals holds crash_free_rate(session)/(user) and sum(session)/count_unique(user).
    """
    query = urllib.parse.urlencode(
        [
            ("field", "crash_free_rate(session)"),
            ("field", "crash_free_rate(user)"),
            ("field", "sum(session)"),
            ("field", "count_unique(user)"),
            ("query", f"release:{release}"),
            ("statsPeriod", period),
            ("interval", interval_for_period(period)),
            ("project", project_id),
        ]
    )
    status, payload = sentry_get(f"{SENTRY_BASE}/organizations/{org}/sessions/?{query}", token)
    if status == 401 or status == 403:
        return f"Sentry auth rejected (HTTP {status})", {}
    if status == 0:
        return "Sentry API unreachable (network error)", {}
    if status != 200 or not isinstance(payload, dict):
        detail = ""
        if isinstance(payload, dict) and payload.get("detail"):
            detail = f": {payload['detail']}"
        return f"Sentry sessions API returned HTTP {status}{detail}", {}
    groups = payload.get("groups") or []
    if not groups:
        return None, {
            "crash_free_rate(session)": None,
            "crash_free_rate(user)": None,
            "sum(session)": 0,
            "count_unique(user)": 0,
        }
    return None, dict(groups[0].get("totals") or {})


def rate_to_pct(raw: Any) -> float | None:
    """Sentry returns crash-free rate as a 0..1 fraction. Convert to percent."""
    if raw is None:
        return None
    try:
        return round(float(raw) * 100, 4)
    except (TypeError, ValueError):
        return None


def classify(
    *,
    creds_present: bool,
    api_error: str | None,
    session_rate: float | None,
    user_rate: float | None,
    total_sessions: int,
    session_threshold: float,
    user_threshold: float,
    min_sessions: int,
) -> dict[str, Any]:
    """Pure verdict function. No I/O, so --self-test can exercise every path.

    Returns {verdict, color, exit_code, reason}. verdict in
    {pass, fail, unknown}; color in {green, red, yellow}.
    """
    def unknown(reason: str) -> dict[str, Any]:
        return {"verdict": "unknown", "color": "yellow", "exit_code": EXIT_CODES["yellow"], "reason": reason}

    if not creds_present:
        return unknown("cannot verify - credentials absent (SENTRY_AUTH_TOKEN not set)")
    if api_error:
        return unknown(f"cannot verify - {api_error}")
    if session_rate is None:
        return unknown(
            "cannot verify - no crash-free-session data for this release "
            "(release health / session tracking may not be reporting)"
        )
    if total_sessions < min_sessions:
        return unknown(
            f"cannot verify - only {total_sessions} sessions in window "
            f"(< min-sessions {min_sessions}); widen --stats-period or wait for more data"
        )

    below = []
    if session_rate < session_threshold:
        below.append(f"crash-free-sessions {session_rate:.3f}% < {session_threshold}%")
    if user_rate is not None and user_rate < user_threshold:
        below.append(f"crash-free-users {user_rate:.3f}% < {user_threshold}%")
    if below:
        return {
            "verdict": "fail",
            "color": "red",
            "exit_code": EXIT_CODES["red"],
            "reason": "; ".join(below),
        }

    reason = f"crash-free-sessions {session_rate:.3f}% >= {session_threshold}%"
    if user_rate is not None:
        reason += f", crash-free-users {user_rate:.3f}% (>= {user_threshold}%)"
    reason += f" over {total_sessions} sessions"
    return {"verdict": "pass", "color": "green", "exit_code": EXIT_CODES["green"], "reason": reason}


def run_self_test() -> int:
    cases = [
        # (kwargs, expected_verdict, expected_exit)
        (
            dict(creds_present=False, api_error=None, session_rate=None, user_rate=None,
                 total_sessions=0, session_threshold=99.5, user_threshold=99.0, min_sessions=25),
            "unknown", 3,
        ),
        (
            dict(creds_present=True, api_error="Sentry auth rejected (HTTP 401)", session_rate=None,
                 user_rate=None, total_sessions=0, session_threshold=99.5, user_threshold=99.0, min_sessions=25),
            "unknown", 3,
        ),
        (
            dict(creds_present=True, api_error=None, session_rate=None, user_rate=None,
                 total_sessions=0, session_threshold=99.5, user_threshold=99.0, min_sessions=25),
            "unknown", 3,
        ),
        (  # thin data: healthy-looking rate but too few sessions -> not green
            dict(creds_present=True, api_error=None, session_rate=100.0, user_rate=100.0,
                 total_sessions=3, session_threshold=99.5, user_threshold=99.0, min_sessions=25),
            "unknown", 3,
        ),
        (  # clear pass
            dict(creds_present=True, api_error=None, session_rate=99.87, user_rate=99.95,
                 total_sessions=500, session_threshold=99.5, user_threshold=99.0, min_sessions=25),
            "pass", 0,
        ),
        (  # exactly at threshold passes (>=)
            dict(creds_present=True, api_error=None, session_rate=99.5, user_rate=99.0,
                 total_sessions=500, session_threshold=99.5, user_threshold=99.0, min_sessions=25),
            "pass", 0,
        ),
        (  # sessions below threshold -> fail
            dict(creds_present=True, api_error=None, session_rate=98.9, user_rate=99.99,
                 total_sessions=500, session_threshold=99.5, user_threshold=99.0, min_sessions=25),
            "fail", 1,
        ),
        (  # users below threshold -> fail (secondary gate)
            dict(creds_present=True, api_error=None, session_rate=99.9, user_rate=97.0,
                 total_sessions=500, session_threshold=99.5, user_threshold=99.0, min_sessions=25),
            "fail", 1,
        ),
    ]
    failures = 0
    for i, (kwargs, want_verdict, want_exit) in enumerate(cases):
        got = classify(**kwargs)
        if got["verdict"] != want_verdict or got["exit_code"] != want_exit:
            failures += 1
            print(
                f"self-test case {i} FAILED: want ({want_verdict}, exit {want_exit}), "
                f"got ({got['verdict']}, exit {got['exit_code']}) - {got['reason']}",
                file=sys.stderr,
            )
    # Guard the invariant the guardrails doc depends on: unknown/fail never exit 0.
    for verdict, color in (("unknown", "yellow"), ("fail", "red")):
        if EXIT_CODES[color] == 0:
            failures += 1
            print(f"self-test FAILED: {verdict} must not map to exit 0", file=sys.stderr)
    if failures:
        print(f"self-test: {failures} failure(s)", file=sys.stderr)
        return 1
    print(f"self-test passed ({len(cases)} cases)")
    return 0


def emit(result: dict[str, Any], as_json: bool) -> None:
    if as_json:
        print(json.dumps(result, indent=2, sort_keys=True))
        return
    verdict = result["verdict"].upper()
    color = result["color"].upper()
    print(f"[{color}] crash-free gate: {verdict}")
    print(f"  release: {result.get('release')}")
    if result.get("session_rate") is not None:
        print(f"  crash-free-sessions: {result['session_rate']:.3f}% (threshold {result['session_threshold']}%)")
    else:
        print(f"  crash-free-sessions: n/a (threshold {result['session_threshold']}%)")
    if result.get("user_rate") is not None:
        print(f"  crash-free-users:    {result['user_rate']:.3f}% (threshold {result['user_threshold']}%)")
    else:
        print(f"  crash-free-users:    n/a (threshold {result['user_threshold']}%)")
    print(f"  sessions in window:  {result.get('total_sessions', 0)} ({result.get('stats_period')})")
    print(f"  {result['reason']}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version", default=None, help="Release version, e.g. 1.1.47. Defaults to Info.plist.")
    parser.add_argument("--release", default=None, help="Full Sentry release override, e.g. transcripted@1.1.47.")
    parser.add_argument("--org", default=os.environ.get("SENTRY_ORG", DEFAULT_ORG))
    parser.add_argument("--project", default=os.environ.get("SENTRY_PROJECT", DEFAULT_PROJECT))
    parser.add_argument(
        "--threshold",
        type=float,
        default=float(os.environ.get("CRASH_FREE_SESSION_THRESHOLD", DEFAULT_SESSION_THRESHOLD)),
        help=f"Crash-free-session percent floor (default {DEFAULT_SESSION_THRESHOLD}).",
    )
    parser.add_argument(
        "--user-threshold",
        type=float,
        default=float(os.environ.get("CRASH_FREE_USER_THRESHOLD", DEFAULT_USER_THRESHOLD)),
        help=f"Crash-free-user percent floor (default {DEFAULT_USER_THRESHOLD}).",
    )
    parser.add_argument(
        "--min-sessions",
        type=int,
        default=int(os.environ.get("CRASH_FREE_MIN_SESSIONS", DEFAULT_MIN_SESSIONS)),
        help=f"Minimum sessions to trust the rate; below this is YELLOW (default {DEFAULT_MIN_SESSIONS}).",
    )
    parser.add_argument(
        "--stats-period",
        default=os.environ.get("SENTRY_STATS_PERIOD", DEFAULT_STATS_PERIOD),
        help=f"Sentry lookback window, e.g. 24h, 14d, 90d (default {DEFAULT_STATS_PERIOD}).",
    )
    parser.add_argument("--json", action="store_true", help="Emit the verdict as JSON.")
    parser.add_argument("--self-test", action="store_true", help="Run offline verdict checks without network access.")
    args = parser.parse_args()

    if args.self_test:
        return run_self_test()

    root = Path.cwd()
    load_env()

    release = resolve_release(root, args)
    token = os.environ.get("SENTRY_AUTH_TOKEN")

    result: dict[str, Any] = {
        "release": release,
        "org": args.org,
        "project": args.project,
        "stats_period": args.stats_period,
        "session_threshold": args.threshold,
        "user_threshold": args.user_threshold,
        "min_sessions": args.min_sessions,
        "session_rate": None,
        "user_rate": None,
        "total_sessions": 0,
        "total_users": 0,
    }

    if not release:
        result.update(
            classify(
                creds_present=bool(token), api_error="no release resolved (pass --version or --release, or run from repo root with Info.plist)",
                session_rate=None, user_rate=None, total_sessions=0,
                session_threshold=args.threshold, user_threshold=args.user_threshold, min_sessions=args.min_sessions,
            )
        )
        emit(result, args.json)
        return result["exit_code"]

    if not token:
        result.update(
            classify(
                creds_present=False, api_error=None, session_rate=None, user_rate=None, total_sessions=0,
                session_threshold=args.threshold, user_threshold=args.user_threshold, min_sessions=args.min_sessions,
            )
        )
        emit(result, args.json)
        return result["exit_code"]

    api_error: str | None = None
    project_id = project_numeric_id(args.org, args.project, token)
    if project_id is None:
        api_error = f"could not resolve project id for {args.org}/{args.project} (check org/project or token scope)"
        totals: dict[str, Any] = {}
    else:
        api_error, totals = fetch_session_totals(args.org, project_id, release, args.stats_period, token)

    session_rate = rate_to_pct(totals.get("crash_free_rate(session)"))
    user_rate = rate_to_pct(totals.get("crash_free_rate(user)"))
    total_sessions = int(totals.get("sum(session)") or 0)
    total_users = int(totals.get("count_unique(user)") or 0)

    result.update(
        {
            "session_rate": session_rate,
            "user_rate": user_rate,
            "total_sessions": total_sessions,
            "total_users": total_users,
        }
    )
    result.update(
        classify(
            creds_present=True,
            api_error=api_error,
            session_rate=session_rate,
            user_rate=user_rate,
            total_sessions=total_sessions,
            session_threshold=args.threshold,
            user_threshold=args.user_threshold,
            min_sessions=args.min_sessions,
        )
    )
    emit(result, args.json)
    return result["exit_code"]


if __name__ == "__main__":
    sys.exit(main())

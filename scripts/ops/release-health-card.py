#!/usr/bin/env python3
"""Print a compact privacy-safe release health card for Transcripted."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


REPO = "r3dbars/transcripted"
POSTHOG_ACTIVE_EVENTS = (
    "app_launched",
    "app_unclean_shutdown_detected",
    "app_session_stall_detected",
    "dictation_started",
    "dictation_start_failed",
    "dictation_completed",
    "dictation_no_speech",
    "dictation_audio_route_recovery_timeout",
    "meeting_recording_started",
    "meeting_recording_start_failed",
    "meeting_transcript_saved",
    "meeting_transcript_failed",
    "activation_first_artifact_saved",
    "update_check_finished",
    "update_action_clicked",
    "update_download_started",
    "update_download_finished",
    "update_ready_to_install",
    "update_relaunching",
    "update_installed",
)
POSTHOG_UPDATE_TARGET_EVENTS = (
    "update_action_clicked",
    "update_check_finished",
    "update_download_started",
    "update_download_finished",
    "update_ready_to_install",
    "update_relaunching",
    "update_installed",
)
POSTHOG_FAILURE_EVENTS = (
    "app_unclean_shutdown_detected",
    "app_session_stall_detected",
    "dictation_start_failed",
    "dictation_no_speech",
    "dictation_audio_route_recovery_timeout",
    "meeting_recording_start_failed",
    "meeting_transcript_failed",
)
HTTP_HEADERS = {
    "User-Agent": "TranscriptedReleaseHealth/1.0",
}
TRUSTED_POSTHOG_HOSTS = {
    "https://app.posthog.com",
    "https://eu.posthog.com",
    "https://posthog.com",
    "https://us.posthog.com",
}


def load_env() -> None:
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


def run_json(command: list[str]) -> dict[str, Any] | None:
    try:
        output = subprocess.check_output(command, text=True, stderr=subprocess.DEVNULL)
        return json.loads(output)
    except (FileNotFoundError, subprocess.CalledProcessError, json.JSONDecodeError):
        return None


def info_plist_version(root: Path) -> str:
    with (root / "Info.plist").open("rb") as handle:
        plist = plistlib.load(handle)
    return str(plist.get("CFBundleShortVersionString") or "unknown")


def appcast_latest_version(root: Path) -> str:
    text = (root / "docs/appcast.xml").read_text(encoding="utf-8")
    match = re.search(r"<sparkle:version>([^<]+)</sparkle:version>", text)
    return match.group(1) if match else "unknown"


def cask_version(root: Path) -> str:
    text = (root / "Casks/transcripted.rb").read_text(encoding="utf-8")
    match = re.search(r'version "([^"]+)"', text)
    return match.group(1) if match else "unknown"


def github_release(version: str) -> dict[str, Any]:
    payload = run_json(
        [
            "gh",
            "release",
            "view",
            f"v{version}",
            "--repo",
            REPO,
            "--json",
            "tagName,publishedAt,assets,url",
        ]
    )
    if not payload:
        return {"available": False, "download_count": None, "url": None}
    assets = payload.get("assets") or []
    return {
        "available": True,
        "download_count": sum(int(asset.get("downloadCount") or 0) for asset in assets),
        "url": payload.get("url"),
        "published_at": payload.get("publishedAt"),
    }


def head_location(url: str) -> str | None:
    request = urllib.request.Request(url, headers=HTTP_HEADERS, method="HEAD")
    opener = urllib.request.build_opener(NoRedirectHandler)
    try:
        opener.open(request, timeout=12)
    except urllib.error.HTTPError as exc:
        return exc.headers.get("Location")
    except urllib.error.URLError:
        return None
    return None


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[no-untyped-def]
        return None


def fetch_text(url: str) -> str:
    request = urllib.request.Request(url, headers=HTTP_HEADERS)
    with urllib.request.urlopen(request, timeout=15) as response:
        return response.read().decode("utf-8", errors="replace")


def live_surfaces(version: str) -> dict[str, Any]:
    try:
        latest_location = head_location("https://transcripted.app/download/latest.dmg")
        appcast = fetch_text("https://transcripted.app/appcast.xml")
        llms_full = fetch_text("https://transcripted.app/llms-full.txt")
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as exc:
        return {
            "download_latest": "unknown",
            "download_matches": False,
            "appcast_matches": False,
            "llms_matches": False,
            "error": str(exc),
        }
    return {
        "download_latest": latest_location or "unknown",
        "download_matches": f"/v{version}/Transcripted-{version}.dmg" in (latest_location or ""),
        "appcast_matches": f"<sparkle:version>{version}</sparkle:version>" in appcast,
        "llms_matches": f"Latest site download version: {version}" in llms_full,
    }


def normalize_posthog_host(raw: str) -> str:
    host = raw.strip().rstrip("/")
    if host == "https://us.i.posthog.com":
        return "https://us.posthog.com"
    if host == "https://eu.i.posthog.com":
        return "https://eu.posthog.com"
    return host


def sql_quote(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def posthog_release_health(version: str, hours: int) -> dict[str, Any]:
    token = os.environ.get("POSTHOG_PERSONAL_API_KEY")
    project_id = os.environ.get("POSTHOG_PROJECT_ID")
    if not token or not project_id:
        return {"available": False, "error": "missing PostHog credentials"}

    host = normalize_posthog_host(os.environ.get("POSTHOG_APP_HOST") or os.environ.get("POSTHOG_HOST") or "https://us.posthog.com")
    if not host.startswith("https://") or (
        host not in TRUSTED_POSTHOG_HOSTS and os.environ.get("POSTHOG_ALLOW_UNTRUSTED_HOST") != "1"
    ):
        return {"available": False, "error": f"untrusted PostHog host: {host}"}

    events = ", ".join(sql_quote(event) for event in POSTHOG_ACTIVE_EVENTS)
    update_events = ", ".join(sql_quote(event) for event in POSTHOG_UPDATE_TARGET_EVENTS)
    workflow_events = ", ".join(
        sql_quote(event)
        for event in POSTHOG_ACTIVE_EVENTS
        if event not in POSTHOG_UPDATE_TARGET_EVENTS
    )
    query = (
        "SELECT event, count() AS events, uniq(distinct_id) AS devices, "
        "min(timestamp) AS first_seen, max(timestamp) AS last_seen "
        "FROM events "
        f"WHERE timestamp >= now() - INTERVAL {int(hours)} HOUR "
        f"AND event IN ({events}) "
        "AND ("
        f"(event IN ({workflow_events}) AND properties['app_version'] = {sql_quote(version)}) "
        f"OR (event IN ({update_events}) AND properties['version'] = {sql_quote(version)})"
        ") "
        "GROUP BY event ORDER BY event ASC LIMIT 100"
    )
    payload = {
        "query": {"kind": "HogQLQuery", "query": query},
        "refresh": "blocking",
    }
    request = urllib.request.Request(
        f"{host}/api/projects/{project_id}/query/",
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            result = json.loads(response.read().decode("utf-8"))
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        return {"available": False, "error": f"PostHog query failed: {exc}"}

    rows = result.get("results") or result.get("data") or []
    return {
        "available": True,
        "events": {
            str(row[0]): {
                "events": int(row[1] or 0),
                "devices": int(row[2] or 0),
                "first_seen": row[3],
                "last_seen": row[4],
            }
            for row in rows
            if isinstance(row, list) and len(row) >= 5
        },
    }


def posthog_version_health(hours: int, limit: int) -> dict[str, Any]:
    token = os.environ.get("POSTHOG_PERSONAL_API_KEY")
    project_id = os.environ.get("POSTHOG_PROJECT_ID")
    if not token or not project_id:
        return {"available": False, "error": "missing PostHog credentials"}

    host = normalize_posthog_host(os.environ.get("POSTHOG_APP_HOST") or os.environ.get("POSTHOG_HOST") or "https://us.posthog.com")
    if not host.startswith("https://") or (
        host not in TRUSTED_POSTHOG_HOSTS and os.environ.get("POSTHOG_ALLOW_UNTRUSTED_HOST") != "1"
    ):
        return {"available": False, "error": f"untrusted PostHog host: {host}"}

    events = ", ".join(sql_quote(event) for event in POSTHOG_ACTIVE_EVENTS)
    failures = ", ".join(sql_quote(event) for event in POSTHOG_FAILURE_EVENTS)
    query = (
        "SELECT "
        "properties['app_version'] AS app_version, "
        "properties['build_version'] AS build_version, "
        "countIf(event = 'app_launched') AS launches, "
        "uniqIf(distinct_id, event = 'app_launched') AS launch_devices, "
        "countIf(event = 'activation_first_artifact_saved') AS first_artifacts, "
        "uniqIf(distinct_id, event = 'activation_first_artifact_saved') AS first_artifact_devices, "
        "countIf(event = 'dictation_completed') AS dictation_completions, "
        "uniqIf(distinct_id, event = 'dictation_completed') AS dictation_devices, "
        "countIf(event = 'meeting_transcript_saved') AS meeting_saves, "
        "uniqIf(distinct_id, event = 'meeting_transcript_saved') AS meeting_devices, "
        f"countIf(event IN ({failures})) AS failures, "
        f"uniqIf(distinct_id, event IN ({failures})) AS failure_devices, "
        "countIf(event = 'update_check_finished') AS update_checks, "
        "countIf(event = 'update_check_finished' AND properties['result'] = 'available') AS update_available, "
        "countIf(event = 'update_check_finished' AND properties['result'] = 'up_to_date') AS update_up_to_date, "
        "countIf(event = 'update_check_finished' AND properties['result'] = 'failed') AS update_check_failures, "
        "countIf(event = 'update_download_started') AS update_download_started, "
        "countIf(event = 'update_download_finished' AND isNull(properties['failure_kind'])) AS update_download_finished, "
        "countIf(event = 'update_download_finished' AND NOT isNull(properties['failure_kind'])) AS update_download_failed, "
        "countIf(event = 'update_ready_to_install') AS update_ready_to_install, "
        "countIf(event = 'update_relaunching') AS update_relaunching, "
        "countIf(event = 'update_installed') AS update_installed, "
        "max(timestamp) AS last_seen "
        "FROM events "
        f"WHERE timestamp >= now() - INTERVAL {int(hours)} HOUR "
        f"AND event IN ({events}) "
        "GROUP BY app_version, build_version "
        "ORDER BY launch_devices DESC, launches DESC "
        f"LIMIT {int(limit)}"
    )
    payload = {
        "query": {"kind": "HogQLQuery", "query": query},
        "refresh": "blocking",
    }
    request = urllib.request.Request(
        f"{host}/api/projects/{project_id}/query/",
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            result = json.loads(response.read().decode("utf-8"))
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        return {"available": False, "error": f"PostHog query failed: {exc}"}

    rows = result.get("results") or result.get("data") or []
    return {
        "available": True,
        "rows": [
            version_health_row(row)
            for row in rows
            if isinstance(row, list) and len(row) >= 22
        ],
    }


def version_health_row(row: list[Any]) -> dict[str, Any]:
    fields = (
        "app_version",
        "build_version",
        "launches",
        "launch_devices",
        "first_artifacts",
        "first_artifact_devices",
        "dictation_completions",
        "dictation_devices",
        "meeting_saves",
        "meeting_devices",
        "failures",
        "failure_devices",
        "update_checks",
        "update_available",
        "update_up_to_date",
        "update_check_failures",
        "update_download_started",
        "update_download_finished",
        "update_download_failed",
        "update_ready_to_install",
        "update_relaunching",
        "update_installed",
        "last_seen",
    )
    item = dict(zip(fields, row))
    item["app_version"] = str(item.get("app_version") or "unknown")
    item["build_version"] = str(item.get("build_version") or "unknown")
    for field in fields[2:-1]:
        item[field] = int(item.get(field) or 0)
    return item


def event_line(posthog: dict[str, Any], event: str) -> str:
    item = (posthog.get("events") or {}).get(event)
    if not item:
        return f"{event}: 0"
    return f"{event}: {item['events']} / {item['devices']} devices"


def pct(numerator: int, denominator: int) -> str:
    if denominator <= 0:
        return "n/a"
    return f"{(numerator / denominator) * 100:.1f}%"


def shipped_scope_label(app_version: str, target_version: str, gh_release: dict[str, Any], surfaces: dict[str, Any]) -> str:
    if app_version == target_version:
        if gh_release.get("available") and surfaces.get("appcast_matches") and surfaces.get("download_matches"):
            return "shipped/live target"
        if gh_release.get("available"):
            return "GitHub release target"
        return "source/local target"
    if app_version in {"dev", "unknown"}:
        return "local/dev unknown"
    return "other installed version"


def version_health_line(row: dict[str, Any], target_version: str, gh_release: dict[str, Any], surfaces: dict[str, Any]) -> str:
    launches = int(row["launches"])
    failures = int(row["failures"])
    scope = shipped_scope_label(str(row["app_version"]), target_version, gh_release, surfaces)
    updates = (
        f"checks {row['update_checks']}, available {row['update_available']}, "
        f"ready {row['update_ready_to_install']}, installed {row['update_installed']}, failed {row['update_check_failures'] + row['update_download_failed']}"
    )
    return (
        f"{row['app_version']} ({row['build_version']}, {scope}): "
        f"launches {launches} / {row['launch_devices']} devices; "
        f"first_artifact {row['first_artifacts']}; "
        f"dictations {row['dictation_completions']}; "
        f"meeting_saves {row['meeting_saves']}; "
        f"failures {failures} ({pct(failures, launches)} of launches); "
        f"updates {updates}"
    )


def run_self_test() -> int:
    sample = version_health_row([
        "1.2.3",
        "456",
        10,
        4,
        3,
        2,
        8,
        3,
        1,
        1,
        2,
        1,
        5,
        1,
        3,
        1,
        1,
        1,
        0,
        1,
        1,
        1,
        "2026-06-19T00:00:00",
    ])
    line = version_health_line(
        sample,
        "1.2.3",
        {"available": True},
        {"appcast_matches": True, "download_matches": True},
    )
    if "shipped/live target" not in line:
        print("self-test failed: missing shipped/live target classification", file=sys.stderr)
        return 1
    if "failures 2 (20.0% of launches)" not in line:
        print("self-test failed: missing failure rate", file=sys.stderr)
        return 1
    query_guard = posthog_version_health.__code__.co_consts
    if any(isinstance(value, str) and "SELECT *" in value.upper() for value in query_guard):
        print("self-test failed: query uses SELECT *", file=sys.stderr)
        return 1
    print("self-test passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default=None, help="Release version, e.g. 1.1.47. Defaults to Info.plist.")
    parser.add_argument("--hours", type=int, default=24, help="PostHog lookback window.")
    parser.add_argument("--version-limit", type=int, default=12, help="Maximum installed app_version/build_version rows to show.")
    parser.add_argument("--self-test", action="store_true", help="Run offline formatting checks without network access.")
    args = parser.parse_args()
    if args.self_test:
        return run_self_test()

    root = Path.cwd()
    load_env()
    version = args.version or info_plist_version(root)
    gh_release = github_release(version)
    surfaces = live_surfaces(version)
    posthog = posthog_release_health(version, args.hours)
    version_health = posthog_version_health(args.hours, args.version_limit)

    print(f"Transcripted {version} release health")
    print("")
    print("Release surfaces")
    print(f"- Info.plist: {info_plist_version(root)}")
    print(f"- appcast: {appcast_latest_version(root)}")
    print(f"- cask: {cask_version(root)}")
    print(f"- GitHub release: {'yes' if gh_release['available'] else 'missing'} ({gh_release.get('download_count') or 0} downloads)")
    print(f"- /download/latest.dmg: {'ok' if surfaces['download_matches'] else 'check'}")
    print(f"- live appcast: {'ok' if surfaces['appcast_matches'] else 'check'}")
    print(f"- llms-full: {'ok' if surfaces['llms_matches'] else 'check'}")
    print("")
    print(f"PostHog last {args.hours}h")
    if not posthog.get("available"):
        print(f"- unavailable: {posthog.get('error')}")
    else:
        for event in (
            "app_launched",
            "activation_first_artifact_saved",
            "update_check_finished",
            "update_download_finished",
            "update_ready_to_install",
            "update_relaunching",
            "update_installed",
            "dictation_completed",
            "dictation_artifact_saved",
            "meeting_transcript_saved",
            "meeting_transcript_failed",
        ):
            print(f"- {event_line(posthog, event)}")
    print("")
    print(f"PostHog by installed app_version last {args.hours}h")
    print("- scope note: update target `version` is separate from installed `app_version`; rows below group by installed app_version/build_version.")
    if not version_health.get("available"):
        print(f"- unavailable: {version_health.get('error')}")
    elif not version_health.get("rows"):
        print("- no aggregate rows in this window")
    else:
        for row in version_health["rows"]:
            print(f"- {version_health_line(row, version, gh_release, surfaces)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

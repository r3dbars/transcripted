"""Shared privacy-safe PostHog script helpers for Transcripted ops tools."""

from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


TRUSTED_POSTHOG_HOSTS = {
    "https://app.posthog.com",
    "https://eu.posthog.com",
    "https://posthog.com",
    "https://us.posthog.com",
}

ENV_PATHS = (
    Path.cwd() / ".env.local",
    Path.cwd() / ".env",
    Path.home() / ".transcripted-ops.env",
    Path.home() / ".hermes" / ".env",
    Path.home() / ".hermes" / "profiles" / "ops" / ".env",
)


def load_env() -> None:
    for path in ENV_PATHS:
        if not path.is_file():
            continue
        for raw_line in path.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip().removeprefix("export ").strip()
            value = value.strip().strip('"').strip("'")
            if key and value and key not in os.environ:
                os.environ[key] = value


def normalize_posthog_host(raw: str) -> str:
    host = raw.strip().rstrip("/")
    if host == "https://us.i.posthog.com":
        return "https://us.posthog.com"
    if host == "https://eu.i.posthog.com":
        return "https://eu.posthog.com"
    return host


def posthog_config(error_cls: type[Exception]) -> tuple[str, str, str]:
    token = os.environ.get("POSTHOG_PERSONAL_API_KEY")
    project_id = os.environ.get("POSTHOG_PROJECT_ID")
    host = normalize_posthog_host(
        os.environ.get("POSTHOG_APP_HOST")
        or os.environ.get("POSTHOG_HOST")
        or "https://us.posthog.com"
    )

    missing = []
    if not token:
        missing.append("POSTHOG_PERSONAL_API_KEY")
    if not project_id:
        missing.append("POSTHOG_PROJECT_ID")
    if missing:
        raise error_cls("missing " + ", ".join(missing))

    if not host.startswith("https://"):
        raise error_cls(f"refusing non-HTTPS PostHog host: {host}")
    if host not in TRUSTED_POSTHOG_HOSTS and os.environ.get("POSTHOG_ALLOW_UNTRUSTED_HOST") != "1":
        raise error_cls(
            f"refusing untrusted PostHog host: {host}; set POSTHOG_ALLOW_UNTRUSTED_HOST=1 only for trusted self-hosted PostHog"
        )
    return host, project_id, token


def sql_quote(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def sql_list(values: tuple[str, ...]) -> str:
    return ", ".join(sql_quote(value) for value in values)


def event_filter(events: tuple[str, ...]) -> str:
    return f"event IN ({sql_list(events)})"


def app_version_filter(app_version: str | None) -> str:
    if not app_version:
        return ""
    return f"AND properties['app_version'] = {sql_quote(app_version)}"


def version_or_app_version_filter(app_version: str | None) -> str:
    if not app_version:
        return ""
    quoted = sql_quote(app_version)
    return f"AND (properties['app_version'] = {quoted} OR properties['version'] = {quoted})"


def run_hogql(host: str, project_id: str, token: str, query: str, error_cls: type[Exception]) -> dict[str, Any]:
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
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise error_cls(f"PostHog query failed with HTTP {exc.code}: {body}") from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise error_cls(f"PostHog query failed: {exc}") from exc


def rows_as_dicts(
    response: dict[str, Any],
    disallowed_fragments: set[str] | tuple[str, ...],
    error_cls: type[Exception],
    declared_columns: tuple[str, ...] | None = None,
) -> list[dict[str, Any]]:
    response_columns = tuple(str(column) for column in (response.get("columns") or []))
    declared_column_names = tuple(str(column) for column in (declared_columns or ()))
    columns = response_columns or declared_column_names
    columns_to_check = response_columns
    if declared_column_names:
        columns_to_check = response_columns + declared_column_names
    unsafe = [
        str(column)
        for column in columns_to_check
        if any(fragment in str(column).lower() for fragment in disallowed_fragments)
    ]
    if unsafe:
        raise error_cls(f"query attempted to expose unsafe output columns: {', '.join(unsafe)}")

    rows = response.get("results") or response.get("data") or []
    return [
        {str(column): row[index] if index < len(row) else None for index, column in enumerate(columns)}
        for row in rows
    ]

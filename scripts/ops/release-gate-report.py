#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import shlex
import subprocess
import sys
from collections import Counter, deque
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


STATUS_ORDER = {"green": 0, "yellow": 1, "red": 2}
EXIT_CODES = {"green": 0, "yellow": 3, "red": 1}
UNKNOWN_RELEASE_CHECK_IDS = {
    "github-release-metadata-unavailable",
    "live-appcast-unreachable",
    "sentry-cli-missing",
    "sentry-release-health-failed",
}
BLOCKING_RELEASE_WATCH_IDS = {
    "appcast-release-candidate",
}
LOG_PATHS = (
    "debug.log",
    "events.jsonl",
    "reliability.jsonl",
    "app.jsonl",
)
RED_LOG_PATTERNS = {
    "crash_or_panic": re.compile(r"\b(crash|panic|fatal)\b", re.IGNORECASE),
}
YELLOW_LOG_PATTERNS = {
    "error": re.compile(r'("level"\s*:\s*"error"|\berror\b)', re.IGNORECASE),
    "warning": re.compile(r'("level"\s*:\s*"warn(?:ing)?"|\bwarn(?:ing)?\b)', re.IGNORECASE),
    "timeout": re.compile(r"\btimeout|timed_out\b", re.IGNORECASE),
    "degraded": re.compile(r"\bdegraded\b", re.IGNORECASE),
    "recovery": re.compile(r"\brecovery\b", re.IGNORECASE),
    "unclean_shutdown": re.compile(r"\bunclean_shutdown|dirty_shutdown\b", re.IGNORECASE),
}


@dataclass
class ReportItem:
    title: str
    status: str
    detail: str
    evidence: str = ""


@dataclass
class CommandRecord:
    title: str
    status: str
    exit_code: int
    command: str
    log_path: str
    detail: str
    report_path: str = ""


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def shell_command(command: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in command)


def display_path(path: Path) -> str:
    try:
        return "~/" + str(path.expanduser().resolve().relative_to(Path.home()))
    except ValueError:
        return str(path)


def read_text_if_present(path: Path, limit: int = 200_000) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")[:limit]
    except OSError:
        return ""


def command_record_status(exit_code: int) -> str:
    if exit_code == 0:
        return "green"
    if exit_code == 3:
        return "yellow"
    return "red"


def run_command(
    *,
    title: str,
    command: list[str],
    cwd: Path,
    log_path: Path,
    dry_run: bool,
    env: dict[str, str] | None = None,
) -> tuple[CommandRecord, str]:
    command_text = shell_command(command)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    if dry_run:
        log_path.write_text(f"$ {command_text}\n\nDRY RUN: command was not executed.\n", encoding="utf-8")
        return (
            CommandRecord(
                title=title,
                status="yellow",
                exit_code=3,
                command=command_text,
                log_path=str(log_path),
                detail="Dry run only. This proof is unknown.",
            ),
            "",
        )

    result = subprocess.run(
        command,
        cwd=cwd,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    output = (result.stdout or "") + (result.stderr or "")
    log_path.write_text(f"$ {command_text}\n\n{output}", encoding="utf-8")
    status = command_record_status(result.returncode)
    return (
        CommandRecord(
            title=title,
            status=status,
            exit_code=result.returncode,
            command=command_text,
            log_path=str(log_path),
            detail=first_signal_line(output) or f"Command exited {result.returncode}.",
        ),
        output,
    )


def first_signal_line(output: str) -> str:
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("[qa] Report:") or line.startswith("[qa] Verdict:") or line.startswith("Nightly security score:"):
            return line
        if line.startswith("SKIP ") or line.startswith("ERROR:") or "query failed" in line:
            return line
    return ""


def read_info_version(root: Path) -> str:
    try:
        with (root / "Info.plist").open("rb") as handle:
            plist = plistlib.load(handle)
        return str(plist.get("CFBundleShortVersionString", "unknown"))
    except Exception:
        return "unknown"


def git_value(root: Path, args: list[str], fallback: str) -> str:
    result = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, check=False)
    value = result.stdout.strip()
    return value or fallback


def status_label(status: str) -> str:
    return status.upper()


def worst_status(items: list[ReportItem]) -> str:
    if not items:
        return "green"
    return max((item.status for item in items), key=lambda status: STATUS_ORDER[status])


def sync_command_record_status(record: CommandRecord, items: list[ReportItem]) -> None:
    if not items:
        return
    parsed_status = worst_status(items)
    if STATUS_ORDER[parsed_status] <= STATUS_ORDER[record.status]:
        return

    record.status = parsed_status
    first_non_green = next((item for item in items if item.status != "green"), None)
    if first_non_green is not None:
        record.detail = first_non_green.detail or first_non_green.title


def load_json(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def qa_short_answer(report_path: Path) -> str:
    text = read_text_if_present(report_path, limit=20_000)
    for line in text.splitlines():
        if line.startswith(("PASS:", "FAIL:", "INCOMPLETE:")):
            return line
    return "QA report was not readable."


def run_qa_bench(args: argparse.Namespace, root: Path, out_dir: Path, commands: list[CommandRecord]) -> ReportItem:
    if args.skip_qa:
        return ReportItem(
            "QA bench skipped",
            "yellow",
            "Build/tests were skipped by flag. Automated proof is unknown.",
        )

    qa_out_root = out_dir / "qa-bench"
    qa_report = qa_out_root / args.run_id / "qa-report.md"
    command = [
        "bash",
        "scripts/ops/transcripted-qa-bench.sh",
        "--mode",
        args.qa_mode,
        "--out-root",
        str(qa_out_root),
        "--run-id",
        args.run_id,
    ]
    if args.strict_artifacts:
        command.append("--strict-artifacts")

    env = os.environ.copy()
    env["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
    record, _ = run_command(
        title="QA bench",
        command=command,
        cwd=root,
        log_path=out_dir / "logs" / "qa-bench.log",
        dry_run=args.dry_run,
        env=env,
    )
    record.report_path = str(qa_report)
    commands.append(record)

    detail = qa_short_answer(qa_report) if qa_report.exists() else record.detail
    evidence = str(qa_report) if qa_report.exists() else record.log_path
    return ReportItem("Build and test QA bench", record.status, detail, evidence)


def run_packaged_app_smoke(
    args: argparse.Namespace,
    root: Path,
    out_dir: Path,
    commands: list[CommandRecord],
) -> ReportItem | None:
    if not args.include_packaged_app_smoke:
        return None

    json_report = out_dir / "raw" / "packaged-app-smoke.json"
    markdown_report = out_dir / "packaged-app-smoke.md"
    command = [
        "python3",
        "scripts/ops/packaged-app-smoke.py",
        "--out-dir",
        str(out_dir / "packaged-app-smoke"),
        "--write-report",
        str(json_report),
        "--markdown-out",
        str(markdown_report),
    ]
    if args.require_release_debug_files:
        command.append("--require-dsym")
    if args.require_packaged_app_dmg:
        command.append("--require-dmg")

    record, _ = run_command(
        title="Packaged app smoke",
        command=command,
        cwd=root,
        log_path=out_dir / "logs" / "packaged-app-smoke.log",
        dry_run=args.dry_run,
    )
    record.report_path = str(markdown_report if markdown_report.exists() else json_report)
    commands.append(record)

    if args.dry_run:
        return ReportItem(
            "Packaged app smoke not executed",
            "yellow",
            "Dry run only. App launch, DMG, Sparkle, dSYM, and packaged signing proof are unknown.",
            record.log_path,
        )

    report = load_json(json_report)
    if report:
        detail = (
            f"{report.get('passed_count', 0)}/{report.get('check_count', 0)} packaged checks passed; "
            f"warnings={report.get('warning_count', 0)} failures={report.get('failure_count', 0)}."
        )
        return ReportItem("Packaged app smoke", record.status, detail, str(markdown_report))

    return ReportItem("Packaged app smoke", record.status, record.detail, record.log_path)


def release_finding_status(finding: dict[str, Any]) -> str:
    check_id = str(finding.get("check_id", ""))
    summary = str(finding.get("summary", ""))
    detail = str(finding.get("detail", ""))
    lowered = f"{check_id} {summary} {detail}".lower()
    if check_id in UNKNOWN_RELEASE_CHECK_IDS:
        return "yellow"
    if "unavailable" in lowered or "could not be loaded" in lowered or "could not be fetched" in lowered:
        return "yellow"
    severity = str(finding.get("severity", "medium"))
    return "red" if severity in {"high", "medium"} else "yellow"


def release_watch_status(watch: dict[str, Any]) -> str:
    return "red" if str(watch.get("check_id", "")) in BLOCKING_RELEASE_WATCH_IDS else "yellow"


def successful_release_surface_title(args: argparse.Namespace) -> str:
    if not args.skip_live_release_surfaces:
        return "Appcast, download, cask, GitHub, and Sentry release checks"

    subjects = ["Local appcast", "cask", "Sentry"]
    if args.github_release_json:
        subjects.insert(2, "GitHub")
    if len(subjects) == 3:
        joined = f"{subjects[0]}, {subjects[1]}, and {subjects[2]}"
    else:
        joined = f"{subjects[0]}, {subjects[1]}, {subjects[2]}, and {subjects[3]}"
    return f"{joined} release checks"


def run_release_surfaces(args: argparse.Namespace, root: Path, out_dir: Path, commands: list[CommandRecord]) -> list[ReportItem]:
    json_report = out_dir / "raw" / "nightly-security-report.json"
    command = [
        "python3",
        "scripts/ops/nightly-security-check.py",
        "--automation-toml",
        "Tests/Fixtures/nightly-security-automation.toml",
        "--app-bundle",
        "build/Transcripted.app",
        "--sentry-release-health",
        "--write-report",
        str(json_report),
    ]
    if not args.skip_live_release_surfaces:
        command.append("--live-release-surfaces")
    if args.require_sentry_release_health:
        command.append("--require-sentry-release-health")
    if args.require_release_debug_files:
        command.append("--require-release-debug-files")
    if args.github_release_json:
        command.extend(["--github-release-json", args.github_release_json])

    record, _ = run_command(
        title="Release surfaces",
        command=command,
        cwd=root,
        log_path=out_dir / "logs" / "release-surfaces.log",
        dry_run=args.dry_run,
    )
    record.report_path = str(json_report)
    commands.append(record)

    if args.dry_run:
        return [
            ReportItem(
                "Release surfaces not executed",
                "yellow",
                "Dry run only. Appcast, download, GitHub, cask, and Sentry release checks are unknown.",
                record.log_path,
            )
        ]

    report = load_json(json_report)
    if not report:
        return [
            ReportItem(
                "Release surface report missing",
                "red" if record.status == "red" else "yellow",
                "nightly-security-check.py did not write a parseable JSON report.",
                record.log_path,
            )
        ]

    items: list[ReportItem] = []
    for finding in report.get("findings", []):
        status = release_finding_status(finding)
        check_id = str(finding.get("check_id", "release-finding"))
        detail = str(finding.get("detail", ""))
        summary = str(finding.get("summary", "Release check needs attention."))
        items.append(ReportItem(check_id, status, f"{summary} {detail}".strip(), str(json_report)))

    for watch in report.get("watch_items", []):
        check_id = str(watch.get("check_id", "release-watch"))
        summary = str(watch.get("summary", "Release check needs review."))
        detail = str(watch.get("detail", ""))
        items.append(ReportItem(check_id, release_watch_status(watch), f"{summary} {detail}".strip(), str(json_report)))

    has_nightly_items = bool(items)
    if args.skip_live_release_surfaces:
        items.append(
            ReportItem(
                "Live release surfaces skipped",
                "yellow",
                "Live appcast, direct-download route, download page, crawler text, and live GitHub release checks were skipped by flag.",
                str(json_report),
            )
        )

    if not has_nightly_items and record.status == "red":
        items.append(
            ReportItem(
                "Release surface command failed",
                "red",
                record.detail,
                record.log_path,
            )
        )
    elif not has_nightly_items:
        items.append(
            ReportItem(
                successful_release_surface_title(args),
                "green",
                f"nightly-security-check.py score {report.get('score', 'unknown')}/100 with no findings.",
                str(json_report),
            )
        )
    elif record.status == "red" and not any(item.status == "red" for item in items):
        items.append(
            ReportItem(
                "Release surface command failed",
                "red",
                record.detail,
                record.log_path,
            )
        )
    sync_command_record_status(record, items)
    return items


def run_telemetry(args: argparse.Namespace, root: Path, out_dir: Path, commands: list[CommandRecord]) -> list[ReportItem]:
    items: list[ReportItem] = []
    for lane in ("sentry", "posthog"):
        record, output = run_command(
            title=f"{lane.capitalize()} health probe",
            command=["bash", "scripts/ops/health-probe.sh", lane],
            cwd=root,
            log_path=out_dir / "logs" / f"{lane}.log",
            dry_run=args.dry_run,
        )
        if health_probe_has_unknowns(output):
            record.status = "yellow"
            record.detail = first_signal_line(output) or record.detail
        lane_items = classify_health_probe(lane, record, output)
        sync_command_record_status(record, lane_items)
        commands.append(record)
        items.extend(lane_items)
    return items or [ReportItem("Telemetry probes", "yellow", "No telemetry probe output was available.")]


def health_probe_has_unknowns(output: str) -> bool:
    return any(line.strip().startswith("SKIP ") for line in output.splitlines())


def classify_health_probe(lane: str, record: CommandRecord, output: str) -> list[ReportItem]:
    if record.status == "red":
        return [ReportItem(f"{lane} probe failed", "red", record.detail, record.log_path)]
    if record.status == "yellow":
        return [ReportItem(f"{lane} probe not executed", "yellow", record.detail, record.log_path)]

    lines = [line.strip() for line in output.splitlines() if line.strip()]
    items: list[ReportItem] = []
    for line in lines:
        if line.startswith("SKIP "):
            items.append(ReportItem(f"{lane} credentials missing", "yellow", line, record.log_path))
        elif "query failed" in line or line.startswith("ERROR:"):
            items.append(ReportItem(f"{lane} probe failed", "red", line, record.log_path))

    if lane == "sentry":
        for line in lines:
            match = re.search(r"Sentry unresolved issues:\s*(\d+)", line)
            if match and int(match.group(1)) > 0:
                items.append(
                    ReportItem(
                        "Sentry unresolved issues need review",
                        "yellow",
                        line,
                        record.log_path,
                    )
                )
        if not items and any("Sentry health check" in line for line in lines):
            items.append(ReportItem("Sentry aggregate health probe", "green", "Probe ran without blocking failures.", record.log_path))

    if lane == "posthog":
        aggregate = next((line for line in lines if line.startswith("PostHog (last 7d):")), "")
        if aggregate:
            items.append(ReportItem("PostHog aggregate usage probe", "green", aggregate, record.log_path))
        elif not items and any("PostHog health check" in line for line in lines):
            items.append(ReportItem("PostHog aggregate usage probe", "green", "Probe ran without blocking failures.", record.log_path))

    return items or [ReportItem(f"{lane} probe", "yellow", "Probe output did not include a clear aggregate result.", record.log_path)]


def tail_lines(path: Path, max_lines: int) -> list[str]:
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            return list(deque(handle, maxlen=max_lines))
    except OSError:
        return []


def sweep_local_logs(args: argparse.Namespace) -> list[ReportItem]:
    log_root = Path.home() / "Library" / "Application Support" / "Transcripted" / "logs"
    items: list[ReportItem] = []
    for name in LOG_PATHS:
        path = log_root / name
        if not path.exists():
            items.append(
                ReportItem(
                    f"{name} missing",
                    "yellow",
                    "Local log file was not found. This lane is unknown.",
                    display_path(path),
                )
            )
            continue

        lines = tail_lines(path, args.log_lines)
        red_counts = count_matches(lines, RED_LOG_PATTERNS)
        yellow_counts = count_matches(lines, YELLOW_LOG_PATTERNS)
        red_total = sum(red_counts.values())
        yellow_total = sum(yellow_counts.values())
        if red_total:
            detail = f"{red_total} crash/panic/fatal-ish matches in last {len(lines)} lines; raw lines not copied."
            items.append(ReportItem(f"{name} urgent log warnings", "red", detail, display_path(path)))
        elif yellow_total:
            detail = summarize_counts(yellow_counts, f"{yellow_total} warning/error-ish matches in last {len(lines)} lines")
            items.append(ReportItem(f"{name} log warnings", "yellow", f"{detail}; raw lines not copied.", display_path(path)))
        else:
            items.append(ReportItem(f"{name} log tail", "green", f"No warning/error patterns in last {len(lines)} lines.", display_path(path)))
    return items


def count_matches(lines: list[str], patterns: dict[str, re.Pattern[str]]) -> Counter[str]:
    counts: Counter[str] = Counter()
    for line in lines:
        for key, pattern in patterns.items():
            if pattern.search(line):
                counts[key] += 1
    return counts


def summarize_counts(counts: Counter[str], prefix: str) -> str:
    parts = ", ".join(f"{key}={value}" for key, value in sorted(counts.items()) if value)
    return f"{prefix} ({parts})" if parts else prefix


def evidence_list(paths: list[Path]) -> str:
    return "; ".join(str(path) for path in paths)


def manual_items(args: argparse.Namespace, root: Path, out_dir: Path) -> list[ReportItem]:
    qa_manual_path = out_dir / "qa-bench" / args.run_id / "manual-scenarios.md"
    items = [
        ReportItem(
            "Meeting-app volume and route matrix",
            "yellow",
            "UNKNOWN: run docs/qa-issue-500-meeting-audio.md across Chrome Meet, Safari Meet, Firefox Meet, Zoom, and real routes.",
            evidence_list(
                [
                    root / "docs/qa-issue-500-meeting-audio.md",
                    root / "docs/audio-reliability-daily-check.md",
                    qa_manual_path,
                ]
            ),
        ),
        ReportItem(
            "Sleep/wake and device switching",
            "yellow",
            "UNKNOWN: run the daily audio reliability loop for sleep/wake, input-device changes, and Bluetooth/AirPods route changes.",
            evidence_list([qa_manual_path, root / "docs/audio-reliability-daily-check.md"]),
        ),
        ReportItem(
            "Pasteback feel in real apps",
            "yellow",
            "UNKNOWN: check TextEdit, Notes, and a browser text area with Auto Enter off/on.",
            evidence_list([qa_manual_path, root / "docs/qa-test-bench.md"]),
        ),
        ReportItem(
            "Speaker review and rename feel",
            "yellow",
            "UNKNOWN: verify unknown speakers stay unknown until a human names them, and Markdown keeps the chosen name.",
            evidence_list([qa_manual_path, root / "docs/qa-test-bench.md"]),
        ),
        ReportItem(
            "Existing-install update path",
            "yellow",
            "UNKNOWN: on a real installed app, verify Sparkle check/install behavior and Homebrew install/upgrade when publishing.",
            evidence_list([root / "docs/sparkle-updates.md", root / "docs/release-packaging.md"]),
        ),
    ]
    if args.qa_mode != "live":
        items.insert(
            0,
            ReportItem(
                "Live mic and system-audio capture",
                "yellow",
                "UNKNOWN: run the live QA bench on this Mac when release claims depend on real audio/TCC proof.",
                evidence_list([qa_manual_path, root / "docs/qa-test-bench.md"]),
            ),
        )
    return items


def render_items(items: list[ReportItem], empty: str) -> list[str]:
    if not items:
        return [empty]
    rendered = []
    for item in items:
        evidence = f" Evidence: `{item.evidence}`." if item.evidence else ""
        rendered.append(f"- {status_label(item.status)} - {item.title}: {item.detail}{evidence}")
    return rendered


def render_report(
    *,
    root: Path,
    out_dir: Path,
    run_id: str,
    generated_at: str,
    app_version: str,
    branch: str,
    commit: str,
    automated: list[ReportItem],
    telemetry: list[ReportItem],
    release_surfaces: list[ReportItem],
    local_logs: list[ReportItem],
    manual: list[ReportItem],
    commands: list[CommandRecord],
) -> tuple[str, dict[str, Any]]:
    process_items = automated + telemetry + release_surfaces + local_logs
    all_items = automated + telemetry + release_surfaces + local_logs + manual
    regressions = [item for item in all_items if item.status == "red"]
    needs_human = [item for item in all_items if item.status == "yellow"]
    working = [item for item in all_items if item.status == "green"]
    process_status = worst_status(process_items)
    manual_status = worst_status(manual)
    overall = worst_status(all_items)
    release_status = "GO" if overall == "green" else "HOLD"
    release_reason = (
        "all automated and manual release proof is green"
        if release_status == "GO"
        else "manual proof or automated release evidence is still incomplete"
    )

    lines: list[str] = [
        "# Transcripted Release Gate Report",
        "",
        "## Short Answer",
        "",
        f"{status_label(overall)}: working={len(working)}, regressed={len(regressions)}, needs_human_check={len(needs_human)}.",
        f"Automated gate: {status_label(process_status)}.",
        f"Release: {release_status} - {release_reason}.",
        "Exit code follows the overall report status: green=0, yellow=3, red=1.",
        "",
        f"- Run id: `{run_id}`",
        f"- Generated: `{generated_at}`",
        f"- Branch: `{branch}`",
        f"- Commit: `{commit}`",
        f"- App version: `{app_version}`",
        f"- Artifacts: `{out_dir}`",
        "",
        "## Privacy Boundary",
        "",
        "Raw logs, transcripts, audio, device names, tokens, and private paths stay local. This report only writes aggregate status.",
        "Missing Sentry/PostHog credentials are reported as yellow/unknown, not green proof.",
        "The command exit code follows the overall report color, so manual-only unknowns still exit yellow.",
        "",
        "## Sidecar Boundary",
        "",
        "Live sidecar transcripts are provisional and local. Final saved Markdown remains canonical, and this report does not quote sidecar transcript text.",
        "",
        f"## Automated Proof - {status_label(worst_status(automated))}",
        "",
        *render_items(automated, "No automated proof was recorded."),
        "",
        f"## Regressions - {status_label(worst_status(regressions))}",
        "",
        *render_items(regressions, "No automated regressions were detected."),
        "",
        f"## Telemetry - {status_label(worst_status(telemetry))}",
        "",
        *render_items(telemetry, "No telemetry checks were recorded."),
        "",
        f"## Release Surfaces - {status_label(worst_status(release_surfaces))}",
        "",
        *render_items(release_surfaces, "No release-surface checks were recorded."),
        "",
        f"## Local Log Warnings - {status_label(worst_status(local_logs))}",
        "",
        *render_items(local_logs, "No local log sweep was recorded."),
        "",
        f"## Manual QA Checklist - {status_label(worst_status(manual))}",
        "",
        *render_items(manual, "No manual QA checklist was recorded."),
        "",
        "## Commands",
        "",
        "| Status | Exit | Command | Log | Report |",
        "| --- | ---: | --- | --- | --- |",
    ]

    for record in commands:
        report_path = f"`{record.report_path}`" if record.report_path else ""
        lines.append(
            f"| {status_label(record.status)} | {record.exit_code} | `{record.command}` | `{record.log_path}` | {report_path} |"
        )

    payload = {
        "status": overall,
        "generated_at": generated_at,
        "repo_root": str(root),
        "run_id": run_id,
        "branch": branch,
        "commit": commit,
        "app_version": app_version,
        "artifacts": str(out_dir),
        "process_status": process_status,
        "release_status": release_status,
        "exit_code": EXIT_CODES[overall],
        "manual_status": manual_status,
        "working_count": len(working),
        "regression_count": len(regressions),
        "needs_human_check_count": len(needs_human),
        "synthetic_only": False,
        "privacy_warnings": [
            "raw content omitted",
            "missing Sentry/PostHog credentials are yellow/unknown",
        ],
        "local_paths_checked": [str(Path.home() / "Library" / "Application Support" / "Transcripted" / "logs" / name) for name in LOG_PATHS],
        "manual_proof_required": [item.title for item in manual],
        "sections": {
            "automated_proof": [item.__dict__ for item in automated],
            "regressions": [item.__dict__ for item in regressions],
            "telemetry": [item.__dict__ for item in telemetry],
            "release_surfaces": [item.__dict__ for item in release_surfaces],
            "local_log_warnings": [item.__dict__ for item in local_logs],
            "manual_qa_checklist": [item.__dict__ for item in manual],
        },
        "commands": [record.__dict__ for record in commands],
    }
    return "\n".join(lines) + "\n", payload


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run Transcripted pre-merge/release gate checks and write one Markdown report.")
    parser.add_argument("--release-candidate", action="store_true", help="Preset for one-command release gate reporting: --qa-mode full --strict-artifacts.")
    parser.add_argument("--qa-mode", default="quick", choices=["quick", "deep", "full", "live"], help="QA bench mode to run. Default: quick.")
    parser.add_argument("--strict-artifacts", action="store_true", help="Forward --strict-artifacts to the QA bench.")
    parser.add_argument("--skip-qa", action="store_true", help="Skip the build/test QA bench and mark it unknown.")
    parser.add_argument("--include-packaged-app-smoke", action="store_true", help="Run packaged app smoke against build/Transcripted.app and the versioned DMG.")
    parser.add_argument("--require-packaged-app-dmg", action="store_true", help="When packaged smoke is enabled, fail if build/Transcripted-<version>.dmg is missing.")
    parser.add_argument("--skip-live-release-surfaces", action="store_true", help="Skip live appcast/download/crawler checks.")
    parser.add_argument("--require-sentry-release-health", action="store_true", help="Make missing Sentry release metadata a red release failure.")
    parser.add_argument("--require-release-debug-files", action="store_true", help="Require build/Transcripted.app.dSYM to match the built app binary.")
    parser.add_argument("--github-release-json", help="Optional GitHub release JSON fixture for deterministic release checks.")
    parser.add_argument("--out-root", default="/tmp/transcripted-release-gate", help="Output root. Default: /tmp/transcripted-release-gate")
    parser.add_argument("--run-id", default=f"release-gate-{datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')}")
    parser.add_argument("--log-lines", type=int, default=400, help="Tail lines to inspect per local log file. Default: 400.")
    parser.add_argument("--dry-run", action="store_true", help="Write a yellow report without executing external commands.")
    parser.add_argument("--self-test", action="store_true", help="Run a tiny renderer/classifier self-test and exit.")
    args = parser.parse_args()
    if args.release_candidate:
        args.qa_mode = "full"
        args.strict_artifacts = True
    return args


def self_test() -> int:
    root = repo_root()
    generated_at = "2026-06-07T00:00:00Z"
    release_record = CommandRecord(
        title="Release surfaces",
        status="green",
        exit_code=0,
        command="python3 scripts/ops/nightly-security-check.py",
        log_path="/tmp/release-surfaces.log",
        detail="Nightly security score: 100/100",
    )
    sync_command_record_status(
        release_record,
        [
            ReportItem(
                "appcast-release-candidate",
                "red",
                "Release candidate appcast metadata is newer than the shipped production release.",
            )
        ],
    )
    telemetry_record = CommandRecord(
        title="Sentry health probe",
        status="green",
        exit_code=0,
        command="bash scripts/ops/health-probe.sh sentry",
        log_path="/tmp/sentry.log",
        detail="Sentry unresolved issues: 2",
    )
    sync_command_record_status(
        telemetry_record,
        [ReportItem("Sentry unresolved issues need review", "yellow", "Sentry unresolved issues: 2")],
    )
    report, payload = render_report(
        root=root,
        out_dir=Path("/tmp/transcripted-release-gate/self-test"),
        run_id="self-test",
        generated_at=generated_at,
        app_version="1.2.3",
        branch="codex/self-test",
        commit="abcdef0",
        automated=[ReportItem("QA bench", "green", "Fixture pass.")],
        telemetry=[ReportItem("Sentry credentials missing", "yellow", "SKIP sentry: missing SENTRY_AUTH_TOKEN")],
        release_surfaces=[ReportItem("appcast", "green", "Fixture pass.")],
        local_logs=[ReportItem("events.jsonl", "yellow", "Fixture warning count.")],
        manual=[ReportItem("Meeting route proof", "yellow", "Fixture manual item.")],
        commands=[release_record],
    )
    required = [
        "Automated Proof",
        "Regressions",
        "Telemetry",
        "Release Surfaces",
        "Local Log Warnings",
        "Manual QA Checklist",
        "needs_human_check",
    ]
    missing = [marker for marker in required if marker not in report]
    blocking_watch_ok = release_watch_status({"check_id": "appcast-release-candidate"}) == "red"
    release_command_ok = release_record.status == "red"
    telemetry_command_ok = telemetry_record.status == "yellow"

    _, manual_payload = render_report(
        root=root,
        out_dir=Path("/tmp/transcripted-release-gate/self-test"),
        run_id="self-test-manual-only",
        generated_at=generated_at,
        app_version="1.2.3",
        branch="codex/self-test",
        commit="abcdef0",
        automated=[ReportItem("QA bench", "green", "Fixture pass.")],
        telemetry=[ReportItem("Telemetry", "green", "Fixture pass.")],
        release_surfaces=[ReportItem("Release surfaces", "green", "Fixture pass.")],
        local_logs=[ReportItem("Local logs", "green", "Fixture pass.")],
        manual=[ReportItem("Meeting route proof", "yellow", "Fixture manual item.")],
        commands=[],
    )
    manual_boundary_ok = (
        manual_payload["status"] == "yellow"
        and manual_payload["process_status"] == "green"
        and manual_payload["exit_code"] == EXIT_CODES["yellow"]
    )
    skipped_title_ok = "GitHub" not in successful_release_surface_title(
        argparse.Namespace(skip_live_release_surfaces=True, github_release_json=None)
    )
    fixture_title_ok = "GitHub" in successful_release_surface_title(
        argparse.Namespace(skip_live_release_surfaces=True, github_release_json="fixture.json")
    )
    if (
        missing
        or payload["status"] != "yellow"
        or not blocking_watch_ok
        or not release_command_ok
        or not telemetry_command_ok
        or not manual_boundary_ok
        or not skipped_title_ok
        or not fixture_title_ok
    ):
        print(
            f"release-gate-report self-test failed: missing={missing}, "
            f"status={payload['status']}, blocking_watch_ok={blocking_watch_ok}, "
            f"release_command_ok={release_command_ok}, telemetry_command_ok={telemetry_command_ok}, "
            f"manual_boundary_ok={manual_boundary_ok}, "
            f"skipped_title_ok={skipped_title_ok}, fixture_title_ok={fixture_title_ok}",
            file=sys.stderr,
        )
        return 1
    print("release-gate-report self-test passed")
    return 0


def main() -> int:
    args = parse_args()
    if args.self_test:
        return self_test()

    root = repo_root()
    out_root = Path(args.out_root)
    if not out_root.is_absolute():
        out_root = root / out_root
    out_dir = out_root / args.run_id
    (out_dir / "logs").mkdir(parents=True, exist_ok=True)
    (out_dir / "raw").mkdir(parents=True, exist_ok=True)

    commands: list[CommandRecord] = []
    automated = [run_qa_bench(args, root, out_dir, commands)]
    packaged_smoke = run_packaged_app_smoke(args, root, out_dir, commands)
    if packaged_smoke is not None:
        automated.append(packaged_smoke)
    release_surfaces = run_release_surfaces(args, root, out_dir, commands)
    telemetry = run_telemetry(args, root, out_dir, commands)
    local_logs = sweep_local_logs(args)
    manual = manual_items(args, root, out_dir)

    generated_at = utc_now()
    branch = git_value(root, ["branch", "--show-current"], "detached")
    commit = git_value(root, ["rev-parse", "--short", "HEAD"], "unknown")
    app_version = read_info_version(root)
    markdown, payload = render_report(
        root=root,
        out_dir=out_dir,
        run_id=args.run_id,
        generated_at=generated_at,
        app_version=app_version,
        branch=branch,
        commit=commit,
        automated=automated,
        telemetry=telemetry,
        release_surfaces=release_surfaces,
        local_logs=local_logs,
        manual=manual,
        commands=commands,
    )

    report_path = out_dir / "release-gate-report.md"
    json_path = out_dir / "release-gate-report.json"
    report_path.write_text(markdown, encoding="utf-8")
    json_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    print(f"Release gate report: {report_path}")
    print(f"Release gate JSON: {json_path}")
    print(f"Verdict: {status_label(payload['status'])}")
    return EXIT_CODES[payload["status"]]


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Read-only Sentry release and dSYM readiness check for Transcripted."
    )
    parser.add_argument(
        "--version",
        help="Expected app version, e.g. 1.1.49. Defaults to Info.plist CFBundleShortVersionString.",
    )
    parser.add_argument(
        "--info-plist",
        default="Info.plist",
        help="Path to the source Info.plist. Defaults to ./Info.plist.",
    )
    parser.add_argument(
        "--app-binary",
        default="build/Transcripted.app/Contents/MacOS/Transcripted",
        help="Release app binary path used for dSYM UUID matching.",
    )
    parser.add_argument(
        "--debug-files",
        default="build/Transcripted.app.dSYM",
        help="Release dSYM/debug-files path used for UUID matching.",
    )
    parser.add_argument(
        "--sentry-org",
        default=os.environ.get("SENTRY_ORG", "r3dbars"),
        help="Sentry org slug. Defaults to SENTRY_ORG or r3dbars.",
    )
    parser.add_argument(
        "--sentry-project",
        default=os.environ.get("SENTRY_PROJECT", "apple-macos"),
        help="Sentry project slug. Defaults to SENTRY_PROJECT or apple-macos.",
    )
    parser.add_argument(
        "--sentry-repository",
        default=os.environ.get("SENTRY_REPOSITORY", "r3dbars/transcripted"),
        help="Repository slug used for the future set-commits call.",
    )
    parser.add_argument(
        "--check-sentry-release",
        action="store_true",
        help="Read-only: run sentry-cli releases info for the expected release.",
    )
    parser.add_argument(
        "--require-sentry-release",
        action="store_true",
        help="Treat a missing sentry-cli release info result as BLOCKED.",
    )
    parser.add_argument(
        "--require-debug-files",
        action="store_true",
        help="Treat a missing local app binary/dSYM pair as BLOCKED.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print machine-readable JSON instead of text.",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit non-zero when any BLOCKED row is present.",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run a small offline self-test.",
    )
    return parser.parse_args()


def run(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=False)


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def status_row(status: str, check: str, detail: str, command: str | None = None) -> dict[str, str]:
    row = {"status": status, "check": check, "detail": detail}
    if command:
        row["command"] = command
    return row


def load_info_plist(path: Path) -> dict:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def validate_release_name(value: str) -> str | None:
    if len(value) > 200:
        return "Sentry release name must be 200 characters or fewer."
    if value in {".", "..", " "}:
        return "Sentry release name cannot be '.', '..', or a single space."
    if any(character in value for character in ("\n", "\t", "/", "\\")):
        return "Sentry release name cannot contain newlines, tabs, or slashes."
    return None


def uuid_set_for_path(root: Path, path: Path) -> tuple[set[str], str]:
    result = run(["dwarfdump", "--uuid", str(path)], cwd=root)
    if result.returncode != 0:
        return set(), (result.stderr or result.stdout).strip()
    uuids = {
        match.group(1).upper()
        for match in re.finditer(r"^UUID:\s+([A-Fa-f0-9-]+)\s", result.stdout, re.MULTILINE)
    }
    return uuids, ""


def commit_spec(root: Path, version: str, repository: str) -> tuple[str | None, dict[str, str]]:
    release_tag = f"v{version}"
    release_commit = run(["git", "rev-parse", "--verify", f"{release_tag}^{{commit}}"], cwd=root)
    if release_commit.returncode != 0:
        return None, status_row(
            "PENDING",
            "commit association",
            f"Missing local tag {release_tag}; fetch or create the matching release tag before set-commits.",
            f"SENTRY_SET_COMMITS=0 bash scripts/release/register-sentry-release.sh {version}",
        )

    previous_tags = run(
        ["git", "tag", "--merged", release_commit.stdout.strip(), "--sort=-v:refname", "v[0-9]*"],
        cwd=root,
    )
    previous_tag = ""
    if previous_tags.returncode == 0:
        previous_tag = next(
            (
                tag
                for tag in previous_tags.stdout.splitlines()
                if tag.strip() and tag.strip() != release_tag
            ),
            "",
        )

    if previous_tag:
        previous_commit = run(["git", "rev-parse", "--verify", f"{previous_tag}^{{commit}}"], cwd=root)
        if previous_commit.returncode == 0:
            return (
                f"{repository}@{previous_commit.stdout.strip()}..{release_commit.stdout.strip()}",
                status_row("READY", "commit association", f"Future set-commits range can start at {previous_tag}."),
            )

    return (
        f"{repository}@{release_commit.stdout.strip()}",
        status_row("READY", "commit association", "Future set-commits can use the release tag commit."),
    )


def build_report(args: argparse.Namespace, root: Path) -> dict:
    rows: list[dict[str, str]] = [
        status_row(
            "READY",
            "dry-run boundary",
            "This checker does not create/finalize Sentry releases, set commits, or upload debug files.",
        )
    ]
    info_path = root / args.info_plist
    if not info_path.exists():
        rows.append(status_row("BLOCKED", "Info.plist", f"Missing {args.info_plist}."))
        return {"status": "BLOCKED", "rows": rows}

    plist = load_info_plist(info_path)
    info_version = str(plist.get("CFBundleShortVersionString", "")).strip()
    dist = str(plist.get("CFBundleVersion", "")).strip()
    prefix = str(plist.get("TranscriptedSentryReleasePrefix", "transcripted")).strip()
    expected_version = (args.version or info_version).strip()
    release = f"{prefix}@{expected_version}"
    release_error = validate_release_name(release)

    if not info_version or not dist or not prefix:
        rows.append(status_row("BLOCKED", "release metadata", "Info.plist is missing version, dist, or release prefix."))
    elif release_error:
        rows.append(status_row("BLOCKED", "release metadata", release_error))
    elif info_version != expected_version:
        rows.append(
            status_row(
                "PENDING",
                "release metadata",
                f"Info.plist is {info_version}; expected release would be {release}. Bump before real registration.",
            )
        )
    else:
        rows.append(status_row("READY", "release metadata", f"{release} with dist {dist}."))

    for tool in ["sentry-cli", "dwarfdump", "git"]:
        if shutil.which(tool):
            rows.append(status_row("READY", f"{tool} installed", f"{tool} is available."))
        else:
            status = "BLOCKED" if tool in {"git"} or (tool == "dwarfdump" and args.require_debug_files) else "PENDING"
            rows.append(status_row(status, f"{tool} installed", f"{tool} is not on PATH."))

    if os.environ.get("SENTRY_AUTH_TOKEN") or Path.home().joinpath(".sentryclirc").exists():
        rows.append(status_row("READY", "Sentry auth surface", "Sentry auth appears configured; token value was not printed."))
    else:
        rows.append(
            status_row(
                "PENDING",
                "Sentry auth surface",
                "No SENTRY_AUTH_TOKEN env var or ~/.sentryclirc detected in this shell.",
            )
        )

    spec, commit_row = commit_spec(root, expected_version, args.sentry_repository)
    if spec:
        commit_row["command"] = f"sentry-cli releases set-commits --commit {spec} {release}"
    rows.append(commit_row)

    app_binary = root / args.app_binary
    debug_files = root / args.debug_files
    if app_binary.exists() and debug_files.exists() and shutil.which("dwarfdump"):
        binary_uuids, binary_error = uuid_set_for_path(root, app_binary)
        debug_uuids, debug_error = uuid_set_for_path(root, debug_files)
        if binary_uuids and binary_uuids == debug_uuids:
            rows.append(
                status_row(
                    "READY",
                    "dSYM UUID match",
                    f"{args.debug_files} matches {args.app_binary}: {', '.join(sorted(binary_uuids))}.",
                )
            )
        else:
            rows.append(
                status_row(
                    "BLOCKED",
                    "dSYM UUID match",
                    (
                        f"binary UUIDs={sorted(binary_uuids)!r}; dSYM UUIDs={sorted(debug_uuids)!r}; "
                        f"errors={binary_error or debug_error or 'none'}"
                    ),
                )
            )
    else:
        status = "BLOCKED" if args.require_debug_files else "PENDING"
        rows.append(
            status_row(
                status,
                "dSYM UUID match",
                f"Need both {args.app_binary} and {args.debug_files} from the same release build.",
            )
        )

    should_check_sentry = args.check_sentry_release or args.require_sentry_release
    if should_check_sentry and shutil.which("sentry-cli"):
        result = run(
            [
                "sentry-cli",
                "releases",
                "info",
                "--org",
                args.sentry_org,
                "--project",
                args.sentry_project,
                release,
            ],
            cwd=root,
        )
        if result.returncode == 0:
            rows.append(status_row("READY", "remote Sentry release", f"{release} exists in {args.sentry_org}/{args.sentry_project}."))
        else:
            rows.append(
                status_row(
                    "BLOCKED" if args.require_sentry_release else "PENDING",
                    "remote Sentry release",
                    f"{release} was not verified in {args.sentry_org}/{args.sentry_project}.",
                )
            )
    elif should_check_sentry:
        rows.append(status_row("BLOCKED", "remote Sentry release", "sentry-cli is required for remote release info."))

    if any(row["status"] == "BLOCKED" for row in rows):
        status = "BLOCKED"
    elif any(row["status"] == "PENDING" for row in rows):
        status = "PENDING"
    else:
        status = "READY"

    return {
        "status": status,
        "version": expected_version,
        "sentry_release": release,
        "sentry_dist": dist,
        "sentry_org": args.sentry_org,
        "sentry_project": args.sentry_project,
        "rows": rows,
    }


def print_text(report: dict) -> None:
    print(f"Sentry release dry run: {report.get('status', 'BLOCKED')}")
    if "sentry_release" in report:
        print(f"release: {report['sentry_release']}")
        print(f"dist: {report.get('sentry_dist', '')}")
        print(f"project: {report.get('sentry_org')}/{report.get('sentry_project')}")
    print("")
    for row in report["rows"]:
        print(f"- {row['status']}: {row['check']} - {row['detail']}")
        if row.get("command"):
            print(f"  command: {row['command']}")


def self_test() -> int:
    class Args:
        version = "9.9.9"
        info_plist = "Info.plist"
        app_binary = "build/Transcripted.app/Contents/MacOS/Transcripted"
        debug_files = "build/Transcripted.app.dSYM"
        sentry_org = "r3dbars"
        sentry_project = "apple-macos"
        sentry_repository = "r3dbars/transcripted"
        check_sentry_release = False
        require_sentry_release = False
        require_debug_files = False
        json = False
        strict = False
        self_test = True

    old_token = os.environ.get("SENTRY_AUTH_TOKEN")
    os.environ["SENTRY_AUTH_TOKEN"] = "sentry_test_secret_value"
    try:
        report = build_report(Args(), repo_root())
    finally:
        if old_token is None:
            os.environ.pop("SENTRY_AUTH_TOKEN", None)
        else:
            os.environ["SENTRY_AUTH_TOKEN"] = old_token

    serialized = json.dumps(report)
    assert report["sentry_release"] == "transcripted@9.9.9"
    assert any(row["check"] == "dry-run boundary" for row in report["rows"])
    assert "sentry_test_secret_value" not in serialized
    print("sentry-release-dry-run self-test passed")
    return 0


def main() -> int:
    args = parse_args()
    if args.self_test:
        return self_test()
    report = build_report(args, repo_root())
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print_text(report)
    if args.strict and report["status"] == "BLOCKED":
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

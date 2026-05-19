#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import plistlib
import shlex
import sys
from pathlib import Path


DEFAULT_RELEASE_PREFIX = "transcripted"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Print Transcripted's Sentry release and dist metadata from Info.plist."
    )
    parser.add_argument(
        "info_plist",
        nargs="?",
        default="Info.plist",
        help="Path to the app Info.plist. Defaults to ./Info.plist.",
    )
    parser.add_argument(
        "--format",
        choices=("plain", "json", "shell"),
        default="plain",
        help="Output format. shell prints safely quoted SENTRY_* assignments.",
    )
    return parser.parse_args()


def require_non_empty(value: object, key: str) -> str:
    text = str(value or "").strip()
    if not text:
        raise SystemExit(f"{key} is missing or empty")
    return text


def validate_release_name(value: str) -> None:
    if len(value) > 200:
        raise SystemExit("Sentry release name must be 200 characters or fewer")
    if value in {".", "..", " "}:
        raise SystemExit("Sentry release name cannot be '.', '..', or a single space")
    if any(character in value for character in ("\n", "\t", "/", "\\")):
        raise SystemExit("Sentry release name cannot contain newlines, tabs, or slashes")


def load_metadata(info_plist_path: Path) -> dict[str, str]:
    with info_plist_path.open("rb") as handle:
        plist = plistlib.load(handle)

    version = require_non_empty(plist.get("CFBundleShortVersionString"), "CFBundleShortVersionString")
    dist = require_non_empty(plist.get("CFBundleVersion"), "CFBundleVersion")
    prefix = require_non_empty(
        plist.get("TranscriptedSentryReleasePrefix", DEFAULT_RELEASE_PREFIX),
        "TranscriptedSentryReleasePrefix",
    )
    release = f"{prefix}@{version}"
    validate_release_name(release)

    return {
        "app_version": version,
        "sentry_release": release,
        "sentry_dist": dist,
    }


def print_shell(metadata: dict[str, str]) -> None:
    assignments = {
        "APP_VERSION": metadata["app_version"],
        "SENTRY_RELEASE": metadata["sentry_release"],
        "SENTRY_DIST": metadata["sentry_dist"],
    }
    for key, value in assignments.items():
        print(f"{key}={shlex.quote(value)}")


def main() -> int:
    args = parse_args()
    metadata = load_metadata(Path(args.info_plist))

    if args.format == "json":
        print(json.dumps(metadata, indent=2, sort_keys=True))
    elif args.format == "shell":
        print_shell(metadata)
    else:
        print(f"release={metadata['sentry_release']}")
        print(f"dist={metadata['sentry_dist']}")
        print(f"version={metadata['app_version']}")

    return 0


if __name__ == "__main__":
    sys.exit(main())

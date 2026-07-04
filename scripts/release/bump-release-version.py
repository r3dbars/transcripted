#!/usr/bin/env python3
"""Bump Transcripted source version metadata without touching release surfaces."""

from __future__ import annotations

import argparse
import plistlib
import re
import shutil
import sys
import tempfile
from pathlib import Path


VERSION_PATTERN = re.compile(r"^\d+\.\d+\.\d+$")


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def validate_version(version: str) -> str:
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError(f"Version must look like x.y.z, got {version!r}")
    return version


def load_plist(path: Path) -> dict:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def write_plist(path: Path, payload: dict) -> None:
    with path.open("wb") as handle:
        plistlib.dump(payload, handle, sort_keys=False)


def update_info_plist(path: Path, version: str, dry_run: bool) -> bool:
    if not path.exists():
        raise FileNotFoundError(f"Info.plist not found: {path}")

    payload = load_plist(path)
    changed = False
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        if payload.get(key) != version:
            payload[key] = version
            changed = True

    if changed and not dry_run:
        write_plist(path, payload)
    return changed


def update_beta_config(path: Path, version: str, dry_run: bool) -> str:
    if not path.exists():
        return "not present"

    original = path.read_text()
    updated, count = re.subn(
        r'(static let appVersion = ")([^"]+)(")',
        rf"\g<1>{version}\g<3>",
        original,
        count=1,
    )
    if count == 0:
        return "no appVersion mirror"
    if updated == original:
        return "unchanged"
    if not dry_run:
        path.write_text(updated)
    return "updated"


def bump(repo: Path, version: str, dry_run: bool) -> list[str]:
    info_changed = update_info_plist(repo / "Info.plist", version, dry_run)
    beta_status = update_beta_config(repo / "Sources" / "Beta" / "BetaConfig.swift", version, dry_run)
    return [
        f"Info.plist: {'would update' if dry_run and info_changed else 'updated' if info_changed else 'unchanged'}",
        f"Sources/Beta/BetaConfig.swift: {beta_status if not dry_run or beta_status in {'unchanged', 'not present', 'no appVersion mirror'} else 'would update'}",
    ]


def self_test() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = root / "Info.plist"
        write_plist(
            fixture,
            {
                "CFBundleShortVersionString": "1.1.48",
                "CFBundleVersion": "1.1.48",
                "CFBundleName": "Transcripted",
            },
        )
        beta_dir = root / "Sources" / "Beta"
        beta_dir.mkdir(parents=True)
        beta_config = beta_dir / "BetaConfig.swift"
        beta_config.write_text('enum BetaConfig { static let appVersion = "1.1.48" }\n')

        messages = bump(root, "1.1.49", dry_run=False)
        payload = load_plist(fixture)
        assert payload["CFBundleShortVersionString"] == "1.1.49"
        assert payload["CFBundleVersion"] == "1.1.49"
        assert 'appVersion = "1.1.49"' in beta_config.read_text()
        assert any("Info.plist: updated" == item for item in messages)

        dry_root = root / "dry"
        shutil.copytree(root, dry_root)
        bump(dry_root, "1.1.50", dry_run=True)
        assert load_plist(dry_root / "Info.plist")["CFBundleShortVersionString"] == "1.1.49"

    print("bump-release-version self-test passed")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=False, help="Target app version, for example 1.1.49.")
    parser.add_argument("--repo", default=str(repo_root()), help="Repo checkout to update. Defaults to this repo.")
    parser.add_argument("--dry-run", action="store_true", help="Print what would change without writing files.")
    parser.add_argument("--self-test", action="store_true", help="Run fixture tests and exit.")
    args = parser.parse_args()
    if not args.self_test and not args.version:
        parser.error("--version is required unless --self-test is set")
    return args


def main() -> int:
    args = parse_args()
    if args.self_test:
        return self_test()

    try:
        version = validate_version(args.version)
        repo = Path(args.repo).expanduser().resolve()
        for message in bump(repo, version, args.dry_run):
            print(message)
    except Exception as error:
        print(f"bump-release-version failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

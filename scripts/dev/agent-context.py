#!/usr/bin/env python3
"""Print bounded, machine-backed context for a Transcripted change or symptom."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONTRACT = REPO_ROOT / ".agents/agent-contract.json"
MATRIX_SELECTOR = REPO_ROOT / "scripts/dev/test-matrix-checks.py"


class ContractError(ValueError):
    pass


def load_contract(path: Path) -> dict[str, Any]:
    try:
        contract = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise ContractError(f"invalid JSON: {error.msg}") from error
    if not isinstance(contract, dict):
        raise ContractError("contract root must be an object")
    if contract.get("schema_version") != 1:
        raise ContractError("schema_version must be 1")
    areas = contract.get("areas")
    if not isinstance(areas, list) or not areas:
        raise ContractError("areas must be a non-empty list")
    return contract


def validate_contract(contract: dict[str, Any], repo_root: Path) -> None:
    required_root = {
        "schema_version",
        "start_doc",
        "test_matrix",
        "proof_classes",
        "global_invariants",
        "areas",
    }
    missing_root = required_root.difference(contract)
    if missing_root:
        raise ContractError(f"missing root keys: {sorted(missing_root)}")

    referenced_files = [contract["start_doc"], contract["test_matrix"]]
    area_ids: set[str] = set()
    path_claims = 0
    for index, area in enumerate(contract["areas"]):
        if not isinstance(area, dict):
            raise ContractError(f"area {index} must be an object")
        required_area = {
            "id",
            "path_prefixes",
            "docs",
            "keywords",
            "owns",
            "invariants",
            "manual_proof",
        }
        missing_area = required_area.difference(area)
        if missing_area:
            raise ContractError(f"area {index} is missing keys: {sorted(missing_area)}")
        area_id = area["id"]
        if not isinstance(area_id, str) or not area_id:
            raise ContractError(f"area {index} has an invalid id")
        if area_id in area_ids:
            raise ContractError(f"duplicate area id: {area_id}")
        area_ids.add(area_id)
        for list_key in ("path_prefixes", "docs", "keywords", "invariants", "manual_proof"):
            value = area[list_key]
            if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
                raise ContractError(f"{area_id}.{list_key} must be a string list")
        exact_paths = area.get("exact_paths", [])
        if not isinstance(exact_paths, list) or any(not isinstance(item, str) for item in exact_paths):
            raise ContractError(f"{area_id}.exact_paths must be a string list")
        path_claims += len(area["path_prefixes"]) + len(exact_paths)
        referenced_files.extend(area["docs"])

    if len(area_ids) < 12 or path_claims < 20:
        raise ContractError("contract is too small to describe the live repo")
    for relative_path in sorted(set(referenced_files)):
        if not (repo_root / relative_path).exists():
            raise ContractError(f"referenced file does not exist: {relative_path}")


def _git_lines(*arguments: str) -> list[str]:
    result = subprocess.run(
        ["git", *arguments],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def changed_paths(base_ref: str) -> list[str]:
    verify_result = subprocess.run(
        ["git", "rev-parse", "--verify", base_ref],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if verify_result.returncode != 0:
        raise ContractError(f"base ref does not exist: {base_ref}")
    merge_base_result = subprocess.run(
        ["git", "merge-base", "HEAD", base_ref],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    diff_base = merge_base_result.stdout.strip() if merge_base_result.returncode == 0 else base_ref
    committed_diff = subprocess.run(
        ["git", "diff", "--name-only", f"{diff_base}...HEAD"],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if committed_diff.returncode != 0:
        raise ContractError(f"could not compare HEAD with base ref: {base_ref}")
    paths = {line.strip() for line in committed_diff.stdout.splitlines() if line.strip()}
    paths.update(_git_lines("diff", "--cached", "--name-only"))
    paths.update(_git_lines("diff", "--name-only"))
    paths.update(_git_lines("ls-files", "--others", "--exclude-standard"))
    return sorted(paths)


def area_matches_path(area: dict[str, Any], path: str) -> bool:
    return any(path.startswith(prefix) for prefix in area["path_prefixes"]) or path in area.get(
        "exact_paths", []
    )


def area_matches_symptom(area: dict[str, Any], symptom: str) -> bool:
    lowered = symptom.casefold()
    return any(
        re.search(rf"(?<!\w){re.escape(keyword.casefold())}(?!\w)", lowered)
        for keyword in area["keywords"]
    )


def normalize_repo_path(raw_path: str) -> str:
    candidate = Path(raw_path)
    resolved = candidate.resolve(strict=False) if candidate.is_absolute() else (
        REPO_ROOT / candidate
    ).resolve(strict=False)
    try:
        return resolved.relative_to(REPO_ROOT.resolve()).as_posix()
    except ValueError as error:
        raise ContractError(f"path is outside the repo: {raw_path}") from error


def nearest_local_doc(path: str) -> str | None:
    current = (REPO_ROOT / path).parent
    while current != REPO_ROOT and REPO_ROOT in current.parents:
        guide = current / "CLAUDE.md"
        if guide.is_file():
            return guide.relative_to(REPO_ROOT).as_posix()
        current = current.parent
    return None


def select_areas(
    contract: dict[str, Any], paths: list[str], symptom: str | None
) -> list[dict[str, Any]]:
    selected = []
    for area in contract["areas"]:
        if any(area_matches_path(area, path) for path in paths) or (
            symptom and area_matches_symptom(area, symptom)
        ):
            selected.append(area)
    return selected


def select_checks(contract: dict[str, Any], paths: list[str]) -> list[str]:
    if not paths:
        return []
    result = subprocess.run(
        [
            sys.executable,
            str(MATRIX_SELECTOR),
            "--matrix",
            str(REPO_ROOT / contract["test_matrix"]),
            *paths,
        ],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ContractError(result.stderr.strip() or "test matrix selection failed")
    return [line for line in result.stdout.splitlines() if line]


def build_context(
    contract: dict[str, Any], paths: list[str], symptom: str | None
) -> dict[str, Any]:
    areas = select_areas(contract, paths, symptom)
    docs = [contract["start_doc"]]
    docs.extend(guide for path in paths if (guide := nearest_local_doc(path)))
    invariants = list(contract["global_invariants"])
    manual_proof: list[str] = []
    for area in areas:
        docs.extend(area["docs"])
        invariants.extend(area["invariants"])
        manual_proof.extend(area["manual_proof"])
    return {
        "schema_version": contract["schema_version"],
        "paths": paths,
        "areas": [{"id": area["id"], "owns": area["owns"]} for area in areas],
        "docs": list(dict.fromkeys(docs)),
        "invariants": list(dict.fromkeys(invariants)),
        "checks": select_checks(contract, paths),
        "manual_proof": list(dict.fromkeys(manual_proof)),
        "proof_classes": contract["proof_classes"],
    }


def print_human(context: dict[str, Any]) -> None:
    print("Transcripted agent context")
    print()
    print("Changed paths:")
    for path in context["paths"]:
        print(f"- {path}")
    if not context["paths"]:
        print("- none")
    print()
    print("Owners:")
    for area in context["areas"]:
        print(f"- {area['id']}: {area['owns']}")
    if not context["areas"]:
        print("- no matching area; use AGENT_START.md and inspect the nearest owner")
    print()
    print("Read:")
    for doc in context["docs"]:
        print(f"- {doc}")
    print()
    print("Keep true:")
    for invariant in context["invariants"]:
        print(f"- {invariant}")
    print()
    print("Mapped checks:")
    for check in context["checks"]:
        print(f"- {check}")
    if not context["checks"]:
        print("- scripts/dev/agent-preflight.sh")
    print()
    print("Manual or hardware proof:")
    for proof in context["manual_proof"]:
        print(f"- UNKNOWN until verified: {proof}")
    if not context["manual_proof"]:
        print("- none mapped")


def self_test(contract_path: Path) -> None:
    contract = load_contract(contract_path)
    validate_contract(contract, REPO_ROOT)
    cases = {
        "Sources/Speech/ParakeetEngine.swift": {"speech"},
        "Sources/Meeting/MeetingSessionController.swift": {"meeting-app"},
        "Sources/TranscriptedCore/Audio/Audio.swift": {"meeting-core"},
        "Package.swift": {"meeting-core"},
        "scripts/entrypoints/build-beta.sh": {"beta-release"},
        "Tools/TranscriptedMCP/Package.swift": {"tools"},
        "AGENTS.md": {"agent-workflow"},
    }
    for path, expected_ids in cases.items():
        actual_ids = {area["id"] for area in select_areas(contract, [path], None)}
        missing = expected_ids.difference(actual_ids)
        if missing:
            raise ContractError(f"{path} is missing owners: {sorted(missing)}")
    symptom_ids = {
        area["id"] for area in select_areas(contract, [], "model download stuck with AirPods")
    }
    if "speech" not in symptom_ids:
        raise ContractError("symptom routing did not select speech")
    unrelated_ids = {
        area["id"] for area in select_areas(contract, [], "build failure")
    }
    if "ui" in unrelated_ids:
        raise ContractError("short symptom keywords must match on word boundaries")
    sample_path = "Sources/Speech/ParakeetEngine.swift"
    if normalize_repo_path(f"./{sample_path}") != sample_path:
        raise ContractError("relative paths must normalize before routing")
    if normalize_repo_path(str(REPO_ROOT / sample_path)) != sample_path:
        raise ContractError("absolute repo paths must normalize before routing")
    nested_context = build_context(
        contract, ["Tools/TranscriptedMCP/Sources/TranscriptedMCP/Server.swift"], None
    )
    if "Tools/TranscriptedMCP/CLAUDE.md" not in nested_context["docs"]:
        raise ContractError("nested paths must include their nearest local guide")
    try:
        changed_paths("refs/heads/__agent_context_missing_base__")
    except ContractError:
        pass
    else:
        raise ContractError("an invalid base ref must fail closed")
    print("Agent contract self-test passed.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", help="repo-relative paths")
    parser.add_argument("--base", default="origin/main", help="base ref for automatic change detection")
    parser.add_argument("--contract", type=Path, default=DEFAULT_CONTRACT)
    parser.add_argument("--symptom", help="short symptom description; never persisted")
    parser.add_argument("--json", action="store_true", help="emit bounded JSON")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    try:
        if args.self_test:
            self_test(args.contract)
            return 0
        contract = load_contract(args.contract)
        validate_contract(contract, REPO_ROOT)
        paths = sorted(
            {normalize_repo_path(path) for path in args.paths}
            if args.paths
            else changed_paths(args.base)
        )
        context = build_context(contract, paths, args.symptom)
        if args.json:
            print(json.dumps(context, indent=2, sort_keys=True))
        else:
            print_human(context)
        return 0
    except (OSError, ContractError) as error:
        print(f"Agent context failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

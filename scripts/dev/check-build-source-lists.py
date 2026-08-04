#!/usr/bin/env python3
"""Validate hand-maintained swiftc source lists point at files that exist.

The app build's APP_SOURCE_FILES is discovered with `find` and needs no
checking; the lists below are curated by hand and can rot when files move.
run-tests.sh re-derives fast-test conventions itself before compiling, so
convention checks live there, not here.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def extract_shell_array(script_path: str, array_name: str) -> list[str]:
    contents = (REPO_ROOT / script_path).read_text(encoding="utf-8")
    match = re.search(rf"^{re.escape(array_name)}=\(\n(.*?)^\)", contents, re.MULTILINE | re.DOTALL)
    if not match:
        raise ValueError(f"{script_path}: missing {array_name}=(...) array")
    return re.findall(r'"([^"\n]+)"', match.group(1))


SHARED_SOURCES_SCRIPT = "scripts/entrypoints/lib/shared-smoke-sources.sh"
# Matches a bare array-expansion reference like "${SHARED_TEST_STORAGE_SOURCES[@]}"
# left behind after extract_shell_array() strips the surrounding quotes. This
# is also what's left after stripping the `set -u`-safe empty-array guard the
# consumer scripts use (`${ARR[@]+"${ARR[@]}"}`) — see shared-smoke-sources.sh
# for why that guard exists; only the inner quoted `"${ARR[@]}"` is quoted, so
# extract_shell_array's quote-scanning regex only ever sees this bare form.
SHARED_ARRAY_REF_RE = re.compile(r"^\$\{(\w+)\[@\]\}$")
# Anything else that still smells like an unfinished/mistyped bash expansion
# (starts with "$" or contains "${") must not be silently treated as a
# literal file path: validate_paths() only checks Sources/Tests/Tools-prefixed
# entries, so a malformed reference — e.g. a typo'd array name, or `${ARR[*]}`
# instead of `${ARR[@]}` — would otherwise pass straight through unnoticed
# instead of failing loudly.
UNRESOLVED_REF_RE = re.compile(r"^\$|\$\{")


def expand_shared_array_refs(paths: list[str]) -> list[str]:
    """Inline any ${SOME_ARRAY[@]} reference to a bash array sourced from
    SHARED_SOURCES_SCRIPT (see scripts/entrypoints/lib/shared-smoke-sources.sh)
    so validate_paths still checks every file each script actually compiles,
    not just the files it lists directly. Raises ValueError (caught by the
    caller, same as a missing-array error) on any reference that cannot be
    resolved, or that resolves to an empty array — both indicate a shared
    array a consumer script expects to compile files from is broken."""
    expanded: list[str] = []
    shared_cache: dict[str, list[str]] = {}
    for path in paths:
        ref_match = SHARED_ARRAY_REF_RE.match(path)
        if not ref_match:
            if UNRESOLVED_REF_RE.search(path):
                raise ValueError(f"unresolved array reference in source list: {path!r}")
            expanded.append(path)
            continue
        array_name = ref_match.group(1)
        if array_name not in shared_cache:
            resolved = extract_shell_array(SHARED_SOURCES_SCRIPT, array_name)
            if not resolved:
                raise ValueError(f"{SHARED_SOURCES_SCRIPT}: {array_name} expands to zero entries")
            shared_cache[array_name] = resolved
        expanded.extend(shared_cache[array_name])
    return expanded


def validate_paths(label: str, paths: list[str]) -> list[str]:
    failures: list[str] = []
    if not paths:
        failures.append(f"{label}: source list is empty")
        return failures
    for path in paths:
        if path.startswith(("Sources/", "Tests/", "Tools/")) and not (REPO_ROOT / path).is_file():
            failures.append(f"{label}: missing source {path}")
    return failures


def main() -> int:
    failures: list[str] = []

    for script_path, array_name in [
        ("scripts/entrypoints/run-tests.sh", "APP_SOURCES"),
        ("scripts/entrypoints/run-e2e-smoke.sh", "SWIFT_SOURCES"),
        ("scripts/entrypoints/run-slow-pasteback-smoke.sh", "SWIFT_SOURCES"),
    ]:
        try:
            paths = expand_shared_array_refs(extract_shell_array(script_path, array_name))
            failures.extend(validate_paths(f"{script_path} {array_name}", paths))
        except (OSError, ValueError) as error:
            failures.append(str(error))

    if failures:
        print("Build source-list validation failed:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print("Build source-list validation passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

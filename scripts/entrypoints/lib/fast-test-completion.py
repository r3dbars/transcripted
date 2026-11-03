#!/usr/bin/env python3
"""Execute one fast-test binary and require proof that every selected entry returned."""

import argparse
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import tempfile


RECEIPT_KEYS = {
    "version", "run_id", "selection_digest", "selected_functions", "executed_functions",
    "assertions", "passed_assertions", "failed_assertions", "quarantined_suites",
}
COUNT_KEYS = {
    "selected_functions", "executed_functions", "assertions", "passed_assertions",
    "failed_assertions", "quarantined_suites",
}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate receipt key")
        result[key] = value
    return result


def read_completion(path, run_id, selection_digest, expected_functions):
    """Fail closed without reflecting untrusted receipt content into diagnostics."""
    try:
        properties = path.lstat()
        if not stat.S_ISREG(properties.st_mode) or properties.st_size > 8192:
            return None
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as handle:
            data = handle.read(8193)
        if len(data) > 8192:
            return None
        receipt = json.loads(data, object_pairs_hook=unique_object)
    except (OSError, ValueError, UnicodeError):
        return None
    if not isinstance(receipt, dict) or set(receipt) != RECEIPT_KEYS:
        return None
    if type(receipt["version"]) is not int or receipt["version"] != 1:
        return None
    if receipt["run_id"] != run_id or receipt["selection_digest"] != selection_digest:
        return None
    if any(type(receipt[key]) is not int or not 0 <= receipt[key] <= 1_000_000_000 for key in COUNT_KEYS):
        return None
    if (receipt["selected_functions"] != expected_functions
            or receipt["executed_functions"] != expected_functions
            or receipt["assertions"] != receipt["passed_assertions"] + receipt["failed_assertions"]):
        return None
    return receipt


def execute(command, run_root, expected_functions, selection_digest):
    # The outer harness owns run_root. TemporaryDirectory creates and removes
    # only this unique 0700 child; a previous invocation cannot supply its proof.
    with tempfile.TemporaryDirectory(prefix="fast-test-completion-", dir=run_root) as directory:
        receipt_path = Path(directory) / "completion.json"
        run_id = secrets.token_hex(32)
        environment = dict(os.environ)
        environment["TRANSCRIPTED_FAST_TEST_COMPLETION_PATH"] = str(receipt_path)
        environment["TRANSCRIPTED_FAST_TEST_COMPLETION_RUN_ID"] = run_id
        result = subprocess.run(command, env=environment)
        if result.returncode != 0:
            return result.returncode if result.returncode > 0 else 128 - result.returncode
        receipt = read_completion(receipt_path, run_id, selection_digest, expected_functions)
        if receipt is None:
            print("Fast-test completion receipt missing or invalid; run is incomplete.", file=sys.stderr)
            return 1
        description = (f"{receipt['executed_functions']}/{expected_functions} functions, "
                       f"{receipt['assertions']} assertions, {receipt['failed_assertions']} failed")
        if receipt["failed_assertions"]:
            print(f"Fast-test completion verified with failures: {description}.", file=sys.stderr)
            return 1
        print(f"Fast-test completion verified: {description}.")
        return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-root", type=Path, required=True)
    parser.add_argument("--expected-functions", type=int, required=True)
    parser.add_argument("--selection-digest", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if (not command or args.expected_functions < 1
            or not re.fullmatch(r"[0-9a-f]{64}", args.selection_digest)):
        print("Invalid fast-test completion contract.", file=sys.stderr)
        return 1
    try:
        return execute(command, args.run_root, args.expected_functions, args.selection_digest)
    except (OSError, subprocess.SubprocessError):
        print("Fast-test child could not run; completion is unverified.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Reject app-launch smokes that could use the owner's macOS preferences.

Allowed: a separate OS account from the console user, a verified hosted CI
runner, or a CI job inside the owner's Mac runner's throwaway VM
(scripts/ci/mac-runner.sh), which writes a root-owned marker during its
golden-image setup. That VM is deleted after every job, so its desktop user's
preferences are its own.

HOME and CFFIXED_USER_HOME are insufficient: CFPreferences may still resolve
UserDefaults.standard through the real account's cfprefsd session.
"""

from __future__ import annotations

import os
import pwd
import sys


def allowed(
    *,
    uid: int,
    euid: int,
    console_uid: int | None,
    ci: bool,
    github_actions: bool,
    github_hosted: bool,
    hosted_runner_account: bool,
    throwaway_ci_vm: bool = False,
) -> bool:
    if uid == 0 or euid != uid or console_uid is None:
        return False
    if ci and github_actions and github_hosted and hosted_runner_account:
        return True
    if ci and github_actions and throwaway_ci_vm:
        return True
    return console_uid != 0 and uid != console_uid


CI_VM_MARKER = "/Library/TranscriptedCI/throwaway-ci-vm"
CI_VM_RUNNER_PREFIX = "transcripted-mac-"


def root_only(path: str) -> bool:
    """Owned by root and writable by nobody else, for the path and its folders."""
    current = path
    while current and current != "/":
        try:
            info = os.lstat(current)
        except OSError:
            return False
        if info.st_uid != 0 or info.st_mode & 0o022:
            return False
        current = os.path.dirname(current)
    return True


def in_throwaway_ci_vm() -> bool:
    return (
        os.environ.get("RUNNER_ENVIRONMENT") == "self-hosted"
        and os.environ.get("RUNNER_NAME", "").startswith(CI_VM_RUNNER_PREFIX)
        and os.path.isfile(CI_VM_MARKER)
        and root_only(CI_VM_MARKER)
    )


def current_state() -> dict[str, object]:
    try:
        console_uid = os.stat("/dev/console").st_uid
    except OSError:
        console_uid = None
    try:
        account = pwd.getpwuid(os.getuid())
        hosted_runner_account = account.pw_name == "runner" and account.pw_dir == "/Users/runner"
    except KeyError:
        hosted_runner_account = False
    return {
        "uid": os.getuid(),
        "euid": os.geteuid(),
        "console_uid": console_uid,
        "ci": os.environ.get("CI") == "true",
        "github_actions": os.environ.get("GITHUB_ACTIONS") == "true",
        "github_hosted": os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted",
        "hosted_runner_account": hosted_runner_account,
        "throwaway_ci_vm": in_throwaway_ci_vm(),
    }


def main() -> int:
    if allowed(**current_state()):
        return 0
    print(
        "Native Transcripted smoke blocked: this macOS account may share "
        "the owner's UserDefaults and TCC state. Run in a separate OS account "
        "or a verified hosted CI runner. HOME overrides do not isolate preferences.",
        file=sys.stderr,
    )
    return 3


if __name__ == "__main__":
    raise SystemExit(main())

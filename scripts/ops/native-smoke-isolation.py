#!/usr/bin/env python3
"""Reject app-launch smokes that could use the owner's macOS preferences.

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
) -> bool:
    if uid == 0 or euid != uid or console_uid is None:
        return False
    if ci and github_actions and github_hosted and hosted_runner_account:
        return True
    return console_uid != 0 and uid != console_uid


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

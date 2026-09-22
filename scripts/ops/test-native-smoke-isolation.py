#!/usr/bin/env python3
"""Pure policy checks; does not launch Transcripted."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


script = Path(__file__).with_name("native-smoke-isolation.py")
spec = importlib.util.spec_from_file_location("native_smoke_isolation", script)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class NativeSmokeIsolationTests(unittest.TestCase):
    def allowed(self, *, uid=501, euid=501, console_uid=501, ci=False,
                github_actions=False, github_hosted=False, virtual_machine=False,
                hosted_runner_account=False):
        return module.allowed(
            uid=uid, euid=euid, console_uid=console_uid, ci=ci,
            github_actions=github_actions, github_hosted=github_hosted,
            virtual_machine=virtual_machine, hosted_runner_account=hosted_runner_account,
        )

    def test_active_user_and_spoofed_ci_are_blocked(self):
        self.assertFalse(self.allowed())
        self.assertFalse(self.allowed(ci=True, github_actions=True, github_hosted=True))

    def test_separate_os_account_is_allowed(self):
        self.assertTrue(self.allowed(uid=502, euid=502))

    def test_root_unknown_console_and_impersonation_are_blocked(self):
        self.assertFalse(self.allowed(uid=0, euid=0))
        self.assertFalse(self.allowed(console_uid=None))
        self.assertFalse(self.allowed(console_uid=0))
        self.assertFalse(self.allowed(euid=0, console_uid=502))

    def test_hosted_ci_requires_runner_account_or_vm(self):
        self.assertTrue(self.allowed(ci=True, github_actions=True, github_hosted=True, virtual_machine=True))
        self.assertTrue(self.allowed(ci=True, github_actions=True, github_hosted=True, hosted_runner_account=True))
        self.assertFalse(self.allowed(ci=True, github_actions=True, virtual_machine=True))
        self.assertFalse(self.allowed(ci=True, github_actions=True, github_hosted=True))


if __name__ == "__main__":
    unittest.main()

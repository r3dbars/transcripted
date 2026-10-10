#!/usr/bin/env python3
"""Tests for the PR risk classifier and merge gate (scripts/ops/risk-triage.py).

Run: python3 scripts/ops/test-risk-triage.py
Pure logic: no network, no gh, no GitHub.
"""
from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("risk_triage", Path(__file__).with_name("risk-triage.py"))
rt = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rt)

SHA = "abc123"


def files(*names, lines=5):
    return [{"filename": n, "additions": lines, "deletions": 0} for n in names]


def risk(*names, lines=5):
    return rt.classify(files(*names, lines=lines))


class ClassifierTests(unittest.TestCase):
    def test_docs_and_tests_are_low(self):
        self.assertEqual(risk("docs/qa.md", "Tests/FooTests.swift", "README.md")["risk"], "low")

    def test_small_source_fix_with_test_is_low(self):
        r = risk("Sources/UI/Foo.swift", "Tests/FooTests.swift", lines=10)
        self.assertEqual(r["risk"], "low")

    def test_source_fix_without_test_is_medium(self):
        self.assertEqual(risk("Sources/UI/Foo.swift")["risk"], "medium")

    def test_big_source_fix_is_medium(self):
        self.assertEqual(risk("Sources/UI/Foo.swift", "Tests/FooTests.swift", lines=200)["risk"], "medium")

    def test_too_many_source_files_is_medium(self):
        self.assertEqual(risk("Sources/UI/A.swift", "Sources/UI/B.swift", "Sources/UI/C.swift",
                              "Tests/ATests.swift", lines=1)["risk"], "medium")

    def test_unknown_path_is_high(self):
        self.assertEqual(risk("scripts/dev/whatever.py")["risk"], "high")
        self.assertEqual(risk("Sources/UI/Foo.swift", "Tests/FooTests.swift", "Makefile")["risk"], "high")

    def test_release_and_signing_paths_need_owner(self):
        for path in ("scripts/release/update-cask.sh", "Casks/transcripted.rb", "docs/appcast.xml",
                     "Info.plist", "Sources/TranscriptedKeyboard/Info.plist",
                     ".github/workflows/release-candidate.yml", ".github/workflows/publish-mcp-registry.yml",
                     "Sources/Observability/SparkleUpdaterController.swift", "build.sh",
                     "config/entitlements/beta.plist", "Sources/TranscriptedWriting/Runtime/OwnSigningTeam.swift",
                     "server.json", "Sources/Support/TranscriptedAppVersion.swift", ".github/CODEOWNERS",
                     "scripts/ops/risk-triage.py", "docs/agent-merge-policy.md", ".github/workflows/swift-ci.yml"):
            r = risk(path)
            self.assertEqual((r["risk"], r["owner_required"]), ("high", True), path)

    def test_other_high_paths(self):
        for path in ("Sources/TranscriptedCore/Audio/SCKAudioCapture.swift", "Sources/Capture/ContextCaptureEngine.swift",
                     "Sources/Meeting/MeetingCaptureBridge.swift", "Sources/TranscriptedCore/Speaker/SpeakerDatabase.swift",
                     "Sources/TranscriptedCore/Storage/SQLiteHandle.swift", "Sources/Meeting/SpeakerSettingsMigration.swift",
                     "Tools/TranscriptedMCP/Sources/TranscriptedMCP/TranscriptIndex+Schema.swift",
                     "Sources/Support/SystemAudioCaptureTCC.swift", "Package.swift"):
            r = risk(path)
            self.assertEqual((r["risk"], r["owner_required"]), ("high", False), path)

    def test_highest_match_wins(self):
        r = risk("docs/qa.md", "Sources/UI/Foo.swift", "scripts/release/update-cask.sh")
        self.assertEqual((r["risk"], r["owner_required"]), ("high", True))

    def test_rename_away_from_release_path_stays_high(self):
        r = rt.classify([{"filename": "docs/old.md", "previous_filename": "scripts/release/update-cask.sh"}])
        self.assertEqual((r["risk"], r["owner_required"]), ("high", True))

    def test_empty_or_incomplete_file_list_is_high(self):
        self.assertEqual(rt.classify([])["risk"], "high")


def run(name, status="completed", conclusion="success", t="1"):
    return {"name": name, "status": status, "conclusion": conclusion, "started_at": t}


class ChecksTests(unittest.TestCase):
    def test_all_success(self):
        self.assertTrue(rt.checks_green([run("build-and-test"), run("repo-hygiene")], [])[0])

    def test_missing_skipped_pending_neutral_are_not_green(self):
        for bad in ([run("build-and-test")],
                    [run("build-and-test"), run("repo-hygiene", conclusion="skipped")],
                    [run("build-and-test"), run("repo-hygiene", status="in_progress", conclusion=None)],
                    [run("build-and-test"), run("repo-hygiene", conclusion="neutral")],
                    [run("build-and-test"), run("repo-hygiene", conclusion="cancelled")]):
            self.assertFalse(rt.checks_green(bad, [])[0], bad)

    def test_newest_run_wins(self):
        runs = [run("build-and-test"), run("repo-hygiene", t="1"),
                run("repo-hygiene", conclusion="failure", t="2")]
        self.assertFalse(rt.checks_green(runs, [])[0])

    def test_commit_status_counts(self):
        self.assertTrue(rt.checks_green([run("build-and-test")], [{"context": "repo-hygiene", "state": "success"}])[0])


class AiTests(unittest.TestCase):
    def verdict(self, **kw):
        return {"sha": SHA, "status": "ok", "p0": 0, "p1": 0, **kw}

    def test_clear(self):
        self.assertTrue(rt.ai_clear(self.verdict(), SHA, set(), False)[0])

    def test_no_result_blocks(self):
        self.assertFalse(rt.ai_clear(None, SHA, set(), False)[0])
        self.assertFalse(rt.ai_clear(self.verdict(status="no-key"), SHA, set(), False)[0])
        self.assertFalse(rt.ai_clear(self.verdict(sha="old"), SHA, set(), False)[0])

    def test_p1_blocks_unless_owner_waived(self):
        v = self.verdict(p1=1)
        self.assertFalse(rt.ai_clear(v, SHA, set(), False)[0])
        self.assertFalse(rt.ai_clear(v, SHA, {rt.WAIVE_LABEL}, False)[0])
        self.assertTrue(rt.ai_clear(v, SHA, {rt.WAIVE_LABEL}, True)[0])

    def test_parse_text_needs_counts_and_takes_max(self):
        self.assertEqual(rt.parse_ai_text("looks fine")["status"], "unparseable")
        r = rt.parse_ai_text("[P1] bug\n[P1] another\nCOUNTS P0=0 P1=0")
        self.assertEqual((r["status"], r["p1"]), ("ok", 2))

    def test_comment_round_trip(self):
        body = f'{rt.AI_MARKER}\n<!-- risk-triage:verdict {{"sha": "{SHA}", "status": "ok", "p0": 0, "p1": 0}} -->'
        self.assertEqual(rt.parse_ai_comment(body)["sha"], SHA)
        self.assertIsNone(rt.parse_ai_comment("<!-- risk-triage:verdict {} -->"))


def review(user, state="APPROVED", sha=SHA):
    return {"user": {"login": user}, "state": state, "commit_id": sha}


class ApprovalTests(unittest.TestCase):
    def test_self_approval_does_not_count(self):
        self.assertFalse(rt.approvals_ok([review("bot")], "bot", SHA, False)[0])

    def test_other_approver_counts(self):
        self.assertTrue(rt.approvals_ok([review("alice")], "bot", SHA, False)[0])

    def test_stale_approval_does_not_count(self):
        self.assertFalse(rt.approvals_ok([review("alice", sha="old")], "bot", SHA, False)[0])

    def test_owner_required_for_release(self):
        self.assertFalse(rt.approvals_ok([review("alice")], "bot", SHA, True)[0])
        self.assertTrue(rt.approvals_ok([review("r3dbars")], "bot", SHA, True)[0])

    def test_owner_cannot_self_approve_release(self):
        self.assertFalse(rt.approvals_ok([review("r3dbars")], "r3dbars", SHA, True)[0])

    def test_changes_requested_blocks(self):
        self.assertFalse(rt.approvals_ok([review("alice"), review("bob", "CHANGES_REQUESTED")], "bot", SHA, False)[0])


def pr(**kw):
    base = {"draft": False, "labels": [], "head": {"repo": {"full_name": rt.REPO}}}
    base.update(kw)
    return base


OK = (True, [])
AI_OK = (True, "AI review clear")
NO_APPROVAL = (False, "needs approval")


class DecideTests(unittest.TestCase):
    def test_low_and_medium_auto_merge(self):
        for tier in ("low", "medium"):
            d = rt.decide(pr(), {"risk": tier}, OK, AI_OK, NO_APPROVAL)
            self.assertEqual((d["state"], d["automerge"]), ("success", True))

    def test_high_never_auto_merges(self):
        d = rt.decide(pr(), {"risk": "high"}, OK, AI_OK, NO_APPROVAL)
        self.assertEqual((d["state"], d["automerge"]), ("pending", False))
        d = rt.decide(pr(), {"risk": "high"}, OK, AI_OK, (True, "approved"))
        self.assertEqual((d["state"], d["automerge"]), ("success", False))

    def test_blockers(self):
        cases = [
            (pr(draft=True), OK, AI_OK),
            (pr(head={"repo": {"full_name": "someone/fork"}}), OK, AI_OK),
            (pr(labels=[{"name": "hold"}]), OK, AI_OK),
            (pr(), (False, ["repo-hygiene: skipped"]), AI_OK),
            (pr(), OK, (False, "no AI review")),
        ]
        for p, checks, ai in cases:
            d = rt.decide(p, {"risk": "low"}, checks, ai, NO_APPROVAL)
            self.assertFalse(d["automerge"], p)
            self.assertEqual(d["state"], "pending")


if __name__ == "__main__":
    unittest.main(verbosity=1)

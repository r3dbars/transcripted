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

    def test_entrypoint_build_scripts_need_owner(self):
        for path in ("scripts/entrypoints/build-beta.sh", "scripts/entrypoints/build.sh", "scripts/entrypoints/lib/sign.sh"):
            self.assertEqual((risk(path)["risk"], risk(path)["owner_required"]), ("high", True), path)

    def test_redact(self):
        out = rt.redact("mail a@b.com at /Users/justin/x /tmp/meet.wav https://x.io/q token=abcdefghijk ghp_" + "a" * 30)
        for bad in ("a@b.com", "justin", "meet.wav", "x.io", "abcdefghijk", "ghp_"):
            self.assertNotIn(bad, out)

    def test_speech_engine_is_high(self):
        self.assertEqual(risk("Sources/Speech/ParakeetAudioTap.swift", "Tests/XTests.swift", lines=1)["risk"], "high")

    def test_removed_test_is_not_proof(self):
        fs = [{"filename": "Sources/UI/Foo.swift", "additions": 1, "deletions": 0},
              {"filename": "Tests/FooTests.swift", "additions": 0, "deletions": 9, "status": "removed"}]
        self.assertEqual(rt.classify(fs)["risk"], "high")  # removing a test needs human review

    def test_agent_instructions_are_high(self):
        for path in ("AGENTS.md", "CLAUDE.md", "Sources/AGENTS.md", "docs/CLAUDE.md"):
            self.assertEqual(risk(path)["risk"], "high", path)

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


def run(name, status="completed", conclusion="success", t="1", app=15368, rid=1):
    return {"name": name, "status": status, "conclusion": conclusion, "completed_at": t, "id": rid,
            "app": {"id": app}}


class ChecksTests(unittest.TestCase):
    def test_all_success(self):
        self.assertTrue(rt.checks_green([run("build-and-test"), run("repo-hygiene")])[0])

    def test_missing_skipped_pending_neutral_are_not_green(self):
        for bad in ([run("build-and-test")],
                    [run("build-and-test"), run("repo-hygiene", conclusion="skipped")],
                    [run("build-and-test"), run("repo-hygiene", status="in_progress", conclusion=None)],
                    [run("build-and-test"), run("repo-hygiene", conclusion="neutral")],
                    [run("build-and-test"), run("repo-hygiene", conclusion="cancelled")]):
            self.assertFalse(rt.checks_green(bad)[0], bad)

    def test_newest_run_wins(self):
        runs = [run("build-and-test"), run("repo-hygiene", t="1"),
                run("repo-hygiene", conclusion="failure", t="2", rid=2)]
        self.assertFalse(rt.checks_green(runs)[0])

    def test_other_apps_do_not_count(self):
        self.assertFalse(rt.checks_green([run("build-and-test"), run("repo-hygiene", app=999)])[0])

    def test_queued_rerun_beats_older_success(self):  # P1 #7
        runs = [run("build-and-test"), run("repo-hygiene", t="1"),
                {"name": "repo-hygiene", "status": "queued", "conclusion": None, "completed_at": None,
                 "id": 9, "app": {"id": 15368}}]
        ok, why = rt.checks_green(runs)
        self.assertFalse(ok)
        self.assertIn("pending", why[0])

    def test_passed_on_retry_stays_pending(self):
        runs = [run("build-and-test"), run("repo-hygiene", conclusion="failure", t="1"),
                run("repo-hygiene", t="2", rid=2)]
        self.assertEqual(rt.checks_green(runs), (False, ["repo-hygiene: passed on retry"]))


class AiTests(unittest.TestCase):
    def verdict(self, **kw):
        return {"sha": SHA, "status": "ok", "p0": 0, "p1": 0, **kw}

    def test_clear(self):
        self.assertTrue(rt.ai_clear(self.verdict(), SHA)[0])

    def test_no_result_blocks(self):
        self.assertFalse(rt.ai_clear(None, SHA)[0])
        self.assertFalse(rt.ai_clear(self.verdict(status="no-key"), SHA)[0])
        self.assertFalse(rt.ai_clear(self.verdict(sha="old"), SHA)[0])

    def test_p1_always_blocks_no_waiver(self):
        # The ai-findings-waived label is gone: any agent using Justin's login could add it.
        self.assertFalse(rt.ai_clear(self.verdict(p1=1), SHA)[0])
        self.assertFalse(hasattr(rt, "WAIVE_LABEL"))

    def test_parse_text_needs_counts_and_takes_max(self):
        self.assertEqual(rt.parse_ai_text("looks fine")["status"], "unparseable")
        r = rt.parse_ai_text("[P1] bug\n[P1] another\nCOUNTS P0=0 P1=0")
        self.assertEqual((r["status"], r["p1"]), ("ok", 2))

    def test_verdict_round_trip(self):
        body = f'<!-- risk-triage:verdict {{"sha": "{SHA}", "status": "ok", "p0": 0, "p1": 0}} -->'
        self.assertEqual(rt.parse_verdict(body)["sha"], SHA)
        self.assertIsNone(rt.parse_verdict("<!-- risk-triage:verdict [] -->"))


def review(user, state="APPROVED", sha=SHA, assoc="COLLABORATOR"):
    return {"user": {"login": user}, "state": state, "commit_id": sha, "author_association": assoc}


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

    def test_owner_authored_gets_no_exemption(self):
        # Agent PRs are authored by r3dbars too, so authorship grants nothing.
        self.assertFalse(rt.approvals_ok([], "r3dbars", SHA, True)[0])

    def test_untrusted_reviewer_does_not_count(self):
        self.assertFalse(rt.approvals_ok([review("rando", assoc="NONE")], "bot", SHA, False)[0])

    def test_owner_authored_release_needs_more_than_other_approval(self):
        self.assertFalse(rt.approvals_ok([review("alice")], "r3dbars", SHA, True)[0])

    def test_owner_authored_still_blocked_by_changes_requested(self):
        self.assertFalse(rt.approvals_ok([review("alice", "CHANGES_REQUESTED")], "r3dbars", SHA, True)[0])

    def test_untrusted_changes_requested_ignored(self):
        self.assertFalse(rt.changes_requested([review("rando", "CHANGES_REQUESTED", assoc="NONE")]))

    def test_changes_requested_detected(self):
        self.assertTrue(rt.changes_requested([review("bob", "CHANGES_REQUESTED")]))
        self.assertFalse(rt.changes_requested([review("bob", "CHANGES_REQUESTED"), review("bob")]))

    def test_changes_requested_blocks(self):
        self.assertFalse(rt.approvals_ok([review("alice"), review("bob", "CHANGES_REQUESTED")], "bot", SHA, False)[0])


def pr(**kw):
    base = {"draft": False, "labels": [], "head": {"repo": {"full_name": rt.REPO}}, "base": {"ref": "main"}}
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
        self.assertEqual((d["state"], d["automerge"]), ("pending", False))

    def test_changes_requested_blocks_every_tier(self):
        for tier in ("low", "medium", "high"):
            d = rt.decide(pr(), {"risk": tier}, OK, AI_OK, (True, "approved"), True)
            self.assertEqual((d["state"], d["automerge"]), ("pending", False), tier)

    def test_high_never_passes_even_with_owner_approval(self):
        for author in ("r3dbars", "bot"):
            d = rt.decide(pr(user={"login": author}), {"risk": "high"}, OK, AI_OK,
                          rt.approvals_ok([review("r3dbars"), review("alice")], author, SHA, True))
            self.assertEqual((d["state"], d["automerge"]), ("pending", False), author)

    def test_r3dbars_authored_high_with_approvals_stays_pending(self):
        d = rt.decide(pr(user={"login": "r3dbars"}), {"risk": "high", "owner_required": True}, OK, AI_OK,
                      rt.approvals_ok([review("alice")], "r3dbars", SHA, True))
        self.assertEqual((d["state"], d["automerge"]), ("pending", False))

    def test_owner_authored_high_stays_pending(self):
        d = rt.decide(pr(), {"risk": "high"}, OK, AI_OK, rt.approvals_ok([], "r3dbars", SHA, True))
        self.assertEqual((d["state"], d["automerge"]), ("pending", False))
        self.assertTrue(any("manually" in w for w in d["why"]))

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




class DesignCallTests(unittest.TestCase):
    def test_medium_over_400_lines_is_high(self):
        self.assertEqual(risk("Sources/UI/Foo.swift", lines=401)["risk"], "high")
        self.assertEqual(risk("Sources/UI/Foo.swift", lines=400)["risk"], "medium")
        two = [{"filename": "Sources/UI/A.swift", "additions": 150, "deletions": 60},
               {"filename": "Sources/UI/B.swift", "additions": 100, "deletions": 100}]
        self.assertEqual(rt.classify(two)["risk"], "high")  # 410 total

    def test_low_docs_over_400_lines_stay_low(self):
        self.assertEqual(risk("docs/big.md", lines=900)["risk"], "low")

    def test_test_renamed_out_of_tests_is_high(self):
        r = rt.classify([{"filename": "scripts/dev/foo_helper.py", "previous_filename": "Tests/FooTests.swift",
                          "status": "renamed"}])
        self.assertEqual(r["risk"], "high")
        self.assertTrue(any("removes a test" in x for x in r["reasons"]))

    def test_test_renamed_within_tests_keeps_tier(self):
        r = rt.classify([{"filename": "Tests/Sub/FooTests.swift", "previous_filename": "Tests/FooTests.swift",
                          "status": "renamed"}])
        self.assertEqual(r["risk"], "low")

    def test_modified_test_keeps_tier(self):
        mod = {"filename": "Tests/FooTests.swift", "status": "modified", "additions": 2, "deletions": 8}
        self.assertEqual(rt.classify([mod])["risk"], "low")
        self.assertEqual(rt.classify([mod, {"filename": "Sources/UI/Foo.swift", "additions": 1}])["risk"], "low")
        self.assertEqual(rt.classify([mod, {"filename": "Sources/UI/Foo.swift", "additions": 100}])["risk"], "medium")

    def test_baselines_are_medium_except_concurrency(self):
        self.assertEqual(risk(".agents/test-shape-baseline.json", "Tests/FooTests.swift")["risk"], "medium")
        self.assertEqual(risk(".agents/concurrency-baseline.json")["risk"], "high")


class LegacyGateTests(unittest.TestCase):
    def test_legacy_gate_blocks_triage_high(self):
        spec = importlib.util.spec_from_file_location("amg", Path(__file__).with_name("auto-merge-gate.py"))
        amg = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(amg)
        import contextlib, io
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(amg.self_test(), 0)  # includes the "risk triage says high" cases


class ExtensionRenameTests(unittest.TestCase):
    def test_test_renamed_to_non_test_extension_is_high(self):
        r = rt.classify([{"filename": "Tests/FooTests.md", "previous_filename": "Tests/FooTests.swift",
                          "status": "renamed"}])
        self.assertEqual(r["risk"], "high")

    def test_test_moved_same_extension_keeps_tier(self):
        r = rt.classify([{"filename": "Tests/A/FooTests.swift", "previous_filename": "Tests/FooTests.swift",
                          "status": "renamed"}])
        self.assertEqual(r["risk"], "low")


HEAD = "f" * 40
APP = "424242"


def gate_run(app=APP, sha=HEAD, t="2026-10-10T05:00:00Z", rid=1, **v):
    import json as _j
    verdict = {"sha": sha, "status": "ok", "p0": 0, "p1": 0, "pr": 9, **v}
    return {"id": rid, "name": "risk-gate", "head_sha": sha, "started_at": t, "app": {"id": int(app)},
            "output": {"text": f"<!-- risk-triage:verdict {_j.dumps(verdict)} -->"}}


class AppVerdictTests(unittest.TestCase):
    """P1s 1, 2, 3: the verdict lives in a check run only the gate App can create."""

    def test_genuine_app_verdict_accepted(self):
        v, why = rt.app_verdict([gate_run()], HEAD, APP)
        self.assertIsNotNone(v, why)

    def test_forgeries_rejected(self):
        cases = {
            "posted by GitHub Actions (a PR workflow)": gate_run(app="15368"),
            "posted by another app": gate_run(app="1"),
            "other commit run": gate_run(sha="e" * 40),
            "verdict names another sha": dict(gate_run(), output={"text": gate_run(sha="e" * 40)["output"]["text"]}),
            "other check name": dict(gate_run(), name="risk-gate-x"),
            "no verdict block": dict(gate_run(), output={"text": "all good"}),
        }
        for name, r in cases.items():
            self.assertIsNone(rt.app_verdict([r], HEAD, APP)[0], name)

    def test_no_app_configured_means_no_verdict(self):
        v, why = rt.app_verdict([gate_run()], HEAD, "")
        self.assertIsNone(v)
        self.assertIn("not configured", why)

    def test_newest_app_run_wins(self):
        runs = [gate_run(p1=0, t="2026-10-10T05:00:00Z", rid=1), gate_run(p1=2, t="2026-10-10T06:00:00Z", rid=2),
                gate_run(app="15368", p1=0, t="2026-10-10T07:00:00Z", rid=3)]
        self.assertEqual(rt.app_verdict(runs, HEAD, APP)[0]["p1"], 2)


class GatePolicyTests(unittest.TestCase):
    SUCCESS = {"state": "success", "automerge": True, "why": ["risk:low"]}

    def test_kill_switch_off_holds(self):
        r = rt.apply_gate_policy(self.SUCCESS, behind=False, mode="off", app_configured=True)
        self.assertEqual((r["state"], r["automerge"]), ("pending", False))

    def test_signal_only_posts_success_without_arming(self):
        r = rt.apply_gate_policy(self.SUCCESS, behind=False, mode="signal-only", app_configured=True)
        self.assertEqual((r["state"], r["automerge"]), ("success", False))

    def test_enabled_arms(self):
        r = rt.apply_gate_policy(self.SUCCESS, behind=False, mode="true", app_configured=True)
        self.assertEqual((r["state"], r["automerge"]), ("success", True))

    def test_no_app_or_behind_holds(self):
        for kw in ({"behind": False, "app_configured": False}, {"behind": True, "app_configured": True}):
            r = rt.apply_gate_policy(self.SUCCESS, mode="true", **kw)
            self.assertEqual((r["state"], r["automerge"]), ("pending", False), kw)

    def test_mode_defaults_off(self):
        import os
        old = os.environ.pop("AUTOMERGE_ENABLED", None)
        try:
            self.assertEqual(rt.automerge_mode(), "off")
            os.environ["AUTOMERGE_ENABLED"] = "yes"
            self.assertEqual(rt.automerge_mode(), "off")
        finally:
            os.environ.pop("AUTOMERGE_ENABLED", None)
            if old is not None:
                os.environ["AUTOMERGE_ENABLED"] = old

    def test_automerge_off_label_holds(self):
        d = rt.decide(pr(labels=[{"name": "automerge:off"}]), {"risk": "low"}, OK, AI_OK, NO_APPROVAL)
        self.assertEqual(d["state"], "pending")

    def test_high_check_never_completes(self):
        body = rt.build_check({"risk": "high", "reasons": ["x"]}, {"status": "ok", "p0": 0, "p1": 0, "text": ""},
                              {"sha": HEAD, "pr": 9, "status": "ok", "p0": 0, "p1": 0},
                              {"state": "pending", "automerge": False, "why": ["high risk"]})
        self.assertEqual((body["status"], body["conclusion"]), ("completed", "failure"))
        self.assertEqual(rt.parse_verdict(body["output"]["text"])["sha"], HEAD)

    def test_conclusion_per_tier_never_neutral(self):  # adversarial P0-4
        v = {"sha": HEAD, "pr": 9, "status": "ok", "p0": 0, "p1": 0}
        rv = {"status": "ok", "p0": 0, "p1": 0, "text": ""}
        ok = {"state": "success", "automerge": True, "why": ["clear"]}
        wait = {"state": "pending", "automerge": False, "why": ["checks pending"]}
        cases = {("low", "s"): ("completed", "success"), ("medium", "s"): ("completed", "success"),
                 ("low", "p"): ("in_progress", None), ("medium", "p"): ("in_progress", None),
                 ("high", "p"): ("completed", "failure")}
        for (tier, st), want in cases.items():
            b = rt.build_check({"risk": tier, "reasons": []}, rv, v, ok if st == "s" else wait)
            self.assertEqual((b["status"], b.get("conclusion")), want, (tier, st))
            self.assertNotIn(b.get("conclusion"), ("neutral", "skipped", "action_required" if tier != "high" else "x"))


class NoSelfMergeTests(unittest.TestCase):
    """No merge or arm with a person's token; only the gate App token."""

    def test_arm_needs_app_token(self):
        import os
        saved = os.environ.pop("GATE_TOKEN", None)
        orig_app = rt.GATE_APP_ID
        try:
            rt.GATE_APP_ID = APP
            self.assertIsNone(rt._app_env())
            os.environ["GATE_TOKEN"] = "app-token"
            self.assertEqual(rt._app_env()["GH_TOKEN"], "app-token")
            rt.GATE_APP_ID = ""
            self.assertIsNone(rt._app_env())
        finally:
            rt.GATE_APP_ID = orig_app
            os.environ.pop("GATE_TOKEN", None)
            if saved is not None:
                os.environ["GATE_TOKEN"] = saved

    def test_no_admin_merges_or_merge_token_anywhere(self):
        root = Path(__file__).resolve().parents[2]
        paths = (list((root / ".github/workflows").glob("*.yml")) + list((root / "scripts").rglob("*.py"))
                 + list((root / "scripts").rglob("*.sh")))
        for p in paths:
            if p.name == "test-risk-triage.py":
                continue
            self.assertNotRegex(p.read_text(errors="ignore"), r"gh pr merge[^\n]*--admin", str(p))
        self.assertNotIn("AUTOMERGE_TOKEN", (root / ".github/workflows/risk-triage.yml").read_text())
        self.assertNotIn("MERGE_TOKEN", (root / "scripts/ops/risk-triage.py").read_text())


class PaginationTests(unittest.TestCase):
    def test_workflow_runs_for_reads_every_page(self):
        import json
        pages = [{"total_count": 101, "workflow_runs": [{"check_suite_id": i} for i in range(100)]},
                 {"total_count": 101, "workflow_runs": [{"check_suite_id": 100, "path": "x"}]}]
        calls = []
        orig = rt.gh
        rt.gh = lambda *a, **k: (calls.append(a), json.dumps(pages))[1]
        try:
            runs = rt.workflow_runs_for(SHA)
        finally:
            rt.gh = orig
        self.assertIn("--paginate", calls[0])
        self.assertEqual(len(runs), 101)
        self.assertEqual(runs[100]["path"], "x")


class WorkflowShapeTests(unittest.TestCase):
    def wf(self):
        return (Path(__file__).resolve().parents[2] / ".github/workflows/risk-triage.yml").read_text()

    def test_no_pull_request_target(self):
        # GitHub blocks pull_request_target on public repos by default from 2026-11-02.
        wf = self.wf()
        self.assertNotRegex(wf, r"(?m)^\s+pull_request_target:")
        self.assertNotRegex(wf, r"(?m)^\s+pull_request:")
        self.assertIn("workflow_run:", wf)

    def test_gate_uses_app_token_in_main_only_env(self):
        wf = self.wf()
        self.assertIn("environment: automerge-app", wf)
        self.assertIn("actions/create-github-app-token", wf)
        self.assertIn("GATE_TOKEN: ${{ steps.app.outputs.token }}", wf)
        self.assertNotIn("ref: ${{ github.event.workflow_run.head", wf)

    def test_gate_concurrency_is_per_pr_and_never_cancels(self):
        wf = self.wf()
        self.assertIn("cancel-in-progress: false", wf)
        self.assertIn("group: risk-gate-${{ inputs.pr || github.event.workflow_run.head_sha || 'sweep' }}", wf)


class Phase1PathTests(unittest.TestCase):
    def tier(self, p):
        return rt.classify([{"filename": p, "additions": 1}, {"filename": "Tests/XTests.swift"}])

    def test_meeting_detection_is_high(self):  # P1 #5
        for p in ("Sources/Meeting/MicActivityMonitor.swift", "Sources/Meeting/CameraActivityMonitor.swift",
                  "Sources/Meeting/MeetingPromptDetector.swift", "Sources/Meeting/MeetingPromptDetector+Backoff.swift",
                  "Sources/Support/AutoCallDetectionPreferences.swift"):
            self.assertEqual(self.tier(p)["risk"], "high", p)

    def test_owner_protected_surfaces_are_high(self):  # P1 #9
        for p in ("Sources/UI/Settings/SpeakerPeopleSettingsSection.swift", "Sources/Meeting/SpeakerSettingsStore.swift",
                  "Sources/Support/DictationAutoSendPreferences.swift",
                  "Sources/UI/Settings/AutoEnterDisplayNameResolver.swift",
                  "Sources/Support/ModelCacheInventory.swift", "Sources/UI/MenuBar/StatusItemPresentation.swift",
                  "Sources/UI/Shared/MeetingAudioPlayback.swift"):
            r = self.tier(p)
            self.assertEqual(r["risk"], "high", p)
            self.assertTrue(any("owner-protected" in x for x in r["reasons"]), p)

    def test_harness_guards_are_high(self):  # P1 #10
        for p in ("Sources/Support/AutomatedLaunchEnvironment.swift",
                  "Tools/TranscriptedQA/Sources/TranscriptedQA/Utilities/NativeSmokeIsolation.swift"):
            self.assertEqual(self.tier(p)["risk"], "high", p)

    def test_gate_ci_and_agent_config_are_always_high(self):
        for p in (".github/workflows/repo-hygiene.yml", ".github/workflows/new.yml", ".github/actions/x/action.yml",
                  "scripts/ops/risk-triage.py", "scripts/ops/test-risk-triage.py", "scripts/ops/auto-merge-gate.py",
                  "scripts/dev/linux-checks.sh", "scripts/dev/check-file-size.py", "scripts/ci/pick-ci-runner.py",
                  "CLAUDE.md", ".claude/settings.json", ".codex/config.toml", "AGENTS.md"):
            self.assertEqual(self.tier(p)["risk"], "high", p)

    def test_agent_instructions_and_release_job_code_are_high(self):  # adversarial P0-3, P0-5, P0-6
        for p in (".claude/agents/test-writer.md", ".codex/prompts/x.md", ".agents/skills/verify/SKILL.md",
                  "skills/foo/SKILL.md", ".agent-review/notes.md", ".github/pull_request_template.md",
                  "WORKFLOW.md", "Sources/AGENTS.md", "docs/appcast.xml",
                  "Tools/TranscriptedQA/Sources/TranscriptedQA/main.swift", "scripts/ops/privacy-leak-sweep.py",
                  "scripts/entrypoints/run.sh", "Tools/TranscriptedMCP/Package.swift", "Package.resolved"):
            self.assertEqual(self.tier(p)["risk"], "high", p)
        self.assertEqual(rt.classify([{"filename": ".agents/test-shape-baseline.json", "additions": 1}])["risk"], "medium")

    def test_only_runnable_tests_are_proof(self):  # P1 #4
        src = {"filename": "Sources/UI/Foo.swift", "additions": 5}
        self.assertEqual(rt.classify([src, {"filename": "Tests/README.md", "additions": 1}])["risk"], "medium")
        self.assertEqual(rt.classify([src, {"filename": "Tests/Fixtures/x.json", "additions": 1}])["risk"], "medium")
        self.assertEqual(rt.classify([src, {"filename": "Tests/FooTests.swift", "additions": 1}])["risk"], "low")

    def test_any_absolute_path_is_redacted(self):  # P1 #8
        out = rt.redact("at /Applications/Transcripted.app/Contents and /workspace/a/b and ~/Library/X\n"
                        "+++ b/Sources/Foo.swift x / y")
        for leaked in ("/Applications", "/workspace", "~/Library"):
            self.assertNotIn(leaked, out)
        self.assertIn("b/Sources/Foo.swift", out)
        self.assertIn("x / y", out)


class FailClosedTests(unittest.TestCase):
    def test_evaluation_error_fails_closed_in_sweep(self):
        import contextlib, io
        calls = []
        orig = (rt.fail_closed, rt._gate_one)
        rt.fail_closed = lambda num, why: calls.append(num)
        rt._gate_one = lambda num, apply: (_ for _ in ()).throw(RuntimeError("api down"))
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(rt.cmd_gate(3, True), 1)
        finally:
            rt.fail_closed, rt._gate_one = orig
        self.assertEqual(calls, [3])


class PrivacyPathTests(unittest.TestCase):
    def test_privacy_and_redaction_files_are_high(self):
        for p in ("Sources/Observability/PayloadSanitizationCore.swift",
                  "Sources/Observability/ObservabilityTextRedactor.swift",
                  "Sources/TranscriptedCore/Logging/PrivacyTextRedactor.swift",
                  "Sources/TranscriptedCore/Logging/LogPrivacySanitizer.swift",
                  "Sources/Observability/LocalObservabilityPayloadSanitizer.swift",
                  "Sources/Observability/CrashReporterPrivacyOptions.swift",
                  "Sources/Observability/SentryRuntimeConfiguration.swift",
                  "Sources/Observability/AnalyticsReporter.swift",
                  "Sources/Observability/TelemetryContext.swift",
                  "Sources/Support/AnalyticsPreferences.swift",
                  "Sources/TranscriptedWriting/Core/Text/DiagnosticsMetadataRedactor.swift",
                  "Sources/TranscriptedWriting/Core/Text/WritingSecretScrubber.swift",
                  "Sources/TranscriptedWriting/Core/Text/WritingScrubberTokenIdentity.swift",
                  "Sources/TranscriptedWriting/Runtime/SaveMyWriting/WritingDayFileRescrubber.swift"):
            r = rt.classify([{"filename": p, "additions": 1}, {"filename": "Tests/XTests.swift"}])
            self.assertEqual(r["risk"], "high", p)


class CrashTelemetryPathTests(unittest.TestCase):
    def test_crash_and_telemetry_files_are_high(self):
        for p in ("Sources/Observability/CrashReporter.swift",
                  "Sources/Observability/CrashReportingPreferences.swift",
                  "Sources/Observability/EventReporter.swift",
                  "Sources/Observability/InstallIdentity.swift",
                  "Sources/Observability/SupportDiagnosticsBundle.swift",
                  "Sources/Meeting/MeetingPromptTelemetry.swift",
                  "Sources/UI/Overlay/DictationSessionController+Telemetry.swift",
                  "Tools/TranscriptedMCP/Sources/TranscriptedMCP/AgentCaptureQueryTelemetry.swift"):
            r = rt.classify([{"filename": p, "additions": 1}, {"filename": "Tests/XTests.swift"}])
            self.assertEqual(r["risk"], "high", p)


class SharedHoldLabelTests(unittest.TestCase):
    def test_blocked_holds_both_gates(self):
        self.assertIn("blocked", rt.HOLD_LABELS)
        d = rt.decide(pr(labels=[{"name": "blocked"}]), {"risk": "low"}, OK, AI_OK, NO_APPROVAL)
        self.assertEqual((d["state"], d["automerge"]), ("pending", False))
        spec = importlib.util.spec_from_file_location("amg2", Path(__file__).with_name("auto-merge-gate.py"))
        amg = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(amg)
        self.assertTrue(rt.HOLD_LABELS <= amg.RISK_TRIAGE.HOLD_LABELS)
        self.assertIn("RISK_TRIAGE.HOLD_LABELS", Path(amg.__file__).read_text())


class SweepTests(unittest.TestCase):
    def test_one_bad_pr_does_not_stop_the_sweep(self):
        seen = []
        orig = rt._gate_one

        def fake(num, apply, entries=None):
            seen.append(num)
            if num == 2:
                raise RuntimeError("boom")
            return 0
        rt._gate_one = fake
        try:
            import contextlib, io
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                orig_json = rt.gh_json
                rt.gh_json = lambda path, paginate=False: [{"number": 1}, {"number": 2}, {"number": 3}]
                try:
                    code = rt.cmd_gate(None, False)
                finally:
                    rt.gh_json = orig_json
        finally:
            rt._gate_one = orig
        self.assertEqual(seen, [1, 2, 3])
        self.assertEqual(code, 1)


class ExtraClassifierTests(unittest.TestCase):
    def test_removed_test_is_high(self):
        r = rt.classify([{"filename": "Tests/FooTests.swift", "status": "removed", "deletions": 50}])
        self.assertEqual(r["risk"], "high")

    def test_incomplete_list_requires_owner(self):
        self.assertTrue(rt.classify([])["owner_required"])

    def test_privacy_egress_is_high(self):
        for p in ("Sources/Observability/SentryPayloadSanitizer.swift",
                  "Sources/Observability/AnalyticsEventPolicy.swift"):
            self.assertEqual(rt.classify([{"filename": p, "additions": 1}, {"filename": "Tests/XTests.swift"}])["risk"], "high", p)


GREEN = (True, [])
CLEAR = (True, "AI review clear")
NOAPP = (False, "x")


class ReviewFixTests(unittest.TestCase):
    """#2199 review: F1 base/shared head, F2 workflow provenance, test weakening."""

    def test_non_main_base_never_succeeds(self):
        d = rt.decide(pr(base={"ref": "scratch"}), risk("docs/a.md"), GREEN, CLEAR, NOAPP)
        self.assertEqual(d["state"], "pending")
        self.assertFalse(d["automerge"])

    def test_shared_head_holds(self):
        d = rt.decide(pr(), risk("docs/a.md"), GREEN, CLEAR, NOAPP, shared_head=True)
        self.assertEqual(d["state"], "pending")

    def test_verdict_bound_to_pr_and_base(self):
        v = {"sha": SHA, "pr": 1, "base_sha": "b1", "status": "ok", "p0": 0, "p1": 0}
        self.assertTrue(rt.verdict_matches(v, SHA, 1, "b1"))
        self.assertFalse(rt.verdict_matches(v, SHA, 2, "b1"))
        self.assertFalse(rt.verdict_matches(v, SHA, 1, "b2"))

    def test_app_verdict_requires_external_id(self):
        import json
        v = {"sha": SHA, "pr": 1, "base_sha": "b1", "status": "ok", "p0": 0, "p1": 0}
        text = f"<!-- risk-triage:verdict {json.dumps(v)} -->"
        run = {"name": rt.GATE_CONTEXT, "app": {"id": 99}, "head_sha": SHA, "output": {"text": text},
               "external_id": rt.external_id(1, "b1", SHA)}
        self.assertIsNotNone(rt.app_verdict([run], SHA, "99", 1, "b1")[0])
        self.assertIsNone(rt.app_verdict([run], SHA, "99", 2, "b1")[0])
        self.assertIsNone(rt.app_verdict([{**run, "external_id": "other"}], SHA, "99", 1, "b1")[0])

    def _run(self, name, suite):
        return {"name": name, "app": {"id": rt.ACTIONS_APP_ID}, "status": "completed",
                "conclusion": "success", "head_sha": SHA, "check_suite": {"id": suite}}

    def test_required_check_needs_expected_workflow_and_event(self):
        runs = [self._run("build-and-test", 1), self._run("repo-hygiene", 2)]
        good = {1: {"path": ".github/workflows/swift-ci.yml", "event": "pull_request", "head_sha": SHA},
                2: {"path": ".github/workflows/repo-hygiene.yml", "event": "pull_request", "head_sha": SHA}}
        self.assertTrue(rt.checks_green(runs, workflow_runs=good, head_sha=SHA)[0])
        forged = {**good, 1: {"path": ".github/workflows/evil.yml", "event": "pull_request", "head_sha": SHA}}
        self.assertFalse(rt.checks_green(runs, workflow_runs=forged, head_sha=SHA)[0])
        wrong_event = {**good, 2: {**good[2], "event": "workflow_dispatch"}}
        self.assertFalse(rt.checks_green(runs, workflow_runs=wrong_event, head_sha=SHA)[0])
        self.assertFalse(rt.checks_green(runs, workflow_runs={}, head_sha=SHA)[0])

    def test_test_weakening_is_high(self):
        for f in ("Tests/quarantine.txt", "Tests/Fixtures/ObservabilitySanitizerCorpus.json",
                  "Tests/flaky-allowlist.txt", "Tests/skiplist.txt", "Transcripted.xctestplan"):
            self.assertEqual(risk(f)["risk"], "high", f)

    def test_normal_test_still_low(self):
        self.assertEqual(risk("Tests/FooTests.swift")["risk"], "low")

    def test_review_job_output_rejected_on_mismatch(self):
        entry = {"pr": 1, "sha": SHA, "base_sha": "b1", "status": "ok", "p0": 0, "p1": 0, "text": "t"}
        self.assertIsNotNone(rt.review_for(entry and [entry], 1, SHA, "b1"))
        self.assertIsNone(rt.review_for([entry], 1, SHA, "b2"))
        self.assertIsNone(rt.review_for([{**entry, "p0": "x"}], 1, SHA, "b1"))


class PaginationTests(unittest.TestCase):
    def test_workflow_runs_for_reads_every_page(self):
        import json
        pages = [{"total_count": 101, "workflow_runs": [{"check_suite_id": i} for i in range(100)]},
                 {"total_count": 101, "workflow_runs": [{"check_suite_id": 100, "path": "x"}]}]
        calls = []
        orig = rt.gh
        rt.gh = lambda *a, **k: (calls.append(a), json.dumps(pages))[1]
        try:
            runs = rt.workflow_runs_for(SHA)
        finally:
            rt.gh = orig
        self.assertIn("--paginate", calls[0])
        self.assertEqual(len(runs), 101)
        self.assertEqual(runs[100]["path"], "x")


class WorkflowShapeTests(unittest.TestCase):
    ROOT = Path(__file__).resolve().parents[2]

    def test_app_token_job_never_sees_diff_or_ai_key(self):
        wf = (self.ROOT / ".github/workflows/risk-triage.yml").read_text()
        review, gate = wf.split("\n  gate:\n", 1)
        self.assertNotIn("create-github-app-token", review)
        self.assertNotIn("AUTOMERGE_APP_PRIVATE_KEY", review)
        self.assertNotIn("AI_REVIEW_API_KEY", gate)
        self.assertIn("--reviews", gate)

    def test_gate_never_fetches_diff(self):
        import inspect
        src = inspect.getsource(rt.evaluate) + inspect.getsource(rt._gate_one) + inspect.getsource(rt.cmd_gate)
        self.assertNotIn("vnd.github.diff", src)
        self.assertNotIn("ai_review(", src)

    def test_release_candidate_uses_release_environment(self):
        wf = (self.ROOT / ".github/workflows/release-candidate.yml").read_text()
        self.assertIn("environment: release", wf)


if __name__ == "__main__":
    unittest.main(verbosity=1)

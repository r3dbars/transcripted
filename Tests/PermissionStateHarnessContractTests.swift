// Repo-structure / contract suite, not behavioral coverage.
// It asserts that the QA CLI registers the permission-state command, keeps its
// probe matrix intact, and that the QA bench gates live automation in order.
// It greps source/script text only and exercises no permission-probe runtime logic.

import Foundation

func testPermissionStateHarnessContract() {
    runSuite("Permission state harness contract - QA CLI exposes stable command") {
        let entrypoint = readSourceFixture("Tools/TranscriptedQA/Sources/TranscriptedQA/TranscriptedQA.swift")
        let command = readSourceFixture("Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/PermissionState.swift")

        assertTrue(
            entrypoint.contains("PermissionState.self"),
            "TranscriptedQA should register the permission-state command"
        )
        assertTrue(
            command.contains("commandName: \"permission-state\"")
                && command.contains("PermissionStateMode")
                && command.contains("CGPreflightScreenCaptureAccess")
                && command.contains("CGPreflightPostEventAccess")
                && command.contains("CGPreflightListenEventAccess")
                && command.contains("AXIsProcessTrusted")
                && command.contains("AVCaptureDevice.authorizationStatus")
                && command.contains("AEDeterminePermissionToAutomateTarget")
                && command.contains("PermissionRunningApplication"),
            "permission-state should keep the no-prompt Codex permission probe matrix intact"
        )
    }

    runSuite("Permission state harness contract - QA bench gates live automation") {
        let qaBench = readSourceFixture("scripts/ops/transcripted-qa-bench.sh")
        let permissionIndex = qaBench.range(of: "transcripted-qa permission-state --mode live-capture")?.lowerBound
        let liveSmokeIndex = qaBench.range(of: "bash run-live-capture-smoke.sh --skip-build")?.lowerBound

        assertTrue(
            permissionIndex != nil && liveSmokeIndex != nil && permissionIndex! < liveSmokeIndex!,
            "QA bench should run permission-state before live capture smoke"
        )
        assertTrue(
            qaBench.contains("if run_permission_state; then")
                && qaBench.contains("skipped after permission-state preflight"),
            "QA bench should not run live capture smoke when permission-state warns or fails"
        )
        assertTrue(
            qaBench.contains("INCOMPLETE: harness permission blocked")
                && qaBench.contains("prove a visible state change after each click"),
            "manual scenarios should stop false-green UI automation when macOS blocks events"
        )
        assertTrue(
            qaBench.contains("No duplicate or wrong running Transcripted app instance"),
            "manual scenarios should make duplicate running apps incomplete instead of ambiguous UI proof"
        )
    }

    runSuite("Permission state harness contract - docs keep TCC blockers incomplete") {
        let qaDocs = readSourceFixture("docs/qa-test-bench.md")
        let gateDocs = readSourceFixture(".agents/qa-gates.yml")

        assertTrue(
            qaDocs.contains("permission-state")
                && qaDocs.contains("INCOMPLETE")
                && qaDocs.contains("harness permission blocked"),
            "QA bench docs should name permission-state blockers as incomplete"
        )
        assertTrue(
            gateDocs.contains("permission_state")
                && gateDocs.contains("Permission blockers are INCOMPLETE, not green"),
            "agent QA gates should preserve the permission-state boundary"
        )
    }
}

import Foundation

func testPermissionStateHarnessContract() {
    runSuite("Permission state harness contract - QA CLI exposes stable command") {
        let entrypoint = readPermissionHarnessContractFile("Tools/TranscriptedQA/Sources/TranscriptedQA/TranscriptedQA.swift")
        let command = readPermissionHarnessContractFile("Tools/TranscriptedQA/Sources/TranscriptedQA/Commands/PermissionState.swift")

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
                && command.contains("AEDeterminePermissionToAutomateTarget"),
            "permission-state should keep the no-prompt Codex permission probe matrix intact"
        )
    }

    runSuite("Permission state harness contract - QA bench gates live automation") {
        let qaBench = readPermissionHarnessContractFile("scripts/ops/transcripted-qa-bench.sh")
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
    }

    runSuite("Permission state harness contract - docs keep TCC blockers incomplete") {
        let qaDocs = readPermissionHarnessContractFile("docs/qa-test-bench.md")
        let gateDocs = readPermissionHarnessContractFile(".agents/qa-gates.yml")

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

private func readPermissionHarnessContractFile(_ relativePath: String) -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

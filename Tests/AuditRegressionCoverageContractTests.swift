import Foundation

func testAuditRegressionCoverageContract() {
    runSuite("AuditRegressionCoverageContract — meeting overlay duration updates are whole-second throttled") {
        let source = readAuditContractSource("Sources/UI/Overlay/MeetingOverlayController.swift")
        assertTrue(
            source.contains("let previousDisplay = MeetingDurationFormatter.formatDuration(self.currentDuration)"),
            "meeting overlay should compare the rendered timer text before pushing a full layout update"
        )
        assertTrue(
            source.contains("guard MeetingDurationFormatter.formatDuration(duration) != previousDisplay else { return }"),
            "5 Hz recording-duration ticks must not trigger 5 Hz full overlay layout work"
        )
    }

    runSuite("AuditRegressionCoverageContract — menubar duration updates stay deduped to whole seconds") {
        let source = readAuditContractSource("Sources/UI/MenuBar/MenuBarPanelController.swift")
        assertTrue(
            source.contains(".map { Int($0) }"),
            "menubar recording-duration sink should collapse subsecond ticks"
        )
        assertTrue(
            source.contains(".removeDuplicates()"),
            "menubar timer refreshes should skip unchanged whole-second values"
        )
    }

    runSuite("AuditRegressionCoverageContract — pasteback focus changes downgrade to copied before Cmd+V") {
        let source = readAuditContractSource("Sources/Support/ClipboardRestoringTextPaster.swift")
        assertTrue(
            source.contains("!target.matchesCurrentFrontmostApp()"),
            "pasteback must re-check the captured target app before dispatching Cmd+V"
        )
        assertTrue(
            source.contains("reason: .focusChanged"),
            "focus drift should produce an honest copied result instead of a false pasted result"
        )
        assertTrue(
            source.contains("guard pasteDispatcher() else"),
            "the paste dispatch result must remain an explicit fallback seam"
        )
    }

    runSuite("AuditRegressionCoverageContract — failed meeting queue survives synchronous terminal failures") {
        let source = readAuditContractSource("Sources/Meeting/MeetingSessionController.swift")
        assertTrue(
            source.contains("finalizeBackgroundTranscriptionStateIfNeeded()"),
            "terminal display-status handlers should revisit background queue state"
        )
        assertTrue(
            source.contains("handleBackgroundTranscriptionWorkChanged(snapshot: currentBackgroundTranscriptionWorkSnapshot)"),
            "queue draining should have a no-argument path for terminal status changes that do not publish activeCount"
        )
    }
}

private func readAuditContractSource(_ relativePath: String) -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(relativePath)
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        failedTests += 1
        totalTests += 1
        print("  FAIL [AuditRegressionCoverageContractTests.swift] could not read \(relativePath): \(error)")
        return ""
    }
}

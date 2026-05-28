import Foundation

func testLiveMeetingCodexSession() {
    runSuite("LiveMeetingCodexSession.ensureWorkspaceFiles - creates the sidecar workspace") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedLiveMeetingCodex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = LiveMeetingCodexSession(workspaceRoot: root)
        try? session.ensureWorkspaceFiles(createdAt: Date(timeIntervalSince1970: 1_765_994_400))

        assertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("README.md").path),
            "workspace should include README"
        )
        assertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("AGENTS.md").path),
            "workspace should include AGENTS"
        )
        assertTrue(
            FileManager.default.fileExists(atPath: session.setupURL.path),
            "workspace should include Codex setup prompt"
        )
        assertTrue(
            FileManager.default.fileExists(atPath: session.previewURL.path),
            "workspace should include HTML preview"
        )

        let state = decodeLiveMeetingCodexState(at: session.stateURL)
        assertEqual(state?.status, .idle, "new workspace should start idle")
        assertTrue(
            state?.liveTranscriptPath.hasSuffix(LiveMeetingCodexSession.liveTranscriptFilename) == true,
            "state should point at live transcript file"
        )
    }

    runSuite("LiveMeetingCodexSession lifecycle - streams provisional text and links final Markdown") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedLiveMeetingCodex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = LiveMeetingCodexSession(workspaceRoot: root)
        try? session.start(
            title: "Product Review",
            startedAt: Date(timeIntervalSince1970: 1_765_994_400)
        )
        try? session.append(
            LiveMeetingCodexTranscriptEntry(
                source: .microphone,
                text: "We should keep the final transcript untouched.",
                timestampSeconds: 65,
                createdAt: Date(timeIntervalSince1970: 1_765_994_465)
            )
        )
        try? session.append(
            LiveMeetingCodexTranscriptEntry(
                source: .system,
                text: "Agree, the live mode should be a sidecar.",
                timestampSeconds: 70,
                createdAt: Date(timeIntervalSince1970: 1_765_994_470)
            )
        )
        try? session.finish(
            status: .stopped,
            at: Date(timeIntervalSince1970: 1_765_994_500)
        )

        let liveText = (try? String(contentsOf: session.liveTranscriptURL, encoding: .utf8)) ?? ""
        assertTrue(liveText.contains("Title: Product Review"), "live transcript should include the title")
        assertTrue(liveText.contains("**01:05** [Microphone]"), "mic lines should keep source label and timestamp")
        assertTrue(liveText.contains("**01:10** [System]"), "system lines should keep source label and timestamp")
        assertTrue(liveText.contains("Recording stopped"), "stop should leave a handoff note")

        var state = decodeLiveMeetingCodexState(at: session.stateURL)
        assertEqual(state?.status, .stopped, "state should record stopped status before final Markdown exists")
        assertNil(state?.finalTranscriptPath, "state should not invent a final transcript path")

        let finalURL = root.appendingPathComponent("Product Review.md", isDirectory: false)
        try? session.attachFinalTranscript(
            url: finalURL,
            title: "Product Review",
            at: Date(timeIntervalSince1970: 1_765_994_560)
        )

        state = decodeLiveMeetingCodexState(at: session.stateURL)
        assertEqual(state?.status, .transcriptSaved, "state should mark final transcript ready")
        assertEqual(state?.finalTranscriptPath, finalURL.path, "state should point Codex at the final Markdown")

        let updatedLiveText = (try? String(contentsOf: session.liveTranscriptURL, encoding: .utf8)) ?? ""
        assertTrue(
            updatedLiveText.contains("Prefer the final file for participant names"),
            "live transcript should tell Codex to prefer the final Markdown after save"
        )
    }
}

private func decodeLiveMeetingCodexState(at url: URL) -> LiveMeetingCodexState? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(LiveMeetingCodexState.self, from: data)
}

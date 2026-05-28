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
        assertTrue(
            FileManager.default.fileExists(atPath: session.handoffURL.path),
            "workspace should include automatic Codex handoff marker"
        )

        let state = decodeLiveMeetingCodexState(at: session.stateURL)
        assertEqual(state?.status, .idle, "new workspace should start idle")
        assertTrue(
            state?.liveTranscriptPath.hasSuffix(LiveMeetingCodexSession.liveTranscriptFilename) == true,
            "state should point at live transcript file"
        )

        let previewText = (try? String(contentsOf: session.previewURL, encoding: .utf8)) ?? ""
        assertTrue(previewText.contains("Status: idle"), "preview should embed the idle transcript")
        assertFalse(previewText.contains("http-equiv=\"refresh\""), "preview should not full-page refresh")
        assertTrue(previewText.contains("setInterval(refreshPreview, 1000)"), "preview should poll without strobing")
        assertTrue(previewText.contains("/live_transcript.md"), "preview should hot-load the live transcript route")
        assertTrue(previewText.contains("renderTranscript(lastTranscript)"), "preview should render a formatted transcript stream")
        assertTrue(previewText.contains("data-filter=\"microphone\""), "preview should include a microphone filter")
        assertTrue(previewText.contains("data-filter=\"system\""), "preview should include a system audio filter")
        assertTrue(previewText.contains("Final transcript ready for Codex."), "preview should include automatic handoff copy")
        assertFalse(previewText.contains("navigator.clipboard.writeText"), "preview should not require manual prompt copying")
        let handoffText = (try? String(contentsOf: session.handoffURL, encoding: .utf8)) ?? ""
        assertTrue(handoffText.contains("Status: idle"), "new handoff marker should start idle")
        assertEqual(
            LiveMeetingCodexSession.previewServerURL.absoluteString,
            "http://127.0.0.1:47834/live-preview",
            "Codex browser preview should use the stable local URL"
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
                createdAt: Date(timeIntervalSince1970: 1_765_994_465),
                isFinal: false
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
        assertTrue(liveText.contains("**01:05** [Microphone] [partial]"), "partial mic lines should keep source label and timestamp")
        assertTrue(liveText.contains("**01:10** [System]"), "system lines should keep source label and timestamp")
        assertTrue(liveText.contains("Recording stopped"), "stop should leave a handoff note")

        var previewText = (try? String(contentsOf: session.previewURL, encoding: .utf8)) ?? ""
        assertTrue(
            previewText.contains("We should keep the final transcript untouched."),
            "preview should embed current live transcript text"
        )
        assertTrue(previewText.contains("class=\"stream\""), "preview should use the formatted stream container")
        assertTrue(previewText.contains("stopped - local_streaming_asr_stopped"), "preview should show current session state")

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

        let handoffText = (try? String(contentsOf: session.handoffURL, encoding: .utf8)) ?? ""
        assertTrue(handoffText.contains("Status: ready"), "handoff marker should become ready after final save")
        assertTrue(handoffText.contains(finalURL.path), "handoff marker should point at the final Markdown")
        assertTrue(
            handoffText.contains("Read the final transcript path above"),
            "handoff marker should tell Codex to read the final transcript automatically"
        )

        let updatedLiveText = (try? String(contentsOf: session.liveTranscriptURL, encoding: .utf8)) ?? ""
        assertTrue(
            updatedLiveText.contains("Prefer the final file for participant names"),
            "live transcript should tell Codex to prefer the final Markdown after save"
        )

        previewText = (try? String(contentsOf: session.previewURL, encoding: .utf8)) ?? ""
        assertTrue(previewText.contains("transcript_saved"), "preview should update after the final transcript is attached")
        assertTrue(previewText.contains("Product Review.md"), "preview should include the final transcript handoff")
        assertTrue(
            previewText.contains("Final transcript ready for Codex."),
            "preview should show automatic final-transcript handoff after recording saves"
        )
    }
}

private func decodeLiveMeetingCodexState(at url: URL) -> LiveMeetingCodexState? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(LiveMeetingCodexState.self, from: data)
}

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
            FileManager.default.fileExists(atPath: session.previewAuthTokenURL.path),
            "workspace should include a private preview auth token"
        )
        assertTrue(
            FileManager.default.fileExists(atPath: session.handoffURL.path),
            "workspace should include automatic Codex handoff marker"
        )
        assertTrue(
            FileManager.default.fileExists(atPath: session.watcherStateURL.path),
            "workspace should include agent watcher state"
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
        assertTrue(previewText.contains("withPreviewAuthToken(\"/state.json\")"), "preview should token-gate server polling")
        assertTrue(previewText.contains("renderTranscript(lastTranscript)"), "preview should render a formatted transcript stream")
        assertTrue(previewText.contains("Notes for yourself"), "preview should keep a simple secondary scratchpad")
        assertTrue(previewText.contains(">Hide transcript</span>"), "preview should show the live transcript by default")
        assertFalse(previewText.contains("Ask about this meeting"), "preview should not show an ask affordance")
        assertFalse(previewText.contains("Notes stay here while you record"), "preview should avoid explanatory copy")
        assertTrue(previewText.contains("localStorage"), "scratchpad prototype should persist notes in the browser")
        assertFalse(previewText.contains("data-filter=\"microphone\""), "preview should no longer lead with source filters")
        assertFalse(previewText.contains("data-filter=\"system\""), "preview should no longer lead with source filters")
        assertTrue(previewText.contains("Final transcript ready."), "preview should include automatic handoff copy")
        assertFalse(previewText.contains("navigator.clipboard.writeText"), "preview should not require manual prompt copying")
        let handoffText = (try? String(contentsOf: session.handoffURL, encoding: .utf8)) ?? ""
        assertTrue(handoffText.contains("Status: idle"), "new handoff marker should start idle")
        let watcherStateText = (try? String(contentsOf: session.watcherStateURL, encoding: .utf8)) ?? ""
        assertTrue(
            watcherStateText.contains("\"lastHandledFinalTranscriptPath\": null"),
            "watcher state should start without a handled final transcript"
        )
        let previewToken = ((try? String(contentsOf: session.previewAuthTokenURL, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        assertTrue(previewToken.count >= 32, "preview auth token should be unguessable enough for localhost routing")
        assertTrue(
            session.previewServerBrowserURL().absoluteString.hasPrefix("http://127.0.0.1:47834/live-preview?token="),
            "Codex browser preview should use the stable local URL with a per-workspace token"
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
        assertTrue(liveText.contains("Status: stopped"), "live transcript status should match stopped state")
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
        assertTrue(
            handoffText.contains("agent-watcher-state.json"),
            "handoff marker should tell agents how to avoid repeated old transcript wakeups"
        )

        let updatedLiveText = (try? String(contentsOf: session.liveTranscriptURL, encoding: .utf8)) ?? ""
        assertTrue(
            updatedLiveText.contains("Status: transcript_saved"),
            "live transcript status should match final saved state"
        )
        assertTrue(
            updatedLiveText.contains("Prefer the final file for participant names"),
            "live transcript should tell Codex to prefer the final Markdown after save"
        )

        previewText = (try? String(contentsOf: session.previewURL, encoding: .utf8)) ?? ""
        assertTrue(previewText.contains("transcript_saved"), "preview should update after the final transcript is attached")
        assertTrue(previewText.contains("Product Review.md"), "preview should include the final transcript handoff")
        assertTrue(
            previewText.contains("Final transcript ready."),
            "preview should show automatic final-transcript handoff after recording saves"
        )
    }

    runSuite("LiveMeetingCodexSession.ensureWorkspaceFiles - rebuilds automatic handoff from saved state") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedLiveMeetingCodex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = LiveMeetingCodexSession(workspaceRoot: root)
        let finalURL = root.appendingPathComponent("Recovered Meeting.md", isDirectory: false)
        try? session.start(
            title: "Recovered Meeting",
            startedAt: Date(timeIntervalSince1970: 1_765_994_400)
        )
        try? session.attachFinalTranscript(
            url: finalURL,
            title: "Recovered Meeting",
            at: Date(timeIntervalSince1970: 1_765_994_560)
        )
        try? "stale idle marker".write(to: session.handoffURL, atomically: true, encoding: .utf8)
        try? """
        {
          "version": 1,
          "lastHandledFinalTranscriptPath": "\(finalURL.path)",
          "lastHandledAt": "2025-12-18T10:04:20Z",
          "note": "already handled"
        }
        """.write(to: session.watcherStateURL, atomically: true, encoding: .utf8)
        try? """
        # Live Transcripted Meeting

        Status: recording
        Title: Recovered Meeting

        ## Live Transcript
        **00:01** [Microphone] stale but useful text
        """.write(to: session.liveTranscriptURL, atomically: true, encoding: .utf8)

        let reopenedSession = LiveMeetingCodexSession(workspaceRoot: root)
        try? reopenedSession.ensureWorkspaceFiles(createdAt: Date(timeIntervalSince1970: 1_765_994_620))

        let handoffText = (try? String(contentsOf: reopenedSession.handoffURL, encoding: .utf8)) ?? ""
        assertTrue(handoffText.contains("Status: ready"), "reopened workspace should rebuild stale handoff as ready")
        assertTrue(handoffText.contains(finalURL.path), "rebuilt handoff should keep the final transcript path")

        let liveText = (try? String(contentsOf: reopenedSession.liveTranscriptURL, encoding: .utf8)) ?? ""
        assertTrue(liveText.contains("Status: transcript_saved"), "reopened workspace should repair stale live status")
        assertTrue(liveText.contains("stale but useful text"), "reopened workspace should keep existing live transcript text")

        let watcherStateText = (try? String(contentsOf: reopenedSession.watcherStateURL, encoding: .utf8)) ?? ""
        assertTrue(watcherStateText.contains("already handled"), "reopened workspace should preserve agent watcher state")
    }
}

private func decodeLiveMeetingCodexState(at url: URL) -> LiveMeetingCodexState? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(LiveMeetingCodexState.self, from: data)
}

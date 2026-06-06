import Darwin
import Foundation

func testLocalMeetingSummarizer() async {
    runSuite("LocalMeetingTranscriptExtractor strips frontmatter and keeps only transcript text") {
        let markdown = """
        ---
        capture_type: meeting
        title: "Weekly Sync"
        ---

        # Weekly Sync

        Recorded Jun 5

        ## Channel & Speaker Analytics

        Ignore this analytics section.

        ## Transcript

        **00:01**  [System/Maya]
        We should ship the smaller version first.

        **00:09**  [Mic/Justin]
        I will write the follow-up.

        ## Notes

        Ignore this later section.
        """

        let transcript = LocalMeetingTranscriptExtractor.transcriptText(from: markdown)
        assertTrue(transcript.contains("We should ship the smaller version first."), "transcript text should be preserved")
        assertFalse(transcript.contains("capture_type"), "frontmatter should not be sent to the model")
        assertFalse(transcript.contains("Ignore this analytics section."), "non-transcript sections should be excluded")
        assertFalse(transcript.contains("Ignore this later section."), "later markdown sections should be excluded")
    }

    runSuite("LocalMeetingSummaryChunker keeps speaker turns together") {
        let transcript = """
        [Maya] 15:00:01
        First topic has enough text to fill the first chunk with a decision and some supporting context.

        [Justin] 15:01:10
        Second topic has enough text to spill into another chunk without splitting the speaker turn.

        [Sara] 15:02:20
        Third topic closes the loop.
        """

        let chunks = LocalMeetingSummaryChunker.chunks(from: transcript, targetCharacterLimit: 115)
        assertTrue(chunks.count >= 2, "long transcripts should be chunked for M1 memory safety")
        assertTrue(chunks.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, "chunks should not be empty")
        assertTrue(chunks[0].contains("[Maya] 15:00:01"), "first turn should stay intact")
        assertTrue(chunks.dropFirst().joined(separator: "\n").contains("[Justin] 15:01:10"), "later turns should stay intact")
    }

    runSuite("LocalGemmaSummaryConfiguration uses a conservative M1 profile") {
        let gib = UInt64(1024 * 1024 * 1024)
        let m1Config = LocalGemmaSummaryConfiguration.m1Optimized(physicalMemoryBytes: 16 * gib)
        assertEqual(m1Config.profileName, "m1-low-memory", "16GB Apple Silicon should use the low-memory profile")
        assertTrue(m1Config.chunkCharacterLimit <= 9_000, "M1 profile should keep chunks small enough for 16GB unified-memory Macs")
        assertTrue(m1Config.maxKVSize <= 6_144, "M1 profile should keep KV cache below the hotter baseline")
        assertTrue(m1Config.mergeMaxTokens >= 2_400, "M1 profile should leave enough merge budget for long-meeting final merges")
        assertTrue(m1Config.processNiceValue >= 10, "M1 profile should lower local Gemma process priority")
        assertTrue(m1Config.cpuThreadLimit <= 2, "M1 profile should cap CPU helper threads conservatively")
        assertTrue(m1Config.interJobCooldownSeconds >= 2, "M1 profile should cool down between local Gemma jobs")
        do {
            try m1Config.validateHardware(physicalMemoryBytes: 16 * gib)
            assertTrue(true, "16GB should be allowed")
        } catch {
            assertTrue(false, "16GB should be allowed, got \(error)")
        }

        do {
            try m1Config.validateHardware(physicalMemoryBytes: 8 * gib)
            assertTrue(false, "8GB should be refused for Gemma 4 12B")
        } catch {
            guard case LocalMeetingSummaryError.insufficientMemory = error else {
                assertTrue(false, "Expected insufficient-memory error, got \(error)")
                return
            }
            assertTrue(true, "8GB should be refused for Gemma 4 12B")
        }
    }

    runSuite("LocalMeetingSummarySetupStatus reports runtime and low-memory readiness") {
        let gib = UInt64(1024 * 1024 * 1024)
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMeetingSummarySetupStatusTests-\(UUID().uuidString)")
        let uvURL = temporaryDirectory.appendingPathComponent("uv")
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        FileManager.default.createFile(atPath: uvURL.path, contents: Data("#!/bin/sh\n".utf8))
        chmod(uvURL.path, 0o755)

        let status = LocalMeetingSummarySetupStatus.current(
            physicalMemoryBytes: 16 * gib,
            environment: ["TRANSCRIPTED_UV_PATH": uvURL.path],
            fileManager: .default
        )

        assertEqual(status.modelID, "mlx-community/gemma-4-12B-it-4bit", "setup status should expose the exact MLX model")
        assertEqual(status.runtimePackage, "mlx-vlm==0.6.1", "setup status should expose the pinned MLX runtime package")
        assertEqual(status.profileName, "m1-low-memory", "16GB machines should report the low-memory profile")
        assertEqual(status.physicalMemoryGB, 16, "status should show rounded physical memory")
        assertEqual(status.minimumMemoryGB, 12, "Gemma summary setup should communicate the minimum memory")
        assertTrue(status.hasRuntime, "executable uv path should make the setup runtime-ready")
        assertTrue(status.hasEnoughMemory, "16GB should satisfy the memory check")
        assertTrue(status.isReady, "16GB with uv should be ready")

        let lowMemoryStatus = LocalMeetingSummarySetupStatus.current(
            physicalMemoryBytes: 8 * gib,
            environment: ["TRANSCRIPTED_UV_PATH": uvURL.path],
            fileManager: .default
        )

        assertFalse(lowMemoryStatus.hasEnoughMemory, "8GB should be below the local Gemma memory floor")
        assertFalse(lowMemoryStatus.isReady, "low-memory Macs should not be setup-ready even with uv")
    }

    runSuite("LocalGemmaSummaryRuntime passes only a safe subprocess environment") {
        let runtime = LocalGemmaSummaryRuntime(
            configuration: localMeetingSummaryTestConfiguration(),
            environment: [
                "PATH": "/usr/bin",
                "HOME": "/Users/example",
                "TMPDIR": "/tmp/example",
                "HF_HOME": "/tmp/hf-cache",
                "SENTRY_DSN": "https://secret@example.invalid/1",
                "POSTHOG_API_KEY": "phc_secret",
                "OPENAI_API_KEY": "sk-secret",
                "HF_TOKEN": "hf_secret",
                "TRANSCRIPTED_UV_PATH": "/opt/homebrew/bin/uv"
            ]
        )

        let env = runtime.sanitizedProcessEnvironment(threadLimit: "2")

        assertEqual(env["PATH"], "/usr/bin", "safe executable lookup should be preserved")
        assertEqual(env["HOME"], "/Users/example", "safe home path should be preserved for cache resolution")
        assertEqual(env["HF_HOME"], "/tmp/hf-cache", "explicit local Hugging Face cache should be preserved")
        assertEqual(env["OMP_NUM_THREADS"], "2", "thread cap should be forwarded")
        assertEqual(env["TOKENIZERS_PARALLELISM"], "false", "tokenizer helper threads should stay disabled")
        assertNil(env["SENTRY_DSN"], "Sentry DSNs should not reach local model subprocesses")
        assertNil(env["POSTHOG_API_KEY"], "PostHog keys should not reach local model subprocesses")
        assertNil(env["OPENAI_API_KEY"], "generic API keys should not reach local model subprocesses")
        assertNil(env["HF_TOKEN"], "Hugging Face tokens should not reach local model subprocesses")
        assertNil(env["TRANSCRIPTED_UV_PATH"], "runtime discovery override should not be forwarded to the child process")
    }

    runSuite("LocalMeetingSummaryStore keeps the legacy sibling summary path for fallback reads") {
        let transcriptURL = URL(fileURLWithPath: "/tmp/Product Sync.md")
        assertEqual(
            LocalMeetingSummaryStore.summaryURL(for: transcriptURL).path,
            "/tmp/Product Sync.summary.md",
            "legacy summary artifacts should still be discoverable for older local summaries"
        )
    }

    runSuite("LocalMeetingSummaryNormalizer restores missing sections") {
        let normalized = LocalMeetingSummaryNormalizer.normalized("# Summary\nUseful brief.")
        for heading in [
            "# Title",
            "# Summary",
            "# Decisions",
            "# Action Items",
            "# Open Questions",
            "# Risks or Follow-ups",
            "# Accuracy Notes"
        ] {
            assertTrue(normalized.contains(heading), "normalized summaries should include \(heading)")
        }
    }

    runSuite("LocalMeetingSummaryNormalizer extracts generated titles") {
        let normalized = LocalMeetingSummaryNormalizer.normalized("""
        # Title
        Launch Pricing Review

        # Summary
        Team agreed to keep the first version small.
        """)

        assertEqual(
            LocalMeetingSummaryNormalizer.summaryTitle(in: normalized),
            "Launch Pricing Review",
            "summaries should expose a short generated title for Home"
        )
    }

    runSuite("LocalMeetingSummaryNormalizer accepts first heading titles from Gemma") {
        let normalized = LocalMeetingSummaryNormalizer.normalized("""
        # Launch Pricing Review

        # Summary
        Team agreed to keep the first version small.

        # Decisions
        Ship the smaller launch first.
        """)

        assertEqual(
            LocalMeetingSummaryNormalizer.summaryTitle(in: normalized),
            "Launch Pricing Review",
            "Gemma sometimes returns the generated title as the first H1 instead of under # Title"
        )
    }

    runSuite("LocalMeetingSummaryNormalizer ignores structural chunk headings as titles") {
        let normalized = LocalMeetingSummaryNormalizer.normalized("""
        # Chunk 1

        # Summary
        The team discussed launch scope.

        # Decisions
        None found.
        """)

        assertEqual(
            LocalMeetingSummaryNormalizer.summaryTitle(in: normalized),
            nil,
            "Chunk labels should not become generated meeting titles"
        )
    }

    runSuite("LocalMeetingSummaryMarkdownUpdater embeds summary metadata into the transcript") {
        let markdown = """
        ---
        capture_type: meeting
        title: "Quick notes"
        date: "2026-06-05"
        speakers:
          - "Justin"
        ---

        # Quick notes

        ## Transcript

        **00:01** [Mic/Justin]
        We should launch the smaller version first.
        """
        let updated = LocalMeetingSummaryMarkdownUpdater.markdown(
            byApplying: sampleLocalMeetingSummarySections(),
            to: markdown,
            configuration: .m1Optimized(physicalMemoryBytes: 16 * 1024 * 1024 * 1024),
            generatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            chunkCount: 2
        )

        assertTrue(updated.contains("capture_type: meeting"), "existing frontmatter should be preserved")
        assertTrue(updated.contains("  - \"Justin\""), "nested frontmatter lines should be preserved")
        assertTrue(updated.contains("local_summary_version: \"1\""), "summary metadata should live in frontmatter")
        assertTrue(updated.contains("local_summary_title: \"Launch Pricing Review\""), "generated title should live in frontmatter")
        assertTrue(updated.contains("local_summary_action_items:"), "action items should live in frontmatter")
        assertTrue(updated.contains(LocalMeetingSummaryMarkdownUpdater.startMarker), "transcript should get a managed summary block")
        assertTrue(updated.contains("## Local Gemma Summary"), "managed block should be readable markdown")
        assertTrue(updated.contains("## Transcript"), "original transcript body should remain in the same file")
    }

    await runSuite("LocalMeetingSummarizer aborts when transcript text changes during generation") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMeetingSummaryStaleTranscriptTests-\(UUID().uuidString)", isDirectory: true)
        let transcriptURL = directory.appendingPathComponent("Meeting.md")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try localMeetingSummaryMarkdown(title: "Launch Review", transcript: localMeetingSummaryLongTranscript())
                .write(to: transcriptURL, atomically: true, encoding: .utf8)

            let changedMarkdown = localMeetingSummaryMarkdown(
                title: "Launch Review",
                transcript: localMeetingSummaryChangedTranscript()
            )
            let runtime = LocalGemmaSummaryRuntime(
                configuration: localMeetingSummaryTestConfiguration(),
                generateBatchOverride: { _, _ in
                    try changedMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
                    return [localMeetingSummaryModelOutput()]
                }
            )
            let summarizer = LocalMeetingSummarizer(
                configuration: localMeetingSummaryTestConfiguration(),
                runtime: runtime
            )

            do {
                _ = try await summarizer.summarize(
                    transcriptURL: transcriptURL,
                    title: "Launch Review",
                    date: Date(timeIntervalSince1970: 1_780_000_000)
                )
                assertTrue(false, "summarizer should reject stale writes when transcript text changed")
            } catch {
                guard case LocalMeetingSummaryError.transcriptChanged = error else {
                    assertTrue(false, "expected transcriptChanged, got \(error)")
                    return
                }
                let currentMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
                assertFalse(
                    currentMarkdown.contains(LocalMeetingSummaryMarkdownUpdater.startMarker),
                    "stale generation should not write a managed summary block"
                )
            }
        } catch {
            assertTrue(false, "stale-transcript fixture should run: \(error)")
        }
    }

    await runSuite("LocalMeetingSummarizer applies summaries to the latest unchanged transcript file") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMeetingSummaryLatestMarkdownTests-\(UUID().uuidString)", isDirectory: true)
        let transcriptURL = directory.appendingPathComponent("Meeting.md")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let transcript = localMeetingSummaryLongTranscript()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try localMeetingSummaryMarkdown(title: "Original Title", transcript: transcript)
                .write(to: transcriptURL, atomically: true, encoding: .utf8)

            let editedMarkdown = localMeetingSummaryMarkdown(title: "Edited Title", transcript: transcript)
            let runtime = LocalGemmaSummaryRuntime(
                configuration: localMeetingSummaryTestConfiguration(),
                generateBatchOverride: { _, _ in
                    try editedMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
                    return [localMeetingSummaryModelOutput()]
                }
            )
            let summarizer = LocalMeetingSummarizer(
                configuration: localMeetingSummaryTestConfiguration(),
                runtime: runtime
            )

            _ = try await summarizer.summarize(
                transcriptURL: transcriptURL,
                title: "Launch Review",
                date: Date(timeIntervalSince1970: 1_780_000_000)
            )

            let currentMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
            assertTrue(currentMarkdown.contains("title: \"Edited Title\""), "unchanged transcript text should preserve latest metadata edits")
            assertTrue(
                currentMarkdown.contains(LocalMeetingSummaryMarkdownUpdater.startMarker),
                "summary should be written after confirming transcript text stayed stable"
            )
        } catch {
            assertTrue(false, "latest-markdown fixture should run: \(error)")
        }
    }

    runSuite("LocalMeetingSummaryMarkdownUpdater replaces prior local summary metadata") {
        let firstPass = LocalMeetingSummaryMarkdownUpdater.markdown(
            byApplying: sampleLocalMeetingSummarySections(),
            to: """
            ---
            capture_type: meeting
            local_summary_title: "Old Title"
            local_summary: "Old summary"
            ---

            ## Transcript

            Original body.

            \(LocalMeetingSummaryMarkdownUpdater.startMarker)
            ## Local Gemma Summary

            ### Summary
            Old summary.
            \(LocalMeetingSummaryMarkdownUpdater.endMarker)
            """,
            configuration: .m1Optimized(physicalMemoryBytes: 16 * 1024 * 1024 * 1024),
            generatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            chunkCount: 1
        )

        assertEqual(
            firstPass.components(separatedBy: LocalMeetingSummaryMarkdownUpdater.startMarker).count - 1,
            1,
            "regeneration should keep exactly one managed summary block"
        )
        assertFalse(firstPass.contains("Old summary"), "old managed summary text should be replaced")
        assertTrue(firstPass.contains("local_summary_title: \"Launch Pricing Review\""), "managed frontmatter should be refreshed")
    }
}

private func localMeetingSummaryTestConfiguration() -> LocalGemmaSummaryConfiguration {
    LocalGemmaSummaryConfiguration(
        modelID: LocalMeetingSummarySetupStatus.defaultModelID,
        runtimePackage: LocalMeetingSummarySetupStatus.defaultRuntimePackage,
        profileName: "test",
        minimumPhysicalMemoryBytes: 0,
        chunkCharacterLimit: 100_000,
        chunkMaxTokens: 64,
        directMaxTokens: 64,
        mergeMaxTokens: 64,
        maxKVSize: 1_024,
        processTimeoutSeconds: 5,
        processNiceValue: 0,
        cpuThreadLimit: 1,
        interJobCooldownSeconds: 0
    )
}

private func localMeetingSummaryMarkdown(title: String, transcript: String) -> String {
    """
    ---
    capture_type: meeting
    title: "\(title)"
    ---

    # \(title)

    ## Transcript

    \(transcript)
    """
}

private func localMeetingSummaryLongTranscript() -> String {
    """
    **00:01** [Mic/Justin]
    We reviewed the beta launch plan and agreed that the first version should stay small, private, and focused on saved meeting summaries for people who explicitly turn on the local model setting.

    **00:22** [System/Maya]
    Maya will check the release notes, confirm the install instructions, and report back before Friday with any wording that might confuse people during setup.

    **00:44** [Mic/Justin]
    The open question is whether the summary action should appear for every meeting or only when the model runtime is already installed and ready.
    """
}

private func localMeetingSummaryChangedTranscript() -> String {
    """
    **00:01** [Mic/Justin]
    We changed the transcript while the summary was still running, so the local model output should not overwrite this newer user-edited version of the meeting notes.

    **00:20** [System/Maya]
    Maya added a different follow-up, changed the scope, and marked the release note copy as blocked until a separate review finishes later this week.
    """
}

private func localMeetingSummaryModelOutput() -> String {
    """
    # Title
    Launch Summary Review

    # Summary
    Team agreed to keep the beta launch small and private.

    # Decisions
    Ship the smaller launch first.

    # Action Items
    Maya will check release notes before Friday.

    # Open Questions
    Whether to show the action only when the runtime is installed.

    # Risks or Follow-ups
    Setup wording could confuse beta users.

    # Accuracy Notes
    Based only on the transcript.
    """
}

private func sampleLocalMeetingSummarySections() -> LocalMeetingSummarySections {
    LocalMeetingSummarySections(
        title: "Launch Pricing Review",
        summary: "Team agreed to keep launch pricing simple.",
        decisions: "Ship the smaller launch version first.",
        actionItems: "Alex will check pricing language before Friday.",
        openQuestions: "Whether enterprise pricing needs a separate page.",
        risksOrFollowUps: "Pricing copy could overpromise the first version.",
        accuracyNotes: "Based only on the transcript."
    )
}

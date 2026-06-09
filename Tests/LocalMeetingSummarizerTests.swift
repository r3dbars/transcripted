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

    runSuite("LocalMeetingSummarySetupStatus reports missing runtime without starting setup") {
        let gib = UInt64(1024 * 1024 * 1024)
        let status = LocalMeetingSummarySetupStatus.current(
            physicalMemoryBytes: 16 * gib,
            environment: [
                "HOME": "/tmp/local-meeting-summary-missing-runtime",
                "TRANSCRIPTED_UV_PATH": "/tmp/local-meeting-summary-missing-runtime/uv"
            ],
            fileManager: LocalMeetingSummaryNonExecutableFileManager()
        )

        assertEqual(status.modelID, "mlx-community/gemma-4-12B-it-4bit", "setup status should keep the expected Gemma model ID")
        assertEqual(status.runtimePackage, "mlx-vlm==0.6.1", "setup status should keep the pinned runtime package")
        assertTrue(status.hasEnoughMemory, "16GB should satisfy the local Gemma memory floor")
        assertFalse(status.hasRuntime, "missing uv should keep setup runtime-unready")
        assertFalse(status.isReady, "setup should not be ready until the local runtime exists")
        assertNil(status.uvPath, "missing runtime should not report a uv path")
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

    runSuite("LocalGemmaSummaryRuntime fails closed when the bundled runner is missing") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMeetingSummaryMissingRunnerTests-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("Empty.bundle", isDirectory: true)
        let workDirectory = root.appendingPathComponent("work", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            guard let emptyBundle = Bundle(url: bundleURL) else {
                assertTrue(false, "empty bundle fixture should be constructible")
                return
            }

            let runtime = LocalGemmaSummaryRuntime(
                configuration: localMeetingSummaryTestConfiguration(),
                environment: ["TRANSCRIPTED_UV_PATH": "/bin/sh"],
                bundle: emptyBundle
            )

            do {
                _ = try runtime.generate(
                    prompt: "safe prompt",
                    label: "direct",
                    maxTokens: 16,
                    workDirectory: workDirectory
                )
                assertTrue(false, "runtime should fail before attempting setup when the bundled runner is missing")
            } catch {
                guard case LocalMeetingSummaryError.missingBundledRunner = error else {
                    assertTrue(false, "expected missingBundledRunner, got \(error)")
                    return
                }
                assertTrue(true, "missing runner should be reported deterministically")
            }
        } catch {
            assertTrue(false, "missing-runner fixture should run: \(error)")
        }
    }

    runSuite("LocalMeetingSummaryStore keeps the legacy sibling summary path for fallback reads") {
        let transcriptURL = URL(fileURLWithPath: "/tmp/Product Sync.md")
        assertEqual(
            LocalMeetingSummaryStore.summaryURL(for: transcriptURL).path,
            "/tmp/Product Sync.summary.md",
            "legacy summary artifacts should still be discoverable for older local summaries"
        )
    }

    runSuite("LocalMeetingSummaryStore removes only generated summaries for the matching transcript") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMeetingSummaryRemovalTests-\(UUID().uuidString)", isDirectory: true)
        let transcriptURL = root.appendingPathComponent("Call.md")
        let summaryURL = LocalMeetingSummaryStore.summaryURL(for: transcriptURL)
        let unrelatedURL = root.appendingPathComponent("Other.summary.md")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try "transcript".write(to: transcriptURL, atomically: true, encoding: .utf8)
            try """
            ---
            capture_type: meeting_summary
            source_transcript: "Call.md"
            ---

            # Summary
            Old summary.
            """.write(to: summaryURL, atomically: true, encoding: .utf8)
            try """
            ---
            capture_type: meeting_summary
            source_transcript: "Different.md"
            ---

            # Summary
            Other summary.
            """.write(to: unrelatedURL, atomically: true, encoding: .utf8)

            assertTrue(
                try LocalMeetingSummaryStore.removeGeneratedSummary(for: transcriptURL),
                "matching generated summary should be removed"
            )
            assertFalse(FileManager.default.fileExists(atPath: summaryURL.path), "matching summary sidecar should be gone")
            assertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path), "unrelated summary sidecar should stay")
            assertFalse(
                try LocalMeetingSummaryStore.removeGeneratedSummary(for: transcriptURL),
                "removing an already-cleared summary should be a no-op"
            )
        } catch {
            assertionFailure("summary removal fixture should not throw: \(error)")
        }
        try? FileManager.default.removeItem(at: root)
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
        assertTrue(updated.contains("local_summary_provider: \"gemmaMLX\""), "provider metadata should live in frontmatter")
        assertTrue(updated.contains("local_summary_title: \"Launch Pricing Review\""), "generated title should live in frontmatter")
        assertTrue(updated.contains("local_summary_action_items:"), "action items should live in frontmatter")
        assertTrue(updated.contains(LocalMeetingSummaryMarkdownUpdater.startMarker), "transcript should get a managed summary block")
        assertTrue(updated.contains("## Local Gemma Summary"), "managed block should be readable markdown")
        assertTrue(updated.contains("## Transcript"), "original transcript body should remain in the same file")
    }

    runSuite("LocalMeetingSummaryMarkdownUpdater records Apple provider metadata") {
        let markdown = """
        ---
        capture_type: meeting
        title: "Apple notes"
        ---

        # Apple notes

        ## Transcript

        **00:01** [Mic/Justin]
        Use Apple's on-device model when available.
        """
        let updated = LocalMeetingSummaryMarkdownUpdater.markdown(
            byApplying: sampleLocalMeetingSummarySections(),
            to: markdown,
            metadata: LocalMeetingSummaryRunMetadata(
                provider: .appleFoundation,
                modelID: "com.apple.foundationmodels.system.default",
                runtimePackage: "FoundationModels.framework",
                profileName: "apple-foundation-context-4096",
                heading: "Local Apple Summary"
            ),
            generatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            chunkCount: 3
        )

        assertTrue(updated.contains("local_summary_provider: \"appleFoundation\""), "Apple provider should be recorded")
        assertTrue(updated.contains("local_summary_model: \"com.apple.foundationmodels.system.default\""), "Apple model should be recorded")
        assertTrue(updated.contains("local_summary_runtime: \"FoundationModels.framework\""), "Apple runtime should be recorded")
        assertTrue(updated.contains("local_summary_profile: \"apple-foundation-context-4096\""), "Apple profile should be recorded")
        assertTrue(updated.contains("local_summary_chunk_count: \"3\""), "Apple chunk count should be recorded")
        assertTrue(updated.contains("## Local Apple Summary"), "Apple summary heading should be readable")
    }

    await runSuite("LocalMeetingSummarizer writes inline output shape without sidecars or prompt leaks") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMeetingSummarySuccessTests-\(UUID().uuidString)", isDirectory: true)
        let transcriptURL = directory.appendingPathComponent("Private Meeting.md")
        let promptCaptureURL = directory.appendingPathComponent("captured-prompt.txt")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let markdown = """
            ---
            capture_type: meeting
            title: "Private Demo"
            source_path: "/Users/redbars/Private/Private Meeting.md"
            contact_email: "justin@example.com"
            api_key: "sk-test-secret"
            ---

            # Private Demo

            ## Channel & Speaker Analytics

            Ignore this non-transcript plan with justin@example.com and /Users/redbars/Private.

            ## Transcript

            \(localMeetingSummaryPrivacyTranscript())

            ## Notes

            Ignore these later notes with sk-test-secret.
            """
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)

            let runtime = LocalGemmaSummaryRuntime(
                configuration: localMeetingSummaryTestConfiguration(),
                generateBatchOverride: { prompts, _ in
                    let promptText = prompts.map { $0.prompt }.joined(separator: "\n---\n")
                    try promptText.write(to: promptCaptureURL, atomically: true, encoding: .utf8)
                    return prompts.map { _ in localMeetingSummaryModelOutput() }
                }
            )
            let summarizer = LocalMeetingSummarizer(
                configuration: localMeetingSummaryTestConfiguration(),
                runtime: runtime
            )

            let result = try await summarizer.summarize(
                transcriptURL: transcriptURL,
                title: "Private Demo",
                date: Date(timeIntervalSince1970: 1_780_000_000)
            )

            let currentMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
            let capturedPrompt = try String(contentsOf: promptCaptureURL, encoding: .utf8)
            let permissions = try FileManager.default.attributesOfItem(atPath: transcriptURL.path)[.posixPermissions] as? NSNumber

            assertEqual(result.transcriptURL, transcriptURL, "result should point at the updated transcript")
            assertEqual(result.chunkCount, 1, "short transcripts should use the direct summary path")
            assertEqual(result.profileName, "test", "result should expose the active summary profile")
            assertEqual(result.provider, .gemmaMLX, "result should expose the active summary provider")
            assertTrue(currentMarkdown.contains("local_summary_version: \"1\""), "summary metadata should be embedded inline")
            assertTrue(currentMarkdown.contains("local_summary_provider: \"gemmaMLX\""), "output should record the provider")
            assertTrue(currentMarkdown.contains("local_summary_model: \"mlx-community/gemma-4-12B-it-4bit\""), "output should record the local model")
            assertTrue(currentMarkdown.contains("local_summary_runtime: \"mlx-vlm==0.6.1\""), "output should record the local runtime")
            assertTrue(currentMarkdown.contains("local_summary_profile: \"test\""), "output should record the runtime profile")
            assertTrue(currentMarkdown.contains("local_summary_chunk_count: \"1\""), "output should record the chunk count")
            assertTrue(currentMarkdown.contains("local_summary_title: \"Launch Summary Review\""), "output should record the generated title")
            assertTrue(currentMarkdown.contains("local_summary: \"Team agreed to keep the beta launch small and private.\""), "output should record the generated summary body")
            assertTrue(currentMarkdown.contains("local_summary_decisions: \"Ship the smaller launch first.\""), "output should record generated decisions")
            assertTrue(currentMarkdown.contains("## Local Gemma Summary"), "summary should be written into the saved transcript")
            assertTrue(
                currentMarkdown.contains("### Summary\nTeam agreed to keep the beta launch small and private."),
                "managed summary block should include the generated summary text"
            )
            assertTrue(
                currentMarkdown.contains("### Decisions\nShip the smaller launch first."),
                "managed summary block should include generated decisions"
            )
            assertTrue(currentMarkdown.contains("### Action Items"), "managed summary block should keep the expected section shape")
            assertTrue(currentMarkdown.contains("## Transcript"), "original transcript should remain readable")
            assertFalse(
                FileManager.default.fileExists(atPath: LocalMeetingSummaryStore.summaryURL(for: transcriptURL).path),
                "successful summaries should not create a separate generated sidecar"
            )
            if let permissions {
                assertEqual(permissions.intValue & 0o777, 0o600, "updated transcript should be owner-readable only")
            } else {
                assertTrue(false, "updated transcript permissions should be readable")
            }
            assertTrue(capturedPrompt.contains("We agreed that the summary beta stays opt-in"), "prompt should include transcript text")
            assertFalse(capturedPrompt.contains("source_path"), "frontmatter keys should not be sent to the model prompt")
            assertFalse(capturedPrompt.contains("/Users/redbars/Private"), "absolute local paths should not be sent to the model prompt")
            assertFalse(capturedPrompt.contains("justin@example.com"), "frontmatter and non-transcript emails should not be sent to the model prompt")
            assertFalse(capturedPrompt.contains("sk-test-secret"), "non-transcript secrets should not be sent to the model prompt")
            assertFalse(capturedPrompt.contains("Ignore this non-transcript plan"), "pre-transcript sections should not be sent to the model prompt")
            assertFalse(capturedPrompt.contains("Ignore these later notes"), "post-transcript sections should not be sent to the model prompt")
        } catch {
            assertTrue(false, "successful summarizer fixture should run: \(error)")
        }
    }

    await runSuite("LocalMeetingSummarizer prepares Gemma without transcript text") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMeetingSummaryPrepareTests-\(UUID().uuidString)", isDirectory: true)
        let promptCaptureURL = directory.appendingPathComponent("prepare-prompt.txt")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let runtime = LocalGemmaSummaryRuntime(
                configuration: localMeetingSummaryTestConfiguration(),
                generateBatchOverride: { prompts, _ in
                    try prompts.map(\.prompt).joined(separator: "\n---\n").write(
                        to: promptCaptureURL,
                        atomically: true,
                        encoding: .utf8
                    )
                    return prompts.map { _ in "Ready." }
                }
            )
            let summarizer = LocalMeetingSummarizer(
                configuration: localMeetingSummaryTestConfiguration(),
                runtime: runtime
            )

            let profile = try await summarizer.prepareModelForFirstSummary()
            let capturedPrompt = try String(contentsOf: promptCaptureURL, encoding: .utf8)

            assertEqual(profile, "test", "prepare should return the active profile")
            assertTrue(capturedPrompt.contains("Reply with exactly"), "prepare should use a tiny setup prompt")
            assertFalse(capturedPrompt.contains("## Transcript"), "prepare should not include meeting markdown")
            assertFalse(capturedPrompt.contains("Action Items"), "prepare should not include summary prompt sections")
        } catch {
            assertTrue(false, "unexpected prepare failure: \(error)")
        }
    }

    runSuite("LocalGemmaSummaryRuntime stops a hung runner at the configured timeout") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMeetingSummaryTimeoutTests-\(UUID().uuidString)", isDirectory: true)
        let workDirectory = root.appendingPathComponent("work", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            let runtime = try localMeetingSummaryProcessRuntime(
                root: root,
                runnerSource: """
                import time
                time.sleep(5)
                """,
                timeout: 0.25
            )

            let startedAt = Date()
            do {
                _ = try runtime.generate(
                    prompt: "safe prompt",
                    label: "direct",
                    maxTokens: 16,
                    workDirectory: workDirectory
                )
                assertTrue(false, "hung runner should time out")
            } catch {
                guard case LocalMeetingSummaryError.processTimedOut(let label) = error else {
                    assertTrue(false, "expected processTimedOut, got \(error)")
                    return
                }
                assertEqual(label, "direct", "timeout should preserve the prompt label")
                assertTrue(Date().timeIntervalSince(startedAt) < 3, "timeout fixture should not hang the fast suite")
            }
        } catch {
            assertTrue(false, "timeout fixture should run: \(error)")
        }
    }

    await runSuite("LocalMeetingSummarizer leaves transcript untouched when runtime fails") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMeetingSummaryRuntimeFailureTests-\(UUID().uuidString)", isDirectory: true)
        let transcriptURL = directory.appendingPathComponent("Meeting.md")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let originalMarkdown = localMeetingSummaryMarkdown(title: "Launch Review", transcript: localMeetingSummaryLongTranscript())
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try originalMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)

            let runtime = LocalGemmaSummaryRuntime(
                configuration: localMeetingSummaryTestConfiguration(),
                generateBatchOverride: { _, _ in
                    throw LocalMeetingSummaryError.processFailed(
                        label: "direct",
                        exitCode: 2,
                        detail: "model cache missing"
                    )
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
                assertTrue(false, "summarizer should surface runtime failures")
            } catch {
                guard case LocalMeetingSummaryError.processFailed(let label, let exitCode, _) = error else {
                    assertTrue(false, "expected processFailed, got \(error)")
                    return
                }
                assertEqual(label, "direct", "direct summary failure should keep its label")
                assertEqual(exitCode, 2, "runtime exit code should be preserved")
                let currentMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
                assertEqual(currentMarkdown, originalMarkdown, "failed runtime should not rewrite the transcript")
                assertFalse(
                    currentMarkdown.contains(LocalMeetingSummaryMarkdownUpdater.startMarker),
                    "failed runtime should not write a managed summary block"
                )
            }
        } catch {
            assertTrue(false, "runtime-failure fixture should run: \(error)")
        }
    }

    await runSuite("LocalMeetingSummarizer leaves transcript untouched when the model is missing") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMeetingSummaryMissingModelTests-\(UUID().uuidString)", isDirectory: true)
        let transcriptURL = root.appendingPathComponent("Meeting.md")
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let originalMarkdown = localMeetingSummaryMarkdown(title: "Launch Review", transcript: localMeetingSummaryLongTranscript())
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try originalMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)

            let runtime = try localMeetingSummaryProcessRuntime(
                root: root,
                runnerSource: """
                import sys
                sys.stderr.write("model load failed: missing model cache for mlx-community/gemma-4-12B-it-4bit\\n")
                sys.stderr.write("prompt_file=/tmp/private-direct-prompt.txt\\n")
                sys.stderr.write("/tmp/private-jobs.json\\n")
                sys.exit(7)
                """
            )
            let summarizer = LocalMeetingSummarizer(
                configuration: runtime.configuration,
                runtime: runtime
            )

            do {
                _ = try await summarizer.summarize(
                    transcriptURL: transcriptURL,
                    title: "Launch Review",
                    date: Date(timeIntervalSince1970: 1_780_000_000)
                )
                assertTrue(false, "missing model should surface as a runtime failure")
            } catch {
                guard case LocalMeetingSummaryError.processFailed(let label, let exitCode, let detail) = error else {
                    assertTrue(false, "expected processFailed, got \(error)")
                    return
                }
                assertEqual(label, "direct", "missing-model failure should keep its prompt label")
                assertEqual(exitCode, 7, "missing-model exit code should be preserved")
                assertTrue(detail.contains("missing model cache"), "missing-model detail should be visible to the degraded state")
                assertFalse(detail.contains("prompt_file"), "runtime detail should not leak prompt file keys")
                assertFalse(detail.contains("jobs.json"), "runtime detail should not leak jobs file paths")
                assertFalse(detail.contains("-prompt.txt"), "runtime detail should not leak prompt file paths")
                let currentMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
                assertEqual(currentMarkdown, originalMarkdown, "missing model should not rewrite the transcript")
                assertFalse(
                    currentMarkdown.contains(LocalMeetingSummaryMarkdownUpdater.startMarker),
                    "missing model should not write a managed summary block"
                )
            }
        } catch {
            assertTrue(false, "missing-model fixture should run: \(error)")
        }
    }

    await runSuite("LocalMeetingSummarizer leaves transcript untouched when output is missing") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMeetingSummaryMissingOutputTests-\(UUID().uuidString)", isDirectory: true)
        let transcriptURL = directory.appendingPathComponent("Meeting.md")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try localMeetingSummaryMarkdown(title: "Launch Review", transcript: localMeetingSummaryLongTranscript())
                .write(to: transcriptURL, atomically: true, encoding: .utf8)

            let runtime = LocalGemmaSummaryRuntime(
                configuration: localMeetingSummaryTestConfiguration(),
                generateBatchOverride: { _, _ in [] }
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
                assertTrue(false, "summarizer should fail when the runner returns no output")
            } catch {
                guard case LocalMeetingSummaryError.outputMissing(let label) = error else {
                    assertTrue(false, "expected outputMissing, got \(error)")
                    return
                }
                assertEqual(label, "direct", "missing direct output should keep its label")
                let currentMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
                assertFalse(
                    currentMarkdown.contains(LocalMeetingSummaryMarkdownUpdater.startMarker),
                    "missing output should not write a managed summary block"
                )
            }
        } catch {
            assertTrue(false, "missing-output fixture should run: \(error)")
        }
    }

    await runSuite("LocalMeetingSummarizer leaves transcript untouched when cancelled") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalMeetingSummaryCancelTests-\(UUID().uuidString)", isDirectory: true)
        let transcriptURL = directory.appendingPathComponent("Meeting.md")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try localMeetingSummaryMarkdown(title: "Launch Review", transcript: localMeetingSummaryLongTranscript())
                .write(to: transcriptURL, atomically: true, encoding: .utf8)

            let runtime = LocalGemmaSummaryRuntime(
                configuration: localMeetingSummaryTestConfiguration(),
                generateBatchOverride: { _, _ in
                    throw CancellationError()
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
                assertTrue(false, "summarizer should surface cancellation")
            } catch {
                assertTrue(error is CancellationError, "expected CancellationError, got \(error)")
                let currentMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
                assertFalse(
                    currentMarkdown.contains(LocalMeetingSummaryMarkdownUpdater.startMarker),
                    "cancelled summaries should not write a managed summary block"
                )
            }
        } catch {
            assertTrue(false, "cancel fixture should run: \(error)")
        }
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

private func localMeetingSummaryProcessRuntime(
    root: URL,
    runnerSource: String,
    timeout: TimeInterval = 2
) throws -> LocalGemmaSummaryRuntime {
    let runnerURL = root.appendingPathComponent("gemma4_mlx_prompt_runner.py")
    let uvURL = root.appendingPathComponent("uv")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try runnerSource.write(to: runnerURL, atomically: true, encoding: .utf8)
    try """
    #!/bin/sh
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "python" ]; then
        shift
        exec /usr/bin/python3 "$@"
      fi
      shift
    done
    echo "missing python runner" >&2
    exit 127
    """.write(to: uvURL, atomically: true, encoding: .utf8)
    chmod(uvURL.path, 0o755)

    let configuration = LocalGemmaSummaryConfiguration(
        modelID: LocalMeetingSummarySetupStatus.defaultModelID,
        runtimePackage: LocalMeetingSummarySetupStatus.defaultRuntimePackage,
        profileName: "process-fixture",
        minimumPhysicalMemoryBytes: 0,
        chunkCharacterLimit: 100_000,
        chunkMaxTokens: 64,
        directMaxTokens: 64,
        mergeMaxTokens: 64,
        maxKVSize: 1_024,
        processTimeoutSeconds: timeout,
        processNiceValue: 0,
        cpuThreadLimit: 1,
        interJobCooldownSeconds: 0
    )

    return LocalGemmaSummaryRuntime(
        configuration: configuration,
        environment: [
            "TRANSCRIPTED_UV_PATH": uvURL.path,
            "PATH": "/usr/bin:/bin",
            "HOME": root.path
        ],
        runnerURLOverride: runnerURL
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

private func localMeetingSummaryPrivacyTranscript() -> String {
    """
    **00:01** [Mic/Justin]
    We agreed that the summary beta stays opt-in, runs only after the user chooses the action, and should keep the saved transcript as the only durable output.

    **00:21** [System/Maya]
    Maya will review the setup copy, confirm that the first run may download the local Gemma model, and check whether the Home menu still feels clear.

    **00:45** [Mic/Justin]
    The risk is that people mistake the feature for a release-ready claim before runtime proof exists on a normal low-memory Apple Silicon machine.
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

private final class LocalMeetingSummaryNonExecutableFileManager: FileManager {
    override func isExecutableFile(atPath path: String) -> Bool {
        false
    }
}

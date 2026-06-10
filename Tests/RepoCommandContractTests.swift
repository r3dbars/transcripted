import Foundation

func testRepoCommandContract() {
    runSuite("Repo command contract - root build and test wrappers stay script-based") {
        let wrappers = [
            "build-deps.sh": "scripts/entrypoints/build-deps.sh",
            "build-beta.sh": "scripts/entrypoints/build-beta.sh",
            "build.sh": "scripts/entrypoints/build.sh",
            "run-e2e-smoke.sh": "scripts/entrypoints/run-e2e-smoke.sh",
            "run-live-capture-smoke.sh": "scripts/entrypoints/run-live-capture-smoke.sh",
            "run-slow-pasteback-smoke.sh": "scripts/entrypoints/run-slow-pasteback-smoke.sh",
            "run-tests.sh": "scripts/entrypoints/run-tests.sh",
            "run-integration-smoke.sh": "scripts/entrypoints/run-integration-smoke.sh"
        ]

        for (wrapper, entrypoint) in wrappers.sorted(by: { $0.key < $1.key }) {
            let contents = readRepoTextFile(wrapper)
            assertTrue(contents.contains("exec \"$SCRIPT_DIR/\(entrypoint)\" \"$@\""), "\(wrapper) should delegate to \(entrypoint)")
            assertFalse(contents.contains("Transcripted.xcodeproj"), "\(wrapper) should not use the removed Xcode project path")
            assertFalse(contents.contains("xcodebuild"), "\(wrapper) should not bypass the documented shell entrypoint")
        }
    }

    runSuite("Repo command contract - live automation docs do not point at removed Xcode project") {
        let disallowedMatches = repoTextFiles(relativeTo: repoRootURL())
            .filter { shouldScanForLiveCommandContract($0) }
            .flatMap { file -> [String] in
                let contents = readRepoTextFile(file)
                return contents
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .enumerated()
                    .compactMap { index, line in
                        line.contains("Transcripted.xcodeproj") || line.contains("xcodebuild -project")
                            ? "\(file):\(index + 1)"
                            : nil
                    }
            }

        assertEqual(disallowedMatches, [], "live docs/scripts should reference bash build.sh, not the historical Xcode project")
    }

    runSuite("Repo command contract - health probe checks live Cloudflare Pages projects") {
        let contents = readRepoTextFile("scripts/ops/health-probe.sh")

        assertTrue(contents.contains("\"transcripted-web\""), "Cloudflare probe should check the live Transcripted Pages project")
        assertTrue(contents.contains("\"redbars\""), "Cloudflare probe should check the live r3d.bar Pages project")
        assertFalse(contents.contains("\"transcripted-app\""), "Cloudflare probe should not check the old Transcripted Pages project name")
        assertFalse(contents.contains("\"r3d-bar\""), "Cloudflare probe should not check the old redbars Pages project name")
    }

    runSuite("Repo command contract - Sentry health probe prints aggregate issue rollup") {
        let contents = readRepoTextFile("scripts/ops/health-probe.sh")

        assertTrue(
            contents.contains("Sentry unresolved issue rollup (top 5):")
                && contents.contains(".shortId")
                && contents.contains("count=\\(.count")
                && contents.contains("users=\\(.userCount")
                && contents.contains("lastSeen=\\(.lastSeen"),
            "Sentry probe should show aggregate issue counts and freshness for operator triage"
        )
        assertTrue(
            contents.contains("sentry_test_event")
                && contents.contains("support_diagnostic_event")
                && contents.contains("contains(\"sentry_test_event\")")
                && contents.contains("contains(\"support_diagnostic_event\")"),
            "Sentry probe should filter manual verification and support diagnostic events out of health rollups"
        )
        assertFalse(
            contents.contains("/events/"),
            "Sentry health probe should not fetch raw event payloads for the nightly rollup"
        )
    }

    runSuite("Repo command contract - PostHog health probe uses the query API") {
        let contents = readRepoTextFile("scripts/ops/health-probe.sh")

        assertTrue(
            contents.contains("posthog_api_host()"),
            "PostHog probe should normalize app/ingest hosts before querying"
        )
        assertTrue(
            contents.contains("https://us.i.posthog.com)") && contents.contains("https://us.posthog.com"),
            "PostHog probe should translate the US ingest host to the API host"
        )
        assertTrue(
            contents.contains("kind: \"HogQLQuery\"") && contents.contains("refresh: \"blocking\""),
            "PostHog probe should use the current HogQL query API payload"
        )
        assertTrue(
            contents.contains("(.data // .results)"),
            "PostHog probe should parse both old and current query response shapes"
        )
        assertFalse(
            contents.contains("https://us.i.posthog.com/api/projects"),
            "PostHog probe should not send API queries to the ingest host"
        )
        assertTrue(
            contents.contains("validate_posthog_api_host") && contents.contains("POSTHOG_ALLOW_UNTRUSTED_HOST"),
            "PostHog probe should validate hosts before sending the personal API key"
        )
    }

    runSuite("Repo command contract - PostHog health probe keeps aggregate daily active-device trend") {
        let contents = readRepoTextFile("scripts/ops/health-probe.sh")
        let digest = readRepoTextFile("scripts/ops/generate-nightly-digest.py")
        let workflowEvents = sourceSlice(
            contents,
            from: "workflow_events=",
            to: "  onboarding_events="
        )

        assertTrue(
            contents.contains("daily_query=")
                && contents.contains("toDate(timestamp) as day")
                && contents.contains("uniq(distinct_id) as active_devices")
                && contents.contains("group by day order by day asc"),
            "PostHog probe should keep the daily aggregate active-device trend query"
        )
        assertTrue(
            contents.contains("daily_payload=")
                && contents.contains("daily_response=")
                && contents.contains("daily_devices=")
                && contents.contains("PostHog daily active devices:"),
            "PostHog probe should print the daily aggregate trend alongside 7-day totals"
        )
        assertFalse(
            contents.contains("PostHog daily active device ids"),
            "PostHog probe should not print user or device identifiers"
        )
        assertTrue(
            workflowEvents.contains("meeting_file_imported") && digest.contains("\"meeting_file_imported\""),
            "aggregate active-device workflow sets should count imported audio activity"
        )
    }

    runSuite("Repo command contract - PostHog health probe counts emitted first-value events") {
        let probe = readRepoTextFile("scripts/ops/health-probe.sh")
        let docs = readRepoTextFile("docs/ops-credentials.md")
        let digest = readRepoTextFile("scripts/ops/generate-nightly-digest.py")
        let firstValueEvents = sourceSlice(
            probe,
            from: "first_value_events=",
            to: "  query="
        )

        for event in [
            "dictation_completed",
            "onboarding_first_dictation_saved",
            "meeting_transcript_saved",
            "onboarding_agent_cta_clicked",
            "activation_artifact_action_clicked",
            "activation_agent_prompt_action_clicked",
            "activation_agent_setup_cta_clicked",
            "activation_return_proxy_observed"
        ] {
            assertTrue(
                firstValueEvents.contains(event) && docs.contains(event),
                "PostHog first-value probe and docs should include \(event)"
            )
        }
        for event in [
            "activation_artifact_action_clicked",
            "activation_agent_prompt_action_clicked",
            "activation_agent_setup_cta_clicked",
            "activation_return_proxy_observed"
        ] {
            assertTrue(
                digest.contains(event),
                "nightly digest DAU event set should include \(event)"
            )
        }
        assertTrue(
            probe.contains("first_value_events=") && probe.contains("first_value_events_7d"),
            "PostHog probe should keep the aggregate first-value event count"
        )
        assertFalse(
            firstValueEvents.contains("meeting_file_imported"),
            "imported audio should count as activity but not as first value"
        )
    }

    runSuite("Repo command contract - build bundles only the runtime Parakeet model") {
        let contents = readRepoTextFile("scripts/entrypoints/build.sh")
        assertTrue(
            contents.contains("PARAKEET_MODEL_DIR=\"parakeet-tdt-0.6b-v3-coreml\""),
            "build.sh should bundle the CoreML Parakeet directory loaded by ParakeetEngine"
        )
        assertFalse(
            contents.contains("\"parakeet-tdt-0.6b-v3\""),
            "build.sh should not bundle the legacy Parakeet directory as a second 461 MB copy"
        )
    }

    runSuite("Repo command contract - build-deps readiness matches the app build") {
        let buildDepsScript = readRepoTextFile("scripts/entrypoints/build-deps.sh")
        assertTrue(
            buildDepsScript.contains("TRANSCRIPTED_CORE_MODULE=\"$DEPS_MODULES/TranscriptedCore.swiftmodule/arm64-apple-macos.swiftmodule\""),
            "build-deps.sh should not skip when the app-required TranscriptedCore module is missing"
        )
        assertTrue(
            buildDepsScript.contains("newest_dependency_input") && buildDepsScript.contains("deps_are_ready"),
            "build-deps.sh should rebuild stale TranscriptedCore artifacts instead of printing a false ready message"
        )
    }

    runSuite("Repo command contract - fast test runner generation is per-process") {
        let contents = readRepoTextFile("scripts/entrypoints/run-tests.sh")
        assertTrue(
            contents.contains("GENERATED_RUNNER=\"$BUILD_DIR/FastTestRunner.$$.swift\""),
            "parallel run-tests.sh invocations should not overwrite the same generated Swift source"
        )
        assertTrue(
            contents.contains("trap cleanup_generated_runner EXIT"),
            "temporary generated test runners should be removed on exit"
        )
        assertTrue(
            contents.contains("Unknown option: $arg") && contents.contains("exit 2"),
            "run-tests.sh should reject unknown flags instead of silently ignoring typos"
        )
    }

    runSuite("Repo command contract - agent verification stays non-interactive") {
        let matrix = readRepoTextFile(".agents/test-matrix.yml")
        let preflight = readRepoTextFile("scripts/dev/agent-preflight.sh")
        let agents = readRepoTextFile("AGENTS.md")
        let agentStart = readRepoTextFile("AGENT_START.md")
        let workflow = readRepoTextFile("WORKFLOW.md")

        assertTrue(
            matrix.contains("bash build.sh --no-open")
                && !matrix.contains("\"bash build.sh\""),
            "agent test matrix should use the non-opening build command"
        )
        assertTrue(
            preflight.contains("add_command \"bash build.sh --no-open\"")
                && !preflight.contains("add_command \"bash build.sh\""),
            "agent preflight should suggest the non-opening build command"
        )
        assertTrue(
            agents.contains("bash build.sh --no-open")
                && agentStart.contains("bash build.sh --no-open")
                && workflow.contains(".agents/test-matrix.yml"),
            "agent-facing docs should keep verification non-interactive and defer unattended work to the matrix"
        )
    }

    runSuite("Repo command contract - QA bench full gate stays wired for review habit") {
        let qaBench = readRepoTextFile("scripts/ops/transcripted-qa-bench.sh")
        let qaGates = readRepoTextFile(".agents/qa-gates.yml")
        let agents = readRepoTextFile("AGENTS.md")
        let agentStart = readRepoTextFile("AGENT_START.md")
        let onboarding = readRepoTextFile("docs/agent-onboarding.md")
        let testsReadme = readRepoTextFile("Tests/README.md")
        let qaBenchDoc = readRepoTextFile("docs/qa-test-bench.md")
        let scriptsReadme = readRepoTextFile("scripts/README.md")
        let matrix = readRepoTextFile(".agents/test-matrix.yml")

        assertTrue(
            qaBench.contains("quick|deep|full|ui|packaged|artifact|audio-synthetic|pasteback-synthetic|corpus|corpus-compare|live")
                && qaBench.contains("run_full_tail")
                && qaBench.contains("60-release-health")
                && qaBench.contains("61-gemma-summary-plan")
                && qaBench.contains("Local Gemma summary dry-run plan not applicable (no eligible local transcripts)")
                && qaBench.contains("Operator Verdict")
                && qaBench.contains("Release:")
                && qaBench.contains("HOLD - automated full gate is green, but manual proof is still required"),
            "QA bench should expose a full gate with release-health, optional Gemma planning, and non-false-green operator verdict rows"
        )
        assertTrue(
            qaGates.contains("full: \"bash scripts/ops/transcripted-qa-bench.sh --mode full\"")
                && qaGates.contains("docs_only_tiny:")
                && qaGates.contains("meaningful_code:")
                && qaGates.contains("release_impacting:")
                && qaGates.contains("codex-review against the real PR base"),
            "qa-gates should define full QA plus PR review levels"
        )
        assertTrue(
            agents.contains("PR QA levels:")
                && agents.contains("Tiny docs-only")
                && agents.contains("Meaningful code")
                && agents.contains("release-impacting")
                && agentStart.contains("Before merging, classify the PR level")
                && onboarding.contains("before merging a meaningful code PR, run `codex-review`")
                && matrix.contains("PR-level overlays still apply"),
            "agent docs should make codex-review and full QA a PR-level overlay instead of a blanket every-PR gate"
        )
        assertTrue(
            qaBenchDoc.contains("## Full Run")
                && qaBenchDoc.contains("Working")
                && qaBenchDoc.contains("Regressed")
                && qaBenchDoc.contains("Needs human")
                && qaBenchDoc.contains("Release GO/HOLD")
                && testsReadme.contains("--mode full")
                && testsReadme.contains("--mode ui")
                && testsReadme.contains("not every-PR requirements"),
            "QA bench docs should explain full mode and keep tiny PRs out of mandatory release QA"
        )
        assertTrue(
            scriptsReadme.contains("Full usage: `bash scripts/ops/transcripted-qa-bench.sh --mode full`")
                && scriptsReadme.contains("release-health fixture checks"),
            "scripts README should list the full QA bench mode"
        )
    }

    runSuite("Repo command contract - script edits map to syntax and owned checks") {
        let matrix = readRepoTextFile(".agents/test-matrix.yml")
        let preflight = readRepoTextFile("scripts/dev/agent-preflight.sh")
        let expectedChecks = [
            "bash -n scripts/entrypoints/build-deps.sh",
            "bash build-deps.sh --force",
            "bash -n scripts/entrypoints/build.sh",
            "bash -n scripts/entrypoints/run-tests.sh",
            "bash -n scripts/entrypoints/run-integration-smoke.sh",
            "bash -n scripts/ops/daily-audio-reliability-check.sh",
            "bash -n scripts/ops/health-probe.sh",
            "bash -n scripts/dev/onboarding.sh",
            "bash -n scripts/dev/benchmark-home-recent-captures.sh",
            "python3 -m py_compile scripts/ops/generate-nightly-digest.py",
            "python3 scripts/ops/generate-nightly-digest.py --self-test",
            "python3 -m py_compile scripts/ops/nightly-security-check.py",
            "python3 -m py_compile scripts/ops/release-gate-report.py",
            "python3 scripts/ops/release-gate-report.py --self-test",
            "python3 -m py_compile scripts/ops/build-codex-memory-index.py",
            "bash -n scripts/ops/nightly-transcripted-archive-miner.sh",
            "ruby -c scripts/ops/performance-budget.rb",
            "ruby -c scripts/ops/dictation-recovery-autoeval.rb"
        ]

        for check in expectedChecks {
            assertTrue(matrix.contains(check), "test matrix should include \(check)")
            assertTrue(preflight.contains(check), "agent preflight should include \(check)")
        }
    }

    runSuite("Repo command contract - release gate report composes QA, telemetry, release, and logs") {
        let report = readRepoTextFile("scripts/ops/release-gate-report.py")
        let docs = readRepoTextFile("docs/qa-test-bench.md")
        let scriptsReadme = readRepoTextFile("scripts/README.md")
        let qaGates = readRepoTextFile(".agents/qa-gates.yml")

        assertTrue(
            report.contains("scripts/ops/transcripted-qa-bench.sh")
                && report.contains("scripts/ops/health-probe.sh")
                && report.contains("scripts/ops/nightly-security-check.py")
                && report.contains("sweep_local_logs"),
            "release gate report should compose QA bench, telemetry probes, release surfaces, and local log sweep"
        )
        assertTrue(
            report.contains("SKIP sentry: missing SENTRY_AUTH_TOKEN")
                && report.contains("Sentry credentials missing")
                && report.contains("missing Sentry/PostHog credentials"),
            "release gate report should keep missing telemetry tokens yellow/unknown rather than green"
        )
        assertTrue(
            report.contains("BLOCKING_RELEASE_WATCH_IDS")
                && report.contains("appcast-release-candidate")
                && report.contains("release_watch_status")
                && report.contains("sync_command_record_status")
                && report.contains("Live release surfaces skipped"),
            "release gate report should keep blocking release watch items red, skipped live checks yellow, and command rows aligned with parsed release proof"
        )
        assertTrue(
            report.contains("Automated Proof")
                && report.contains("Regressions")
                && report.contains("Telemetry")
                && report.contains("Release Surfaces")
                && report.contains("Local Log Warnings")
                && report.contains("Manual QA Checklist"),
            "release gate report should render the expected owner-facing sections"
        )
        assertTrue(
            report.contains(#"--release-candidate"#)
                && report.contains(#"choices=["quick", "deep", "full", "live"]"#)
                && report.contains(#"EXIT_CODES[payload["status"]]"#)
                && report.contains("Exit code follows the overall report status"),
            "release gate report should support the full one-command QA mode and exit from the overall green/yellow/red verdict"
        )
        assertTrue(
            docs.contains("python3 scripts/ops/release-gate-report.py")
                && scriptsReadme.contains("release-gate-report.py")
                && qaGates.contains("release_gate_report"),
            "release gate report should be discoverable in QA docs, scripts README, and QA gates"
        )
    }

    runSuite("Repo command contract - integration smoke rejects stale Core deps") {
        let contents = readRepoTextFile("scripts/entrypoints/run-integration-smoke.sh")
        assertTrue(
            contents.contains("newest_dependency_input")
                && contents.contains("deps_build_stamp_info")
                && contents.contains("Dependencies are stale for TranscriptedCore."),
            "integration smoke should refuse stale TranscriptedCore dependency artifacts"
        )
    }

    runSuite("Repo command contract - Core verification starts with rebuilt deps") {
        let matrix = readRepoTextFile(".agents/test-matrix.yml")
        let preflight = readRepoTextFile("scripts/dev/agent-preflight.sh")

        let coreMatrixBlock = sourceSlice(
            matrix,
            from: "- \"Package.swift\"",
            to: "- \"Sources/Observability/**\""
        )
        assertTrue(
            coreMatrixBlock.contains("bash build-deps.sh --force")
                && coreMatrixBlock.contains("bash build.sh --no-open")
                && coreMatrixBlock.contains("bash run-integration-smoke.sh")
                && coreMatrixBlock.contains("swift test"),
            "Core/package test guidance should rebuild dependency frameworks before app, smoke, or package checks"
        )

        let corePreflightBlock = sourceSlice(
            preflight,
            from: "if matches_any \"$path\" \"Package.swift\"",
            to: "if matches_any \"$path\" \"Tools/TranscriptedCLI/*\""
        )
        assertTrue(
            corePreflightBlock.contains("add_command \"bash build-deps.sh --force\"")
                && corePreflightBlock.contains("add_command \"bash build.sh --no-open\"")
                && corePreflightBlock.contains("add_command \"bash run-integration-smoke.sh\"")
                && corePreflightBlock.contains("add_command \"swift test\""),
            "agent preflight should list the dependency rebuild before Core verification commands"
        )
    }

    runSuite("Repo command contract - Audio preflight uses injected Core paths") {
        let contents = readRepoTextFile("Sources/TranscriptedCore/Audio/Audio.swift")
        assertTrue(
            contents.contains("RecordingValidator.validateRecordingConditions(paths: paths)"),
            "Audio.start should validate the same CoreStoragePaths that the embedder injected"
        )
    }

    runSuite("Repo command contract - microphone permission callback cannot start after cancellation") {
        let contents = readRepoTextFile("Sources/TranscriptedCore/Audio/Audio.swift")
        assertTrue(
            contents.contains("pendingStartIntentId")
                && contents.contains("isCurrentStartIntent(startIntentId)")
                && contents.contains("Ignoring stale microphone permission response after start was cancelled"),
            "Audio.start should bind permission callbacks to the active start intent"
        )
    }

    runSuite("Repo command contract - ScreenCaptureKit callbacks are timeout-bounded") {
        let contents = readRepoTextFile("Sources/TranscriptedCore/Audio/SCKAudioCapture.swift")
        assertTrue(
            contents.contains("SCKCaptureTimeoutError")
                && contents.contains("timeout: DispatchTimeInterval = callbackTimeout")
                && contents.contains("wait(timeout: .now() + timeout)")
                && contents.contains("permissionPromptCallbackTimeout")
                && contents.contains("operation: \"shareable content fetch\"")
                && contents.contains("timeout: Self.permissionPromptCallbackTimeout")
                && !contents.contains("semaphore.wait()\n"),
            "ScreenCaptureKit waits should stay bounded while allowing first-run permission prompts longer than normal callbacks"
        )
        assertTrue(
            contents.contains("stopStreamAndCleanupIfConfirmed")
                && contents.contains("retainStreamReferenceAfterTimedOutStop")
                && contents.contains("cleanupAfterLateCallback")
                && contents.contains("running late stop callback cleanup")
                && contents.contains("SCKAudioCapture: keeping stream reference after stop timeout"),
            "ScreenCaptureKit should keep the stream reference when a stop callback times out, then clean it up if the callback arrives late"
        )
        assertTrue(
            contents.contains("isWaitingForTimedOutStopCallback")
                && contents.contains("stopCurrentStreamBeforePrepare")
                && contents.contains("refusing to prepare new stream while previous stop is still pending")
                && contents.contains("refusing to prepare new stream because previous stream is still stopping")
                && contents.contains("refusing to start stream while previous stop is still pending"),
            "ScreenCaptureKit should block new prepare/start attempts while an old timed-out stop callback is still pending"
        )
    }

    runSuite("Repo command contract - deterministic E2E smoke stays on the release surface") {
        let wrapper = readRepoTextFile("run-e2e-smoke.sh")
        let entrypoint = readRepoTextFile("scripts/entrypoints/run-e2e-smoke.sh")
        let testsReadme = readRepoTextFile("Tests/README.md")
        let matrix = readRepoTextFile(".agents/test-matrix.yml")

        assertTrue(
            wrapper.contains("exec \"$SCRIPT_DIR/scripts/entrypoints/run-e2e-smoke.sh\" \"$@\""),
            "root E2E wrapper should delegate to the scripts entrypoint"
        )
        assertTrue(
            entrypoint.contains("Tests/E2E/TranscriptedE2ESmoke.swift"),
            "E2E entrypoint should compile the deterministic release-critical smoke"
        )
        assertTrue(
            entrypoint.contains("TRANSCRIPTED_DISABLE_FILE_LOGGER=1"),
            "E2E smoke should keep local production logs clean"
        )
        assertTrue(
            testsReadme.contains("bash run-e2e-smoke.sh"),
            "Tests README should document the deterministic E2E smoke"
        )
        assertTrue(
            matrix.contains("Tests/E2E/**") && matrix.contains("bash run-e2e-smoke.sh"),
            "test matrix should map E2E smoke changes to the E2E command"
        )
    }

    runSuite("Repo command contract - live capture smoke stays explicit and opt-in") {
        let wrapper = readRepoTextFile("run-live-capture-smoke.sh")
        let entrypoint = readRepoTextFile("scripts/entrypoints/run-live-capture-smoke.sh")
        let liveSmokeTest = readRepoTextFile("Tests/TranscriptedCoreTests/LiveCaptureSmokeTests.swift")
        let testsReadme = readRepoTextFile("Tests/README.md")
        let matrix = readRepoTextFile(".agents/test-matrix.yml")

        assertTrue(
            wrapper.contains("exec \"$SCRIPT_DIR/scripts/entrypoints/run-live-capture-smoke.sh\" \"$@\""),
            "root live-capture wrapper should delegate to the scripts entrypoint"
        )
        assertTrue(
            entrypoint.contains("bash build.sh --no-open") && entrypoint.contains("--skip-build"),
            "live capture smoke should build by default while keeping a faster rerun path"
        )
        assertTrue(
            entrypoint.contains("TRANSCRIPTED_LIVE_CAPTURE_SMOKE=1")
                && entrypoint.contains("swift test --filter LiveCaptureSmokeTests"),
            "live capture smoke should stay env-gated and scoped to the hardware/TCC XCTest"
        )
        assertTrue(
            liveSmokeTest.contains("XCTSkip(\"Set TRANSCRIPTED_LIVE_CAPTURE_SMOKE=1"),
            "the live capture XCTest should skip by default outside the explicit smoke command"
        )
        assertTrue(
            testsReadme.contains("bash run-live-capture-smoke.sh")
                && testsReadme.contains("microphone permission"),
            "Tests README should document the local permission requirements"
        )
        assertTrue(
            matrix.contains("Tests/TranscriptedCoreTests/LiveCaptureSmokeTests.swift")
                && matrix.contains("bash run-live-capture-smoke.sh --skip-build"),
            "test matrix should map live-smoke changes to the permission-aware command"
        )
    }

    runSuite("Repo command contract - release resources ship only the active app icon") {
        let infoPlist = readRepoTextFile("Info.plist")
        assertTrue(
            infoPlist.contains("<key>CFBundleIconFile</key>\n\t<string>Transcripted</string>"),
            "Info.plist should point at the active Transcripted icon"
        )

        let resourceURL = repoRootURL().appendingPathComponent("Resources", isDirectory: true)
        let shippedIcons = ((try? FileManager.default.contentsOfDirectory(
            at: resourceURL,
            includingPropertiesForKeys: nil
        )) ?? [])
            .map(\.lastPathComponent)
            .filter { $0.hasSuffix(".icns") || $0.hasSuffix(".png") }
            .sorted()

        assertEqual(
            shippedIcons,
            ["Transcripted.icns"],
            "Resources are copied wholesale into the app bundle, so old icon experiments should not ship"
        )
    }

    runSuite("Repo command contract - legacy bundle identifier is an explicit compatibility contract") {
        let infoPlist = readRepoTextFile("Info.plist")
        let releaseDocs = readRepoTextFile("docs/release-packaging.md")

        assertEqual(
            plistStringValue("CFBundleIdentifier", in: infoPlist),
            "com.justinbetker.draft",
            "bundle id should stay unchanged until there is an explicit TCC/defaults migration"
        )
        assertTrue(
            releaseDocs.contains("Bundle Identifier Compatibility")
                && releaseDocs.contains("com.justinbetker.draft")
                && releaseDocs.contains("Treat any bundle")
                && releaseDocs.contains("identifier rename as a release migration"),
            "release docs should explain why the legacy bundle id is intentional"
        )
    }

    runSuite("Repo command contract - release metadata stays aligned") {
        let infoPlist = readRepoTextFile("Info.plist")
        let cask = readRepoTextFile("Casks/transcripted.rb")
        let appcast = readRepoTextFile("docs/appcast.xml")

        let appVersion = plistStringValue("CFBundleShortVersionString", in: infoPlist)
        let buildVersion = plistStringValue("CFBundleVersion", in: infoPlist)
        let sentryReleasePrefix = plistStringValue("TranscriptedSentryReleasePrefix", in: infoPlist)
        let caskVersion = rubyStringAssignment("version", in: cask)
        let caskSHA = rubyStringAssignment("sha256", in: cask)
        let latestAppcastItem = firstAppcastItem(in: appcast)
        let minimumSystemVersion = plistStringValue("LSMinimumSystemVersion", in: infoPlist)
        let appcastTitle = xmlText("title", in: latestAppcastItem)
        let appcastVersion = xmlText("sparkle:version", in: latestAppcastItem)
        let appcastShortVersion = xmlText("sparkle:shortVersionString", in: latestAppcastItem)
        let appcastMinimumSystemVersion = xmlText("sparkle:minimumSystemVersion", in: latestAppcastItem)
        let appcastHardwareRequirements = xmlText("sparkle:hardwareRequirements", in: latestAppcastItem)
        let appcastEnclosureURL = xmlAttribute("url", inFirstTagNamed: "enclosure", text: latestAppcastItem)
        let appcastLength = xmlAttribute("length", inFirstTagNamed: "enclosure", text: latestAppcastItem)
        let appcastSignature = xmlAttribute("sparkle:edSignature", inFirstTagNamed: "enclosure", text: latestAppcastItem)
        let appcastLink = xmlText("link", in: latestAppcastItem)
        let appcastReleaseNotesLink = xmlText("sparkle:releaseNotesLink", in: latestAppcastItem)
        let expectedReleaseURL = appVersion.map { "https://github.com/r3dbars/transcripted/releases/tag/v\($0)" }

        assertNotNil(appVersion, "Info.plist should expose CFBundleShortVersionString")
        assertEqual(buildVersion, appVersion, "marketing and build versions should move together for Sparkle")
        assertEqual(sentryReleasePrefix, "transcripted", "Sentry release names should stay on the transcripted@<version> format")
        assertEqual(caskVersion, appVersion, "Homebrew cask version should match the app bundle version")
        assertEqual(appcastTitle, appVersion, "latest appcast title should name the release version")
        assertEqual(appcastVersion, appVersion, "latest appcast item should match the app bundle version")
        assertEqual(appcastShortVersion, appVersion, "Sparkle shortVersionString should match the app bundle version")
        assertEqual(appcastMinimumSystemVersion, minimumSystemVersion, "Sparkle minimum macOS version should match Info.plist")
        assertEqual(appcastHardwareRequirements, "arm64", "Sparkle appcast should keep the release hardware requirement explicit")
        assertEqual(
            appcastEnclosureURL,
            appVersion.map { "https://github.com/r3dbars/transcripted/releases/download/v\($0)/Transcripted-\($0).dmg" },
            "latest appcast enclosure should point at the matching GitHub DMG"
        )
        assertEqual(appcastLink, expectedReleaseURL, "latest appcast link should point at the matching GitHub release")
        assertEqual(appcastReleaseNotesLink, expectedReleaseURL, "latest appcast notes should point at the matching GitHub release")
        assertTrue(
            isPositiveInteger(appcastLength),
            "latest appcast enclosure should include a positive asset length"
        )
        assertTrue(
            isNonEmptyBase64Like(appcastSignature),
            "latest appcast enclosure should include a Sparkle EdDSA signature"
        )
        assertTrue(
            isSHA256Hex(caskSHA),
            "Homebrew cask should include a real 64-character SHA-256 digest"
        )
        assertTrue(
            cask.contains("releases/download/v#{version}/Transcripted-#{version}.dmg"),
            "Homebrew cask URL should keep tracking the matching GitHub release asset"
        )
        assertTrue(cask.contains("depends_on arch: :arm64"), "Homebrew cask should keep the arm64 release contract")
        assertTrue(cask.contains("depends_on macos: \">= :tahoe\""), "Homebrew cask should stay aligned with the macOS 26+ release floor")
    }

    runSuite("Repo command contract - Sentry release registration requires matching dSYM") {
        let buildBeta = readRepoTextFile("scripts/entrypoints/build-beta.sh")
        let registerSentry = readRepoTextFile("scripts/release/register-sentry-release.sh")
        let releaseDocs = readRepoTextFile("docs/release-packaging.md")

        assertTrue(
            buildBeta.contains("GENERATE_DSYM=\"${GENERATE_DSYM:-1}\"")
                && buildBeta.contains("dsymutil \"$APP_BINARY\" -o \"$APP_DSYM\""),
            "release builds should generate the app dSYM by default"
        )
        assertTrue(
            buildBeta.contains("SENTRY_REQUIRE_DEBUG_FILES=\"${SENTRY_REQUIRE_DEBUG_FILES:-1}\"")
                && buildBeta.contains("SENTRY_APP_BINARY_PATH=\"${SENTRY_APP_BINARY_PATH:-$APP_BINARY}\"")
                && buildBeta.contains("SENTRY_DEBUG_FILES_PATH=\"${SENTRY_DEBUG_FILES_PATH:-$APP_DSYM}\""),
            "build-beta.sh should register Sentry with the exact app/dSYM pair from the release build"
        )
        assertTrue(
            registerSentry.contains("SENTRY_REQUIRE_DEBUG_FILES=\"${SENTRY_REQUIRE_DEBUG_FILES:-1}\"")
                && registerSentry.contains("SENTRY_DEBUG_FILES_PATH=\"${SENTRY_DEBUG_FILES_PATH:-build/Transcripted.app.dSYM}\"")
                && registerSentry.contains("SENTRY_APP_BINARY_PATH=\"${SENTRY_APP_BINARY_PATH:-build/Transcripted.app/Contents/MacOS/Transcripted}\""),
            "standalone Sentry registration should require the release dSYM and know the matching app binary path by default"
        )
        assertTrue(
            registerSentry.contains("dwarfdump --uuid \"$path\"")
                && registerSentry.contains("verify_debug_file_match \"$SENTRY_APP_BINARY_PATH\" \"$SENTRY_DEBUG_FILES_PATH\"")
                && registerSentry.contains("Sentry debug files do not match the app binary."),
            "Sentry registration should fail before upload when the dSYM UUID does not match the app binary"
        )
        assertTrue(
            registerSentry.contains("Release is yellow unless matching dSYM was uploaded separately"),
            "explicit debug-file skips should call the release yellow"
        )
        assertTrue(
            releaseDocs.contains("verifies the dSYM UUID matches the built app binary")
                && releaseDocs.contains("SENTRY_DEBUG_FILES_PATH=/path/to/Transcripted.app.dSYM")
                && releaseDocs.contains("SENTRY_APP_BINARY_PATH=/path/to/Transcripted.app/Contents/MacOS/Transcripted")
                && releaseDocs.contains("call the release yellow"),
            "release docs should tell future workers how to register a reused artifact without stale symbols"
        )
    }

    runSuite("Repo command contract - Sparkle app settings point at the committed appcast") {
        let infoPlist = readRepoTextFile("Info.plist")
        let appcast = readRepoTextFile("docs/appcast.xml")
        let sparkleDocs = readRepoTextFile("docs/sparkle-updates.md")

        let feedURL = plistStringValue("SUFeedURL", in: infoPlist)
        let appcastSelfURL = xmlAttribute("href", inFirstTagNamed: "atom:link", text: appcast)
        let publicKey = plistStringValue("SUPublicEDKey", in: infoPlist)

        assertEqual(
            feedURL,
            "https://raw.githubusercontent.com/r3dbars/transcripted/main/docs/appcast.xml",
            "Info.plist should use the committed main-branch appcast feed"
        )
        assertEqual(appcastSelfURL, feedURL, "appcast self link should match Info.plist SUFeedURL")
        assertTrue(plistBooleanValue("SUEnableAutomaticChecks", in: infoPlist) == true, "Sparkle automatic checks should stay enabled")
        assertTrue(plistBooleanValue("SUAllowsAutomaticUpdates", in: infoPlist) == true, "Sparkle automatic downloads should stay available")
        assertEqual(plistIntegerValue("SUScheduledCheckInterval", in: infoPlist), 14_400, "Sparkle check interval should stay at 4 hours")
        assertNotNil(publicKey, "Info.plist should include the Sparkle EdDSA public key")
        if let publicKey {
            assertTrue(
                sparkleDocs.contains("<string>\(publicKey)</string>"),
                "docs/sparkle-updates.md should document the committed Sparkle public key"
            )
        }
    }

    runSuite("Repo command contract - update check timeout marks the cycle failed") {
        let controller = readRepoTextFile("Sources/Observability/SparkleUpdaterController.swift")
        let failureBlock = sourceSlice(
            controller,
            from: "private func markUpdateCheckFailed(",
            to: "private func markUpdaterIdle("
        )

        assertTrue(
            failureBlock.contains("didTrackCurrentUpdateCycleFailure = true"),
            "tracked update-check failures should suppress duplicate finish-cycle error telemetry"
        )
        assertFalse(
            failureBlock.contains("if error != nil {\n            didTrackCurrentUpdateCycleFailure = true\n        }"),
            "timeout fallback failures have nil errors but still count as tracked failures"
        )
    }

    runSuite("Repo command contract - existing Sparkle sessions do not start app-owned timeouts") {
        let controller = readRepoTextFile("Sources/Observability/SparkleUpdaterController.swift")
        let checkBlock = sourceSlice(
            controller,
            from: "private func beginObservedUpdateCheckIfPossible() -> Bool",
            to: "private func syncReadiness("
        )
        let existingSessionBlock = sourceSlice(
            checkBlock,
            from: "if updater.sessionInProgress",
            to: "guard updater.canCheckForUpdates"
        )

        assertTrue(existingSessionBlock.contains("syncReadiness(from: updater)"), "existing Sparkle sessions should only sync visible readiness")
        assertFalse(existingSessionBlock.contains("beginObservedUpdateCheck()"), "existing Sparkle sessions should not start a new timeout timer")
    }

    runSuite("Repo command contract - Sparkle no-update finish cycles stay successful") {
        let controller = readRepoTextFile("Sources/Observability/SparkleUpdaterController.swift")
        let didNotFindBlock = sourceSlice(
            controller,
            from: "func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error)",
            to: "func updaterDidNotFindUpdate(_ updater: SPUUpdater)"
        )
        let finishCycleBlock = sourceSlice(
            controller,
            from: "func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?)",
            to: "func updaterWillRelaunchApplication"
        )

        let didNotFindNoUpdateCheck = didNotFindBlock.range(of: "UpdateFailureKind.isNoUpdate(error)")
        let didNotFindNoUpdateHandler = didNotFindBlock.range(of: "markNoUpdateAvailable(from: updater)")
        let didNotFindFailureHandler = didNotFindBlock.range(of: "markUpdateCheckFailed(from: updater, error: error)")
        let noUpdateCheck = finishCycleBlock.range(of: "UpdateFailureKind.isNoUpdate(error)")
        let noUpdateHandler = finishCycleBlock.range(of: "markNoUpdateAvailable(from: updater)")
        let failureHandler = finishCycleBlock.range(of: "markUpdateCheckFailed(from: updater, error: error)")

        assertNotNil(didNotFindNoUpdateCheck, "Sparkle 1001 did-not-find callbacks should be detected as no-update outcomes")
        assertNotNil(didNotFindNoUpdateHandler, "Sparkle no-update did-not-find callbacks should use the success path")
        assertNotNil(didNotFindFailureHandler, "real did-not-find errors should still use the failure path")
        if let didNotFindNoUpdateCheck, let didNotFindFailureHandler {
            assertTrue(
                didNotFindNoUpdateCheck.lowerBound < didNotFindFailureHandler.lowerBound,
                "no-update did-not-find callbacks should be handled before the generic failure path"
            )
        }
        assertNotNil(noUpdateCheck, "Sparkle 1001 finish-cycle errors should be detected as no-update outcomes")
        assertNotNil(noUpdateHandler, "Sparkle no-update finish cycles should use the success path")
        assertNotNil(failureHandler, "real finish-cycle errors should still use the failure path")
        if let noUpdateCheck, let failureHandler {
            assertTrue(
                noUpdateCheck.lowerBound < failureHandler.lowerBound,
                "no-update finish cycles should be handled before the generic failure path"
            )
        }
    }

    runSuite("Repo command contract - Sparkle download failures include diagnostic codes") {
        let controller = readRepoTextFile("Sources/Observability/SparkleUpdaterController.swift")
        let downloadFailureBlock = sourceSlice(
            controller,
            from: "func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error)",
            to: "func updater(\n        _ updater: SPUUpdater,\n        willInstallUpdateOnQuit"
        )

        assertTrue(
            downloadFailureBlock.contains("failureCode: UpdateFailureKind.diagnosticCode(error)")
                || downloadFailureBlock.contains("failureCode = UpdateFailureKind.diagnosticCode(error)"),
            "Sparkle download failures should attach a coarse diagnostic code to finished telemetry"
        )
        assertTrue(
            downloadFailureBlock.contains("failureCode: failureCode"),
            "download_failed update_check_finished telemetry should include the diagnostic code"
        )
    }

    runSuite("Repo command contract - downloaded Sparkle state emits ready telemetry") {
        let controller = readRepoTextFile("Sources/Observability/SparkleUpdaterController.swift")
        let readyHelper = sourceSlice(
            controller,
            from: "private func markUpdateReadyToInstall(",
            to: "private func baseUpdateTelemetryProperties("
        )
        let userDriverBlock = sourceSlice(
            controller,
            from: "nonisolated func standardUserDriverWillHandleShowingUpdate(",
            to: "\n    }\n}"
        )

        assertTrue(
            readyHelper.contains("lastTrackedReadyToInstallVersion != version"),
            "ready-to-install telemetry should stay one event per version"
        )
        assertTrue(
            readyHelper.contains("update_ready_to_install"),
            "ready-to-install helper should emit the update funnel event"
        )
        assertTrue(
            userDriverBlock.contains("markUpdateReadyToInstall"),
            "Sparkle downloaded-state UI should not skip ready-to-install telemetry"
        )
    }

    runSuite("Repo command contract - Sparkle relaunch records installed-update confirmation") {
        let controller = readRepoTextFile("Sources/Observability/SparkleUpdaterController.swift")
        let relaunchBlock = sourceSlice(
            controller,
            from: "func updaterWillRelaunchApplication",
            to: "extension SparkleUpdaterController: SPUStandardUserDriverDelegate"
        )
        let confirmationBlock = sourceSlice(
            controller,
            from: "private func trackInstalledUpdateIfNeeded()",
            to: "private func markUpdateReadyToInstall("
        )

        assertTrue(
            relaunchBlock.contains("rememberPendingInstalledUpdate"),
            "Sparkle relaunch should persist the expected installed version before quitting"
        )
        assertTrue(
            confirmationBlock.contains("update_installed"),
            "next launch should emit a narrow installed-update confirmation event"
        )
        assertTrue(
            confirmationBlock.contains("removeObject(forKey: Self.pendingInstalledUpdateVersionKey)"),
            "installed-update confirmation should clear the one-shot marker"
        )
    }

    runSuite("Repo command contract - release docs keep Sparkle and Homebrew gates explicit") {
        let releaseDocs = readRepoTextFile("docs/release-packaging.md")
        let sparkleDocs = readRepoTextFile("docs/sparkle-updates.md")
        let scriptsReadme = readRepoTextFile("scripts/README.md")

        assertTrue(
            releaseDocs.contains("docs/sparkle-updates.md") && releaseDocs.contains("docs/appcast.xml"),
            "release packaging docs should keep Sparkle in the release contract"
        )
        assertTrue(
            releaseDocs.contains("existing installs will not discover the new build in-app yet"),
            "release packaging docs should warn when Sparkle metadata is stale"
        )
        assertTrue(
            releaseDocs.contains("bash scripts/release/update-cask.sh <version>"),
            "release packaging docs should include the Homebrew cask update command"
        )
        assertTrue(
            releaseDocs.contains("bash scripts/release/register-sentry-release.sh <version>"),
            "release packaging docs should include the Sentry release registration command"
        )
        assertTrue(
            releaseDocs.contains("Prefer this post-publish registration path")
                && releaseDocs.contains("REGISTER_SENTRY_RELEASE=1"),
            "release packaging docs should explain when build-time Sentry registration is safe"
        )
        assertTrue(
            releaseDocs.contains("Homebrew users will still") && releaseDocs.contains("install or upgrade to the older version"),
            "release packaging docs should warn when the cask is stale"
        )
        assertTrue(
            releaseDocs.contains("live `/appcast.xml`")
                && releaseDocs.contains("live `/download`")
                && releaseDocs.contains("live `/download/latest.dmg`")
                && releaseDocs.contains("Cloudflare Pages deployment status"),
            "release packaging docs should keep live web release truth separate from source truth"
        )
        assertTrue(
            releaseDocs.contains("SKIP_NOTARIZATION=1 REQUIRE_BUNDLED_PARAKEET_MODELS=0 BUNDLE_PARAKEET_MODELS=0 REQUIRE_BUNDLED_DIARIZER_MODELS=0 BUNDLE_DIARIZER_MODELS=0 bash build-beta.sh <beta-token> <user-name>"),
            "release packaging docs should include a local thin packaging smoke command"
        )
        assertTrue(
            sparkleDocs.contains("release is not done until `docs/appcast.xml` has been updated and pushed"),
            "Sparkle docs should make the pushed appcast a required gate"
        )
        assertTrue(
            sparkleDocs.contains("bash scripts/release/generate-sparkle-appcast.sh /path/to/updates-folder"),
            "Sparkle docs should include the appcast generation command"
        )
        assertTrue(
            sparkleDocs.contains("bash scripts/release/verify-sparkle-release.sh <version>"),
            "Sparkle docs should include the release verification command"
        )
        assertTrue(
            sparkleDocs.contains("Commit and push the updated `docs/appcast.xml`."),
            "Sparkle docs should keep the final push gate explicit"
        )
        assertTrue(
            scriptsReadme.contains("scripts/release/generate-sparkle-appcast.sh")
                && scriptsReadme.contains("scripts/release/verify-sparkle-release.sh")
                && scriptsReadme.contains("scripts/release/update-cask.sh")
                && scriptsReadme.contains("scripts/release/register-sentry-release.sh")
                && scriptsReadme.contains("scripts/dev/benchmark-home-recent-captures.sh")
                && scriptsReadme.contains("scripts/ops/dictation-recovery-autoeval.rb"),
            "scripts README should list the active release, benchmark, and autoeval helper scripts"
        )
    }

    runSuite("Repo command contract - release path preflight rebuilds deps") {
        let matrix = readRepoTextFile(".agents/test-matrix.yml")
        let preflight = readRepoTextFile("scripts/dev/agent-preflight.sh")
        let releaseMatrixBlock = sourceSlice(
            matrix,
            from: "- \"build-beta.sh\"",
            to: "- \"Tools/TranscriptedCLI/**\""
        )
        let releasePreflightBlock = sourceSlice(
            preflight,
            from: "if matches_any \"$path\" \"build-beta.sh\"",
            to: "if matches_any \"$path\" \"README.md\""
        )

        assertTrue(
            releaseMatrixBlock.contains("bash build-deps.sh --force")
                && releaseMatrixBlock.contains("bash build.sh --no-open")
                && releaseMatrixBlock.contains("SKIP_NOTARIZATION=1 bash build-beta.sh '' <user-name>"),
            "release-path matrix checks should rebuild deps before app and packaging smoke"
        )
        assertTrue(
            releasePreflightBlock.contains("add_command \"bash build-deps.sh --force\"")
                && releasePreflightBlock.contains("add_command \"bash build.sh --no-open\"")
                && releasePreflightBlock.contains("add_command \"SKIP_NOTARIZATION=1 bash build-beta.sh '' <user-name>\""),
            "agent preflight should suggest dependency rebuilds for release-path edits"
        )
    }

    runSuite("Repo command contract - Cloudflare ops docs split read from deploy") {
        let docs = readRepoTextFile("docs/ops-credentials.md")

        assertTrue(
            docs.contains("Cloudflare Pages Read")
                && docs.contains("Pages project, deployment, zone, and analytics status")
                && docs.contains("Pages Read")
                && docs.contains("Zone Read")
                && docs.contains("Cloudflare Pages Deploy")
                && docs.contains("Pages Write"),
            "Cloudflare ops docs should distinguish health-check read scopes from deploy-capable credentials"
        )
        assertTrue(
            docs.contains("health probe reads Pages project/deployment status and zone analytics")
                && docs.contains("Manual deploys need `Pages Write`"),
            "Cloudflare docs should warn that health-probe auth is not deploy proof"
        )
    }

    runSuite("Repo command contract - release helper scripts keep local release checks available") {
        let expectedBashScripts = [
            "scripts/release/generate-sparkle-appcast.sh",
            "scripts/release/verify-sparkle-release.sh",
            "scripts/release/update-cask.sh",
            "scripts/release/register-sentry-release.sh",
        ]

        for script in expectedBashScripts {
            assertTrue(fileExists(script), "\(script) should stay in the repo")
            assertTrue(readRepoTextFile(script).hasPrefix("#!/bin/bash"), "\(script) should remain a bash entrypoint")
        }
        assertTrue(fileExists("scripts/release/sentry-release-metadata.py"), "Sentry release metadata helper should stay in the repo")
        assertTrue(
            readRepoTextFile("scripts/release/sentry-release-metadata.py").hasPrefix("#!/usr/bin/env python3"),
            "Sentry release metadata helper should remain a Python entrypoint"
        )

        let generateAppcast = readRepoTextFile("scripts/release/generate-sparkle-appcast.sh")
        assertTrue(
            generateAppcast.contains("deps-tools/sparkle/bin/generate_appcast")
                && generateAppcast.contains("REPO_APPCAST_PATH=\"${REPO_APPCAST_PATH:-docs/appcast.xml}\""),
            "generate-sparkle-appcast should use the pinned Sparkle tool and committed appcast"
        )
        assertTrue(
            generateAppcast.contains("INFO_PLIST_PATH=\"${INFO_PLIST_PATH:-Info.plist}\"")
                && generateAppcast.contains("minimumSystemVersion")
                && generateAppcast.contains("hardwareRequirements"),
            "generate-sparkle-appcast should align feed metadata with Info.plist"
        )
        assertTrue(
            generateAppcast.contains("sparkle:edSignature")
                && generateAppcast.contains("releases/download/v{version}/Transcripted-{version}.dmg"),
            "generate-sparkle-appcast should require signed Sparkle updates and GitHub release asset URLs"
        )

        let verifySparkle = readRepoTextFile("scripts/release/verify-sparkle-release.sh")
        assertTrue(
            verifySparkle.contains("gh release view")
                && verifySparkle.contains("curl -fsSIL")
                && verifySparkle.contains("EXPECTED_URL=\"https://github.com/r3dbars/transcripted/releases/download/${TAG}/${DMG_NAME}\""),
            "verify-sparkle-release should check the published GitHub release and DMG URL"
        )
        assertTrue(
            verifySparkle.contains("Print :SUFeedURL")
                && verifySparkle.contains("Print :SUPublicEDKey")
                && verifySparkle.contains("Print :SUEnableAutomaticChecks"),
            "verify-sparkle-release should check app updater settings"
        )
        assertTrue(
            verifySparkle.contains("latest appcast item is missing enclosure")
                && verifySparkle.contains("sparkle:edSignature")
                && verifySparkle.contains("latest appcast item has invalid length"),
            "verify-sparkle-release should check the local appcast entry before release closeout"
        )

        let updateCask = readRepoTextFile("scripts/release/update-cask.sh")
        assertTrue(
            updateCask.contains("CASK_PATH=\"$REPO_ROOT/Casks/transcripted.rb\"")
                && updateCask.contains("DMG_URL=\"https://github.com/r3dbars/transcripted/releases/download/v${VERSION}/Transcripted-${VERSION}.dmg\""),
            "update-cask should update the committed cask from the matching GitHub DMG"
        )
        assertTrue(
            updateCask.contains("shasum -a 256")
                && updateCask.contains("sha256"),
            "update-cask should compute the published artifact digest locally"
        )

        let sentryMetadata = readRepoTextFile("scripts/release/sentry-release-metadata.py")
        assertTrue(
            sentryMetadata.contains("CFBundleShortVersionString")
                && sentryMetadata.contains("CFBundleVersion")
                && sentryMetadata.contains("TranscriptedSentryReleasePrefix"),
            "Sentry metadata helper should derive release and dist from Info.plist"
        )

        let registerSentry = readRepoTextFile("scripts/release/register-sentry-release.sh")
        assertTrue(
            registerSentry.contains("sentry-cli releases new")
                && registerSentry.contains("--finalize")
                && registerSentry.contains("sentry-cli releases set-commits")
                && registerSentry.contains("sentry-cli debug-files upload")
                && registerSentry.contains("--no-sources")
                && registerSentry.contains("SENTRY_DEBUG_FILES_PATH")
                && registerSentry.contains("SENTRY_REQUIRE_DEBUG_FILES")
                && registerSentry.contains("SENTRY_REPOSITORY")
                && registerSentry.contains("v${APP_VERSION}")
                && registerSentry.contains("--commit \"$COMMIT_SPEC\"")
                && registerSentry.contains("Skipping finalize so reruns do not change the existing release date.")
                && registerSentry.contains("scripts/release/sentry-release-metadata.py"),
            "Sentry release registration should create the matching finalized release, pin commits, and upload debug symbols"
        )

        let localBuildScript = readRepoTextFile("scripts/entrypoints/build.sh")
        let betaBuildScript = readRepoTextFile("scripts/entrypoints/build-beta.sh")
        assertTrue(
            localBuildScript.contains("sentry-release-metadata.py --format shell Info.plist"),
            "local builds should verify Sentry release metadata before compiling"
        )
        assertTrue(
            localBuildScript.contains("ORIGINAL_SENTRY_RELEASE_WAS_SET")
                && localBuildScript.contains("export SENTRY_RELEASE=\"$ORIGINAL_SENTRY_RELEASE\"")
                && localBuildScript.contains("unset SENTRY_RELEASE"),
            "local builds should not clobber exported Sentry runtime overrides before launch smoke"
        )
        assertTrue(
            betaBuildScript.contains("sentry-release-metadata.py --format shell Info.plist")
                && betaBuildScript.contains("REGISTER_SENTRY_RELEASE")
                && betaBuildScript.contains("APP_DSYM")
                && betaBuildScript.contains("SWIFTC_TEMP_DIR")
                && betaBuildScript.contains("dsymutil")
                && betaBuildScript.contains("-gline-tables-only")
                && betaBuildScript.contains("-debug-prefix-map \"$REPO_ROOT=.\"")
                && betaBuildScript.contains("-save-temps")
                && betaBuildScript.contains("SENTRY_DEBUG_FILES_PATH")
                && betaBuildScript.contains("SENTRY_REQUIRE_DEBUG_FILES")
                && betaBuildScript.contains("register-sentry-release.sh \"$APP_VERSION\""),
            "distribution builds should surface the Sentry release/dist, generate dSYMs, and support explicit registration"
        )
    }

    runSuite("Repo command contract - performance budget checks release bloat") {
        let contents = readRepoTextFile("scripts/ops/performance-budget.rb")
        assertTrue(
            contents.contains("EXPECTED_PARAKEET_MODEL_DIR = \"parakeet-tdt-0.6b-v3-coreml\""),
            "performance budget should assert the runtime Parakeet model directory"
        )
        assertTrue(
            contents.contains("EXPECTED_RESOURCE_ICONS = [\"Transcripted.icns\"]"),
            "performance budget should keep old icon experiments out of release resources"
        )
        assertTrue(
            contents.contains("MAX_APP_BYTES = 650 * 1024 * 1024"),
            "performance budget should cap expanded app size"
        )
        assertTrue(
            contents.contains("MAX_RESOURCES_BYTES = 520 * 1024 * 1024"),
            "performance budget should cap resource size"
        )
        assertTrue(
            contents.contains("MAX_TRANSCRIPTION_P95_SECONDS = 0.5"),
            "performance budget should cap warmed dictation transcription latency"
        )
        assertTrue(
            contents.contains("MAX_TRANSCRIPTION_P95_RTF = 0.05"),
            "performance budget should cap warmed dictation real-time factor"
        )
        assertTrue(
            contents.contains("MAX_MODEL_READY_P90_SECONDS = 30.0"),
            "performance budget should keep a launch model-ready budget for explicit eager-load samples"
        )
        assertTrue(
            contents.contains("startup_model_ready_durations(events)"),
            "performance budget should parse launch to model-ready events"
        )
        assertTrue(
            contents.contains("--require-launch-model-ready-samples"),
            "lazy startup should not require launch-to-model-ready samples unless the budget asks for them"
        )
        assertTrue(
            contents.contains("MAX_DICTATION_FAST_START_P95_MS = 250.0"),
            "performance budget should cap ready-engine dictation start latency when samples are required"
        )
        assertTrue(
            contents.contains("MAX_DICTATION_REQUEST_TO_RECORDING_P95_MS = 250.0"),
            "performance budget should cap request-to-recording latency when strict start samples are required"
        )
        assertTrue(
            contents.contains("MAX_DICTATION_START_TO_FIRST_SAMPLE_P95_MS = 350.0"),
            "performance budget should cap start-to-first-sample latency when strict start samples are required"
        )
        assertTrue(
            contents.contains("MAX_DICTATION_STOP_TO_PASTE_P95_MS = 750.0"),
            "performance budget should cap stop-to-paste latency when samples are required"
        )
        assertTrue(
            contents.contains("MAX_DICTATION_STOP_TO_DONE_P95_MS = 1_000.0"),
            "performance budget should cap the full stop pipeline when samples are required"
        )
        assertTrue(
            contents.contains("MAX_MEETING_P95_RTF = 0.05"),
            "performance budget should cap meeting processing real-time factor when stats are provided"
        )
        assertTrue(
            contents.contains("MIN_MEETING_DURATION_SECONDS = 30.0"),
            "meeting throughput budgets should ignore tiny fixed-overhead clips by default"
        )
        assertTrue(
            contents.contains("--require-dictation-fast-start-samples"),
            "performance budget should support strict fresh dictation start proof"
        )
        assertTrue(
            contents.contains("--max-dictation-request-to-recording-p95-ms")
                && contents.contains("--max-dictation-start-to-first-sample-p95-ms"),
            "strict dictation start proof should expose budgets for the user-visible start and audio-flow metrics"
        )
        assertTrue(
            contents.contains("--require-dictation-stop-latency-samples"),
            "performance budget should support strict fresh dictation stop proof"
        )
        assertTrue(
            contents.contains("--events-since ISO8601")
                && contents.contains("event[\"_time\"] >= options[:events_since]"),
            "performance budget should support fresh-window runtime event scoring"
        )
        assertTrue(
            contents.contains("--stats-since ISO8601")
                && contents.contains("created_at >= '#{since_time.utc.iso8601}'"),
            "performance budget should support fresh-window meeting throughput scoring"
        )
        assertTrue(
            contents.contains("--min-transcription-samples")
                && contents.contains("--min-meeting-samples"),
            "performance budget should let focused experiments set explicit sample requirements"
        )
        assertTrue(
            contents.contains("dictation_stop_latency_measured")
                && contents.contains("stop_to_paste_ms")
                && contents.contains("stop_to_done_ms"),
            "performance budget should parse measured dictation stop latency samples"
        )
        assertTrue(
            contents.contains("STOP_LATENCY_STAGE_KEYS")
                && contents.contains("Dictation stop stage p95s:")
                && contents.contains("Dictation stop slowest stage:"),
            "performance budget should report per-stage stop latency and identify the slowest stop segment"
        )
        assertTrue(
            contents.contains("dictation_request_to_recording_ms"),
            "performance budget should surface true request-to-recording timing when logs include it"
        )
        assertTrue(
            contents.contains("start_to_first_sample_ms"),
            "performance budget should surface audio-flow timing when logs include it"
        )
        assertTrue(
            contents.contains("dictation_start_proof_events")
                && contents.contains("dictation request-to-recording samples")
                && contents.contains("Dictation request-to-recording p95 is")
                && contents.contains("dictation start-to-first-sample samples")
                && contents.contains("Dictation start-to-first-sample p95 is"),
            "strict dictation start proof should enforce the collected request-to-recording and audio-flow samples"
        )
        assertTrue(
            contents.contains("--stats PATH"),
            "performance budget should support optional meeting throughput stats"
        )
        assertTrue(
            contents.contains("--min-meeting-duration-s"),
            "performance budget should make the meeting throughput duration threshold explicit"
        )
        assertTrue(
            contents.contains("--allow-missing-parakeet-model"),
            "performance budget should support intentional thin builds"
        )

        let localBuildScript = readRepoTextFile("scripts/entrypoints/build.sh")
        assertTrue(
            localBuildScript.contains("PERFORMANCE_BUDGET_ARGS=(--app \"$APP_BUNDLE\")")
                && localBuildScript.contains("scripts/ops/performance-budget.rb \"${PERFORMANCE_BUDGET_ARGS[@]}\""),
            "local build should fail before opening a bundle that violates performance budgets"
        )
        assertTrue(
            localBuildScript.contains("--no-open"),
            "local build should support non-interactive verification without leaving the app running"
        )
        assertTrue(
            localBuildScript.contains("--thin"),
            "local build should support a thin app variant that downloads the model on first use"
        )
        assertTrue(
            localBuildScript.contains("BUNDLE_PARAKEET_MODELS=\"${BUNDLE_PARAKEET_MODELS:-0}\""),
            "local build should default to the lightweight model-download app variant"
        )
        assertTrue(
            localBuildScript.contains("BUNDLE_PARAKEET_MODELS"),
            "local build should make model bundling an explicit build choice"
        )
        assertTrue(
            localBuildScript.contains("SWIFTC_NUM_THREADS")
                && localBuildScript.contains("-whole-module-optimization")
                && localBuildScript.contains("-num-threads \"$SWIFTC_NUM_THREADS\""),
            "local build should use threaded whole-module Swift compilation for a fast signed build loop"
        )
        assertTrue(
            localBuildScript.contains("TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS=1"),
            "local launch smoke should not create dirty-shutdown diagnostics markers"
        )
        assertTrue(
            localBuildScript.contains("/usr/bin/open -n -g -F -W")
                && localBuildScript.contains("--env \"TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT=$ui_report\"")
                && localBuildScript.contains("--env \"TRANSCRIPTED_LAUNCH_UI_SMOKE_TERMINATE_AFTER_REPORT=1\"")
                && localBuildScript.contains("\"$APP_BUNDLE\""),
            "local launch smoke should launch the app bundle through LaunchServices"
        )
        assertFalse(
            localBuildScript.contains("\"$APP_BINARY\" >\"$smoke_log\""),
            "local launch smoke should not run the app executable directly from sandboxed agent contexts"
        )
        assertTrue(
            localBuildScript.contains("pre_launch_app_pids=\"$(snapshot_launch_smoke_app_pids)\"")
                && localBuildScript.contains("terminate_launch_smoke_app()")
                && localBuildScript.contains("pgrep -f \"$APP_BINARY\"")
                && localBuildScript.contains("is_pre_launch_app_pid")
                && localBuildScript.contains("kill -TERM \"$pid\"")
                && localBuildScript.contains("kill -KILL \"$pid\""),
            "local launch smoke timeout cleanup should terminate only app processes created by this smoke run"
        )
        let appSource = readRepoTextFile("Sources/TranscriptedApp.swift")
        assertTrue(
            appSource.contains("TRANSCRIPTED_LAUNCH_UI_SMOKE_TERMINATE_AFTER_REPORT")
                && appSource.contains("scheduleLaunchUISmokeTerminationIfRequested")
                && appSource.contains("Darwin.exit(0)"),
            "launch smoke should let the app terminate itself instead of depending on process-listing in sandboxed agents"
        )

        let runtimeDiagnostics = readRepoTextFile("Sources/Observability/RuntimeDiagnostics.swift")
        assertTrue(
            runtimeDiagnostics.contains("TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS"),
            "runtime diagnostics should expose a smoke/test disable flag"
        )
        assertTrue(
            runtimeDiagnostics.contains("guard !isDisabled else { return }"),
            "runtime diagnostics should skip marker writes when disabled"
        )

        let betaBuildScript = readRepoTextFile("scripts/entrypoints/build-beta.sh")
        assertTrue(
            betaBuildScript.contains("PERFORMANCE_BUDGET_ARGS=(--app \"$APP_BUNDLE\")")
                && betaBuildScript.contains("scripts/ops/performance-budget.rb \"${PERFORMANCE_BUDGET_ARGS[@]}\""),
            "beta release build should fail before DMG packaging when the app violates performance budgets"
        )
        assertTrue(
            betaBuildScript.contains("BUNDLE_PARAKEET_MODELS"),
            "beta release build should support an intentional thin distribution variant"
        )
        assertTrue(
            betaBuildScript.contains("BUNDLE_PARAKEET_MODELS=\"${BUNDLE_PARAKEET_MODELS:-1}\""),
            "beta release build should bundle Parakeet by default for first-launch trust"
        )
        assertTrue(
            betaBuildScript.contains("BUNDLE_PARAKEET_MODELS=0 requires REQUIRE_BUNDLED_PARAKEET_MODELS=0"),
            "beta release build should not allow thin distribution unless the model requirement is explicitly disabled"
        )
        assertTrue(
            betaBuildScript.contains("BUNDLE_DIARIZER_MODELS=\"${BUNDLE_DIARIZER_MODELS:-1}\"")
                && betaBuildScript.contains("offline-diarizer-models")
                && betaBuildScript.contains("speaker-diarization-coreml"),
            "beta release build should bundle the offline diarizer models used by meeting capture"
        )
        assertTrue(
            betaBuildScript.contains("BUNDLE_DIARIZER_MODELS=0 requires REQUIRE_BUNDLED_DIARIZER_MODELS=0"),
            "beta release build should not allow missing diarizer models unless the requirement is explicitly disabled"
        )
        assertTrue(
            betaBuildScript.contains("SWIFTC_NUM_THREADS")
                && betaBuildScript.contains("-whole-module-optimization")
                && betaBuildScript.contains("-num-threads \"$SWIFTC_NUM_THREADS\""),
            "beta release build should use threaded whole-module Swift compilation"
        )
    }

    runSuite("Repo command contract - dictation recovery autoeval separates baseline from kept policy") {
        let contents = readRepoTextFile("scripts/ops/dictation-recovery-autoeval.rb")
        let baselineBlock = sourceSlice(contents, from: "BASELINE = Config.new(", to: ")\n\nKEPT_POLICY = Config.new(")
        let keptBlock = sourceSlice(contents, from: "KEPT_POLICY = Config.new(", to: ")\n\nSCENARIOS = [")

        assertTrue(
            baselineBlock.contains("name: \"baseline\"")
                && baselineBlock.contains("poll_ms: 150")
                && baselineBlock.contains("forced_recovery_refreshes: 6")
                && baselineBlock.contains("max_recording_start_attempts: 3"),
            "recovery autoeval baseline should stay the pre-keeper policy, not the kept winner"
        )
        assertTrue(
            keptBlock.contains("name: \"kept_current_policy\"")
                && keptBlock.contains("poll_ms: 100")
                && keptBlock.contains("forced_recovery_refreshes: 5")
                && keptBlock.contains("max_recording_start_attempts: 2"),
            "recovery autoeval should name the current kept policy separately from the baseline"
        )
        assertTrue(
            contents.contains("all_results.fetch(BASELINE.name)")
                && contents.contains("Baseline: pre-keeper policy")
                && contents.contains("Kept current policy:"),
            "recovery autoeval deltas and raw rows should be anchored to the real baseline"
        )
    }

    runSuite("Repo command contract - dictation fast start does not fall through into recovery wait") {
        let contents = readRepoTextFile("Sources/UI/Overlay/DictationSessionController.swift")
        guard
            let fastPathStart = contents.range(of: "case .skipLoadingAndStartRecording:"),
            let slowPathStart = contents.range(
                of: "case .showLoadingWhileWaiting:",
                range: fastPathStart.upperBound..<contents.endIndex
            )
        else {
            assertionFailure("Dictation start policy cases should exist")
            return
        }

        let fastPathBlock = String(contents[fastPathStart.lowerBound..<slowPathStart.lowerBound])
        assertTrue(
            fastPathBlock.contains("\n            return\n"),
            "fast dictation start should not schedule direct recording and then replace it with the recovery wait task"
        )
        assertTrue(
            fastPathBlock.contains("dictation_recording_fast_start"),
            "fast dictation start should emit a measurable local proof event"
        )
        assertTrue(
            fastPathBlock.contains("request_to_recording_ms"),
            "fast dictation start should measure request-to-recording latency, not only CoreAudio start time"
        )
        assertTrue(
            fastPathBlock.contains("pre_recording_overhead_ms"),
            "fast dictation start should expose non-CoreAudio overhead for future autoeval runs"
        )
        assertTrue(
            fastPathBlock.contains("dictation_fast_start_fell_back_to_wait"),
            "fast dictation start fallback should emit a local proof event"
        )
    }

    runSuite("Repo command contract - forced dictation recovery preempts refresh churn") {
        let contents = readRepoTextFile("Sources/UI/Overlay/DictationSessionController.swift")
        let forcedRecoveryBlock = sourceSlice(
            contents,
            from: "func startForcedRecovery(appState: TranscriptedAppState, reason: String) -> Bool",
            to: "func cancelIfTimedOut(now: TimeInterval) -> DictationReadinessRefreshTimeout?"
        )

        assertTrue(
            forcedRecoveryBlock.contains("operation != \"force_input_recovery\""),
            "hard dictation input recovery should leave an existing hard recovery alone"
        )
        assertTrue(
            forcedRecoveryBlock.contains("cancel()"),
            "hard dictation input recovery should preempt lower-priority readiness refresh churn"
        )
    }

    runSuite("Repo command contract - dictation stop path emits paste latency proof") {
        let contents = readRepoTextFile("Sources/UI/Overlay/DictationSessionController.swift")
        assertTrue(
            contents.contains("DictationStopTiming(requestedAt: stopRequestedAt)")
                && contents.contains("stopTiming.micStoppedAt")
                && contents.contains("stopTiming.transcriptionStartedAt")
                && contents.contains("stopTiming.pastedAt")
                && contents.contains("stopTiming.savedAt"),
            "dictation stop path should mark the critical stages from stop through paste and save"
        )
        assertTrue(
            contents.contains("dictation_stop_latency_measured")
                && contents.contains("stop_to_paste_ms")
                && contents.contains("stop_to_done_ms"),
            "dictation stop path should emit local raw stop latency measurements"
        )
        assertTrue(
            contents.contains("AnalyticsReporter.latencyBucket(milliseconds:")
                && contents.contains("\"stop_to_paste_bucket\"")
                && contents.contains("\"stop_to_done_bucket\""),
            "dictation stop analytics should send coarse latency buckets instead of raw milliseconds"
        )
    }

    runSuite("Repo command contract - dictation Auto Enter stays after paste readiness") {
        let contents = readRepoTextFile("Sources/UI/Overlay/DictationSessionController.swift")
        let saveBeforeAutoEnterBlock = sourceSlice(
            contents,
            from: "case .saveBeforeAutoEnter:",
            to: "let wordCount = text.split"
        )
        let saveTaskRange = saveBeforeAutoEnterBlock.range(of: "let saveTask = self.startPersistingDictationTranscript")
        let autoEnterRange = saveBeforeAutoEnterBlock.range(of: "autoSendOutcome = await self.performAutoEnterIfNeeded")
        let finishSaveRange = saveBeforeAutoEnterBlock.range(of: "saveFailureMessage = await self.finishPersistingDictationTranscript")

        assertTrue(
            saveTaskRange != nil
                && autoEnterRange != nil
                && finishSaveRange != nil
                && saveTaskRange!.lowerBound < autoEnterRange!.lowerBound
                && autoEnterRange!.lowerBound < finishSaveRange!.lowerBound,
            "default stop finalization should start saving, wait/send Auto Enter, then await the save result"
        )

        let autoEnterBlock = sourceSlice(
            contents,
            from: "private func performAutoEnterIfNeeded(",
            to: "@discardableResult"
        )
        let delayRange = autoEnterBlock.range(of: "Task.sleep(nanoseconds: TranscriptedConstants.dictationAutoEnterDelay)")
        let readinessRange = autoEnterBlock.range(of: "await textPaster.waitForClipboardReadyForAutoEnter()")
        let sendRange = autoEnterBlock.range(of: "return autoSender.send(DictationAutoSendPreferences.sendKey())")

        assertTrue(
            delayRange != nil
                && readinessRange != nil
                && sendRange != nil
                && delayRange!.lowerBound < readinessRange!.lowerBound
                && readinessRange!.lowerBound < sendRange!.lowerBound,
            "Auto Enter should sleep briefly, wait for clipboard read/readiness, then send the follow-up key"
        )
    }

    runSuite("Repo command contract - audio sample flow start stays measurable") {
        let contents = readRepoTextFile("Sources/Speech/ParakeetEngine.swift")
        assertTrue(
            contents.contains("start_to_first_sample_ms"),
            "audio_samples_detected should include start-to-first-buffer latency for dictation start autoevals"
        )
    }

    runSuite("Repo command contract - dictation audio start exposes stage timings") {
        let contents = readRepoTextFile("Sources/Speech/ParakeetEngine.swift")
        assertTrue(
            contents.contains("dictation_audio_start_timing"),
            "dictation start autoevals need a local stage-timing event"
        )
        assertTrue(
            contents.contains("audio_input_snapshot_read_ms")
                && contents.contains("audio_tap_install_ms")
                && contents.contains("audio_engine_start_ms"),
            "stage timing should cover audio snapshot read, tap install, and engine start"
        )
    }

    runSuite("Repo command contract - mini cursor stays compact from startup through paste") {
        let overlayContents = readRepoTextFile("Sources/UI/Overlay/FloatingOverlayController.swift")
        let sizeBlock = sourceSlice(
            overlayContents,
            from: "private func preferredPanelSize(for state: OverlayState) -> NSSize",
            to: "private func errorPanelSize() -> NSSize"
        )
        let showPanelBlock = sourceSlice(
            overlayContents,
            from: "func showPanel(near sourceApp: NSRunningApplication?, anchorRect: NSRect? = nil)",
            to: "func resizePanelToCompact()"
        )

        let miniSizeReturn = "return NSSize(width: OverlayTokens.panelCursorMiniWidth, height: OverlayTokens.panelCursorMiniHeight)"
        for (caseText, expectation) in [
            ("case .starting where isCursorMiniPresentationMode:", "mini cursor dictation should be tiny on the first visible startup frame"),
            ("case .listening where isCursorMiniPresentationMode:", "mini cursor dictation should stay tiny while listening"),
            ("case .drafting where errorMessage.isEmpty && isCursorMiniPresentationMode:", "mini cursor dictation should stay tiny while transcription is pending"),
            ("case .success where isCursorMiniPresentationMode:", "mini cursor dictation should stay tiny for the pasted confirmation"),
        ] {
            guard let caseRange = sizeBlock.range(of: caseText) else {
                assertTrue(false, expectation)
                continue
            }
            let restOfSizeBlock = String(sizeBlock[caseRange.upperBound...])
            assertTrue(
                restOfSizeBlock.contains(miniSizeReturn),
                expectation
            )
        }
        assertTrue(
            showPanelBlock.contains("let shouldOpenAtCursor = isCursorMiniPanelMode")
                && showPanelBlock.contains("? nil")
                && showPanelBlock.contains(": sourceApp.flatMap")
                && showPanelBlock.contains("if shouldOpenAtCursor")
                && showPanelBlock.contains("origin = cursorFollowOrigin(for: mousePos, panelSize: panelSize)"),
            "mini cursor dictation should skip AX lookup and open at the cursor instead of first anchoring to the text box"
        )
        assertTrue(
            showPanelBlock.contains("panel.ignoresMouseEvents = isCursorMiniPanelMode"),
            "mini cursor dictation should not briefly intercept the mouse while it appears"
        )
        assertTrue(
            showPanelBlock.contains("if !isCursorMiniPanelMode, let contentLayer = panel.contentView?.layer"),
            "mini cursor dictation should not run the full-panel spring animation"
        )

        let showStartingBlock = sourceSlice(
            overlayContents,
            from: "func showStartingState(near sourceApp: NSRunningApplication?, anchorRect: NSRect? = nil)",
            to: "@discardableResult"
        )
        assertTrue(
            showStartingBlock.contains("errorMessage = \"\"")
                && showStartingBlock.contains("state = .starting")
                && showStartingBlock.contains("resizePanelToCompact()")
                && showStartingBlock.contains("showPanel(near: sourceApp, anchorRect: anchorRect)"),
            "starting state should clear stale UI, force mini/compact size, then show the panel"
        )

        let loadingBlock = sourceSlice(
            overlayContents,
            from: "func showLoadingState(",
            to: "func showError("
        )
        assertTrue(
            loadingBlock.contains("if isCursorMiniPresentationMode, state == .starting || state == .listening")
                && loadingBlock.contains("scheduleMiniLoadingReveal()"),
            "mini cursor dictation should debounce full loading UI instead of flashing it immediately"
        )
        assertTrue(
            loadingBlock.contains("resizePanel(to: loadingSize, keepingVisible: true")
                && overlayContents.contains("private func clampedVisiblePanelFrame"),
            "delayed mini cursor loading expansion should stay clamped to the visible screen"
        )
        assertTrue(
            overlayContents.contains("miniLoadingRevealDelayNanoseconds: UInt64 = 700_000_000"),
            "mini cursor should keep the quiet startup waveform visible long enough to avoid a broken-looking full-window flash"
        )
        assertTrue(
            overlayContents.contains("NSWorkspace.shared.accessibilityDisplayShouldReduceMotion"),
            "cursor-follow smoothing should respect macOS Reduce Motion"
        )
        assertTrue(
            overlayContents.contains("updatePanelCornerRadius()")
                && overlayContents.contains("OverlayTokens.panelCursorMiniCornerRadius"),
            "mini cursor dictation should use a pill-like radius instead of the full overlay corner radius"
        )

        let headerContents = readRepoTextFile("Sources/UI/Overlay/OverlayHeaderView.swift")
        assertTrue(
            headerContents.contains("state == .starting || state == .listening || (state == .drafting && !isError) || state == .success"),
            "mini cursor dictation should use the tiny centered header layout during startup"
        )
        assertTrue(
            headerContents.contains("let miniWaveformOnly = usesMiniCursorLayout && (state == .starting || state == .listening)"),
            "mini cursor dictation should render starting/listening as waveform-only instead of flashing text"
        )
        assertTrue(
            headerContents.contains("stopButton.isHidden = usesMiniCursorLayout || state != .listening")
                && headerContents.contains("stopButton.frame = .zero"),
            "mini cursor dictation should never leak the stop button into the tiny pill"
        )
        assertTrue(
            headerContents.contains("setAccessibilityLabel(accessibilityLabel(for: state))")
                && headerContents.contains("Dictation listening")
                && headerContents.contains("Press Escape or your dictation shortcut"),
            "mini cursor waveform-only states should still expose an accessible dictation status and stop hint"
        )

        let rootContents = readRepoTextFile("Sources/UI/Overlay/OverlayRootView.swift")
        assertTrue(
            rootContents.contains("showsQuietStartupWaveform: state == .starting && isMiniCursorMode"),
            "mini cursor dictation should show a flat quiet waveform during startup"
        )

        let contents = readRepoTextFile("Sources/UI/Overlay/DictationSessionController.swift")
        let readyModelStartBlock = sourceSlice(
            contents,
            from: "if appState.sttRouter.isModelLoaded {",
            to: "startDictationAfterWarmup(sourceApp: sourceApp)"
        )
        assertTrue(
            readyModelStartBlock.contains("beginDictationRecording(sourceApp: sourceApp)"),
            "ready-model dictation should hand off directly to recording startup"
        )
        assertFalse(
            readyModelStartBlock.contains("overlayController.showPanel"),
            "ready-model dictation should not show an idle overlay before recording startup sets the first visible state"
        )
        let fastPathStartBlock = sourceSlice(
            contents,
            from: "case .skipLoadingAndStartRecording:",
            to: "recordingStartRetryTask?.cancel()"
        )
        assertTrue(
            fastPathStartBlock.contains("overlayController.showStartingState(near: sourceApp, anchorRect: sessionAnchorRect)"),
            "starting dictation should force the current panel to the mini/compact size before async recording work"
        )

        let warmupStartBlock = sourceSlice(
            contents,
            from: "private func startDictationAfterWarmup(sourceApp: NSRunningApplication?)",
            to: "startupTask = Task"
        )
        assertTrue(
            warmupStartBlock.contains("overlayController.showMiniCursorStartingStateIfNeeded")
                && warmupStartBlock.contains("updateLoadingOverlay(sourceApp: sourceApp)"),
            "mini cursor dictation should show a tiny startup pill before any delayed model-loading UI"
        )
        assertTrue(
            contents.contains("hasStartupTask: startupTask != nil"),
            "mini cursor model warmup should remain cancellable before the delayed loading reveal"
        )
        let lifecycleContents = readRepoTextFile("Sources/UI/Overlay/DictationRecordingStartOverlayPolicy.swift")
        assertTrue(
            lifecycleContents.contains("hasStartupTask || hasRecordingStartTask"),
            "pending startup tasks should be treated like recording-start tasks for stop/cancel decisions"
        )

        let permissionErrorBlock = sourceSlice(
            contents,
            from: "private func presentMicrophonePermissionError(",
            to: "overlayController.showError("
        )
        assertFalse(
            permissionErrorBlock.contains("overlayController.showPanel"),
            "permission errors should not pre-show an idle/mini panel before the real error panel"
        )

        let transcribingStartBlock = sourceSlice(
            contents,
            from: "overlayController.state = .drafting",
            to: "appState.runtimeDiagnostics.recordSession(kind: \"dictation\", stage: \"transcribing\")"
        )

        assertTrue(
            transcribingStartBlock.contains("overlayController.resizePanelToCompact()"),
            "dictation should re-check the compact/mini overlay size before showing the transcribing state"
        )
    }

    runSuite("Repo command contract - dictation window settings uses visual cards") {
        let contents = readRepoTextFile("Sources/UI/Settings/TranscriptedSettingsGeneralControls.swift")
        let rowBlock = sourceSlice(
            contents,
            from: "struct DictationOverlayModeRow: View",
            to: "struct GeneralActionRow: View"
        )

        assertTrue(
            rowBlock.contains("title: \"Dictation window\"")
                && rowBlock.contains("DictationOverlayModeChoice")
                && rowBlock.contains("DictationOverlayModePreview")
                && rowBlock.contains("NearTextOverlayPreview")
                && rowBlock.contains("MiniCursorOverlayPreview"),
            "General settings should present dictation window modes as visual cards, not a text-only control"
        )
        assertTrue(
            rowBlock.contains("@FocusState")
                && rowBlock.contains(".focusable(true)")
                && rowBlock.contains("isFocused"),
            "custom dictation window cards should expose visible keyboard focus styling"
        )
        assertTrue(
            rowBlock.contains("Dictation window options")
                && rowBlock.contains("Selected")
                && rowBlock.contains("Not selected"),
            "custom dictation window cards should make one-of-two selection state clear to accessibility"
        )
        assertTrue(
            rowBlock.contains("Text(\"Stop\")")
                && rowBlock.contains("stroke(Color.accentColor"),
            "near-text preview should show the larger controlled overlay beside a focused text field"
        )
        assertFalse(
            rowBlock.contains(".pickerStyle(.segmented)"),
            "dictation window setting should not regress to the old segmented text picker"
        )
    }

    runSuite("Repo command contract - launch warmup stays on demand") {
        let contents = readRepoTextFile("Sources/TranscriptedAppState.swift")
        guard
            let initializeStart = contents.range(of: "func initialize() async"),
            let wakeRecoveryStart = contents.range(
                of: "// MARK: - Wake Recovery",
                range: initializeStart.upperBound..<contents.endIndex
            ),
            let warmupStart = contents.range(of: "private func startRuntimeReadinessIfNeeded()"),
            let nextFunction = contents.range(
                of: "private func startAudioStorageMaintenanceIfNeeded()",
                range: warmupStart.upperBound..<contents.endIndex
            )
        else {
            assertionFailure("TranscriptedAppState should keep an explicit runtime readiness function")
            return
        }

        let initializeBlock = String(contents[initializeStart.lowerBound..<wakeRecoveryStart.lowerBound])
        assertTrue(
            initializeBlock.contains("if eagerModelWarmupEnabled"),
            "launch voice-model warmup should be behind an explicit opt-in"
        )
        assertTrue(
            initializeBlock.contains("startRuntimeReadinessIfNeeded()"),
            "the explicit eager-warmup path should still reuse runtime readiness"
        )
        assertTrue(
            contents.contains("TRANSCRIPTED_EAGER_MODEL_WARMUP"),
            "eager voice-model warmup should stay an explicit opt-in for testing or diagnostics"
        )

        let warmupBlock = String(contents[warmupStart.lowerBound..<nextFunction.lowerBound])
        assertTrue(
            warmupBlock.contains("await self.sttRouter.initializeSelectedModel()"),
            "on-demand readiness should load the selected dictation model when requested"
        )
        assertFalse(
            warmupBlock.contains("meetingSession.prepareModels(showLoadingUI: false)"),
            "launch should not eagerly load heavier meeting diarization models"
        )
    }

    runSuite("Repo command contract - warmup status trusts loaded dictation engine") {
        let contents = readRepoTextFile("Sources/Meeting/MeetingSessionController.swift")
        assertTrue(
            contents.contains("let dictationState: MeetingWarmupDictationState = sttRouter.isModelLoaded"),
            "warmup status should treat a loaded STT engine as ready even if the progress enum is stale"
        )
    }

    runSuite("Repo command contract - degraded meeting Sentry context stays bucketed") {
        let contents = readRepoTextFile("Sources/Meeting/MeetingSessionController.swift")
        let reportBlock = sourceSlice(
            contents,
            from: "private func reportCaptureHealthIfNeeded(",
            to: "private func savedTranscriptAnalyticsProperties()"
        )

        assertTrue(
            reportBlock.contains("context[\"gap_count_bucket\"] = AnalyticsReporter.countBucket(healthInfo.audioGaps)"),
            "degraded meeting Sentry events should preserve coarse gap counts"
        )
        assertTrue(
            reportBlock.contains("context[\"route_change_count_bucket\"] = AnalyticsReporter.countBucket(healthInfo.deviceSwitches)"),
            "degraded meeting Sentry events should preserve coarse route-change counts"
        )
        assertTrue(
            reportBlock.contains("context.removeValue(forKey: \"gap_count\")"),
            "raw gap counts inherited from capture diagnostics should be stripped before Sentry context"
        )
        assertTrue(
            reportBlock.contains("context.removeValue(forKey: \"route_change_count\")"),
            "raw route-change counts inherited from capture diagnostics should be stripped before Sentry context"
        )
        assertFalse(
            reportBlock.contains("context[\"gap_count\"] ="),
            "raw gap counts should stay out of degraded meeting Sentry context"
        )
        assertFalse(
            reportBlock.contains("context[\"route_change_count\"] ="),
            "raw route-change counts should stay out of degraded meeting Sentry context"
        )
    }

    runSuite("Repo command contract - queued meetings recover unloaded models before transcription") {
        let controllerContents = readRepoTextFile("Sources/Meeting/MeetingSessionController.swift")
        let downloaderContents = readRepoTextFile("Sources/Meeting/MeetingModelDownloader.swift")

        assertTrue(
            controllerContents.contains("await ensureModelsReadyForQueuedTranscription(job)")
                && controllerContents.contains("runPreparedQueuedTranscription(job)"),
            "queued meeting jobs should load models before entering TranscriptionTaskManager"
        )
        assertTrue(
            controllerContents.contains("downloader.ensureModelsReady(sttModel: job.sttModel)"),
            "queued meeting jobs should reload the STT model selected when the audio was queued"
        )
        assertTrue(
            controllerContents.contains("preparingQueuedTranscriptionJob")
                && controllerContents.contains("isPreparingQueuedTranscriptionStart")
                && controllerContents.contains("preparingQueuedTranscriptionJob?.id == job.id"),
            "model recovery should count as active background work and stale prep tasks must not clear newer queued work"
        )
        let startQueuedBlock = sourceSlice(
            controllerContents,
            from: "private func startQueuedTranscription(_ job: QueuedTranscriptionJob) {",
            to: "private func prepareAndStartQueuedTranscription(_ job: QueuedTranscriptionJob) async {"
        )
        assertTrue(
            startQueuedBlock.contains("recordQueuedTranscriptionRuntimeDiagnosticsIfSafe(for: job)")
                && controllerContents.contains("recordSession(kind: \"meeting\", stage: \"transcribing\")"),
            "each queued meeting start should refresh runtime diagnostics away from the previous terminal outcome"
        )
        assertTrue(
            controllerContents.contains("queuedRuntimeDiagnosticsJobIDs")
                && controllerContents.contains("recordQueuedTranscriptionRuntimeDiagnosticsIfSafe(for: job)")
                && controllerContents.contains("guard !isCaptureSessionActive else { return }"),
            "queued meeting diagnostics should not clobber foreground recording diagnostics"
        )
        assertTrue(
            controllerContents.contains("guard !(sttRouter.isRecording || sttRouter.isTranscribing) else { return }"),
            "queued meeting diagnostics should not clobber foreground dictation diagnostics"
        )
        let queuedRecoveryFailureBlock = sourceSlice(
            controllerContents,
            from: "private func failQueuedTranscriptionJobAfterModelRecovery(_ job: QueuedTranscriptionJob) {",
            to: "private func canStartQueuedTranscriptionImmediately("
        )
        assertTrue(
            queuedRecoveryFailureBlock.contains("clearQueuedTranscriptionRuntimeDiagnosticsIfOwned(for: job, outcome: \"model_recovery_failed\")")
                && controllerContents.contains("queuedRuntimeDiagnosticsJobIDs.remove(job.id)")
                && queuedRecoveryFailureBlock.contains("guard !isCaptureSessionActive else { return }")
                && queuedRecoveryFailureBlock.contains("guard !(sttRouter.isRecording || sttRouter.isTranscribing) else { return }"),
            "queued model recovery failures should clear only the runtime diagnostics session started before recovery"
        )
        assertTrue(
            downloaderContents.contains("func ensureModelsReady(sttModel: TranscriptionModelChoice) async throws")
                && downloaderContents.contains("stt.prepare(model: sttModel)"),
            "meeting model loading should support a queued job's stored speech model"
        )
    }

    runSuite("Repo command contract - imported audio clears runtime diagnostics when models are unavailable") {
        let controllerContents = readRepoTextFile("Sources/Meeting/MeetingSessionController.swift")
        let importBlock = sourceSlice(
            controllerContents,
            from: "func importAudioFile(from sourceURL: URL) async -> Bool {",
            to: "private func importPreparationFailureKind"
        )
        let readinessBlock = sourceSlice(
            importBlock,
            from: "switch state {",
            to: "let preparedAudio: PreparedImportedMeetingAudio"
        )

        assertTrue(
            importBlock.contains("Self.runtimeDiagnosticsRecorder?.recordSession(kind: \"meeting\", stage: \"file_import_requested\")"),
            "imported audio should mark runtime diagnostics while it prepares models and scratch audio"
        )
        assertTrue(
            readinessBlock.contains("case .ready, .transcribing:")
                && readinessBlock.contains("Self.runtimeDiagnosticsRecorder?.clearSession(kind: \"meeting\", outcome: \"models_unavailable\")"),
            "failed imported-audio model prep should clear runtime diagnostics instead of leaving a false active session"
        )
    }

    runSuite("Repo command contract - bridge uses scaled meeting stop timeout") {
        let bridgeContents = readRepoTextFile("Sources/Meeting/MeetingCaptureBridge.swift")
        let stopBlock = sourceSlice(
            bridgeContents,
            from: "func stopAndAwaitFiles(",
            to: "func stopAndDiscardFiles() async -> CaptureStopResult {"
        )

        assertTrue(
            stopBlock.contains("TranscriptedConstants.meetingStopTimeout(")
                && stopBlock.contains("forRecordingDuration: max(recordingDuration, audio.recordingDuration)"),
            "meeting stop should scale the timeout from the observed recording duration"
        )
        assertTrue(
            stopBlock.contains("Task.sleep(nanoseconds: stopTimeout)"),
            "meeting stop should sleep on the scaled timeout, not the fixed base timeout"
        )
        assertTrue(
            stopBlock.contains("onTimedOutCompletion")
                && stopBlock.contains("timedOutStopCompletionHandler"),
            "late audio finalization after a stop timeout should be surfaced to repair retry paths"
        )
    }

    runSuite("Repo command contract - old failed meeting audio is pruned by age") {
        let constantsContents = readRepoTextFile("Sources/Support/TranscriptedConstants.swift")
        let controllerContents = readRepoTextFile("Sources/Meeting/MeetingSessionController.swift")

        assertTrue(
            constantsContents.contains("failedMeetingAudioRetentionDays"),
            "failed meeting audio cleanup should use a named retention constant"
        )
        assertTrue(
            controllerContents.contains("cleanupOldFailedTranscriptions(")
                && controllerContents.contains("TranscriptedConstants.failedMeetingAudioRetentionDays"),
            "MeetingSessionController should prune old failed meeting audio during startup"
        )
    }

    runSuite("Repo command contract - stop-timeout failed meetings refresh Home immediately") {
        let controllerContents = readRepoTextFile("Sources/Meeting/MeetingSessionController.swift")
        let timeoutBlock = sourceSlice(
            controllerContents,
            from: "if stopResult.didTimeOut {",
            to: "let outcome = enqueueTranscriptionJob("
        )
        let helperBlock = sourceSlice(
            controllerContents,
            from: "private func preserveFailedMeetingForRetry(",
            to: "private func refreshFailedMeetings("
        )

        assertTrue(
            timeoutBlock.contains("let preserved = preserveFailedMeetingForRetry("),
            "stop timeouts should route retained audio through the refresh helper before returning"
        )
        assertTrue(
            timeoutBlock.contains("archiveAudio: false"),
            "stop timeouts should keep scratch audio in place because WAV finalization may still be running"
        )
        assertTrue(
            controllerContents.contains("refreshTimedOutFailedMeetingAudio(")
                && controllerContents.contains("promoteFinalizedFailedTranscriptionAudio("),
            "late WAV finalization should promote finalized failed audio before refreshing the failed queue"
        )
        let refreshTimedOutAudioBlock = sourceSlice(
            controllerContents,
            from: "private func refreshTimedOutFailedMeetingAudio(",
            to: "private func refreshFailedMeetings("
        )
        assertTrue(
            refreshTimedOutAudioBlock.contains("let existingFailure = failedManager.failedTranscriptions")
                && refreshTimedOutAudioBlock.contains("let existingMicURL = existingFailure?.micAudioURL")
                && refreshTimedOutAudioBlock.contains("guard let micURL = result.micURL ?? existingMicURL"),
            "late finalization should still promote system-only failed audio by reusing the failed queue mic placeholder"
        )
        assertTrue(
            timeoutBlock.contains("\"preserved_for_retry\": boolString(preserved)"),
            "stop-timeout diagnostics should state whether the retained audio reached the retry queue"
        )
        assertTrue(
            helperBlock.contains("taskManager.addFailedTranscriptionRetainingAvailableAudio(")
                && helperBlock.contains("if preserved {\n            refreshFailedMeetings()"),
            "retained failed-meeting audio should refresh MeetingSessionController.failedMeetings immediately"
        )
        assertTrue(
            controllerContents.contains(".sink { [weak self] failedTranscriptions in\n                self?.refreshFailedMeetings(failedTranscriptions)"),
            "the failed-manager subscription should render the emitted queue instead of re-reading stale @Published state"
        )
        assertFalse(
            controllerContents.contains("taskManager.addFailedTranscriptionRetainingAudio("),
            "MeetingSessionController should not bypass the failed-meeting refresh helper"
        )
        assertEqual(
            countOccurrences(
                of: "taskManager.addFailedTranscriptionRetainingAvailableAudio(",
                in: controllerContents
            ),
            1,
            "direct failed-queue writes in MeetingSessionController should stay centralized in the refresh helper"
        )
    }

    runSuite("Repo command contract - no-speech meetings stay out of Sentry failures") {
        let controllerContents = readRepoTextFile("Sources/Meeting/MeetingSessionController.swift")
        let failureBlock = sourceSlice(
            controllerContents,
            from: "case .failed(let message):",
            to: "if failureKind == .speakerFinalizationFailed"
        )

        assertTrue(
            failureBlock.contains("if failureKind.shouldReportAsSkippedTranscript"),
            "empty/no-speech meeting outcomes should use the canonical skipped-outcome gate"
        )
        assertTrue(
            failureBlock.contains("event: \"meeting_transcript_skipped\""),
            "expected empty/no-speech outcomes should emit the local skipped event"
        )
        assertTrue(
            failureBlock.contains("Self.runtimeDiagnosticsRecorder?.clearSession(kind: \"meeting\", outcome: failureKind.rawValue)"),
            "runtime diagnostics should preserve the concrete skipped failure kind"
        )
        assertFalse(
            failureBlock.contains("event: \"meeting_transcript_failed\""),
            "the skipped-outcome branch should return before the Sentry-allowlisted failure event"
        )
    }

    runSuite("Repo command contract - failed meeting transcripts clear live sidecar final waits") {
        let controllerContents = readRepoTextFile("Sources/Meeting/MeetingSessionController.swift")
        let failureBlock = sourceSlice(
            controllerContents,
            from: "case .failed(let message):",
            to: "case .gettingReady:"
        )
        let helperBlock = sourceSlice(
            controllerContents,
            from: "private func finishLiveCodexSessionForCurrentTranscriptionFailureIfNeeded",
            to: "private func canStartQueuedTranscriptionImmediately("
        )

        assertTrue(
            failureBlock.contains("finishLiveCodexSessionForCurrentTranscriptionFailureIfNeeded"),
            "failed or skipped meeting transcription outcomes should try to stop the owning live sidecar final wait"
        )
        assertTrue(
            countOccurrences(
                of: "finishLiveCodexSessionForCurrentTranscriptionFailureIfNeeded",
                in: failureBlock
            ) >= 3,
            "skipped, speaker-finalization, and generic failed transcript paths should each clear the live sidecar final wait"
        )
        assertTrue(
            helperBlock.contains("failedJobID == awaitedJobID")
                && helperBlock.contains("allowLastSavedTranscriptOwner && taskManager.lastSavedTranscriptTaskId == awaitedJobID"),
            "transcription failures should only fail the live sidecar owned by the active job unless a speaker-finalization failure proves the saved transcript owner"
        )
    }

    runSuite("Repo command contract - shutdown preservation clears live sidecar waits") {
        let controllerContents = readRepoTextFile("Sources/Meeting/MeetingSessionController.swift")
        let terminationBlock = sourceSlice(
            controllerContents,
            from: "func prepareForTermination() async {",
            to: "private func waitForRecordingFinishBeforeTermination() async {"
        )

        assertTrue(
            terminationBlock.contains("let shouldFailPendingLiveHandoff = queuedPreserved > 0")
                && terminationBlock.contains("|| liveCodexSessionAwaitingFinalTranscript")
                && terminationBlock.contains("if shouldFailPendingLiveHandoff")
                && terminationBlock.contains("finishLiveCodexSession(status: .failed, shouldAwaitFinalTranscript: false)"),
            "shutdown should fail any pending live sidecar handoff instead of leaving agents waiting after retry or speaker review state is lost"
        )
        assertTrue(
            terminationBlock.contains("activeQueuedTranscriptionJobID = nil"),
            "shutdown preservation should clear the active queued job owner used for live sidecar final attachment"
        )
        assertTrue(
            terminationBlock.contains("let shutdownFailedTaskId = UUID()")
                && terminationBlock.contains("capture.stopAndAwaitFiles {")
                && terminationBlock.contains("refreshTimedOutFailedMeetingAudio("),
            "shutdown stop timeouts should keep the same late-finalization repair path as normal meeting stops"
        )
        assertTrue(
            terminationBlock.contains("taskId: shutdownFailedTaskId")
                && terminationBlock.contains("archiveAudio: !files.didTimeOut"),
            "shutdown stop timeouts should keep unfinished scratch audio in place until late finalization can promote it"
        )
    }

    runSuite("Repo command contract - transcription cancellation clears live sidecar waits") {
        let controllerContents = readRepoTextFile("Sources/Meeting/MeetingSessionController.swift")
        let cancelBlock = sourceSlice(
            controllerContents,
            from: "func cancelActiveTranscription(reason: TranscriptionCancelReason = .unknown) {",
            to: "func prepareForTermination() async {"
        )

        assertTrue(
            cancelBlock.contains("if liveCodexSessionAwaitingFinalTranscript")
                && cancelBlock.contains("finishLiveCodexSession(status: .failed, shouldAwaitFinalTranscript: false)"),
            "cancelling the owning transcription should fail the pending live sidecar handoff instead of leaving agents waiting forever"
        )
        assertTrue(
            cancelBlock.contains("activeQueuedTranscriptionJobID = nil"),
            "transcription cancellation should clear the queued job owner used for live sidecar final attachment"
        )
    }

    runSuite("Repo command contract - live sidecar attaches only its queued meeting") {
        let controllerContents = readRepoTextFile("Sources/Meeting/MeetingSessionController.swift")
        let taskManagerContents = readRepoTextFile("Sources/TranscriptedCore/Pipeline/TranscriptionTaskManager.swift")
        let startBlock = sourceSlice(
            controllerContents,
            from: "private func startLiveCodexSessionIfNeeded",
            to: "private func finishLiveCodexSession"
        )
        let recordedEnqueueBlock = sourceSlice(
            controllerContents,
            from: "private func enqueueTranscriptionJob(",
            to: "private func enqueueImportedAudioJob("
        )
        let attachBlock = sourceSlice(
            controllerContents,
            from: "private func attachLiveCodexFinalTranscriptIfReady",
            to: "private func refreshWarmupStatus"
        )

        assertTrue(
            startBlock.contains("liveCodexSessionCanAttachFinalTranscript = true"),
            "deferred live ASR should still allow the normal final Transcripted Markdown to attach"
        )
        assertFalse(
            startBlock.contains("liveCodexSessionCanAttachFinalTranscript = canStartLiveBackend"),
            "final transcript handoff should not depend on whether the provisional live ASR backend started"
        )
        assertTrue(
            recordedEnqueueBlock.contains("liveCodexAwaitedTranscriptionJobID = job.id"),
            "a stopped live sidecar should remember the exact recorded job that owns its final transcript"
        )
        assertTrue(
            startBlock.contains("guard !liveCodexSessionAwaitingFinalTranscript")
                && startBlock.contains("live_codex_session_deferred_pending_handoff"),
            "starting another meeting should not overwrite a sidecar that is still waiting for its final transcript handoff"
        )
        assertTrue(
            recordedEnqueueBlock.contains("liveCodexFinalTranscriptNeedsQueuedJobID && liveCodexSessionAwaitingFinalTranscript"),
            "only the recording that stopped an owned sidecar should assign the next queued transcript job as its final handoff owner"
        )
        assertTrue(
            attachBlock.contains("taskManager.hasPendingSpeakerNamingReviewForLastSavedTranscript()"),
            "the live sidecar should wait for local speaker review before telling agents the final Markdown is ready"
        )
        assertTrue(
            attachBlock.contains("taskManager.lastSavedTranscriptTaskId == awaitedJobID"),
            "the live sidecar should attach only a saved URL published by its exact transcription job"
        )
        assertTrue(
            taskManagerContents.contains("@Published public private(set) var lastSavedTranscriptTaskId: UUID? = nil")
                && taskManagerContents.contains("public func startTranscription(\n        taskId: UUID = UUID(),")
                && taskManagerContents.contains("populateSavedMetadata(from: transcriptURL, taskId: taskId)"),
            "TranscriptedCore should publish the owner task for saved-transcript URL handoff"
        )
        assertTrue(
            taskManagerContents.contains("savedTranscriptTaskIdsByTranscriptId")
                && taskManagerContents.contains("savedTranscriptTaskIdsByURL")
                && taskManagerContents.contains("rememberSavedTranscriptOwner("),
            "TranscriptedCore should preserve the saved-transcript owner across speaker-review rewrites, even after another transcript saves"
        )
        assertTrue(
            controllerContents.contains("taskManager.startTranscription(\n                taskId: job.id,"),
            "the app queue id should be passed into TranscriptedCore so the saved-transcript owner matches the awaited live handoff job"
        )
    }

    runSuite("Repo command contract - live meeting preview stays same-origin only") {
        let serverContents = readRepoTextFile("Sources/Meeting/LiveMeetingPreviewServer.swift")
        let fileResponseBlock = sourceSlice(
            serverContents,
            from: "private func fileResponse(",
            to: "private func currentWorkspaceURL()"
        )

        assertFalse(
            serverContents.contains("Access-Control-Allow-Origin"),
            "loopback live transcript preview should not allow arbitrary browser origins to read meeting state"
        )
        assertFalse(
            fileResponseBlock.contains("ensureWorkspaceFiles"),
            "preview polling should read the sidecar files without rewriting live transcript state"
        )
        assertTrue(
            serverContents.contains("startupSemaphore.wait")
                && serverContents.contains("case .failed(let error):")
                && serverContents.contains("throw error"),
            "preview server start should only return the loopback URL after the listener becomes ready or should surface startup failure"
        )
        assertTrue(
            serverContents.contains("isAllowedHost(request.headers[\"host\"])")
                && serverContents.contains("\"127.0.0.1\"")
                && serverContents.contains("\"localhost\"")
                && serverContents.contains("\"[::1]\"")
                && serverContents.contains("403 Forbidden"),
            "preview server should reject DNS-rebinding Host headers before serving live meeting files"
        )
        assertTrue(
            serverContents.contains("isAuthorizedPreviewRequest(token: request.queryItems[\"token\"])")
                && serverContents.contains("previewAuthTokenFilename")
                && serverContents.contains("401 Unauthorized"),
            "preview server should require the sidecar auth token before serving private live meeting files"
        )
    }

    runSuite("Repo command contract - Home attention summary includes failed meetings") {
        let settingsContents = readRepoTextFile("Sources/UI/Settings/TranscriptedSettingsView.swift")
        let needsAttentionBlock = sourceSlice(
            settingsContents,
            from: "private var homeNeedsAttentionIssues: [HomeNeedsAttentionCard.Issue] {",
            to: "private var homeMeetingDaySections:"
        )

        assertTrue(
            needsAttentionBlock.contains("!meetingSession.failedMeetings.isEmpty"),
            "failed meetings should contribute to the Home Needs Attention summary"
        )
        assertTrue(
            needsAttentionBlock.contains("destination: .failedMeetings"),
            "the Home Needs Attention failed-meeting issue should jump to the failed meetings section"
        )
    }

    runSuite("Repo command contract - mic recovery merge streams long segments") {
        let mergerContents = readRepoTextFile("Sources/TranscriptedCore/Audio/MicRecordingFileMerger.swift")

        assertFalse(
            mergerContents.contains("AudioResampler.loadAndResample"),
            "mic segment merge should not load full long recordings into memory during stop"
        )
        assertTrue(
            mergerContents.contains("converter.convert(to: outputBuffer"),
            "mic segment merge should stream conversion into bounded output buffers"
        )
    }

    runSuite("Repo command contract - dictation joins existing model downloads") {
        let overlayContents = readRepoTextFile("Sources/UI/Overlay/DictationSessionController.swift")
        let engineContents = readRepoTextFile("Sources/Speech/ParakeetEngine.swift")
        assertTrue(
            overlayContents.contains("case .notLoaded, .downloading, .cached, .failed:"),
            "dictation start should join an in-progress model file prefetch instead of waiting forever for ready"
        )
        assertTrue(
            engineContents.contains("private var modelInitializationTask: Task<Void, Never>?")
                && engineContents.contains("await modelInitializationTask.value"),
            "Parakeet initialization should join an in-progress direct first-use download/load"
        )
    }

    runSuite("Repo command contract - CoreML inference outputs stay locally owned") {
        let engineContents = readRepoTextFile("Sources/Speech/ParakeetEngine.swift")
        let whisperContents = readRepoTextFile("Sources/Speech/WhisperEngine.swift")
        let diarizationContents = readRepoTextFile("Sources/TranscriptedCore/Services/DiarizationService.swift")

        assertTrue(
            engineContents.contains("runASRInference(")
                && engineContents.contains("beginASRInference()")
                && engineContents.contains("finishASRInference()"),
            "meeting segment ASR should mark CoreML inference active so cleanup cannot release the manager mid-prediction"
        )
        assertTrue(
            diarizationContents.contains("withExtendedLifetime(result)")
                && diarizationContents.contains("embedding.map { $0 }"),
            "diarization should copy CoreML-backed embeddings into plain Swift arrays before returning segments"
        )
        assertFalse(
            engineContents.contains("corrected.prefix(80)") || whisperContents.contains("trimmed.prefix(80)"),
            "local STT success logs should report counts and timing, not transcript snippets"
        )
    }

    runSuite("Repo command contract - meeting ASR does not block dictation state") {
        let engineContents = readRepoTextFile("Sources/Speech/ParakeetEngine.swift")
        guard
            let pureStart = engineContents.range(of: "private func beginPureSampleTranscriptionActivity()"),
            let inferenceStart = engineContents.range(of: "private func beginASRInference()", range: pureStart.upperBound..<engineContents.endIndex),
            let runStart = engineContents.range(of: "private func runASRInference(", range: inferenceStart.upperBound..<engineContents.endIndex)
        else {
            assertionFailure("ParakeetEngine should keep pure-sample and ASR inference helpers")
            return
        }

        let pureAndInferenceHelpers = String(engineContents[pureStart.lowerBound..<runStart.lowerBound])
        assertFalse(
            pureAndInferenceHelpers.contains("isTranscribing = true") || pureAndInferenceHelpers.contains("isTranscribing = false"),
            "meeting/import pure-sample ASR should not flip the published dictation transcribing flag"
        )
    }

    runSuite("Repo command contract - saved meeting retranscription respects dictation activity") {
        let controllerContents = readRepoTextFile("Sources/Meeting/MeetingSessionController.swift")
        assertTrue(
            controllerContents.contains("guard !(sttRouter.isRecording || sttRouter.isTranscribing)"),
            "saved meeting re-transcription should enforce the dictation-active guard at the controller entry point"
        )
        guard
            let functionStart = controllerContents.range(of: "func retranscribeSavedMeeting("),
            let functionEnd = controllerContents.range(of: "func dismissFailedMeeting", range: functionStart.upperBound..<controllerContents.endIndex)
        else {
            assertionFailure("MeetingSessionController should keep a saved-meeting re-transcription entry point")
            return
        }

        let functionBody = String(controllerContents[functionStart.lowerBound..<functionEnd.lowerBound])
        assertTrue(
            functionBody.contains("splitLocalSpeakers: true"),
            "saved meeting re-transcription should force the speaker-ID pass instead of depending on the global local-speaker preference"
        )
        assertFalse(
            functionBody.contains("splitLocalSpeakers: LocalSpeakerPreferences.isEnabled()"),
            "the saved-meeting Identify speakers action should not silently do a single-speaker mic retry when the preference is off"
        )
    }

    runSuite("Repo command contract - replacement retranscription cancellation keeps original transcript") {
        let runnerContents = readRepoTextFile("Sources/TranscriptedCore/Pipeline/TranscriptionPipelineRunner.swift")
        let managerContents = readRepoTextFile("Sources/TranscriptedCore/Pipeline/TranscriptionTaskManager.swift")

        assertTrue(
            managerContents.contains("targetTranscriptURL: replacementTranscriptURL")
                && managerContents.contains("archiveRecordingAudio: replacementTranscriptURL == nil"),
            "saved-audio replacement should overwrite the selected transcript without archiving duplicate retained audio"
        )
        assertTrue(
            runnerContents.contains("let replacementTranscriptRollback = try ReplacementTranscriptRollback.capture(for: targetTranscriptURL)")
                && runnerContents.contains("let transcriptId = replacementTranscriptRollback?.transcriptId ?? UUID()"),
            "replacement retranscription should snapshot the selected transcript and reuse its existing ID"
        )
        assertTrue(
            runnerContents.contains("replacementTranscriptRollback: replacementTranscriptRollback")
                && runnerContents.contains("replacementTranscriptRollback.restore()"),
            "replacement retranscription cancellation should restore the selected original transcript"
        )
        assertTrue(
            runnerContents.contains("let originalFileDates = OriginalFileDates.capture(for: targetURL)")
                && runnerContents.contains("originalFileDates?.restore(to: url)"),
            "replacement retranscription rollback should preserve the selected transcript's file dates for Home ordering"
        )
        assertTrue(
            runnerContents.contains("speakerClipURLs: namingEntries.map(\\.clipURL),\n                deleteSavedTranscriptOnCancellation: deleteSavedTranscriptOnCancellation,\n                replacementTranscriptRollback: replacementTranscriptRollback"),
            "replacement retranscription cancellation during speaker clip extraction should restore the selected original transcript"
        )
        assertTrue(
            runnerContents.contains("if deleteSavedTranscript {")
                && runnerContents.contains("try? FileManager.default.removeItem(at: savedURL)"),
            "new cancelled transcripts should still be removed when they are not replacing an existing file"
        )
    }

    runSuite("Repo command contract - replacement stats do not double-count existing recordings") {
        let statsContents = readRepoTextFile("Sources/TranscriptedCore/Stats/StatsDatabase.swift")

        assertTrue(
            statsContents.contains("let existing = recordingMetadataImpl(id: metadata.id)\n                ?? recordingMetadataImpl(transcriptPath: metadata.transcriptPath)")
                && statsContents.contains("updateDailyActivityForSessionChange(from: existing, to: storedMetadata)"),
            "stats recording should detect same-ID and same-path replacements before updating daily totals"
        )
        assertTrue(
            statsContents.contains("recordingCountDelta: 0")
                && statsContents.contains("durationDelta: metadata.durationSeconds - existing.durationSeconds"),
            "same-day replacement stats should adjust duration without incrementing recording count"
        )
    }

    runSuite("Repo command contract - replacement retranscription clears stale local summaries") {
        let controllerContents = readRepoTextFile("Sources/Meeting/MeetingSessionController.swift")
        let managerContents = readRepoTextFile("Sources/TranscriptedCore/Pipeline/TranscriptionTaskManager.swift")
        let settingsContents = readRepoTextFile("Sources/UI/Settings/TranscriptedSettingsView.swift")
        let summaryContents = readRepoTextFile("Sources/Meeting/LocalMeetingSummarizer.swift")

        assertTrue(
            managerContents.contains("onReplacementTranscriptCommitted")
                && managerContents.contains("if replacementTranscriptURL != nil {\n                        onReplacementTranscriptCommitted?(transcriptURL)"),
            "Core should notify the app after a replacement transcript commits"
        )
        assertTrue(
            controllerContents.contains("onReplacementTranscriptCommitted:")
                && controllerContents.contains("handleReplacementTranscriptCommitted")
                && controllerContents.contains("savedMeetingReplacementCommitCount &+= 1"),
            "saved-meeting replacement should clear stale local summary sidecars and emit a same-URL refresh signal after commit"
        )
        assertTrue(
            settingsContents.contains(".onChange(of: meetingSession.savedMeetingReplacementCommitCount)")
                && settingsContents.contains("speakerPeopleModel.refresh()"),
            "Settings Home should refresh meeting rows and speaker review state after same-URL replacement retranscription"
        )
        assertTrue(
            summaryContents.contains("static func removeGeneratedSummary")
                && summaryContents.contains("values[\"capture_type\"] == \"meeting_summary\"")
                && summaryContents.contains("values[\"source_transcript\"] == transcriptURL.lastPathComponent"),
            "local summary cleanup should only remove generated summaries for the matching transcript"
        )
    }

    runSuite("Repo command contract - Home failed meeting actions surface failures") {
        let settingsContents = readRepoTextFile("Sources/UI/Settings/TranscriptedSettingsView.swift")
        let controllerContents = readRepoTextFile("Sources/Meeting/MeetingSessionController.swift")
        let managerContents = readRepoTextFile("Sources/TranscriptedCore/Services/FailedTranscriptionManager.swift")

        assertTrue(
            controllerContents.contains("func retryFailedMeeting(id: UUID) -> Bool"),
            "failed-meeting retry should report whether the retry started"
        )
        assertTrue(
            controllerContents.contains("func dismissFailedMeeting(id: UUID) -> Bool")
                && controllerContents.contains("func deleteFailedMeeting(id: UUID) -> Bool"),
            "failed-meeting clear actions should report whether the queue changed"
        )
        assertTrue(
            managerContents.contains("public func removeFailedTranscription(id: UUID) -> Bool")
                && managerContents.contains("public func deleteFailedTranscription(id: UUID) -> Bool"),
            "failed-queue manager deletes should return persistence results instead of fire-and-forget"
        )
        assertTrue(
            settingsContents.contains("retryFailedMeeting(item)")
                && settingsContents.contains("let didStart = meetingSession.retryFailedMeeting(id: item.id)")
                && settingsContents.contains("title: \"Could not retry meeting\""),
            "Home retry clicks should surface immediate retry blockers"
        )
        assertTrue(
            settingsContents.contains("let didClear: Bool")
                && settingsContents.contains("didClear = meetingSession.deleteFailedMeeting(id: item.id)")
                && settingsContents.contains("didClear = meetingSession.dismissFailedMeeting(id: item.id)")
                && settingsContents.contains("if !didClear"),
            "Home delete/dismiss clicks should surface failed queue updates"
        )
    }

    runSuite("Repo command contract - Paste Last Dictation uses the paste target guard") {
        let menuContents = readRepoTextFile("Sources/UI/MenuBar/MenuBarPanelController.swift")
        let appContents = readRepoTextFile("Sources/TranscriptedApp.swift")

        assertTrue(
            menuContents.contains("let pasteTarget = DictationPasteTarget.capture(sourceApp: sourceApp)")
                && menuContents.contains("textPaster.paste(latestText, target: pasteTarget)"),
            "menu Paste Last Dictation should copy instead of pasting if focus moves away from the source app"
        )
        assertTrue(
            appContents.contains("let pasteTarget = DictationPasteTarget.capture(sourceApp: sourceApp)")
                && appContents.contains("settingsTextPaster.paste(latestText, target: pasteTarget)"),
            "settings Paste Last Dictation should use the same focus guard as normal dictation paste"
        )
    }

    runSuite("Repo command contract - repeated quit requests get AppKit replies") {
        let appContents = readRepoTextFile("Sources/TranscriptedApp.swift")

        assertTrue(
            appContents.contains("private var pendingTerminationReplyCount = 0"),
            "termination cleanup should track every deferred quit request"
        )
        assertTrue(
            appContents.contains("pendingTerminationReplyCount += 1\n            return .terminateLater"),
            "repeat quit requests during cleanup should be deferred with a later reply"
        )
        assertTrue(
            appContents.contains("pendingTerminationReplyCount = 1"),
            "the first deferred quit request should be counted before cleanup starts"
        )
        assertTrue(
            appContents.contains("replyToPendingTerminationRequests(sender, shouldTerminate: true)"),
            "termination cleanup should reply to every deferred quit request"
        )
        assertTrue(
            appContents.contains("if terminationCleanupFinished {\n            return .terminateNow\n        }"),
            "quit requests after cleanup should complete immediately"
        )
    }

    runSuite("Repo command contract - consolidated settings deep links expand their General section") {
        let windowControllerContents = readRepoTextFile("Sources/UI/Settings/TranscriptedSettingsWindowController.swift")
        let navigationContents = readRepoTextFile("Sources/UI/Settings/TranscriptedSettingsNavigationModel.swift")
        let viewContents = readRepoTextFile("Sources/UI/Settings/TranscriptedSettingsView.swift")

        assertTrue(
            navigationContents.contains("var presentedPage: TranscriptedSettingsPage")
                && windowControllerContents.contains("navigationModel.presentedPage = page"),
            "settings presentation should retain the originally requested page before consolidating to General"
        )
        assertTrue(
            viewContents.contains("expandGeneralDisclosureForPresentedPage()")
                && viewContents.contains("case .models:")
                && viewContents.contains("showGeneralModelSettings = true")
                && viewContents.contains("case .shortcuts:")
                && viewContents.contains("showGeneralShortcutSettings = true")
                && viewContents.contains("case .privacy:")
                && viewContents.contains("showGeneralPrivacySettings = true"),
            "legacy settings deep links should reveal their matching consolidated General controls"
        )
    }

    runSuite("Repo command contract - agent todo runner cleans unauthorized queued issues") {
        let contents = readRepoTextFile("scripts/ops/agent-todo-runner.rb")
        assertTrue(
            contents.contains("issues.select { |issue| active_issue?(issue) || unauthorized_active_issue?(issue) }"),
            "runner should fetch unauthorized active issues so handle_issue can remove agent labels"
        )
        assertTrue(
            contents.contains("def unauthorized_active_issue?(issue)"),
            "runner should keep unauthorized active issue detection explicit"
        )
    }

    runSuite("Repo command contract - GitHub agent surfaces stay preflight-visible") {
        let matrix = readRepoTextFile(".agents/test-matrix.yml")
        let preflight = readRepoTextFile("scripts/dev/agent-preflight.sh")
        let agentTemplate = readRepoTextFile(".github/ISSUE_TEMPLATE/agent_task.md")
        let bugTemplate = readRepoTextFile(".github/ISSUE_TEMPLATE/bug_report.md")
        let featureTemplate = readRepoTextFile(".github/ISSUE_TEMPLATE/feature_request.md")
        let prTemplate = readRepoTextFile(".github/PULL_REQUEST_TEMPLATE.md")
        let repoHygieneWorkflow = readRepoTextFile(".github/workflows/repo-hygiene.yml")
        let qaGateAutoClose = readRepoTextFile(".github/workflows/qa-gate-auto-close-bet88.yml")
        let qaGateStatus = readRepoTextFile(".github/workflows/qa-gate-status-bet88.yml")
        let workflow = readRepoTextFile("WORKFLOW.md")
        let orchestration = readRepoTextFile("docs/agent-issue-orchestration.md")

        assertTrue(
            matrix.contains("\".github/**\"")
                && matrix.contains("\"WORKFLOW.md\"")
                && matrix.contains("\"Tools/README.md\"")
                && matrix.contains("\"scripts/dev/agent-preflight.sh\"")
                && matrix.contains("ruby -c scripts/ops/agent-todo-runner.rb")
                && matrix.contains("bash -n scripts/ops/qa-gate-check.sh"),
            "test matrix should treat GitHub templates, workflow contract, and preflight script as agent-contract surfaces"
        )
        assertTrue(
            preflight.contains("\".github/*\"")
                && preflight.contains("\"WORKFLOW.md\"")
                && preflight.contains("\"Tools/README.md\"")
                && preflight.contains("\"scripts/dev/agent-preflight.sh\"")
                && preflight.contains("ruby -c scripts/ops/agent-todo-runner.rb")
                && preflight.contains("bash -n scripts/ops/qa-gate-check.sh"),
            "agent preflight should suggest itself when GitHub templates or workflow docs change"
        )
        assertTrue(
            agentTemplate.contains("does not start the local runner by itself")
                && agentTemplate.contains("`agent todo` label"),
            "agent issue template should make the manual queue label explicit"
        )
        assertTrue(
            agentTemplate.contains("Activation / saved artifacts / agent payoff")
                && agentTemplate.contains("docs/activation-lane.md")
                && agentTemplate.contains("COORD_DONE: GREEN/BRIEF/RED"),
            "agent issue template should make lane selection and coordinator closeout explicit"
        )
        assertTrue(
            bugTemplate.contains("Please redact transcripts, audio, meeting titles, speaker names, emails, tokens")
                && featureTemplate.contains("Please do not include private transcripts, audio, meeting titles, speaker names"),
            "public issue templates should put privacy redaction guidance where users attach diagnostics"
        )
        assertTrue(
            prTemplate.contains("`scripts/dev/agent-preflight.sh`")
                && prTemplate.contains("Selected checks from `.agents/test-matrix.yml`")
                && prTemplate.contains("`swift test` if I touched `Package.swift`, `Sources/TranscriptedCore/`, or the public core seam")
                && prTemplate.contains("Lane: `activation` / `dictation reliability` / `meeting reliability` / `release ops` / `agent workflow`")
                && prTemplate.contains("COORD_DONE: GREEN/BRIEF/RED")
                && prTemplate.contains("Agent PRs link the issue/workpad")
                && prTemplate.contains("No private transcripts, audio, tokens, personal paths, or customer data"),
            "PR template should point reviewers at preflight, core package checks, agent review evidence, and privacy review"
        )
        assertTrue(
            repoHygieneWorkflow.contains("on:\n  pull_request:")
                && repoHygieneWorkflow.contains("bash scripts/dev/agent-preflight.sh origin/main")
                && repoHygieneWorkflow.contains("ruby -c scripts/ops/agent-todo-runner.rb")
                && repoHygieneWorkflow.contains("python3 -m py_compile scripts/ops/nightly-security-check.py"),
            "repo should have a lightweight pull_request hygiene workflow for repo plumbing"
        )
        assertTrue(
            qaGateAutoClose.contains("contains(github.event.issue.labels.*.name, 'qa-gate-auto-close')")
                && qaGateAutoClose.contains("Historical BET-88/#428 fixture")
                && qaGateStatus.contains("Historical BET-88/#428 fixture")
                && !qaGateAutoClose.contains("child_issue_number"),
            "old BET-88 auto-close workflow should be label-gated and should not mutate a hard-coded child issue"
        )
        assertTrue(
            workflow.contains("symphony-workspaces` folder name is historical")
                && orchestration.contains("symphony-workspaces` name is historical"),
            "agent issue workflow docs should explain the historical local workspace folder name"
        )
    }

    runSuite("Repo command contract - activation lane and closeout docs stay linked") {
        let agentStart = readRepoTextFile("AGENT_START.md")
        let onboarding = readRepoTextFile("docs/agent-onboarding.md")
        let repoLayout = readRepoTextFile("docs/repo-layout.md")
        let activation = readRepoTextFile("docs/activation-lane.md")
        let closeout = readRepoTextFile("docs/agent-closeout.md")
        let workflow = readRepoTextFile("WORKFLOW.md")
        let agents = readRepoTextFile("AGENTS.md")
        let preflight = readRepoTextFile("scripts/dev/agent-preflight.sh")

        assertTrue(
            agentStart.contains("Activation/artifacts/agent payoff - `docs/activation-lane.md`")
                && agentStart.contains("Bluetooth/AirPods dictation")
                && agentStart.contains("Zoom/Meet prompts")
                && agentStart.contains("Pasteback/clipboard/Auto Enter"),
            "agent start should route common current product lanes to the right docs"
        )
        assertTrue(
            onboarding.contains("## Choose The Lane")
                && onboarding.contains("docs/activation-lane.md")
                && onboarding.contains("docs/agent-closeout.md"),
            "agent onboarding should tell workers how to classify vague work before editing"
        )
        assertTrue(
            repoLayout.contains("docs/activation-lane.md")
                && repoLayout.contains("docs/agent-closeout.md")
                && repoLayout.contains("docs/agent-connect.md")
                && repoLayout.contains("Casks/")
                && repoLayout.contains("Dated audit and autoeval docs in `docs/` are point-in-time evidence"),
            "repo layout should list activation, handoff, agent-connect, Homebrew, and point-in-time audit surfaces"
        )
        assertTrue(
            onboarding.contains("Sources/TranscriptedCore/Pipeline/TranscriptionTaskManager.swift")
                && onboarding.contains("Sources/TranscriptedCore/Audio/Audio.swift"),
            "agent onboarding should flag the large Core coordination files alongside the app mega-files"
        )
        assertTrue(
            activation.contains("saved Markdown -> agent use -> return")
                && activation.contains("Sources/Observability/ActivationTelemetry.swift")
                && activation.contains("Do not claim activation is fixed from artifact volume alone"),
            "activation lane doc should keep product payoff and privacy-safe measurement explicit"
        )
        assertTrue(
            closeout.contains("COORD_DONE: GREEN/BRIEF/RED")
                && agents.contains("COORD_DONE: GREEN/BRIEF/RED")
                && preflight.contains("COORD_DONE: GREEN/BRIEF/RED")
                && closeout.contains("delete branches, close issues")
                && workflow.contains("docs/agent-closeout.md"),
            "closeout docs and workflow should keep delegated handoff and GitHub mutation boundaries explicit"
        )
    }

    runSuite("Repo command contract - onboarding agent copy remains measurable") {
        let contents = readRepoTextFile("Sources/UI/Settings/PermissionsOnboardingView.swift")
        assertTrue(
            contents.contains("AnalyticsReporter.track(\n            \"onboarding_agent_cta_clicked\""),
            "copying onboarding agent setup should emit the existing first-value activation event"
        )
        assertTrue(
            contents.contains("\"agent_cta\": agentCTA") && contents.contains("\"step_id\": \"connect_agent\""),
            "onboarding agent setup telemetry should stay limited to coarse CTA and step ids"
        )
        assertFalse(
            contents.contains("AgentConnectionGuide.starterPrompt(filename: nil)\n        AnalyticsReporter.track"),
            "onboarding telemetry should not send copied prompt text"
        )
    }

    runSuite("Repo command contract - onboarding shown telemetry stays coarse") {
        let appContents = readRepoTextFile("Sources/TranscriptedApp.swift")
        let windowContents = readRepoTextFile("Sources/UI/Settings/TranscriptedOnboardingWindowController.swift")

        assertTrue(
            appContents.contains("AnalyticsReporter.track(\n            \"onboarding_shown\""),
            "showing first-run onboarding should emit the existing activation funnel denominator"
        )
        assertTrue(
            appContents.contains("\"entrypoint\": entrypoint")
                && appContents.contains("\"has_target\": lastExternalApplication == nil ? \"false\" : \"true\"")
                && appContents.contains("\"model_state\": modelStateAnalyticsName(appState.sttRouter.modelDownloadState)")
                && appContents.contains("\"pasteback_status\": TranscriptedPermissionAccess.isGranted(.accessibility) ? \"granted\" : \"not_granted\""),
            "onboarding_shown should stay limited to coarse setup state"
        )
        assertTrue(
            windowContents.contains("let wasVisible = window.isVisible")
                && windowContents.contains("if !wasVisible {")
                && windowContents.contains("onPresent(entrypoint)"),
            "onboarding_shown should not fire repeatedly while the onboarding window is already visible"
        )
        assertFalse(
            appContents.contains("\"source_app_name\"")
                || appContents.contains("\"source_app_bundle_id\""),
            "onboarding_shown telemetry should not include source app names or bundle ids"
        )
    }

    runSuite("Repo command contract - onboarding funnel telemetry is wired from the active view") {
        let contents = readRepoTextFile("Sources/UI/Settings/PermissionsOnboardingView.swift")

        assertTrue(
            contents.contains("trackCurrentStepViewed()")
                && contents.contains("onboarding_step_viewed")
                && contents.contains("\"step_id\": currentStep.kind.analyticsID")
                && contents.contains("\"step_index\": String(currentStepIndex)"),
            "active onboarding should emit coarse step views so first-run funnel drop-off is measurable"
        )
        assertTrue(
            contents.contains("onboarding_primary_cta_clicked")
                && contents.contains("\"cta\": primaryCTAAnalyticsID")
                && contents.contains("\"cta_type\": \"primary\"")
                && contents.contains("\"step_elapsed_bucket\": stepElapsedBucket(now: now)"),
            "active onboarding should emit coarse primary CTA clicks without raw button copy"
        )
        assertTrue(
            contents.contains("onboarding_permission_cta_clicked")
                && contents.contains("kind.analyticsValue")
                && contents.contains("\"prior_status\": permissionStatus(for: kind)")
                && contents.contains("\"required\": required ? \"true\" : \"false\""),
            "active onboarding permission CTAs should keep only permission enum and coarse status"
        )
        assertTrue(
            contents.contains("onboarding_permission_status_changed")
                && contents.contains("\"from_status\": previous")
                && contents.contains("\"to_status\": updated"),
            "active onboarding should emit permission status changes after macOS grants are observed"
        )
        assertFalse(
            contents.contains("\"source_app_name\"")
                || contents.contains("\"source_app_bundle_id\"")
                || contents.contains("\"transcript\"")
                || contents.contains("\"audio_path\""),
            "onboarding funnel telemetry should not include sensitive app, transcript, or audio fields"
        )
    }

    runSuite("Repo command contract - home stats action uses parent presenter") {
        let homeContents = readRepoTextFile("Sources/UI/Settings/HomeView.swift")
        let settingsContents = readRepoTextFile("Sources/UI/Settings/TranscriptedSettingsView.swift")
        assertTrue(
            homeContents.contains("Label(\"View stats\", systemImage: \"info.circle\")"),
            "home stats should keep a visible View stats action"
        )
        assertTrue(
            homeContents.contains("let onViewStats: () -> Void")
                && homeContents.contains("onViewStats()")
                && settingsContents.contains("@State private var homeShowsStatsDetails = false")
                && settingsContents.contains(".sheet(isPresented: $homeShowsStatsDetails)")
                && settingsContents.contains("HomeStatsDetailSheet("),
            "home stats should route View stats through the parent settings sheet presenter"
        )
        assertFalse(
            homeContents.contains("@State private var isShowingDetails")
                || homeContents.contains(".sheet(isPresented: $isShowingDetails")
                || homeContents.contains(".popover(isPresented: $isShowingDetails"),
            "home stats badge should not own its own details presentation state"
        )
    }

    runSuite("Repo command contract - Home meeting deletion hashes audio only after metadata candidates") {
        let deletionContents = readRepoTextFile("Sources/UI/Shared/HomeMeetingDeletion.swift")
        let duplicateBlock = sourceSlice(
            deletionContents,
            from: "private static func duplicateRetainedAudioMeetings",
            to: "private static func isAppOwnedMeetingTranscript"
        )
        let preScanBlock = sourceSlice(
            deletionContents,
            from: "private static func duplicateRetainedAudioMeetings",
            to: "let meetingsDirectory"
        )

        assertFalse(
            preScanBlock.contains("audioSignature(for: selectedAudio)"),
            "Home delete should not hash selected retained audio before checking app-owned same-title candidates"
        )
        assertTrue(
            duplicateBlock.contains("var candidates: [(URL, MeetingAudioAttachment)]")
                && duplicateBlock.contains("guard !candidates.isEmpty,\n              let selectedSignature = audioSignature(for: selectedAudio)"),
            "Home delete should collect cheap metadata candidates before hashing retained audio"
        )
    }

    runSuite("Repo command contract - Home meeting deletion runs off the Settings UI path") {
        let settingsContents = readRepoTextFile("Sources/UI/Settings/TranscriptedSettingsView.swift")
        let deleteBlock = sourceSlice(
            settingsContents,
            from: "private func deleteMeeting(_ item: RecentMeetingItem)",
            to: "private func failedMeetingAudioAttachment"
        )

        assertTrue(
            deleteBlock.contains("HomeMeetingDeletion.plan(for: item)")
                && deleteBlock.contains("MeetingAudioPlayback.shared.stopIfActive(attachmentIDs: Set(plan.audioAttachmentIDs))"),
            "Home delete should stop retained-audio playback only when the active attachment is part of the planned deletion"
        )
        assertTrue(
            deleteBlock.contains("Task.detached(priority: .userInitiated)") &&
                deleteBlock.contains("try HomeMeetingDeletion.delete(plan)") &&
                deleteBlock.contains("_ = try await deletionTask.value"),
            "Home delete should run filesystem cleanup away from the main Settings UI path"
        )
    }

    runSuite("Repo command contract - Agent setup details has an explicit toggle") {
        let contents = readRepoTextFile("Sources/UI/Settings/AgentConnectionSettingsPage.swift")

        assertTrue(
            contents.contains("AgentSetupDetailsDisclosure(isExpanded: $showAdvancedAgentSetup)"),
            "Agent settings should use the explicit setup-details toggle row"
        )
        assertTrue(
            contents.contains("private struct AgentSetupDetailsDisclosure<Content: View>"),
            "Agent setup-details disclosure should stay owned by a dedicated view"
        )
        assertTrue(
            contents.contains("withAnimation(.snappy(duration: 0.18)) {\n                    isExpanded.toggle()"),
            "Agent setup-details disclosure should toggle its expansion state directly"
        )
        assertFalse(
            contents.contains("DisclosureGroup(\"Show setup details\", isExpanded: $showAdvancedAgentSetup)"),
            "Agent setup details should not rely on the macOS DisclosureGroup click path"
        )
    }

    runSuite("Repo command contract - live sidecar toggle owns preview server lifecycle") {
        let contents = readRepoTextFile("Sources/UI/Settings/AgentConnectionSettingsPage.swift")
        let settingsViewContents = readRepoTextFile("Sources/UI/Settings/TranscriptedSettingsView.swift")
        let controllerContents = readRepoTextFile("Sources/Meeting/MeetingSessionController.swift")
        let sessionContents = readRepoTextFile("Sources/Meeting/LiveMeetingCodexSession.swift")
        let transcriberContents = readRepoTextFile("Sources/Meeting/LiveMeetingTranscriber.swift")
        let toggleBlock = sourceSlice(
            contents,
            from: ".onChange(of: liveMeetingCodexEnabled)",
            to: "HStack(spacing: 10)"
        )
        let setupBlock = sourceSlice(
            contents,
            from: "private func setupLiveMeetingCodex()",
            to: "private func prepareLiveMeetingSidecarWorkspace()"
        )
        let copyBlock = sourceSlice(
            contents,
            from: "private func copyLiveMeetingCoworkSetup()",
            to: "private func openLiveMeetingPreview()"
        )
        let helperBlock = sourceSlice(
            contents,
            from: "private func prepareLiveMeetingSidecarWorkspaceForUse() throws -> URL",
            to: "private func stopLiveMeetingSidecarPreview()"
        )
        let stopBlock = sourceSlice(
            contents,
            from: "private func stopLiveMeetingSidecarPreview()",
            to: "private func copyText("
        )

        assertTrue(
            toggleBlock.contains("prepareLiveMeetingSidecarWorkspace()")
                && toggleBlock.contains("meetingSession?.stopLiveCodexSessionFromSettings()")
                && toggleBlock.contains("stopLiveMeetingSidecarPreview()"),
            "the live sidecar toggle should start the preview server on enable and stop both the active sidecar and preview server on disable"
        )
        assertTrue(
            settingsViewContents.contains("AgentConnectionSettingsPage(meetingSession: meetingSession)"),
            "Agent settings should receive the meeting session so the opt-out toggle can stop an active live sidecar"
        )
        assertTrue(
            setupBlock.contains("prepareLiveMeetingSidecarWorkspaceForUse()")
                && copyBlock.contains("prepareLiveMeetingSidecarWorkspaceForUse()"),
            "Codex and Cowork setup actions should prepare the workspace and server before handing prompts to agents"
        )
        assertTrue(
            helperBlock.contains("LiveMeetingPreviewServer.shared.start(workspaceURL: workspaceURL)"),
            "the shared setup helper should start the loopback preview server when supported"
        )
        assertTrue(
            stopBlock.contains("LiveMeetingPreviewServer.shared.stop()"),
            "disabling the sidecar should stop the loopback preview server"
        )
        assertTrue(
            controllerContents.contains("func stopLiveCodexSessionFromSettings()")
                && controllerContents.contains("clearPreviewHandlers: !shouldDeferPreviewHandlerClear")
                && controllerContents.contains("liveCodexPreviewHandlersNeedClearingAfterActiveRecording = true")
                && controllerContents.contains("clearDeferredLiveCodexPreviewHandlersIfNeeded()")
                && sessionContents.contains("case disabled")
                && sessionContents.contains("The user turned off the live sidecar"),
            "disabling the preference should mark an active live sidecar disabled without implying the normal transcript will not save"
        )
        assertTrue(
            transcriberContents.contains("func stop(capture: MeetingCaptureBridge, clearPreviewHandlers: Bool = true)")
                && transcriberContents.contains("func clearCapturePreviewHandlers(capture: MeetingCaptureBridge)"),
            "the live sidecar should be able to stop streaming immediately while deferring capture-handler clears until recording stops"
        )
    }

    runSuite("Repo command contract - settings permissions refresh after async grants") {
        let settingsContents = readRepoTextFile("Sources/UI/Settings/TranscriptedSettingsView.swift")
        let permissionAccessContents = readRepoTextFile("Sources/Support/TranscriptedPermissionAccess.swift")

        assertTrue(
            permissionAccessContents.contains("static func requestAccessOrOpenSettings(for kind: TranscriptedPermissionKind) async -> Bool"),
            "permission actions should expose an awaitable path so callers can refresh after macOS returns a grant"
        )
        assertTrue(
            permissionAccessContents.contains("_ = await requestAccessOrOpenSettings(for: kind)"),
            "legacy fire-and-forget permission actions should delegate to the awaitable implementation"
        )
        assertTrue(
            settingsContents.contains("await TranscriptedPermissionAccess.requestAccessOrOpenSettings(for: kind)")
                && settingsContents.contains("refreshPermissions()"),
            "settings should refresh its permission snapshot after the permission request completes, not before"
        )
        assertFalse(
            settingsContents.contains("TranscriptedPermissionAccess.openSettings(for: kind)\n                        refreshPermissions()"),
            "settings should not immediately refresh after a fire-and-forget permission action"
        )
    }
}

private func repoRootURL() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}

private func readRepoTextFile(_ relativePath: String) -> String {
    let url = repoRootURL().appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func fileExists(_ relativePath: String) -> Bool {
    let url = repoRootURL().appendingPathComponent(relativePath)
    return FileManager.default.fileExists(atPath: url.path)
}

private func plistStringValue(_ key: String, in contents: String) -> String? {
    guard let keyRange = contents.range(of: "<key>\(key)</key>"),
          let stringStart = contents.range(of: "<string>", range: keyRange.upperBound..<contents.endIndex),
          let stringEnd = contents.range(of: "</string>", range: stringStart.upperBound..<contents.endIndex)
    else {
        return nil
    }

    return String(contents[stringStart.upperBound..<stringEnd.lowerBound])
}

private func plistBooleanValue(_ key: String, in contents: String) -> Bool? {
    guard let keyRange = contents.range(of: "<key>\(key)</key>"),
          let valueStart = contents.range(of: "<", range: keyRange.upperBound..<contents.endIndex),
          let valueEnd = contents.range(of: ">", range: valueStart.upperBound..<contents.endIndex)
    else {
        return nil
    }

    let tag = String(contents[valueStart.lowerBound...valueEnd.lowerBound])
    if tag == "<true/>" { return true }
    if tag == "<false/>" { return false }
    return nil
}

private func plistIntegerValue(_ key: String, in contents: String) -> Int? {
    guard let keyRange = contents.range(of: "<key>\(key)</key>"),
          let integerStart = contents.range(of: "<integer>", range: keyRange.upperBound..<contents.endIndex),
          let integerEnd = contents.range(of: "</integer>", range: integerStart.upperBound..<contents.endIndex)
    else {
        return nil
    }

    return Int(contents[integerStart.upperBound..<integerEnd.lowerBound])
}

private func rubyStringAssignment(_ key: String, in contents: String) -> String? {
    for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\(key) \""),
              let start = trimmed.firstIndex(of: "\""),
              let end = trimmed[trimmed.index(after: start)...].firstIndex(of: "\"")
        else {
            continue
        }

        return String(trimmed[trimmed.index(after: start)..<end])
    }

    return nil
}

private func firstAppcastItem(in contents: String) -> String {
    guard let start = contents.range(of: "<item>"),
          let end = contents.range(of: "</item>", range: start.upperBound..<contents.endIndex)
    else {
        return ""
    }

    return String(contents[start.lowerBound..<end.upperBound])
}

private func xmlText(_ elementName: String, in contents: String) -> String? {
    guard let start = contents.range(of: "<\(elementName)>"),
          let end = contents.range(of: "</\(elementName)>", range: start.upperBound..<contents.endIndex)
    else {
        return nil
    }

    return String(contents[start.upperBound..<end.lowerBound])
}

private func xmlAttribute(_ name: String, inFirstTagNamed tagName: String, text: String) -> String? {
    guard let tagStart = text.range(of: "<\(tagName) "),
          let tagEnd = text.range(of: ">", range: tagStart.upperBound..<text.endIndex)
    else {
        return nil
    }

    let tag = String(text[tagStart.lowerBound..<tagEnd.upperBound])
    guard let attributeStart = tag.range(of: "\(name)=\""),
          let valueEnd = tag.range(of: "\"", range: attributeStart.upperBound..<tag.endIndex)
    else {
        return nil
    }

    return String(tag[attributeStart.upperBound..<valueEnd.lowerBound])
}

private func isPositiveInteger(_ value: String?) -> Bool {
    guard let value, let integer = Int(value) else { return false }
    return integer > 0
}

private func isNonEmptyBase64Like(_ value: String?) -> Bool {
    guard let value, !value.isEmpty else { return false }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    return value.unicodeScalars.allSatisfy { allowed.contains($0) }
}

private func isSHA256Hex(_ value: String?) -> Bool {
    guard let value, value.count == 64 else { return false }
    let allowed = CharacterSet(charactersIn: "0123456789abcdef")
    return value.unicodeScalars.allSatisfy { allowed.contains($0) }
}

private func repoTextFiles(relativeTo root: URL) -> [String] {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: []
    ) else {
        return []
    }

    var files: [String] = []
    for case let url as URL in enumerator {
        guard shouldDescendInto(url, root: root) else {
            enumerator.skipDescendants()
            continue
        }

        guard
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
            values.isRegularFile == true
        else {
            continue
        }

        let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
        if isTextPath(relativePath) {
            files.append(relativePath)
        }
    }

    return files.sorted()
}

private func shouldDescendInto(_ url: URL, root: URL) -> Bool {
    let relativePath = url.path.replacingOccurrences(of: root.path + "/", with: "")
    let excludedPrefixes = [
        ".build/",
        ".claude/worktrees/",
        ".deps-build/",
        ".git/",
        ".swiftpm/",
        "archive/",
        "build/",
        "deps-frameworks/",
        "deps-libs/",
        "deps-modules/",
        "docs/archive/",
        "Tools/"
    ]

    return !excludedPrefixes.contains { relativePath == String($0.dropLast()) || relativePath.hasPrefix($0) }
}

private func shouldScanForLiveCommandContract(_ relativePath: String) -> Bool {
    relativePath == "README.md"
        || relativePath == "AGENTS.md"
        || relativePath == "CLAUDE.md"
        || relativePath == "CONTRIBUTING.md"
        || relativePath.hasPrefix(".github/")
        || relativePath.hasPrefix("docs/")
        || relativePath.hasPrefix("scripts/")
        || relativePath.hasSuffix(".sh")
}

private func sourceSlice(_ contents: String, from start: String, to end: String) -> String {
    guard
        let startRange = contents.range(of: start),
        let endRange = contents.range(of: end, range: startRange.upperBound..<contents.endIndex)
    else {
        return ""
    }

    return String(contents[startRange.lowerBound..<endRange.lowerBound])
}

private func countOccurrences(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }

    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let range = haystack.range(of: needle, range: searchRange) {
        count += 1
        searchRange = range.upperBound..<haystack.endIndex
    }
    return count
}

private func isTextPath(_ relativePath: String) -> Bool {
    let textExtensions: Set<String> = [
        "md",
        "sh",
        "swift",
        "toml",
        "txt",
        "yml",
        "yaml",
        "rb"
    ]

    return textExtensions.contains(URL(fileURLWithPath: relativePath).pathExtension)
}

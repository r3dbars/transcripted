import Foundation

func testRepoCommandContract() {
    runSuite("Repo command contract - root build and test wrappers stay script-based") {
        let wrappers = [
            "build-deps.sh": "scripts/entrypoints/build-deps.sh",
            "build-beta.sh": "scripts/entrypoints/build-beta.sh",
            "build.sh": "scripts/entrypoints/build.sh",
            "run-e2e-smoke.sh": "scripts/entrypoints/run-e2e-smoke.sh",
            "run-live-capture-smoke.sh": "scripts/entrypoints/run-live-capture-smoke.sh",
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
            releaseDocs.contains("Homebrew users will still") && releaseDocs.contains("install or upgrade to the older version"),
            "release packaging docs should warn when the cask is stale"
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
                && scriptsReadme.contains("scripts/release/register-sentry-release.sh"),
            "scripts README should list the active release helper scripts"
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
            fastPathBlock.contains("dictation_fast_start_fell_back_to_wait"),
            "fast dictation start fallback should emit a local proof event"
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
        assertTrue(
            downloaderContents.contains("func ensureModelsReady(sttModel: TranscriptionModelChoice) async throws")
                && downloaderContents.contains("stt.prepare(model: sttModel)"),
            "meeting model loading should support a queued job's stored speech model"
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

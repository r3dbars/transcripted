import Foundation

func testRepoCommandContract() {
    runSuite("Repo command contract - root build and test wrappers stay script-based") {
        let wrappers = [
            "build-deps.sh": "scripts/entrypoints/build-deps.sh",
            "build.sh": "scripts/entrypoints/build.sh",
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
        let caskVersion = rubyStringAssignment("version", in: cask)
        let caskSHA = rubyStringAssignment("sha256", in: cask)
        let latestAppcastItem = firstAppcastItem(in: appcast)
        let appcastVersion = xmlText("sparkle:version", in: latestAppcastItem)
        let appcastShortVersion = xmlText("sparkle:shortVersionString", in: latestAppcastItem)
        let appcastEnclosureURL = xmlAttribute("url", inFirstTagNamed: "enclosure", text: latestAppcastItem)
        let appcastLength = xmlAttribute("length", inFirstTagNamed: "enclosure", text: latestAppcastItem)
        let appcastSignature = xmlAttribute("sparkle:edSignature", inFirstTagNamed: "enclosure", text: latestAppcastItem)

        assertNotNil(appVersion, "Info.plist should expose CFBundleShortVersionString")
        assertEqual(buildVersion, appVersion, "marketing and build versions should move together for Sparkle")
        assertEqual(caskVersion, appVersion, "Homebrew cask version should match the app bundle version")
        assertEqual(appcastVersion, appVersion, "latest appcast item should match the app bundle version")
        assertEqual(appcastShortVersion, appVersion, "Sparkle shortVersionString should match the app bundle version")
        assertEqual(
            appcastEnclosureURL,
            appVersion.map { "https://github.com/r3dbars/transcripted/releases/download/v\($0)/Transcripted-\($0).dmg" },
            "latest appcast enclosure should point at the matching GitHub DMG"
        )
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
            betaBuildScript.contains("BUNDLE_PARAKEET_MODELS=\"${BUNDLE_PARAKEET_MODELS:-0}\""),
            "beta release build should default to the lightweight model-download distribution"
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
}

private func repoRootURL() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}

private func readRepoTextFile(_ relativePath: String) -> String {
    let url = repoRootURL().appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
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

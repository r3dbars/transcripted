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
            "performance budget should cap launch model-ready regressions"
        )
        assertTrue(
            contents.contains("startup_model_ready_durations(events)"),
            "performance budget should parse launch to model-ready events"
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

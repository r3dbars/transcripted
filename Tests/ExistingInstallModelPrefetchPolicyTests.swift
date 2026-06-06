import Foundation

func testExistingInstallModelPrefetchPolicy() {
    runSuite("ExistingInstallModelPrefetchPolicy.hasExistingInstallSignals — requires durable evidence") {
        assertFalse(
            ExistingInstallModelPrefetchPolicy.hasExistingInstallSignals(
                onboardingCompleted: false,
                hasCaptureLibraryContent: false,
                hasExplicitLaunchAtLoginChoice: false
            ),
            "brand-new installs should not get automatic background model work"
        )
        assertFalse(
            ExistingInstallModelPrefetchPolicy.hasExistingInstallSignals(
                onboardingCompleted: true,
                hasCaptureLibraryContent: false,
                hasExplicitLaunchAtLoginChoice: false
            ),
            "onboarding alone should not make a fresh install prefetch models"
        )
        assertTrue(
            ExistingInstallModelPrefetchPolicy.hasExistingInstallSignals(
                onboardingCompleted: false,
                hasCaptureLibraryContent: true,
                hasExplicitLaunchAtLoginChoice: false
            ),
            "saved captures should count as an existing user even if onboarding state is missing"
        )
        assertTrue(
            ExistingInstallModelPrefetchPolicy.hasExistingInstallSignals(
                onboardingCompleted: false,
                hasCaptureLibraryContent: false,
                hasExplicitLaunchAtLoginChoice: true
            ),
            "saved app preferences should count as an existing install"
        )
    }

    runSuite("ExistingInstallModelPrefetchPolicy.shouldPrefetch — only protects existing Parakeet users") {
        let base = ExistingInstallModelPrefetchContext(
            isExistingInstall: true,
            selectedModel: .parakeetTDTv3,
            isModelLoaded: false,
            isModelWorkInFlight: false,
            eagerModelWarmupEnabled: false
        )

        assertTrue(
            ExistingInstallModelPrefetchPolicy.shouldPrefetch(base),
            "existing Parakeet users should get delayed background file prefetch"
        )
        assertFalse(
            ExistingInstallModelPrefetchPolicy.shouldPrefetch(
                ExistingInstallModelPrefetchContext(
                    isExistingInstall: false,
                    selectedModel: .parakeetTDTv3,
                    isModelLoaded: false,
                    isModelWorkInFlight: false,
                    eagerModelWarmupEnabled: false
                )
            ),
            "brand-new installs should stay explicitly on-demand"
        )
        assertFalse(
            ExistingInstallModelPrefetchPolicy.shouldPrefetch(
                ExistingInstallModelPrefetchContext(
                    isExistingInstall: true,
                    selectedModel: .whisperLargeV3Turbo,
                    isModelLoaded: false,
                    isModelWorkInFlight: false,
                    eagerModelWarmupEnabled: false
                )
            ),
            "users who selected Whisper should not get Parakeet downloaded behind their choice"
        )
        assertFalse(
            ExistingInstallModelPrefetchPolicy.shouldPrefetch(
                ExistingInstallModelPrefetchContext(
                    isExistingInstall: true,
                    selectedModel: .parakeetTDTv3,
                    isModelLoaded: true,
                    isModelWorkInFlight: false,
                    eagerModelWarmupEnabled: false
                )
            ),
            "already-ready models should not do duplicate work"
        )
        assertFalse(
            ExistingInstallModelPrefetchPolicy.shouldPrefetch(
                ExistingInstallModelPrefetchContext(
                    isExistingInstall: true,
                    selectedModel: .parakeetTDTv3,
                    isModelLoaded: false,
                    isModelWorkInFlight: true,
                    eagerModelWarmupEnabled: false
                )
            ),
            "active downloads or loads should not be duplicated"
        )
        assertFalse(
            ExistingInstallModelPrefetchPolicy.shouldPrefetch(
                ExistingInstallModelPrefetchContext(
                    isExistingInstall: true,
                    selectedModel: .parakeetTDTv3,
                    isModelLoaded: false,
                    isModelWorkInFlight: false,
                    eagerModelWarmupEnabled: true
                )
            ),
            "the explicit eager warmup path should remain the only launch warmup override"
        )
    }

    runSuite("ExistingInstallModelPrefetchPolicy.captureLibraryCandidateURLs — keeps safe roots only") {
        let appSupport = URL(fileURLWithPath: "/Users/example/Library/Application Support/Transcripted", isDirectory: true)
        let safeCustom = "/Users/example/Documents/Transcripted Captures"

        let candidates = ExistingInstallModelPrefetchPolicy.captureLibraryCandidateURLs(
            customPath: safeCustom,
            appSupportRoot: appSupport
        )

        assertEqual(candidates.count, 2, "default plus safe custom capture roots should be checked")
        assertEqual(
            candidates.first?.path,
            "/Users/example/Library/Application Support/Transcripted/captures",
            "default capture library should always be checked"
        )
        assertEqual(
            candidates.last?.path,
            safeCustom,
            "safe custom capture library should be included"
        )

        let rejected = ExistingInstallModelPrefetchPolicy.captureLibraryCandidateURLs(
            customPath: "/System/Library",
            appSupportRoot: appSupport
        )
        assertEqual(rejected.count, 1, "unsafe custom capture roots should be ignored")
    }

    runSuite("ExistingInstallModelPrefetchPolicy.captureLibraryHasContent — looks for saved notes") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExistingInstallModelPrefetchPolicyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        assertFalse(
            ExistingInstallModelPrefetchPolicy.captureLibraryHasContent(at: root),
            "missing capture libraries should not count as existing content"
        )

        writeExistingInstallTestFile(
            root.appendingPathComponent("dictations", isDirectory: true)
                .appendingPathComponent("note.md", isDirectory: false)
        )

        assertTrue(
            ExistingInstallModelPrefetchPolicy.captureLibraryHasContent(at: root),
            "saved dictation or meeting notes should count as existing content"
        )
    }

    runSuite("ExistingInstallModelPrefetchPolicy.captureLibraryHasContent — ignores nested archive files") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExistingInstallModelPrefetchPolicyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        writeExistingInstallTestFile(
            root.appendingPathComponent("meetings", isDirectory: true)
                .appendingPathComponent("audio", isDirectory: true)
                .appendingPathComponent("Synthetic_audio", isDirectory: true)
                .appendingPathComponent("recording.m4a", isDirectory: false)
        )

        assertFalse(
            ExistingInstallModelPrefetchPolicy.captureLibraryHasContent(at: root),
            "startup prefetch detection should avoid recursively walking nested audio archives"
        )

        writeExistingInstallTestFile(
            root.appendingPathComponent("meetings", isDirectory: true)
                .appendingPathComponent("Meeting.md", isDirectory: false)
        )

        assertTrue(
            ExistingInstallModelPrefetchPolicy.captureLibraryHasContent(at: root),
            "direct saved meeting files should still count as existing content"
        )
    }

    runSuite("ExistingInstallModelPrefetchPolicy.captureLibraryHasContent — ignores files outside capture buckets") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExistingInstallModelPrefetchPolicyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        writeExistingInstallTestFile(
            root.appendingPathComponent("loose-note.md", isDirectory: false)
        )

        assertFalse(
            ExistingInstallModelPrefetchPolicy.captureLibraryHasContent(at: root),
            "files outside dictations or meetings should not count as capture history"
        )
    }

    runSuite("ExistingInstallModelPrefetchPolicy.captureLibraryHasContent — ignores hidden direct files") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExistingInstallModelPrefetchPolicyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        writeExistingInstallTestFile(
            root.appendingPathComponent("dictations", isDirectory: true)
                .appendingPathComponent(".hidden.md", isDirectory: false)
        )

        assertFalse(
            ExistingInstallModelPrefetchPolicy.captureLibraryHasContent(at: root),
            "hidden files should not make a fresh install look like it has saved captures"
        )
    }

    runSuite("ExistingInstallModelPrefetchPolicy.captureLibraryHasContent — ignores direct child directories") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExistingInstallModelPrefetchPolicyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try? FileManager.default.createDirectory(
            at: root.appendingPathComponent("meetings", isDirectory: true)
                .appendingPathComponent("audio", isDirectory: true),
            withIntermediateDirectories: true
        )

        assertFalse(
            ExistingInstallModelPrefetchPolicy.captureLibraryHasContent(at: root),
            "top-level capture subdirectories should not count without a direct saved file"
        )
    }

    runSuite("ExistingInstallModelPrefetchPolicy.captureLibraryHasContent — visible direct files win with ignored siblings") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExistingInstallModelPrefetchPolicyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dictations = root.appendingPathComponent("dictations", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: dictations.appendingPathComponent("drafts", isDirectory: true),
            withIntermediateDirectories: true
        )
        writeExistingInstallTestFile(
            dictations.appendingPathComponent(".hidden.md", isDirectory: false)
        )
        writeExistingInstallTestFile(
            dictations.appendingPathComponent("saved.md", isDirectory: false)
        )

        assertTrue(
            ExistingInstallModelPrefetchPolicy.captureLibraryHasContent(at: root),
            "a visible direct saved file should still count when ignored siblings are present"
        )
    }
}

private func writeExistingInstallTestFile(_ url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: url.path, contents: Data("test".utf8))
}

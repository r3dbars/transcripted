import Foundation

func testExistingInstallModelPrefetchPolicy() {
    runSuite("ExistingInstallModelPrefetchPolicy.hasExistingInstallSignals — detects real users") {
        assertFalse(
            ExistingInstallModelPrefetchPolicy.hasExistingInstallSignals(
                onboardingCompleted: false,
                hasCaptureLibraryContent: false,
                hasExplicitLaunchAtLoginChoice: false
            ),
            "brand-new installs should not get automatic background model work"
        )
        assertTrue(
            ExistingInstallModelPrefetchPolicy.hasExistingInstallSignals(
                onboardingCompleted: true,
                hasCaptureLibraryContent: false,
                hasExplicitLaunchAtLoginChoice: false
            ),
            "completed onboarding should count as an existing user"
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
}

private func writeExistingInstallTestFile(_ url: URL) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: url.path, contents: Data("test".utf8))
}

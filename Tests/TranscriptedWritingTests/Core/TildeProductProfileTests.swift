import Testing
@testable import TranscriptedWritingCore

struct TildeProductProfileTests {
    @Test func resolvesPreviewBundleIdentifiersWithoutPlistHint() {
        #expect(TildeProductProfile.resolve(
            bundleIdentifier: "com.justinbetker.draft.preview9b",
            declaredProfile: nil
        ) == .preview9B)
        #expect(TildeProductProfile.resolve(
            bundleIdentifier: "com.justinbetker.draft.inputmethod.TranscriptedPreview9B",
            declaredProfile: nil
        ) == .preview9B)
    }

    @Test func unknownAndTestBundlesFailSafeToProduction() {
        #expect(TildeProductProfile.resolve(
            bundleIdentifier: "org.swift.swiftpm.xctest",
            declaredProfile: nil
        ) == .production)
    }

    @Test func previewResourcesDoNotOverlapProduction() {
        let production = TildeProductProfile.production
        let previews = [TildeProductProfile.preview9B]
        #expect(Set(previews.map(\.appBundleIdentifier)).count == previews.count)
        #expect(Set(previews.map(\.inputMethodBundleIdentifier)).count == previews.count)
        #expect(Set(previews.map(\.inputMethodConnectionName)).count == previews.count)
        #expect(Set(previews.map(\.supportDirectoryName)).count == previews.count)
        #expect(Set(previews.map(\.inputMethodInstalledBundleName)).count == previews.count)
        #expect(Set(previews.map(\.llamaServerPort)).count == previews.count)
        for preview in previews {
            #expect(preview.appBundleIdentifier != production.appBundleIdentifier)
            #expect(preview.inputMethodBundleIdentifier != production.inputMethodBundleIdentifier)
            #expect(preview.inputMethodConnectionName != production.inputMethodConnectionName)
            #expect(preview.supportDirectoryName != production.supportDirectoryName)
            #expect(preview.inputMethodInstalledBundleName != production.inputMethodInstalledBundleName)
            #expect(preview.llamaServerPort != production.llamaServerPort)
            #expect(preview.personalHistoryKeychainService != production.personalHistoryKeychainService)
        }
        #expect(production.generatedTokenBudget == 20)
        #expect(TildeProductProfile.preview9B.generatedTokenBudget == 12)
        #expect(production.completionTemperature == 0)
        #expect(production.maximumVisibleWords == CompletionSuggestion.defaultMaxVisibleWords)
        #expect(TildeProductProfile.preview9B.completionTemperature == 0.10)
        #expect(TildeProductProfile.preview9B.maximumVisibleWords == 3)
    }

    @Test func productionModelChoicesDefaultSafelyAndDescribeResources() {
        #expect(TildeModelChoice.resolve(persistedValue: nil) == .gemma4E2B)
        #expect(TildeModelChoice.resolve(persistedValue: "unknown") == .gemma4E2B)
        #expect(TildeModelChoice.resolve(
            persistedValue: TildeModelChoice.qwen35B9B.rawValue
        ) == .qwen35B9B)
        #expect(TildeModelChoice.allCases == [.gemma4E2B, .qwen35B9B])
        #expect(TildeModelChoice.allCases.allSatisfy {
            !$0.displayName.isEmpty && !$0.approximateSize.isEmpty && !$0.resourceGuidance.isEmpty
        })
    }

    /// The picker must not imply the bigger model is simply the better one.
    /// Gemma is the model every shipped measurement was taken on; Qwen is
    /// larger and has not been through the same evidence, and the one line
    /// each model gets says exactly that.
    @Test func modelPickerCopyNamesTheMeasuredDefaultAndTheUnstudiedOption() {
        #expect(TildeModelChoice.gemma4E2B.resourceGuidance.contains("Measured default"))
        #expect(TildeModelChoice.qwen35B9B.resourceGuidance.contains("still under study"))
        #expect(TildeModelChoice.qwen35B9B.resourceGuidance.contains("more memory and storage"))
        // One line, not a paragraph.
        #expect(TildeModelChoice.allCases.allSatisfy {
            !$0.resourceGuidance.contains("\n") && $0.resourceGuidance.count <= 60
        })
    }
}

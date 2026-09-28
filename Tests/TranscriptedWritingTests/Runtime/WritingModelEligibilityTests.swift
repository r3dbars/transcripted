import Foundation
import Testing
@testable import TranscriptedWritingCore
@testable import TranscriptedWritingRuntime

struct WritingModelEligibilityTests {
    private let gibibyte: UInt64 = 1024 * 1024 * 1024

    @Test func gemmaRunsOnEveryMac() {
        for memory in [0, 8 * gibibyte, 16 * gibibyte, 128 * gibibyte] {
            #expect(WritingModelEligibility.isEligible(.gemma4E2B, physicalMemoryBytes: memory))
        }
    }

    @Test func qwenNeedsSixteenGibibytesOfPhysicalMemory() {
        #expect(!WritingModelEligibility.isEligible(.qwen35B9B, physicalMemoryBytes: 8 * gibibyte))
        #expect(!WritingModelEligibility.isEligible(.qwen35B9B, physicalMemoryBytes: 16 * gibibyte - 1))
        #expect(WritingModelEligibility.isEligible(.qwen35B9B, physicalMemoryBytes: 16 * gibibyte))
        #expect(WritingModelEligibility.isEligible(.qwen35B9B, physicalMemoryBytes: 36 * gibibyte))
    }

    @Test func aPersistedQwenRunsGemmaOnAnIneligibleMac() {
        #expect(WritingModelEligibility.effectiveChoice(
            persisted: .qwen35B9B, physicalMemoryBytes: 8 * gibibyte
        ) == .gemma4E2B)
        #expect(WritingModelEligibility.effectiveChoice(
            persisted: .qwen35B9B, physicalMemoryBytes: 16 * gibibyte
        ) == .qwen35B9B)
        #expect(WritingModelEligibility.effectiveChoice(
            persisted: .gemma4E2B, physicalMemoryBytes: 64 * gibibyte
        ) == .gemma4E2B)
    }

    @Test func resolvedChoiceReadsTheGivenSuiteAndLeavesTheSavedChoiceAlone() throws {
        let suiteName = "TranscriptedWritingTests.eligibility.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(WritingModelEligibility.resolvedChoice(
            for: .production, defaults: defaults, physicalMemoryBytes: 64 * gibibyte
        ) == .gemma4E2B)

        TildeModelSelection.persist(.qwen35B9B, defaults: defaults)
        #expect(WritingModelEligibility.resolvedChoice(
            for: .production, defaults: defaults, physicalMemoryBytes: 64 * gibibyte
        ) == .qwen35B9B)
        #expect(WritingModelEligibility.resolvedChoice(
            for: .production, defaults: defaults, physicalMemoryBytes: 8 * gibibyte
        ) == .gemma4E2B)
        #expect(defaults.string(forKey: TildeModelSelection.defaultsKey) == TildeModelChoice.qwen35B9B.rawValue)

        defaults.set("not-a-model", forKey: TildeModelSelection.defaultsKey)
        #expect(WritingModelEligibility.resolvedChoice(
            for: .production, defaults: defaults, physicalMemoryBytes: 64 * gibibyte
        ) == .gemma4E2B)
    }

    @Test func previewProfilesKeepTildesFixedSelection() throws {
        let suiteName = "TranscriptedWritingTests.eligibility.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(WritingModelEligibility.resolvedChoice(
            for: .preview9B, defaults: defaults, physicalMemoryBytes: 64 * gibibyte
        ) == nil)
    }
}

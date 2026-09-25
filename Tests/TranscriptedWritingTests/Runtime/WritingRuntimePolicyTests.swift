import Foundation
import Testing
@testable import TranscriptedWritingCore
@testable import TranscriptedWritingRuntime

struct WritingSuggestionsGateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func inputs(
        suggestionsEnabled: Bool = true,
        pausedUntil: Date? = nil,
        screenMemoryEnabled: Bool = true,
        screenRecordingGranted: Bool = true
    ) -> WritingSuggestionsGate.Inputs {
        WritingSuggestionsGate.Inputs(
            suggestionsEnabled: suggestionsEnabled,
            pausedUntil: pausedUntil,
            screenMemoryEnabled: screenMemoryEnabled,
            screenRecordingGranted: screenRecordingGranted,
            now: now
        )
    }

    @Test func allowsWhenOnUnpausedAndScreenMemoryIsAvailable() {
        #expect(WritingSuggestionsGate.allows(inputs()))
        #expect(WritingSuggestionsGate.allows(inputs(pausedUntil: now.addingTimeInterval(-1))))
    }

    @Test func keepsTildesScreenMemoryRule() {
        #expect(!WritingSuggestionsGate.allows(inputs(screenRecordingGranted: false)))
        #expect(!WritingSuggestionsGate.allows(inputs(screenMemoryEnabled: false)))
    }

    @Test func silentWhenOffOrPaused() {
        #expect(!WritingSuggestionsGate.allows(inputs(suggestionsEnabled: false)))
        #expect(!WritingSuggestionsGate.allows(inputs(pausedUntil: now.addingTimeInterval(3_600))))
    }
}

struct WritingHelperWakePolicyTests {
    @Test func restartsAReadyHelperThatStoppedAnswering() {
        #expect(WritingHelperWakePolicy.action(modelReady: true, snapshot: .ready, helperHealthy: false) == .restart)
        #expect(WritingHelperWakePolicy.action(modelReady: true, snapshot: .ready, helperHealthy: true) == .none)
    }

    @Test func restartsARuntimeThatGaveUp() {
        #expect(WritingHelperWakePolicy.action(
            modelReady: true, snapshot: .failed(.assetsMissing), helperHealthy: false
        ) == .restart)
    }

    @Test func leavesTheHostsOwnRestartLoopAlone() {
        #expect(WritingHelperWakePolicy.action(modelReady: true, snapshot: .starting, helperHealthy: false) == .none)
        #expect(WritingHelperWakePolicy.action(
            modelReady: true, snapshot: .retrying(.healthTimeout), helperHealthy: false
        ) == .none)
    }

    @Test func neverStartsAHelperWithoutAVerifiedModel() {
        #expect(WritingHelperWakePolicy.action(
            modelReady: false, snapshot: .failed(.assetsMissing), helperHealthy: false
        ) == .none)
        #expect(WritingHelperWakePolicy.action(modelReady: false, snapshot: .ready, helperHealthy: false) == .none)
    }
}

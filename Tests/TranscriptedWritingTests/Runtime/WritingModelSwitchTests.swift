import Foundation
import Testing
@testable import TranscriptedWritingCore
@testable import TranscriptedWritingRuntime

/// The model-switch sequence against a fake host: no helper process, no
/// model files, no relaunch.
@MainActor
struct WritingModelSwitchTests {
    private static let enoughMemory: UInt64 = 32 * 1024 * 1024 * 1024
    private static let eightGibibytes: UInt64 = 8 * 1024 * 1024 * 1024

    @MainActor
    private final class FakeHost: WritingModelSwitchHost {
        var steps: [String] = []
        var modelReady = true
        var onPrepare: (() -> Void)?

        func stopHelper() async { steps.append("stop-helper") }
        func persistModelChoice(_ choice: TildeModelChoice) { steps.append("persist \(choice.rawValue)") }
        func rebuildRuntime(for choice: TildeModelChoice) { steps.append("rebuild \(choice.rawValue)") }
        func prepareModel() async -> Bool {
            steps.append("prepare")
            onPrepare?()
            return modelReady
        }
        func startHelper() { steps.append("start-helper") }
    }

    @Test func stopsTheHelperPreparesTheNewModelThenRestartsOnlyTheHelper() async {
        let host = FakeHost()
        let outcome = await WritingModelSwitch.perform(
            from: .gemma4E2B, to: .qwen35B9B, physicalMemoryBytes: Self.enoughMemory, host: host
        )
        #expect(outcome == .switched(helperStarted: true))
        #expect(host.steps == [
            "stop-helper",
            "persist \(TildeModelChoice.qwen35B9B.rawValue)",
            "rebuild \(TildeModelChoice.qwen35B9B.rawValue)",
            "prepare",
            "start-helper",
        ])
    }

    @Test func aModelThatIsNotReadyLeavesTheHelperStopped() async {
        let host = FakeHost()
        host.modelReady = false
        let outcome = await WritingModelSwitch.perform(
            from: .qwen35B9B, to: .gemma4E2B, physicalMemoryBytes: Self.enoughMemory, host: host
        )
        #expect(outcome == .switched(helperStarted: false))
        #expect(!host.steps.contains("start-helper"))
        #expect(host.steps.first == "stop-helper")
    }

    @Test func theSameModelTouchesNothing() async {
        let host = FakeHost()
        let outcome = await WritingModelSwitch.perform(
            from: .gemma4E2B, to: .gemma4E2B, physicalMemoryBytes: Self.enoughMemory, host: host
        )
        #expect(outcome == .unchanged)
        #expect(host.steps.isEmpty)
    }

    @Test func qwenOnAnIneligibleMacTouchesNothing() async {
        let host = FakeHost()
        let outcome = await WritingModelSwitch.perform(
            from: .gemma4E2B, to: .qwen35B9B, physicalMemoryBytes: Self.eightGibibytes, host: host
        )
        #expect(outcome == .ineligible)
        #expect(host.steps.isEmpty)
    }

    @Test func afterAnInterruptedSwitchEvenTheSameModelRunsEveryStep() async {
        let host = FakeHost()
        let outcome = await WritingModelSwitch.perform(
            from: nil, to: .gemma4E2B, physicalMemoryBytes: Self.enoughMemory, host: host
        )
        #expect(outcome == .switched(helperStarted: true))
        #expect(host.steps.count == 5)
    }

    @Test func aCancelledSwitchNeverRestartsTheHelper() async {
        let host = FakeHost()
        // A newer switch cancels this one while its model is being prepared.
        host.onPrepare = { withUnsafeCurrentTask { $0?.cancel() } }
        let memory = Self.enoughMemory
        let outcome = await Task { @MainActor in
            await WritingModelSwitch.perform(
                from: .gemma4E2B, to: .qwen35B9B, physicalMemoryBytes: memory, host: host
            )
        }.value
        #expect(outcome == .cancelled)
        #expect(!host.steps.contains("start-helper"))
    }
}

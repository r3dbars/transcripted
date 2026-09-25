#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// The steps a model switch drives. The Writing bridge implements them
/// against the real helper and model store; tests use fakes.
@MainActor
protocol WritingModelSwitchHost: AnyObject {
    /// Stops the `llama-server` helper and waits for it to exit.
    func stopHelper() async
    func persistModelChoice(_ choice: TildeModelChoice)
    /// Points the model store and the socket server's served configuration
    /// at the new choice. Both are fixed per model in Tilde's runtime.
    func rebuildRuntime(for choice: TildeModelChoice)
    /// Adopts or downloads and verifies the new model. `true` once it's ready.
    func prepareModel() async -> Bool
    func startHelper()
}

/// Switching models without relaunching the app (docs/writing-plan.md,
/// "App runtime": Tilde relaunched itself; Transcripted can't, since a
/// relaunch would end a meeting recording). Only the helper restarts.
enum WritingModelSwitch {
    enum Outcome: Equatable, Sendable {
        /// Already on that model; nothing touched.
        case unchanged
        /// This Mac can't run that model; nothing touched.
        case ineligible
        /// A newer switch took over before the helper was restarted.
        case cancelled
        /// Switched. `helperStarted` is `false` when the model isn't ready
        /// (download failed or still needs a retry), so no helper runs.
        case switched(helperStarted: Bool)
    }

    /// `current` is the model the runtime is built for, or `nil` when an
    /// earlier switch was interrupted and the runtime's state is unknown,
    /// which forces the full sequence even back to the same model.
    @MainActor
    static func perform(
        from current: TildeModelChoice?,
        to requested: TildeModelChoice,
        physicalMemoryBytes: UInt64,
        host: some WritingModelSwitchHost
    ) async -> Outcome {
        guard requested != current else { return .unchanged }
        guard WritingModelEligibility.isEligible(requested, physicalMemoryBytes: physicalMemoryBytes) else {
            return .ineligible
        }
        await host.stopHelper()
        guard !Task.isCancelled else { return .cancelled }
        host.persistModelChoice(requested)
        host.rebuildRuntime(for: requested)
        let ready = await host.prepareModel()
        guard !Task.isCancelled else { return .cancelled }
        guard ready else { return .switched(helperStarted: false) }
        host.startHelper()
        return .switched(helperStarted: true)
    }
}

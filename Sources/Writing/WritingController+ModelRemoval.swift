#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

// Delete model, kept out of `WritingController.swift` (a hotspot at its
// size cap). `stopModelWork()` stays there: it ends the controller's own
// model and wake tasks.
extension WritingController {
    /// Delete model: removes every downloaded autocomplete model, finished
    /// or partial, from the Writing model root. Autocomplete needs one, so
    /// this turns Autocomplete off first (the tab's confirmation says so,
    /// and that turning it back on downloads the model again). The helper
    /// and any download stop before a file goes. Saved writing and
    /// learning data stay.
    func deleteDownloadedModels() async -> WritingModelRemoval.Outcome {
        let outcome = await WritingModelRemoval.perform(host: WritingModelRemovalSteps(controller: self))
        log("WRITING | delete model: \(outcome)")
        let removed = if case .removed = outcome { true } else { false }
        DiagnosticsLog.shared.record("model-deleted", metadata: ["outcome": removed ? "removed" : "incomplete"])
        return outcome
    }

    /// Deletes the current model through its manager (so it drops the
    /// clone it holds and reads as missing), then everything else under
    /// the model root: the other model choice and any partials.
    func removeModelFiles() async -> Bool {
        if let manager = modelManager {
            await manager.deleteModelAndWait()
        }
        let root = modelRoot
        let removal = await Task.detached(priority: .userInitiated) {
            WritingModelStore.removeAll(under: root)
        }.value
        if !removal.isComplete {
            log("WRITING | delete model: \(removal.failedCount) entries left\(removal.refusedRoot ? ", model folder refused" : "")")
        }
        return removal.isComplete
    }
}

/// Drives `WritingModelRemoval` against the live runtime.
@MainActor
private final class WritingModelRemovalSteps: WritingModelRemovalHost {
    private weak var controller: WritingController?

    init(controller: WritingController) {
        self.controller = controller
    }

    var autocompleteEnabled: Bool { controller?.autocompleteEnabled ?? false }
    func turnOffAutocomplete() { controller?.setAutocomplete(false) }
    func stopModelWork() async { await controller?.stopModelWork() }
    func removeModelFiles() async -> Bool { await controller?.removeModelFiles() ?? false }
}

/// The model store the helper launches from. A model switch swaps it while
/// the one `LlamaServerProcessHost` stays, so the host's model provider
/// reads through here.
final class WritingModelManagerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ModelManager

    init(_ manager: ModelManager) {
        current = manager
    }

    var manager: ModelManager {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

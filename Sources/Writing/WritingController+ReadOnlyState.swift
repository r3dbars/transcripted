#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import AppKit
import CoreGraphics
import Foundation

// Read-only state the Writing tab reads, split out of `WritingController.swift`.

extension WritingController {
    var isQwenEligible: Bool {
        WritingModelEligibility.isEligible(.qwen35B9B, physicalMemoryBytes: physicalMemoryBytes)
    }

    var modelState: ModelState? { runtime?.models.manager.state }

    var modelProgress: Double? {
        guard case let .downloading(receivedBytes, totalBytes) = modelState, totalBytes > 0 else {
            return nil
        }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }

    var runtimeState: LlamaRuntimeSnapshot? { runtime?.llamaServerHost.snapshot }
    /// The current model's store, while Writing runs.
    var modelManager: ModelManager? { runtime?.models.manager }

    var screenRecordingGranted: Bool { ScreenRecordingPermission.isGranted() }

    var saveMyWritingEnabled: Bool { Self.preferences().saveMyWritingEnabled }
    /// Set while Save my writing can't write its day files (for example a
    /// capture library on a NAS that won't take owner-only permissions);
    /// `nil` again after the next write that works. The Writing tab shows
    /// "Writing couldn't be saved to this folder." The error case and a
    /// time only, never a path.
    var saveMyWritingProblem: WritingDayFileRecorder.WriteFailure? { runtime?.dayFiles.recorder.lastWriteFailure }
    /// Tilde's suggestions switch (`GhostSuggestionsEnabled`), on by default.
    var autocompleteEnabled: Bool { Self.settings().suggestionsEnabled }
    var personalizedSuggestionsEnabled: Bool { Self.preferences().personalizedSuggestionsEnabled }
    var appScope: WritingAppScope { Self.preferences().appScope }
    /// "Turn on writing" finished at least once.
    var setupCompleted: Bool { WritingSetupState.isCompleted(defaults: Self.appDefaults()) }
    /// Autocomplete and Save my writing are paused until then.
    var pausedUntil: Date? { Self.settings().pausedUntil }

    /// The prompt was shown at least once. With `screenRecordingGranted`
    /// still false, the UI asks the user to reopen Transcripted (macOS
    /// usually applies the grant to a new process only).
    var screenRecordingRequested: Bool { Self.settings().screenRecordingRequested }
}

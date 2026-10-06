// ClipboardPasteConfirmationWait.swift
// How paste-back waits for the target to confirm a paste: the main-thread
// run-loop wait, and the watch that keeps listening for a late confirmation
// after a dictation paste ended its wait early on a likely paste. Split out of
// ClipboardRestoringTextPaster.swift.

import Foundation

enum ClipboardPasteConfirmationWaitResult: Equatable {
    case confirmed
    case unconfirmed
    case focusChanged
    case cancelled
}

@MainActor
enum ClipboardPasteConfirmationWait {
    /// Pumps the main run loop in 20 ms slices until the target confirms the
    /// paste, focus moves, `stopWaitingUnconfirmed` ends the wait, or `timeout`
    /// runs out. `deadline` gets the system uptime the full wait runs (or
    /// would have run) until, so a caller that ended early knows what it skipped.
    static func run(
        targetIsFrontmost: @MainActor () -> Bool,
        pasteConfirmed: @MainActor () -> Bool,
        stopWaitingUnconfirmed: @MainActor () -> Bool,
        isCurrentOperation: @MainActor () -> Bool,
        timeout: TimeInterval,
        deadline: inout TimeInterval
    ) -> ClipboardPasteConfirmationWaitResult {
        func check() -> ClipboardPasteConfirmationWaitResult? {
            guard isCurrentOperation() else { return .cancelled }
            let frontmost = targetIsFrontmost()
            guard isCurrentOperation() else { return .cancelled }
            guard frontmost else { return .focusChanged }
            let confirmed = pasteConfirmed()
            guard isCurrentOperation() else { return .cancelled }
            let stillFrontmost = targetIsFrontmost()
            guard isCurrentOperation() else { return .cancelled }
            guard stillFrontmost else { return .focusChanged }
            if confirmed { return .confirmed }
            let stop = stopWaitingUnconfirmed()
            guard isCurrentOperation() else { return .cancelled }
            return stop ? .unconfirmed : nil
        }
        if let result = check() {
            deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
            return result
        }
        guard timeout > 0 else {
            deadline = ProcessInfo.processInfo.systemUptime
            return .unconfirmed
        }
        let waitDeadline = ProcessInfo.processInfo.systemUptime + timeout
        deadline = waitDeadline
        while ProcessInfo.processInfo.systemUptime < waitDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            if let result = check() { return result }
        }
        return check() ?? .unconfirmed
    }
}

/// After a dictation paste ends its wait early on a likely paste, the target
/// can still confirm over Accessibility before the full wait would have ended.
/// A full wait would then have restored the user's clipboard on the short
/// confirmed-paste delay, so this keeps checking, on the ordinary main run
/// loop instead of a blocking pump, at the wait's 20 ms slice, until the same
/// deadline. It stops at the deadline, on focus moving away, on a confirmation
/// (after calling `onConfirmed` once), or when `isCurrent` says the paste was
/// superseded. The task only holds this watch weakly.
@MainActor
final class ClipboardLateConfirmationWatch {
    private struct Watch {
        let deadline: TimeInterval
        let isCurrent: @MainActor () -> Bool
        let targetIsFrontmost: @MainActor () -> Bool
        let pasteConfirmed: @MainActor () -> Bool
        let onConfirmed: @MainActor () -> Void
    }

    private static let pollInterval: UInt64 = 20_000_000
    private var watch: Watch?
    private var task: Task<Void, Never>?
    private var generation = 0

    func start(
        until deadline: TimeInterval,
        isCurrent: @escaping @MainActor () -> Bool,
        targetIsFrontmost: @escaping @MainActor () -> Bool,
        pasteConfirmed: @escaping @MainActor () -> Bool,
        onConfirmed: @escaping @MainActor () -> Void
    ) {
        cancel()
        generation += 1
        let startedGeneration = generation
        watch = Watch(
            deadline: deadline,
            isCurrent: isCurrent,
            targetIsFrontmost: targetIsFrontmost,
            pasteConfirmed: pasteConfirmed,
            onConfirmed: onConfirmed
        )
        task = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: ClipboardLateConfirmationWatch.pollInterval)
                guard !Task.isCancelled, let self, self.generation == startedGeneration else { return }
                guard self.checkOnce() else { return }
            }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        watch = nil
    }

    /// Waits until the current watch, if any, has finished.
    func waitUntilFinished() async {
        while let current = task {
            await current.value
            if task == current { task = nil }
        }
    }

    /// One check, in the same order as the wait's: frontmost, confirmed, still
    /// frontmost. Returns whether to keep watching.
    private func checkOnce() -> Bool {
        guard let watch else { return finish() }
        let pastDeadline = ProcessInfo.processInfo.systemUptime >= watch.deadline
        guard watch.isCurrent(), watch.targetIsFrontmost() else { return finish() }
        let confirmed = watch.pasteConfirmed()
        guard watch.isCurrent(), watch.targetIsFrontmost() else { return finish() }
        if confirmed {
            _ = finish()
            watch.onConfirmed()
            return false
        }
        return pastDeadline ? finish() : true
    }

    private func finish() -> Bool {
        watch = nil
        task = nil
        return false
    }
}

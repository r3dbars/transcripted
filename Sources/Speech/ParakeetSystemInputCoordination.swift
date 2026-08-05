// ParakeetSystemInputCoordination.swift
// System default-input restore and late-completion reconciliation for
// ParakeetEngine, split out of ParakeetEngine.swift (codebase audit
// 2026-08-05 follow-up wave — same extension-file pattern as
// ParakeetDeviceRecovery.swift and ParakeetModelLifecycle.swift).
//
// When dictation temporarily overrides the system default input device
// (faster-Bluetooth-dictation path), this file owns putting the user's
// previous input back: the owner-bound pending-restore handoff, the
// bounded-timeout CoreAudio writes through the replaceable system-input
// work coordinator, and the reconciliation queue that converges late
// (timed-out) HAL completions back onto current MainActor intent.
//
// These are internal collaborator methods on ParakeetEngine — ParakeetEngine
// remains the public-API owner and MainActor home for this state
// (`pendingSystemInputRestore`, `pendingSystemInputReconciliations`,
// `systemInputReconciliationTask`, `systemInputWorkCoordinator`); this file
// just groups the system-input slice of its implementation.

import CoreAudio
import Foundation
import TranscriptedCore

struct ParakeetSystemInputRestoreTarget: Equatable, Sendable {
    let temporaryInput: AudioDeviceID
    let previousInput: AudioDeviceID
}

struct ParakeetSystemInputReconciliationRequest: Equatable, Sendable {
    let attemptedTarget: ParakeetSystemInputRestoreTarget
    let clearMarkerWhenRestored: Bool
}

extension ParakeetEngine {
    nonisolated private static func restoreSystemInputDeviceIfStillTemporary(
        temporaryInput: AudioDeviceID,
        previousInput: AudioDeviceID
    ) -> String? {
        do {
            let currentInput = try CoreAudioInputDeviceLookup.currentDefaultInputDeviceID()
            guard currentInput == temporaryInput else {
                return nil
            }
            try CoreAudioInputDeviceLookup.setDefaultInputDeviceID(previousInput)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    nonisolated private static func applySystemInputDevice(_ input: AudioDeviceID) -> String? {
        do {
            try CoreAudioInputDeviceLookup.setDefaultInputDeviceID(input)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func restoreSystemInputIfStillTemporary(
        temporaryInput: AudioDeviceID,
        previousInput: AudioDeviceID,
        operation: String
    ) async {
        ignoreInputSelectionConfigChangesUntil = CFAbsoluteTimeGetCurrent()
            + TranscriptedConstants.selfInducedConfigChangeIgnoreWindow
        let restoreTarget = ParakeetSystemInputRestoreTarget(
            temporaryInput: temporaryInput,
            previousInput: previousInput
        )
        let restoreError: String?
        do {
            restoreError = try await Self.systemInputWorkCoordinator.run(
                operation: operation,
                timeoutNanoseconds: TranscriptedConstants.systemInputOperationTimeout,
                cleanupAfterLateCompletion: { [weak self] _ in
                    Task { @MainActor [weak self] in
                        await self?.reconcileSystemInputAfterLateCompletion(
                            attemptedTarget: restoreTarget,
                            clearMarkerWhenRestored: true
                        )
                    }
                }
            ) {
                Self.restoreSystemInputDeviceIfStillTemporary(
                    temporaryInput: temporaryInput,
                    previousInput: previousInput
                )
            }
        } catch {
            reportSystemInputRestoreFailure(operation: operation, failureKind: "timeout")
            await reconcileSystemInputAfterLateCompletion(
                attemptedTarget: restoreTarget,
                clearMarkerWhenRestored: false
            )
            return
        }
        if restoreError != nil {
            reportSystemInputRestoreFailure(
                operation: operation,
                failureKind: "core_audio_error"
            )
        } else {
            if !pendingSystemInputRestore.hasPendingValue {
                DictationPersistentInputPreferences.setTemporaryRecoveryMarker(nil)
            }
        }
    }

    func restorePendingSystemInputAfterRecording(
        ownedBy owner: ParakeetAudioGraphOwnerToken?,
        operation: String
    ) async {
        guard let owner,
              let restoreTarget = pendingSystemInputRestore.take(ownedBy: owner) else { return }
        await restoreSystemInputIfStillTemporary(
            temporaryInput: restoreTarget.temporaryInput,
            previousInput: restoreTarget.previousInput,
            operation: operation
        )
    }

    private func reportSystemInputRestoreFailure(
        operation: String,
        failureKind: String
    ) {
        EventReporter.shared.capture(
            level: .warning,
            engine: "parakeet",
            event: "dictation_system_input_restore_failed",
            message: "Failed to restore system input after dictation route override",
            context: [
                "operation": operation,
                "failure_kind": failureKind,
            ]
        )
    }

    /// A timed-out CoreAudio write can finish after its queue has been retired.
    /// Re-apply the latest owner intent, or restore the attempted route when no
    /// successor exists, so late completion converges on current MainActor state.
    func reconcileSystemInputAfterLateCompletion(
        attemptedTarget: ParakeetSystemInputRestoreTarget,
        clearMarkerWhenRestored: Bool
    ) async {
        enqueueSystemInputReconciliation(
            ParakeetSystemInputReconciliationRequest(
                attemptedTarget: attemptedTarget,
                clearMarkerWhenRestored: clearMarkerWhenRestored
            )
        )
        if let systemInputReconciliationTask {
            await systemInputReconciliationTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainSystemInputReconciliations()
        }
        systemInputReconciliationTask = task
        await task.value
    }

    private func enqueueSystemInputReconciliation(
        _ request: ParakeetSystemInputReconciliationRequest
    ) {
        if let existingIndex = pendingSystemInputReconciliations.firstIndex(where: {
            $0.attemptedTarget == request.attemptedTarget
        }) {
            let existing = pendingSystemInputReconciliations[existingIndex]
            pendingSystemInputReconciliations[existingIndex] = ParakeetSystemInputReconciliationRequest(
                attemptedTarget: request.attemptedTarget,
                clearMarkerWhenRestored: existing.clearMarkerWhenRestored || request.clearMarkerWhenRestored
            )
        } else {
            pendingSystemInputReconciliations.append(request)
        }
    }

    private func drainSystemInputReconciliations() async {
        while !pendingSystemInputReconciliations.isEmpty {
            let request = pendingSystemInputReconciliations.removeFirst()
            await performSystemInputReconciliation(request)
        }
        systemInputReconciliationTask = nil
    }

    private func performSystemInputReconciliation(
        _ request: ParakeetSystemInputReconciliationRequest
    ) async {
        for _ in 0..<TranscriptedConstants.systemInputReconciliationAttempts {
            if let successorOwner = pendingSystemInputRestore.owner,
               let successorTarget = pendingSystemInputRestore.value(ownedBy: successorOwner) {
                let applyError: String?
                do {
                    applyError = try await Self.systemInputWorkCoordinator.run(
                        operation: "late_completion_successor_reconcile",
                        timeoutNanoseconds: TranscriptedConstants.systemInputOperationTimeout,
                        cleanupAfterLateCompletion: { [weak self] lateError in
                            Task { @MainActor [weak self] in
                                await self?.handleLateSystemInputReconciliationCompletion(
                                    coreAudioError: lateError,
                                    intendedOwner: successorOwner,
                                    intendedTarget: successorTarget,
                                    request: request
                                )
                            }
                        }
                    ) {
                        Self.applySystemInputDevice(successorTarget.temporaryInput)
                    }
                } catch {
                    reportSystemInputRestoreFailure(
                        operation: "late_completion_successor_reconcile",
                        failureKind: "timeout"
                    )
                    continue
                }
                guard applyError == nil else {
                    reportSystemInputRestoreFailure(
                        operation: "late_completion_successor_reconcile",
                        failureKind: "core_audio_error"
                    )
                    continue
                }
                if pendingSystemInputRestore.owner == successorOwner,
                   pendingSystemInputRestore.value(ownedBy: successorOwner) == successorTarget {
                    return
                }
                continue
            }

            let restoreError: String?
            do {
                restoreError = try await Self.systemInputWorkCoordinator.run(
                    operation: "late_completion_restore_reconcile",
                    timeoutNanoseconds: TranscriptedConstants.systemInputOperationTimeout,
                    cleanupAfterLateCompletion: { [weak self] lateError in
                        Task { @MainActor [weak self] in
                            await self?.handleLateSystemInputReconciliationCompletion(
                                coreAudioError: lateError,
                                intendedOwner: nil,
                                intendedTarget: nil,
                                request: request
                            )
                        }
                    }
                ) {
                    Self.restoreSystemInputDeviceIfStillTemporary(
                        temporaryInput: request.attemptedTarget.temporaryInput,
                        previousInput: request.attemptedTarget.previousInput
                    )
                }
            } catch {
                reportSystemInputRestoreFailure(
                    operation: "late_completion_restore_reconcile",
                    failureKind: "timeout"
                )
                continue
            }
            guard restoreError == nil else {
                reportSystemInputRestoreFailure(
                    operation: "late_completion_restore_reconcile",
                    failureKind: "core_audio_error"
                )
                continue
            }
            if !pendingSystemInputRestore.hasPendingValue {
                if request.clearMarkerWhenRestored {
                    DictationPersistentInputPreferences.setTemporaryRecoveryMarker(nil)
                }
                return
            }
        }
    }

    /// Timed-out reconciliation work may complete after a replacement queue has
    /// already converged the route. The late result needs more work only when
    /// MainActor intent changed while that HAL call was blocked. An unchanged
    /// successful intent is terminal, which prevents timeout callbacks from
    /// recursively creating an unbounded queue/task chain.
    private func handleLateSystemInputReconciliationCompletion(
        coreAudioError: String?,
        intendedOwner: ParakeetAudioGraphOwnerToken?,
        intendedTarget: ParakeetSystemInputRestoreTarget?,
        request: ParakeetSystemInputReconciliationRequest
    ) async {
        guard coreAudioError == nil else {
            reportSystemInputRestoreFailure(
                operation: intendedOwner == nil
                    ? "late_completion_restore_reconcile"
                    : "late_completion_successor_reconcile",
                failureKind: "core_audio_error"
            )
            return
        }

        if let intendedOwner, let intendedTarget {
            if pendingSystemInputRestore.owner == intendedOwner,
               pendingSystemInputRestore.value(ownedBy: intendedOwner) == intendedTarget {
                return
            }
        } else if !pendingSystemInputRestore.hasPendingValue {
            if request.clearMarkerWhenRestored {
                DictationPersistentInputPreferences.setTemporaryRecoveryMarker(nil)
            }
            return
        }

        await reconcileSystemInputAfterLateCompletion(
            attemptedTarget: request.attemptedTarget,
            clearMarkerWhenRestored: true
        )
    }

    func schedulePendingSystemInputRestore(
        ownedBy owner: ParakeetAudioGraphOwnerToken?,
        operation: String
    ) {
        guard let owner,
              let restoreTarget = pendingSystemInputRestore.take(ownedBy: owner) else { return }
        ignoreInputSelectionConfigChangesUntil = CFAbsoluteTimeGetCurrent()
            + TranscriptedConstants.selfInducedConfigChangeIgnoreWindow
        Self.systemInputWorkCoordinator.schedule(
            operation: operation,
            timeoutNanoseconds: TranscriptedConstants.systemInputOperationTimeout,
            cleanupAfterLateCompletion: { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.reconcileSystemInputAfterLateCompletion(
                        attemptedTarget: restoreTarget,
                        clearMarkerWhenRestored: true
                    )
                }
            },
            completion: { [weak self] (result: Result<String?, Error>) in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch result {
                    case .failure:
                        self.reportSystemInputRestoreFailure(
                            operation: operation,
                            failureKind: "timeout"
                        )
                        await self.reconcileSystemInputAfterLateCompletion(
                            attemptedTarget: restoreTarget,
                            clearMarkerWhenRestored: false
                        )
                    case .success(let restoreError):
                        if restoreError != nil {
                            self.reportSystemInputRestoreFailure(
                                operation: operation,
                                failureKind: "core_audio_error"
                            )
                        } else if !self.pendingSystemInputRestore.hasPendingValue {
                            DictationPersistentInputPreferences.setTemporaryRecoveryMarker(nil)
                        }
                    }
                }
            }
        ) {
            let restoreError = Self.restoreSystemInputDeviceIfStillTemporary(
                temporaryInput: restoreTarget.temporaryInput,
                previousInput: restoreTarget.previousInput
            )
            return restoreError
        }
    }
}

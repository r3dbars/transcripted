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
// (`pendingSystemInputRestore`, `systemInputReconciler`,
// `systemInputWorkCoordinator`); this file just groups the system-input slice
// of its implementation. The reconciliation queue itself is the compiled
// `ParakeetSystemInputReconciler` in ParakeetAudioGraphOwnership.swift.

import CoreAudio
import Foundation
import TranscriptedCore

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
    /// `ParakeetSystemInputReconciler` owns the queue, the bounded passes, and
    /// late-completion classification.
    func reconcileSystemInputAfterLateCompletion(
        attemptedTarget: ParakeetSystemInputRestoreTarget,
        clearMarkerWhenRestored: Bool
    ) async {
        await systemInputReconciler.reconcile(
            ParakeetSystemInputReconciliationRequest(
                attemptedTarget: attemptedTarget,
                clearMarkerWhenRestored: clearMarkerWhenRestored
            )
        )
    }

    func makeSystemInputReconciler() -> ParakeetSystemInputReconciler {
        ParakeetSystemInputReconciler(
            attempts: TranscriptedConstants.systemInputReconciliationAttempts,
            pendingRestore: { [weak self] in
                self?.pendingSystemInputRestore ?? ParakeetOwnerBoundPendingState()
            },
            runCoreAudio: { operation, cleanupAfterLateCompletion, work in
                try await Self.systemInputWorkCoordinator.run(
                    operation: operation,
                    timeoutNanoseconds: TranscriptedConstants.systemInputOperationTimeout,
                    cleanupAfterLateCompletion: cleanupAfterLateCompletion,
                    work
                )
            },
            applyInput: { input in
                Self.applySystemInputDevice(input)
            },
            restoreIfStillTemporary: { target in
                Self.restoreSystemInputDeviceIfStillTemporary(
                    temporaryInput: target.temporaryInput,
                    previousInput: target.previousInput
                )
            },
            reportFailure: { [weak self] operation, failureKind in
                self?.reportSystemInputRestoreFailure(
                    operation: operation,
                    failureKind: failureKind
                )
            }
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

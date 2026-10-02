import Foundation

struct DictationRecordingStartOverlayPolicy {
    enum Plan: Equatable {
        case skipLoadingAndStartRecording
        case showLoadingWhileWaiting
    }

    static func plan(isRecovering: Bool, inputFormatReady: Bool) -> Plan {
        if !isRecovering, inputFormatReady {
            return .skipLoadingAndStartRecording
        }
        return .showLoadingWhileWaiting
    }
}

struct DictationRecordingStartLifecyclePolicy {
    enum StopDecision: Equatable {
        case cancelPendingStart
        case stopRecording
        case ignoreInactive
    }

    static func stopDecision(
        isLoadingOverlay: Bool,
        isListeningOverlay: Bool,
        hasStartupTask: Bool,
        hasRecordingStartTask: Bool,
        sttIsRecording: Bool
    ) -> StopDecision {
        if !sttIsRecording, (isLoadingOverlay || hasStartupTask || hasRecordingStartTask) {
            return .cancelPendingStart
        }

        if isListeningOverlay || sttIsRecording {
            return .stopRecording
        }

        return .ignoreInactive
    }
}

/// Where a Stop request for an active take goes, once repeat stops are fenced.
enum DictationStopRoute: Equatable {
    /// A hotkey ended a start still warming up: say why nothing was recorded.
    case cancelPendingStartAfterEarlyRelease
    case cancelPendingStart
    /// Nothing is recording. `showStillFinishing` answers a press that lands
    /// while the last take is still transcribing, so the hotkey isn't silent.
    case ignore(showStillFinishing: Bool)
    /// Stop arrived before the mic captured anything and no audio was kept.
    case captureNotStarted
    /// Stop the take, including one whose audio survived a device recovery.
    case stopRecording

    static let stillFinishingMessage = "Still finishing the last dictation. Try again in a moment."

    static func route(
        stopDecision: DictationRecordingStartLifecyclePolicy.StopDecision,
        trigger: DictationTrigger,
        isFinishingPreviousTake: @autoclosure () -> Bool,
        isRecording: @autoclosure () -> Bool,
        hasRecoverableRecording: @autoclosure () -> Bool
    ) -> DictationStopRoute {
        switch stopDecision {
        case .cancelPendingStart:
            return trigger == .physicalKey ? .cancelPendingStartAfterEarlyRelease : .cancelPendingStart
        case .ignoreInactive:
            return .ignore(showStillFinishing: isFinishingPreviousTake())
        case .stopRecording:
            // Audio kept through a device recovery still goes to transcription
            // instead of the mic-start failure path.
            guard isRecording() || hasRecoverableRecording() else { return .captureNotStarted }
            return .stopRecording
        }
    }
}

/// Admission fence for the one stop/checkpoint/transcribe/deliver chain that
/// owns a dictation session. Repeated Stop calls cannot cancel or overwrite
/// the first chain while its durable WAV write is still in flight.
struct DictationStopFinalizationGate {
    private(set) var admittedSessionID: UUID?

    mutating func admit(sessionID: UUID) -> Bool {
        guard admittedSessionID != sessionID else { return false }
        admittedSessionID = sessionID
        return true
    }

    mutating func reset() {
        admittedSessionID = nil
    }
}

struct DictationStartAvailabilityPolicy {
    // Also shown while a meeting is still starting, so it can't say "saving".
    static let meetingFinishingMessage = "The meeting is starting or stopping. Try dictation again in a moment."
    static let speakerReviewMessage = "Speaker review can wait. Dictation is available."

    static func unavailableReason(
        hasActiveMeetingCapture: Bool,
        canShareMeetingMic: Bool,
        isSpeakerReviewPending: Bool
    ) -> String? {
        // Active meeting capture is a supported source: dictation borrows the
        // meeting mic stream instead of opening another audio graph. During
        // finalization that stream is no longer safe to borrow, so wait for
        // teardown instead of starting a competing audio graph.
        if hasActiveMeetingCapture, !canShareMeetingMic {
            return meetingFinishingMessage
        }
        _ = isSpeakerReviewPending
        return nil
    }
}

struct DictationRecordingStartFailureCleanupPlan: Equatable {
    let outcome: String
    let resetRuntimeSessionToIdle: Bool
    let resetSpeechEngine: Bool
    let hardResetSpeechEngine: Bool
    let reportBeforeCleanup: Bool
    let reportRuntimeStall: Bool
}

struct DictationRecordingStartFailurePolicy {
    static func cleanupPlan(for failureKind: String) -> DictationRecordingStartFailureCleanupPlan {
        let isMicStartTimeout = failureKind == "microphone_start_timeout"
        return DictationRecordingStartFailureCleanupPlan(
            outcome: failureKind,
            resetRuntimeSessionToIdle: true,
            resetSpeechEngine: true,
            hardResetSpeechEngine: isMicStartTimeout,
            reportBeforeCleanup: isMicStartTimeout,
            reportRuntimeStall: false
        )
    }
}

struct DictationMicrophoneTimeoutPresentationPolicy {
    static func message(
        deviceName: String,
        startAttempts: Int,
        inputFormatReady: Bool,
        routeContext: [String: String] = [:]
    ) -> String {
        if isBluetoothFallbackRoute(routeContext) {
            return "Built-in mic unavailable. Choose another input."
        }

        if startAttempts > 0, inputFormatReady {
            return "Mic didn't start. Try again or choose another input."
        }

        return "Selected mic unavailable. Choose another input."
    }

    private static func isBluetoothFallbackRoute(_ context: [String: String]) -> Bool {
        let selectedInputClass = context["selected_input_class"] ?? context["input_device_class"]

        return context["selection_overrode_default"] == "true"
            && context["selection_reason"] == "preferredBuiltInForBluetoothHeadset"
            && context["default_input_class"] == "bluetooth"
            && context["default_output_class"] == "bluetooth"
            && selectedInputClass == "built_in"
    }
}

/// What to tell a user whose own hotkey ended a dictation session before the
/// microphone finished opening — the single message emitted by
/// `DictationSessionController.cancelPendingDictationStartAfterEarlyRelease`.
///
/// "Mic wasn't ready yet" is the right line when a start was genuinely still
/// working, and the wrong one in the case #1743 turned out to be. That
/// reporter had Push to Talk configured and was tapping the key rather than
/// holding it, so every session ended a few milliseconds after it began. His
/// own logs closed it: three failures at 76ms, 22ms and 72ms, each with the
/// input format already reported ready. Because the message named the
/// microphone as the thing at fault, he swapped built-in for USB mics,
/// suspected his machine's EDR software, and spent five days on a setting.
///
/// So below `shortTapThresholdMs`, in Push to Talk, the key was tapped and
/// the microphone had nothing to do with it — say that instead. The threshold
/// sits well above an observed tap (tens of milliseconds) and well below a
/// deliberate hold, so a real stalled start still gets the honest line.
///
/// Hands-free is deliberately excluded. Its second press arrives through the
/// same branch, but a press that fast is a double-tap, and telling someone to
/// hold a key they are meant to press twice would be worse than saying
/// nothing specific at all.
struct DictationEarlyReleasePresentationPolicy {
    /// Under this, a Push to Talk release is a tap, not a hold.
    static let shortTapThresholdMs = 250

    static let microphoneNotReadyMessage = "Mic wasn't ready yet. Nothing was recorded. Try again."
    static let shortTapMessage = "Hold the key while you speak. Push to Talk records until you let go."

    static func message(shortcutMode: DictationShortcutMode?, pendingForMs: Int) -> String {
        guard shortcutMode == .pushToTalk, pendingForMs < shortTapThresholdMs else {
            return microphoneNotReadyMessage
        }
        return shortTapMessage
    }
}

/// The diagnostics event for a hotkey that ended a start before the mic was
/// ready. It is the line behind the error the user sees.
struct DictationEarlyReleaseCancelReport: Equatable {
    static let engine = "dictation"
    static let event = "dictation_cancelled_before_microphone_ready"
    // Deliberately not "push-to-talk release": hands-free is the default
    // mode, and its stop press reaches here too.
    static let message = "Dictation hotkey ended the session before the microphone finished opening"
    /// `.error`, not `.info`: only `.error` events reach Sentry and the
    /// reliability counter. The user asked to dictate, saw an error, and lost
    /// the attempt, the same as `microphone_start_timeout`.
    static let level: EventLevel = .error

    /// `pending_for_ms` is how long the start had been running when the
    /// hotkey ended it (seconds means a stalled mic open, ~100 ms means a quick
    /// tap beat a normal start, see #1743). `pending_stage` says what that
    /// time went to. `duration_ms` repeats `pending_for_ms` for older readers.
    static func context(
        trigger: String,
        shortcutMode: DictationShortcutMode?,
        pendingForMs: Int,
        pendingStage: String,
        stagePendingForMs: Int,
        startPlan: String,
        appActive: Bool
    ) -> [String: String] {
        [
            "trigger": trigger,
            // Matches the session outcome, and is a key the analytics registry
            // allows for `reliability_failure_observed`.
            "failure_kind": "microphone_not_ready",
            "shortcut_mode": shortcutMode?.rawValue ?? "unknown",
            "pending_for_ms": "\(pendingForMs)",
            "duration_ms": "\(pendingForMs)",
            "pending_stage": pendingStage,
            "stage_pending_for_ms": "\(stagePendingForMs)",
            "start_plan": startPlan,
            "app_active": "\(appActive)",
        ]
    }
}

struct DictationActiveTaskCancellationPlan: Equatable {
    let cancelStreamingTask: Bool
    let cancelSpeechEngine: Bool
}

enum DictationActiveTaskCancellationPolicy {
    static func plan(
        cancelRecording: Bool,
        recordingStartWasInFlight: Bool,
        sttIsRecording: Bool,
        sttIsTranscribing: Bool
    ) -> DictationActiveTaskCancellationPlan {
        DictationActiveTaskCancellationPlan(
            // Cancellation is cooperative: queued work can exit immediately,
            // while native inference retains its busy state until it returns.
            cancelStreamingTask: true,
            cancelSpeechEngine: cancelRecording
                && !sttIsTranscribing
                && (sttIsRecording || recordingStartWasInFlight)
        )
    }
}

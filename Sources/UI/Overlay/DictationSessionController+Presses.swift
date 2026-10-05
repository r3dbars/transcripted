// DictationSessionController+Presses.swift
// Back-to-back and early presses: queued starts, modifier combos, early release.

import AppKit
import Combine

extension DictationSessionController {
    /// A hands-free modifier press started this session, then another key went
    /// down while it was held: it was a combo (Option+M, or typing é), not a
    /// dictation tap. Drop the start with no sound, error, or saved audio.
    /// With no session id the press only queued a start behind a take that
    /// was still finishing, so that queued start is dropped instead.
    func abandonDictationStartForModifierCombo(sessionID: UUID?) {
        guard let (appState, overlayController) = readyState() else { return }
        guard let sessionID else {
            dropQueuedDictationStart(showMessage: false)
            return
        }
        guard isDictating, currentDictationSessionID == sessionID else { return }
        let startPendingForMs = Int((CFAbsoluteTimeGetCurrent() - sessionStartTime) * 1000)
        let stage = pendingStartStage.end(now: CFAbsoluteTimeGetCurrent()).stage.rawValue
        cancelActiveTasks(cancelRecording: true)
        discardStoppedAudioRecovery(explicitDiscard: true)
        overlayController.hideWithCancelAnimation()
        isDictating = false
        appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "modifier_combo")
        DiagnosticsTrail.record(
            logger: appState.logger,
            level: .info,
            engine: "dictation",
            event: "dictation_start_dropped_for_modifier_combo",
            message: "A hands-free key press became a key combo, so its dictation start was dropped",
            context: dictationContext(
                extra: [
                    "trigger": currentDictationTrigger.rawValue,
                    "pending_for_ms": "\(startPendingForMs)",
                    "pending_stage": stage
                ]
            )
        )
        // Closes the attempt `dictation_start_requested` opened, so the start
        // funnel doesn't read a dropped combo as a lost start.
        AnalyticsReporter.track(
            "dictation_start_dropped_for_modifier_combo",
            properties: [
                "duration_bucket": AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime),
                "trigger": currentDictationTrigger.rawValue,
            ]
        )
    }

    // MARK: - Back-to-back presses

    /// Whether the last take has stopped recording but is still being
    /// transcribed, pasted, or saved.
    private var isPreviousDictationFinishing: Bool {
        guard let appState, let overlayController else { return false }
        if isDictating {
            return stopFinalizationGate.admittedSessionID == currentDictationSessionID
                && overlayController.state != .listening
                && overlayController.state != .starting
        }
        return appState.sttRouter.isTranscribing
    }

    /// Remembers a start-shortcut press that landed while the last take is
    /// still finishing, and starts it once that take is done. Returns false
    /// when the press isn't one to remember, so the caller keeps its old
    /// handling.
    @discardableResult
    func rememberStartPressIfFinishing(
        sourceApp: NSRunningApplication?,
        trigger: DictationTrigger,
        shortcutMode: DictationShortcutMode?,
        isRetry: Bool = false
    ) -> Bool {
        guard queuedStartGate.admitsPress(
                  shortcutMode: shortcutMode,
                  previousIsFinishing: { isPreviousDictationFinishing }
              ),
              let shortcutMode else { return false }
        if let queued = queuedDictationStart,
           queued.shortcutMode == .handsFree,
           shortcutMode == .handsFree {
            // Hands-free toggles: a second press takes the waiting start back.
            dropQueuedDictationStart(showMessage: false)
            return true
        }
        queuedDictationStart = QueuedDictationStart(
            sourceApp: sourceApp,
            trigger: trigger,
            shortcutMode: shortcutMode,
            isRetry: isRetry,
            requestedAt: ProcessInfo.processInfo.systemUptime
        )
        if let overlayController,
           overlayController.listeningNotice.isEmpty
            || overlayController.listeningNotice == DictationQueuedStartPolicy.waitingNotice {
            overlayController.listeningNotice = DictationQueuedStartPolicy.waitingNotice
        }
        appState?.logger.log("DICTATION | start press remembered while the last dictation finishes")
        queuedDictationStartTask?.cancel()
        queuedDictationStartTask = Task { @MainActor [weak self] in
            guard let requestedAt = self?.queuedDictationStart?.requestedAt else { return }
            let decision = await DictationQueuedStartWait.run(DictationQueuedStartWait.Steps(
                evaluate: { [weak self] waited in
                    guard let self, self.queuedDictationStart != nil else { return nil }
                    let stillFinishing = self.isDictating || (self.appState?.sttRouter.isTranscribing ?? false)
                    // A take that ended in a problem or a "press ⌘V" notice keeps
                    // its message; starting over it would wipe the only sign the
                    // text didn't land (and its Transcribe It or Paste It button).
                    let previousLeftMessage = self.overlayController.map {
                        DictationQueuedStartPolicy.previousLeftMessage(
                            isDrafting: $0.state == .drafting,
                            errorMessage: $0.errorMessage,
                            messageCanGiveWayToNextStart: $0.messageCanGiveWayToNextStart
                        )
                    } ?? false
                    return DictationQueuedStartPolicy.decision(
                        previousStillFinishing: stillFinishing,
                        previousLeftMessage: previousLeftMessage,
                        secondsWaited: waited
                    )
                },
                watchChanges: { [weak self] wake in
                    guard let self else { return {} }
                    // Only wakes: @Published emits in willSet, so the check
                    // runs on the next turn, once the new value is in place.
                    // dropFirst: the current value isn't a change.
                    var changes: [AnyPublisher<Void, Never>] = [
                        self.$isDictating.dropFirst().map { _ in () }.eraseToAnyPublisher()
                    ]
                    if let router = self.appState?.sttRouter {
                        changes.append(router.$isTranscribing.dropFirst().map { _ in () }.eraseToAnyPublisher())
                    }
                    let watch = Publishers.MergeMany(changes).sink { _ in wake() }
                    return { watch.cancel() }
                },
                now: { ProcessInfo.processInfo.systemUptime },
                requestedAt: requestedAt,
                // Not Task.sleep(for:): ContinuousClock counts system sleep,
                // and systemUptime (what `requestedAt` is on) doesn't.
                sleep: { try? await Task.sleep(nanoseconds: $0) }
            ))
            guard let self, let decision, !Task.isCancelled,
                  let request = self.queuedDictationStart else { return }
            switch decision {
            case .keepWaiting:
                return
            case .start:
                self.queuedDictationStart = nil
                self.queuedDictationStartTask = nil
                self.clearQueuedStartNotice()
                self.startDictation(
                    sourceApp: request.sourceApp,
                    trigger: request.trigger,
                    shortcutMode: request.shortcutMode,
                    isRetry: request.isRetry
                )
            case .giveUp:
                self.queuedDictationStartTask = nil
                self.dropQueuedDictationStart(showMessage: true)
            case .dropForMessage:
                self.queuedDictationStartTask = nil
                self.dropQueuedDictationStart(showMessage: false)
            }
        }
        return true
    }

    // MARK: - Tap to keep listening

    /// A hands-free take is still recording, not finishing, so a Push to
    /// Talk press can stop it.
    var isHandsFreeTakeListening: Bool {
        currentDictationShortcutMode == .handsFree && isTakeStillListening
    }

    /// Recording (or opening the mic), and no stop admitted yet. The overlay
    /// stays `.listening` for a moment after a stop is admitted, so
    /// `isPreviousDictationFinishing` alone isn't enough.
    private var isTakeStillListening: Bool {
        isDictating
            && stopFinalizationGate.admittedSessionID != currentDictationSessionID
            && !isPreviousDictationFinishing
    }

    /// A Push to Talk press ends a hands-free take. Pressed again before the
    /// mic even opened, it was a double tap: drop it quietly rather than say
    /// the mic wasn't ready (#1743).
    func stopHandsFreeTakeFromPushToTalkPress() {
        if let appState, let overlayController,
           DictationRecordingStartLifecyclePolicy.stopDecision(
               isLoadingOverlay: overlayController.state == .loading,
               isListeningOverlay: overlayController.state == .listening,
               hasStartupTask: startupTask != nil,
               hasRecordingStartTask: recordingStartRetryTask != nil,
               sttIsRecording: appState.sttRouter.isRecording
           ) == .cancelPendingStart {
            cancelDictation()
            return
        }
        stopDictationAndPaste(trigger: .physicalKey, shortcutMode: .handsFree)
    }

    /// A Push to Talk press takes back a start a tap kept waiting on the last
    /// take, the way a second hands-free press does. One the hands-free key
    /// queued stays. True when there was one to drop.
    func dropQueuedTapKeptStart() -> Bool {
        guard queuedDictationStart?.keptByTap == true else { return false }
        dropQueuedDictationStart(showMessage: false)
        return true
    }

    /// The Push to Talk key was tapped, not held: keep its take going
    /// hands-free, so the next press stops it. Covers a take still opening
    /// the mic and a press remembered behind the last take. Returns false
    /// when there's no Push to Talk take to keep.
    func keepPushToTalkTakeListening() -> Bool {
        if let queued = queuedDictationStart, queued.shortcutMode == .pushToTalk {
            queuedDictationStart = QueuedDictationStart(
                sourceApp: queued.sourceApp,
                trigger: queued.trigger,
                shortcutMode: .handsFree,
                isRetry: queued.isRetry,
                requestedAt: queued.requestedAt,
                keptByTap: true
            )
            return true
        }
        guard currentDictationShortcutMode == .pushToTalk, isTakeStillListening else { return false }
        currentDictationShortcutMode = .handsFree
        DiagnosticsTrail.record(
            logger: appState?.logger,
            level: .info,
            engine: "dictation",
            event: "dictation_tap_kept_listening",
            message: "Push to Talk key was tapped, so the take keeps listening hands-free",
            context: dictationContext(
                extra: ["trigger": currentDictationTrigger.rawValue]
            )
        )
        return true
    }

    /// A push-to-talk key let go before its remembered press could start.
    /// Returns true when there was one to drop.
    @discardableResult
    func dropQueuedPushToTalkStart() -> Bool {
        guard queuedDictationStart?.shortcutMode == .pushToTalk else { return false }
        dropQueuedDictationStart(showMessage: true)
        return true
    }

    /// Forgets a remembered press. It still counts as a refused start, the
    /// same as the old "still finishing" refusal did.
    func dropQueuedDictationStart(showMessage: Bool) {
        guard let request = queuedDictationStart else { return }
        queuedDictationStart = nil
        queuedDictationStartTask?.cancel()
        queuedDictationStartTask = nil
        clearQueuedStartNotice()
        guard let (appState, overlayController) = readyState() else { return }
        // Counted as a refused request, and quiet while the last take is
        // still on screen transcribing. See DictationQueuedStartPolicy.drop.
        DictationQueuedStartPolicy.drop(
            showMessage: showMessage,
            isDictating: isDictating,
            DictationQueuedStartPolicy.DropSteps(
                countRequest: {
                    self.trackDictationStartRequested(appState: appState, trigger: request.trigger, isRetry: request.isRetry)
                },
                countRefusal: { failureKind in
                    self.trackDictationStartRefused(appState: appState, trigger: request.trigger, failureKind: failureKind)
                },
                showStillFinishing: {
                    overlayController.showError(DictationStopRoute.stillFinishingMessage)
                }
            )
        )
    }

    private func clearQueuedStartNotice() {
        guard let overlayController,
              overlayController.listeningNotice == DictationQueuedStartPolicy.waitingNotice else { return }
        overlayController.listeningNotice = ""
    }

    func cancelPendingDictationStartAfterEarlyRelease(
        appState: TranscriptedAppState,
        overlayController: FloatingOverlayController,
        shortcutMode: DictationShortcutMode?
    ) {
        cancelActiveTasks(cancelRecording: true)
        // No cancel cue here: an early release is often a quick modifier chord
        // (Fn+arrow), and a sound on every one of those would be noise.
        let releasedWhileAppActive = NSApp.isActive
        let now = CFAbsoluteTimeGetCurrent()
        let startPendingForMs = Int((now - sessionStartTime) * 1000)
        // Read what the start was waiting on and reset it in one step, before
        // the session is torn down.
        let ended = pendingStartStage.end(now: now)
        isDictating = false
        appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "microphone_not_ready")
        // This is the line behind the error the user actually sees, and it is
        // the one we ask a reporter to paste back from
        // ~/Library/Application Support/Transcripted/logs/debug.log. What
        // each field means, and why it is an `.error`, is on
        // DictationEarlyReleaseCancelReport (#1743).
        DiagnosticsTrail.record(
            logger: appState.logger,
            level: DictationEarlyReleaseCancelReport.level,
            engine: DictationEarlyReleaseCancelReport.engine,
            event: DictationEarlyReleaseCancelReport.event,
            message: DictationEarlyReleaseCancelReport.message,
            context: dictationContext(
                extra: DictationEarlyReleaseCancelReport.context(
                    trigger: currentDictationTrigger.rawValue,
                    shortcutMode: shortcutMode,
                    pendingForMs: startPendingForMs,
                    pendingStage: ended.stage.rawValue,
                    stagePendingForMs: ended.msInStage,
                    startPlan: currentStartReadinessProfile.name,
                    appActive: releasedWhileAppActive
                )
            )
        )
        // Same two numbers the diagnostics above already carry. Whether the
        // microphone is worth blaming is decided from them, not asserted:
        // see DictationEarlyReleasePresentationPolicy for why #1743's tapped
        // Push to Talk key must not be told the mic wasn't ready.
        overlayController.showError(
            DictationEarlyReleasePresentationPolicy.message(
                shortcutMode: shortcutMode,
                pendingForMs: startPendingForMs
            )
        )
    }
}

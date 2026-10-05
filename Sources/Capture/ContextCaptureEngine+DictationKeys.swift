// ContextCaptureEngine+DictationKeys.swift
// The physical dictation keys as session commands: Push to Talk press and
// release (hold, or tap to keep listening) and the hands-free toggle.

import AppKit

extension ContextCaptureEngine {
    func handlePhysicalDictationPushToTalkPress() {
        let frontApp = NSWorkspace.shared.frontmostApplication
        guard let session = sessionController else { return }
        DiagnosticsTrail.record(
            logger: session.appState?.logger,
            engine: "capture",
            event: "dictation_push_to_talk_pressed",
            message: "Dictation push-to-talk trigger pressed",
            context: [
                "trigger": "physical_key",
                "source_app_name": frontApp?.localizedName ?? "",
                "source_app_bundle_id": frontApp?.bundleIdentifier ?? "",
                "session_state": dictationSessionStateName(session),
                "overlay_state": overlayStateName(session.overlayController?.state)
            ]
        )

        // A press while the last take is still transcribing starts the next
        // one when it finishes, instead of being dropped. A press during a
        // take a tap kept going stops it.
        let wasDictating = session.isDictating
        pushToTalkPressStoppedTake = dictationHotkeyRouter(session: session, sourceApp: frontApp)
            .pushToTalkPressed() == .stoppedHandsFreeTake
        pushToTalkPressStartedSessionID = wasDictating ? nil : session.activeDictationSessionID
    }

    /// A Push to Talk press on a shared modifier fired on press, then a combo
    /// key went down inside the chord window (Option+M, or é typed with Right
    /// Option+E). Drop the dictation it started, or the start it queued
    /// behind a take that was still finishing, as the hands-free key does. A
    /// press that would stop a take waits out the chord delay instead; if the
    /// detector's copy of isDictating was stale and it stopped one anyway,
    /// there's nothing to drop.
    func handlePhysicalDictationPushToTalkComboInterrupted() {
        let sessionID = pushToTalkPressStartedSessionID
        pushToTalkPressStartedSessionID = nil
        guard !pushToTalkPressStoppedTake else {
            pushToTalkPressStoppedTake = false
            return
        }
        sessionController?.abandonDictationStartForModifierCombo(sessionID: sessionID)
    }

    func handlePhysicalDictationPushToTalkRelease(wasTap: Bool) {
        guard let session = sessionController else { return }
        if pushToTalkPressStoppedTake {
            pushToTalkPressStoppedTake = false
            return
        }

        DiagnosticsTrail.record(
            logger: session.appState?.logger,
            engine: "capture",
            event: "dictation_push_to_talk_released",
            message: "Dictation push-to-talk trigger released",
            context: [
                "trigger": "physical_key",
                "was_tap": wasTap ? "true" : "false",
                "session_state": dictationSessionStateName(session),
                "overlay_state": overlayStateName(session.overlayController?.state)
            ]
        )

        // Let go before the remembered press could start: nothing was
        // recorded, so say the last one is still finishing.
        // A quick tap keeps listening hands-free when that's on.
        dictationHotkeyRouter(session: session, sourceApp: nil).pushToTalkReleased(wasTap: wasTap)
    }

    func handlePhysicalDictationHandsFreePress() {
        handsFreePressStartedSessionID = nil
        guard shouldAcceptHotkeyAction(.dictationHandsFree) else {
            DiagnosticsTrail.record(
                logger: sessionController?.appState?.logger,
                level: .info,
                engine: "capture",
                event: "hotkey_repeat_ignored",
                message: "Ignored rapid repeat hands-free dictation trigger",
                context: [
                    "hotkey_id": "dictation_hands_free",
                    "session_state": dictationSessionStateName(sessionController),
                    "overlay_state": overlayStateName(sessionController?.overlayController?.state)
                ]
            )
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let wasDictating = sessionController?.isDictating ?? false
        routeHandsFreeToggle(sourceApp: frontApp)
        if !wasDictating {
            handsFreePressStartedSessionID = sessionController?.activeDictationSessionID
        }
    }

    /// The hands-free press turned out to be a combo (Option+M, or typing é),
    /// so drop the dictation it started, or the start it queued behind a take
    /// that was still finishing, quietly. A press that stopped a dictation
    /// waited for release, so it never gets here.
    func handlePhysicalDictationHandsFreeComboInterrupted() {
        let sessionID = handsFreePressStartedSessionID
        handsFreePressStartedSessionID = nil
        sessionController?.abandonDictationStartForModifierCombo(sessionID: sessionID)
    }

    func routeHandsFreeToggle(sourceApp: NSRunningApplication?) {
        let trigger = DictationTrigger.physicalKey
        guard isHotkeyRoutingActive, let session = sessionController else { return }
        DiagnosticsTrail.record(
            logger: session.appState?.logger,
            engine: "capture",
            event: "dictation_toggle_requested",
            message: "Dictation toggle requested",
            context: [
                "trigger": trigger.rawValue,
                "source_app_name": sourceApp?.localizedName ?? "",
                "source_app_bundle_id": sourceApp?.bundleIdentifier ?? "",
                "session_state": dictationSessionStateName(session),
                "overlay_state": overlayStateName(session.overlayController?.state)
            ]
        )
        dictationHotkeyRouter(session: session, sourceApp: sourceApp).handsFreePressed()
    }

    /// The session commands behind the physical dictation keys. The routing
    /// itself (and which shortcut each command names) is `DictationHotkeyRouter`.
    func dictationHotkeyRouter(
        session: DictationSessionController,
        sourceApp: NSRunningApplication?
    ) -> DictationHotkeyRouter {
        DictationHotkeyRouter(
            isDictating: { session.isDictating },
            rememberStartPressIfFinishing: { trigger, shortcutMode in
                session.rememberStartPressIfFinishing(
                    sourceApp: sourceApp,
                    trigger: trigger,
                    shortcutMode: shortcutMode
                )
            },
            dropQueuedPushToTalkStart: { session.dropQueuedPushToTalkStart() },
            start: { trigger, shortcutMode in
                session.startDictation(sourceApp: sourceApp, trigger: trigger, shortcutMode: shortcutMode)
            },
            stop: { trigger, shortcutMode in
                session.stopDictationAndPaste(trigger: trigger, shortcutMode: shortcutMode)
            },
            tapKeepsListening: { HotkeyPreferences.dictationKeyBehavior() == .holdOrTap },
            isHandsFreeTakeListening: { session.isHandsFreeTakeListening },
            stopHandsFreeTake: { session.stopHandsFreeTakeFromPushToTalkPress() },
            dropQueuedTapKeptStart: { session.dropQueuedTapKeptStart() },
            keepPushToTalkTakeListening: { session.keepPushToTalkTakeListening() }
        )
    }
}

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
        pushToTalkPressStoppedTake = dictationHotkeyRouter(session: session, sourceApp: frontApp)
            .pushToTalkPressed() == .stoppedHandsFreeTake
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
            tapKeepsListening: { HotkeyPreferences.pushToTalkTapKeepsListening() },
            isHandsFreeTakeListening: { session.isHandsFreeTakeListening },
            stopHandsFreeTake: { session.stopHandsFreeTakeFromPushToTalkPress() },
            dropQueuedTapKeptStart: { session.dropQueuedTapKeptStart() },
            keepPushToTalkTakeListening: { session.keepPushToTalkTakeListening() }
        )
    }
}

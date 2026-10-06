// DictationSessionController+SessionCap.swift
// The dictation length cap (15 minutes) and its live countdown.

import AppKit

extension DictationSessionController {
    /// Max duration for a listening session before the cap saves it (15 minutes).
    /// Prevents stuck sessions when the user walks away from the computer.
    /// Derived from the shared constant so the speech engine's audio buffer
    /// sizing stays in lockstep with the cap.
    private static let sessionTimeoutNanos: UInt64 =
        UInt64(TranscriptedConstants.dictationSessionMaxDuration * 1_000_000_000)
    private static let sessionTimeoutInterval: TimeInterval =
        TranscriptedConstants.dictationSessionMaxDuration
    /// Cap on each polling sleep so a wake from system sleep gets a chance to
    /// re-evaluate the uptime-based deadline before firing the cancel branch.
    private static let sessionTimeoutPollIntervalNanos: UInt64 = 30 * 1_000_000_000

    /// Install a timeout that finalizes the session after 15 minutes of
    /// *active* uptime. Tracks the deadline against `ProcessInfo.systemUptime`
    /// so Mac sleep does not consume the session's remaining record window —
    /// otherwise a session that sees the Mac sleep for hours would auto-cancel
    /// immediately on wake when Task.sleep's wall-clock deadline expires.
    func installSessionTimeout() {
        sessionTimeoutTask?.cancel()
        var timeout = DictationSessionTimeout(timeoutInterval: Self.sessionTimeoutInterval)
        timeout.start(at: ProcessInfo.processInfo.systemUptime)
        sessionTimeoutTask = Task { [weak self] in
            // DictationSessionCapTimer sleeps until the last 30 seconds, then
            // ticks every second so the pill counts down live, and returns at
            // the cap (or on cancel).
            await DictationSessionCapTimer.run(
                DictationSessionCapTimer.Steps(
                    timeout: timeout,
                    pollIntervalNanos: Self.sessionTimeoutPollIntervalNanos,
                    uptime: { ProcessInfo.processInfo.systemUptime },
                    sleep: { nanoseconds in try? await Task.sleep(nanoseconds: nanoseconds) },
                    isCancelled: { Task.isCancelled },
                    showCountdown: { remainingSeconds, announce in
                        self?.showSessionCapCountdown(
                            remainingSeconds: remainingSeconds,
                            announce: announce
                        ) == true
                    }
                )
            )
            guard !Task.isCancelled, let self = self else { return }
            if case .finalize(let shouldAutoPaste) = DictationSessionCapFinish.action(
                isDictating: self.isDictating,
                originalTargetIsFrontmost: self.sessionPasteTarget?.matchesCurrentFrontmostApp() ?? false
            ) {
                self.appState?.logger.log(
                    shouldAutoPaste
                        ? "DICTATION | session cap reached, finalizing with original paste target still active"
                        : "DICTATION | session cap reached, finalizing without paste"
                )
                EventReporter.shared.capture(level: .info, engine: "overlay", event: "dictation_timeout",
                    message: shouldAutoPaste
                        ? "Dictation reached the session cap; pasting because the original target is still active"
                        : "Dictation reached the session cap; saving without paste")
                self.stopDictationAndPaste(trigger: .sessionCap, autoPaste: shouldAutoPaste)
            }
        }
    }

    /// Shows the cap countdown in the listening pill's notice slot. The
    /// pill keeps listening (waveform, stop button, Esc) the whole time.
    /// Returns whether the countdown is on screen.
    @discardableResult
    private func showSessionCapCountdown(remainingSeconds: Double, announce: Bool) -> Bool {
        guard isDictating,
              let overlayController,
              overlayController.state == .listening else { return false }
        let current = overlayController.listeningNotice
        // The Esc confirm prompt wins while it waits for a second press; the
        // next tick puts the countdown back.
        guard current.isEmpty || DictationSessionCapWarningPolicy.isCapNotice(current) else { return false }
        overlayController.listeningNotice = DictationSessionCapWarningPolicy.notice(
            remainingSeconds: remainingSeconds,
            shortcutMode: currentDictationShortcutMode
        )
        if announce {
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: DictationSessionCapWarningPolicy.announcement(
                        shortcutMode: currentDictationShortcutMode
                    ),
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }
        return true
    }

    /// Drops the cap countdown once the take stops, so it can't linger into
    /// the transcribing pill. Leaves any other notice alone.
    func clearSessionCapCountdown() {
        guard let overlayController,
              DictationSessionCapWarningPolicy.isCapNotice(overlayController.listeningNotice) else { return }
        overlayController.listeningNotice = ""
    }
}

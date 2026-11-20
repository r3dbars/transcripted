// Runs only in the dev build's isolated launch smoke. Drive AppKit target/action
// on retained buttons so a refresh can occur between hit testing and dispatch.
import AppKit

@MainActor
enum MeetingOverlayActionSmoke {
    static func failures(router: STTRouter) async -> [String] {
        guard AutomatedLaunchEnvironment.isActive() else { return ["Missing launch isolation"] }
        let session = MeetingSessionController(sttRouter: router)
        let overlay = MeetingOverlayController()
        let view = NotchIslandView(frame: .zero)
        let defaults = UserDefaults.standard
        let key = NotchIslandPreferences.meetingMicMuteControlKey
        let originalPreference = defaults.object(forKey: key)
        defer { defaults.set(originalPreference, forKey: key) }
        var failures: [String] = []
        func expect(_ condition: Bool, _ promise: String) {
            if !condition { failures.append(promise) }
        }
        func drain() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        func render() {
            let layout = NotchIslandPresentation.layout(dictation: nil, meeting: overlay.islandContent(),
                callPrompt: nil, recentInsert: nil, expanded: true)
            view.apply(layout, live: .init())
        }
        func button(_ title: String, in parent: NSView, accessibilityLabel: String? = nil) -> NSButton? {
            if let button = parent as? NSButton {
                let matches = accessibilityLabel.map { button.accessibilityLabel() == $0 }
                    ?? (button.attributedTitle.string == title)
                if matches { return button }
            }
            return parent.subviews.lazy.compactMap { button(title, in: $0, accessibilityLabel: accessibilityLabel) }.first
        }
        func drop(containing button: NSButton?) -> NotchIslandDropView? {
            var ancestor: NSView? = button
            while let current = ancestor {
                if let drop = current as? NotchIslandDropView { return drop }
                ancestor = current.superview
            }
            return nil
        }
        func renderPrompt(_ expected: MeetingIslandPromptIdentity, line: UInt = #line) async {
            // Combine schedules the session and warning changes separately.
            for _ in 0..<20 {
                await drain()
                if overlay.islandContent().prompt?.identity == expected {
                    render()
                    return
                }
            }
            failures.append("Expected meeting prompt did not render at line \(line)")
            render()
        }
        func click(_ button: NSButton?, line: UInt = #line) {
            guard let button, let action = button.action else {
                failures.append("Missing rendered control in MeetingOverlayActionSmoke.swift at line \(line)")
                return
            }
            _ = button.sendAction(action, to: button.target)
        }

        overlay.setup(meetingSession: session)
        view.onAction = overlay.handleIslandAction
        await drain()
        let firstID = UUID()
        session.activeRecordingIdentity = firstID
        session.transition(to: .recording, reason: "overlay_smoke")
        await drain()
        let start = Date()
        let event = MeetingPromptDetector.Candidate(id: "fixture", title: "Meeting", detail: "",
            provider: .teams, reason: .calendarNearby, source: .calendarEvent, startDate: start,
            endDate: start.addingTimeInterval(1800), meetingURL: nil, suggestedTranscriptTitle: "Meeting")
        var splitRequests = 0
        session.refreshCalendarForSplitAcceptance = {
            splitRequests += 1
            return false // Exercise admission without starting another capture.
        }
        let firstOffer = MeetingSplitOffer(recordingIdentity: firstID, candidate: event)
        session.meetingSplitOffer = firstOffer
        await renderPrompt(.split(firstOffer))
        // Keep the drop alive too. Its weak forwarding closure must run, so a
        // deallocated view cannot make a broken stale-action test pass.
        let oldSplit = button("Split", in: view)
        let originalDrop = drop(containing: oldSplit)
        let oldKeep = button("Dismiss", in: view)
        session.meetingSplitOffer = nil
        let replacement = MeetingSplitOffer(recordingIdentity: firstID, candidate: event)
        session.meetingSplitOffer = replacement
        await renderPrompt(.split(replacement))
        expect(originalDrop !== drop(containing: button("Split", in: view)), "Identical-copy replacement needs fresh controls")
        withExtendedLifetime(originalDrop) {
            click(oldSplit)
            click(oldKeep)
        }
        await drain()
        expect(session.meetingSplitOffer == replacement, "Replacement offer survived both stale buttons")
        expect(splitRequests == 0, "Stale Split never reached acceptance")
        click(button("Split", in: view))
        await drain()
        expect(splitRequests == 1, "Current Split requested calendar confirmation")
        click(button("Dismiss", in: view))
        expect(session.meetingSplitOffer == nil, "Current Dismiss declined the displayed offer")

        await drain()
        defaults.set(true, forKey: key)
        render()
        let oldMute = button("Mute mic", in: view)
        session.activeRecordingIdentity = UUID()
        click(oldMute)
        expect(!session.isMeetingMicMuted, "Stale Mute preserved the next recording")
        render()
        defaults.set(false, forKey: key)
        click(button("Mute mic", in: view))
        expect(!session.isMeetingMicMuted, "Disabled Mute preserved the current recording")
        defaults.set(true, forKey: key)
        click(button("Mute mic", in: view))
        expect(session.isMeetingMicMuted, "Current opted-in Mute muted the mic")
        defaults.set(false, forKey: key)
        render()
        let oldUnmute = button("Unmute mic", in: view)
        session.activeRecordingIdentity = UUID()
        click(oldUnmute)
        expect(session.isMeetingMicMuted, "Stale Unmute preserved mute")
        render()
        click(button("Unmute mic", in: view))
        expect(!session.isMeetingMicMuted, "Current Unmute worked after opt-out")

        // No mute button contributes identity to these two otherwise equal drops.
        await drain()
        render()
        let stripStop = button("Stop", in: view, accessibilityLabel: "Stop")
        let stripDrop = drop(containing: stripStop)
        click(stripStop)
        session.activeRecordingIdentity = UUID()
        await drain()
        expect(session.isRecording, "Queued strip Stop preserved the next recording")
        render()
        let replacementStripDrop = drop(containing: button("Stop", in: view, accessibilityLabel: "Stop"))
        expect(replacementStripDrop != nil && stripDrop !== replacementStripDrop, "Recording change replaced strip controls")
        withExtendedLifetime(stripDrop) { click(stripStop) }
        await drain()
        expect(session.isRecording, "Retained strip Stop preserved the next recording")

        func observe(_ status: MeetingSystemAudioStatusCopy.Case) -> MeetingSystemAudioDegradationWarning {
            let next = MeetingSystemAudioDegradationPolicy.next(current: session.systemAudioDegradationWarning,
                                                                 status: status, isRecording: true)!
            session.systemAudioDegradationWarning = next
            return next
        }
        let first = observe(.failed)
        expect(observe(.failed) == first, "Refreshing a failure preserved its occurrence")
        await renderPrompt(.systemAudio(session.activeRecordingIdentity!, first))
        let firstStop = button("Stop", in: view)
        let firstContinue = button("Continue", in: view)
        let firstDrop = drop(containing: firstStop)
        click(firstStop)
        let recovered = observe(.healthy)
        let degraded = observe(.failed)
        await drain()
        expect(session.isRecording, "Queued warning Stop preserved the next equal-copy failure")
        await renderPrompt(.systemAudio(session.activeRecordingIdentity!, degraded))
        expect(firstDrop !== drop(containing: button("Stop", in: view)), "A recurring failure replaced its controls")
        withExtendedLifetime(firstDrop) {
            click(firstStop)
            click(firstContinue)
        }
        await drain()
        expect(session.isRecording && session.systemAudioDegradationWarning == degraded,
               "Retained warning controls preserved the recurring failure")
        let recoveredID = session.activeRecordingIdentity!
        let recoveredAgain = observe(.healthy)
        expect(observe(.healthy) == recoveredAgain, "Refreshing a recovery preserved its occurrence")
        session.hideRecoveredSystemAudioWarning(recovered, recordingID: recoveredID)
        expect(session.systemAudioDegradationWarning == recoveredAgain, "Old timer preserved equal-copy recovery")
        await drain()
        func suspendedTimer(for warning: MeetingSystemAudioDegradationWarning) async
            -> (Task<Void, Never>?, AsyncStream<Void>.Continuation) {
            overlay.cancelSystemAudioAutoHide()
            let started = AsyncStream<Void>.makeStream()
            let gate = AsyncStream<Void>.makeStream()
            overlay.updateSystemAudioAutoHide(kind: .systemAudio, warning: warning) { _ in
                started.continuation.finish()
                for await _ in gate.stream { break }
            }
            let timer = overlay.systemAudioAutoHideTask
            if timer != nil { for await _ in started.stream {} }
            return (timer, gate.continuation)
        }
        await renderPrompt(.systemAudio(recoveredID, recoveredAgain))
        let oldOK = button("OK", in: view)
        let recoveredDrop = drop(containing: oldOK)
        let (oldTimer, resumeOldTimer) = await suspendedTimer(for: recoveredAgain)
        _ = observe(.failed)
        let latestRecovery = observe(.healthy)
        resumeOldTimer.finish()
        await oldTimer?.value
        await renderPrompt(.systemAudio(recoveredID, latestRecovery))
        withExtendedLifetime(recoveredDrop) { click(oldOK) }
        expect(oldTimer != nil && session.systemAudioDegradationWarning == latestRecovery,
               "Suspended timer and retained OK preserved the recurring recovery")
        let (currentTimer, resumeCurrentTimer) = await suspendedTimer(for: latestRecovery)
        session.activeRecordingIdentity = UUID()
        resumeCurrentTimer.finish()
        await currentTimer?.value
        expect(currentTimer != nil && session.systemAudioDegradationWarning == latestRecovery,
               "Suspended recovery timer preserved the next recording")
        session.hideRecoveredSystemAudioWarning(latestRecovery, recordingID: session.activeRecordingIdentity!)
        expect(session.systemAudioDegradationWarning?.isPromptDismissed == true, "Current timer dismissed recovered warning")
        session.systemAudioDegradationWarning = nil
        session.audioRouteWarning = .switchFailed
        await renderPrompt(.route(session.activeRecordingIdentity!, .switchFailed))
        click(button("Stop", in: view))
        session.audioRouteWarning = .builtInUnavailable
        await drain()
        expect(session.isRecording, "Dispatched route Stop rechecked the warning")
        session.audioRouteWarning = nil
        let inactivity = MeetingAudioInactivityWarning(inactiveDuration: 300, countdownSeconds: 12)
        session.audioInactivityWarning = inactivity
        await renderPrompt(.inactivity(session.activeRecordingIdentity!, inactivity))
        click(button("Stop", in: view))
        session.activeRecordingIdentity = UUID()
        await drain()
        expect(session.isRecording, "Dispatched inactivity Stop rechecked the recording")
        session.audioInactivityWarning = nil
        session.systemAudioDegradationWarning = degraded
        await renderPrompt(.systemAudio(session.activeRecordingIdentity!, degraded))
        click(button("Stop", in: view))
        await drain()
        expect(!session.isRecording, "Current warning Stop ended the fixture recording")
        return failures
    }
}

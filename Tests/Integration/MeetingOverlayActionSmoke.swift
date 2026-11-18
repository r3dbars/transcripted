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
        func button(_ title: String, in parent: NSView) -> NSButton? {
            if let button = parent as? NSButton, button.attributedTitle.string == title { return button }
            return parent.subviews.lazy.compactMap { button(title, in: $0) }.first
        }
        func drop(containing button: NSButton?) -> NotchIslandDropView? {
            var ancestor: NSView? = button
            while let current = ancestor {
                if let drop = current as? NotchIslandDropView { return drop }
                ancestor = current.superview
            }
            return nil
        }
        func click(_ button: NSButton?) {
            guard let button, let action = button.action else { failures.append("Missing rendered control"); return }
            _ = button.sendAction(action, to: button.target)
        }

        overlay.setup(meetingSession: session)
        view.onAction = overlay.handleIslandAction
        let firstID = UUID()
        session.activeRecordingIdentity = firstID
        session.transition(to: .recording, reason: "overlay_smoke")
        let start = Date()
        let event = MeetingPromptDetector.Candidate(id: "fixture", title: "Meeting", detail: "",
            provider: .teams, reason: .calendarNearby, source: .calendarEvent, startDate: start,
            endDate: start.addingTimeInterval(1800), meetingURL: nil, suggestedTranscriptTitle: "Meeting")
        var splitRequests = 0
        session.refreshCalendarForSplitAcceptance = {
            splitRequests += 1
            return false // Exercise admission without starting another capture.
        }
        session.meetingSplitOffer = MeetingSplitOffer(recordingIdentity: firstID, candidate: event)
        await drain()
        render()
        // Keep the drop alive too. Its weak forwarding closure must run, so a
        // deallocated view cannot make a broken stale-action test pass.
        let oldSplit = button("Split", in: view)
        let originalDrop = drop(containing: oldSplit)
        let oldKeep = button("Keep recording", in: view)
        session.meetingSplitOffer = nil
        session.meetingSplitOffer = MeetingSplitOffer(recordingIdentity: firstID, candidate: event)
        let replacement = session.meetingSplitOffer
        await drain()
        render()
        expect(originalDrop !== drop(containing: button("Split", in: view)), "Identical-copy replacement needs fresh controls")
        withExtendedLifetime(originalDrop) {
            click(oldSplit)
            click(oldKeep)
        }
        await drain()
        expect(replacement != nil && session.meetingSplitOffer == replacement, "Replacement offer survived both stale buttons")
        expect(splitRequests == 0, "Stale Split never reached acceptance")
        click(button("Split", in: view))
        await drain()
        expect(splitRequests == 1, "Current Split requested calendar confirmation")
        click(button("Keep recording", in: view))
        expect(session.meetingSplitOffer == nil, "Current Keep recording declined the displayed offer")

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

        let recovered = MeetingSystemAudioDegradationWarning(cause: .failure, phase: .recovered, isPromptDismissed: false)
        let degraded = MeetingSystemAudioDegradationWarning(cause: .failure, phase: .degraded, isPromptDismissed: false)
        session.systemAudioDegradationWarning = degraded
        await drain()
        render()
        click(button("Stop", in: view))
        session.systemAudioDegradationWarning = recovered
        await drain()
        expect(session.isRecording, "Dispatched Stop rechecked the warning")
        let recoveredID = session.activeRecordingIdentity!
        session.systemAudioDegradationWarning = degraded
        session.hideRecoveredSystemAudioWarning(recovered, recordingID: recoveredID)
        expect(session.systemAudioDegradationWarning == degraded, "Old timer preserved replacement warning")
        session.systemAudioDegradationWarning = recovered
        session.activeRecordingIdentity = UUID()
        session.hideRecoveredSystemAudioWarning(recovered, recordingID: recoveredID)
        expect(session.systemAudioDegradationWarning == recovered, "Old timer preserved replacement recording")
        session.hideRecoveredSystemAudioWarning(recovered, recordingID: session.activeRecordingIdentity!)
        expect(session.systemAudioDegradationWarning?.isPromptDismissed == true, "Current timer dismissed recovered warning")
        session.systemAudioDegradationWarning = nil
        session.audioRouteWarning = .switchFailed
        await drain()
        render()
        click(button("Stop", in: view))
        session.audioRouteWarning = .builtInUnavailable
        await drain()
        expect(session.isRecording, "Dispatched route Stop rechecked the warning")
        session.audioRouteWarning = nil
        session.audioInactivityWarning = .init(inactiveDuration: 300, countdownSeconds: 12)
        await drain()
        render()
        click(button("Stop", in: view))
        session.activeRecordingIdentity = UUID()
        await drain()
        expect(session.isRecording, "Dispatched inactivity Stop rechecked the recording")
        session.audioInactivityWarning = nil
        session.systemAudioDegradationWarning = degraded
        await drain()
        render()
        click(button("Stop", in: view))
        await drain()
        expect(!session.isRecording, "Current warning Stop ended the fixture recording")
        return failures
    }
}

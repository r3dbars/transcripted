import Combine

@available(macOS 14.0, *)
extension TranscriptedAppDelegate {
    func configureCallActivityMonitors() {
        // Use the published edge directly: @Published emits before state changes,
        // and async evaluation may not finish until after recording has stopped.
        appState.meetingSession.$state
            .map { MeetingSessionStateMachine.isSteadyStateRecording($0) }
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.meetingPromptDetector.meetingRecordingDidStart()
            }
            .store(in: &meetingPromptSubscriptions)

        // Assign callbacks before start; HAL reads remain on the monitor queue.
        micActivityMonitor.defaultInputDeviceMonitor = DefaultInputDeviceMonitor.shared
        micActivityMonitor.onChange = { [weak self] users in
            self?.meetingPromptDetector.updateMicInputUsers(users)
        }
        micActivityMonitor.onOutputChange = { [weak self] users in
            self?.meetingPromptDetector.updateAudioOutputUsers(users)
        }
        micActivityMonitor.onBrowserOutputChange = { [weak self] users in
            self?.meetingPromptDetector.updateBrowserOutputUsers(users)
        }
        micActivityMonitor.onCallActivitySnapshot = { [weak self] snapshot in
            guard let self, AutoCallDetectionPreferences.isEnabled() else { return }
            self.appState.meetingSession.observeCallActivity(snapshot)
        }
        let monitor = micActivityMonitor
        appState.meetingSession.callActivitySampler = { [weak monitor] completion in
            monitor?.sampleCallActivityNow(completion)
        }
        cameraActivityMonitor.onChange = { [weak self] inUse in
            self?.meetingPromptDetector.updateCameraInUse(inUse)
        }
        cameraActivityMonitor.onCallCameraActivity = { [weak self] inUse, sampledAt in
            self?.appState.meetingSession.updateCallCameraInUse(inUse, sampledAt: sampledAt)
        }
        configureMeetingSplit()
    }

    /// Split on new meeting: the detector hands calendar meetings that start
    /// during a recording to the session, and the session reports back what
    /// the user chose so the detector neither re-offers nor re-prompts.
    private func configureMeetingSplit() {
        let session = appState.meetingSession
        meetingPromptDetector.onSplitRequest = { [weak session] candidates in
            session?.refreshCalendarSplit(candidates: candidates) ?? false
        }
        session.refreshCalendarForSplitAcceptance = { [weak self] in
            await self?.meetingPromptDetector.refreshForSplitAcceptance() ?? false
        }
        session.onMeetingSplitDecision = { [weak self] candidate, decision in
            guard let detector = self?.meetingPromptDetector else { return }
            switch decision {
            case .accepted: detector.markAccepted(candidate: candidate)
            case .startFailed: detector.markRecordStartFailed(candidate: candidate)
            case .declined: detector.declineSplit(candidate: candidate)
            }
        }
    }
}

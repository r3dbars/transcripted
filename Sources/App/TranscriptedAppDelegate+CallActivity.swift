@available(macOS 14.0, *)
extension TranscriptedAppDelegate {
    func configureCallActivityMonitors() {
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
    }
}

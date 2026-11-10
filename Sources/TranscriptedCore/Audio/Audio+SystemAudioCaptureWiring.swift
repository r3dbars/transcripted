import Foundation
import Combine

extension Audio {
    func ensureCaptureInfrastructureConfigured() {
        installMicEngineConfigurationChangeObserver()
        // Preserve an injected backend. A fresh session has detached its raw
        // predecessor, so installation no longer depends on keeping it alive.
        guard systemAudioCapture == nil,
              reserveSystemAudioInfrastructureInstallation() else { return }
        installWorkspaceSleepWakeObservers()
    }

    /// Only a system-audio recording constructs its backend; infrastructure
    /// setup no longer creates an unprepared placeholder, including mic-only.
    func makeSystemAudioCaptureForRecordingAttempt(sessionGeneration: UInt64)
        -> (any SystemAudioCaptureEngine & Sendable)? {
        guard recordingSessionGeneration == sessionGeneration else { return nil }
        guard currentRecordingCapturesSystemAudio else {
            AppLogger.audioSystem.info("System audio capture skipped for a mic-only recording", [
                "event": "system_audio_capture_skipped_mic_only"
            ])
            return nil
        }
        guard let capture = systemAudioCaptureFactory() else { return nil }
        guard publishSystemAudioCapture(capture, generation: sessionGeneration) else {
            retireUnpublishedSystemCapture(capture)
            return nil
        }
        return capture
    }

    @discardableResult
    func wireSystemAudioStatusPublisher(
        from capture: any SystemAudioCaptureEngine,
        generation: UInt64, captureID: ObjectIdentifier
    ) -> SystemAudioObservationOwnership.Token? {
        systemAudioObservation.bind(
            generation: generation, captureID: captureID,
            errors: capture.errorMessagePublisher,
            recovery: capture.recoveryEventPublisher,
            handlers: .init(
                error: { [weak self] token, message in
                    guard let self, self.recordingSessionGeneration == token.generation else {
                        return .none
                    }
                    return self.updateSystemAudioStatus(fromError: message)
                },
                recovery: { [weak self] token, event in
                    guard let self, self.recordingSessionGeneration == token.generation,
                          self.isRecording, self.currentRecordingCapturesSystemAudio else { return }
                    switch event {
                    case .deviceSwitch:
                        self.recordSystemAudioDeviceSwitch()
                    case .gap(let duration):
                        self.appendSystemAudioGap(duration: duration)
                    case .systemWake, .fellBehind, .recoveryAbandoned:
                        break
                    }
                },
                enqueueGap: { [weak self] token, duration in
                    self?.enqueueSystemRecoverySilencePad(duration: duration, token: token)
                },
                heal: { [weak self] token in
                    guard let self, self.recordingSessionGeneration == token.generation,
                          self.isRecording, self.currentRecordingCapturesSystemAudio,
                          self.systemAudioStatus == .reconnecting else { return }
                    self.systemAudioStatus = .healthy
                }
            )
        )
    }
}

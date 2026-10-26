import Foundation
import QuartzCore
@preconcurrency import AVFoundation
import CoreAudio
import Combine
import Synchronization

extension Audio {
    func ensureCaptureInfrastructureConfigured() {
        installMicEngineConfigurationChangeObserver()
        guard systemAudioCapture == nil else { return }

        // Core Audio process taps capture system audio without enumerating
        // screens or requiring the broader screen-recording permission.
        guard let capture = systemAudioCaptureFactory() else { return }
        systemAudioCapture = capture
        wireSystemAudioStatusPublisher(from: capture)
        installWorkspaceSleepWakeObservers()
    }

    /// Builds this recording's system-audio tap. A mic-only recording never
    /// builds one: that would ask macOS for System Audio Recording and record
    /// silence the user already said they don't want.
    func makeSystemAudioCaptureForRecordingAttempt()
        -> (any SystemAudioCaptureEngine & Sendable)? {
        guard currentRecordingCapturesSystemAudio else {
            AppLogger.audioSystem.info("System audio capture skipped for a mic-only recording", [
                "event": "system_audio_capture_skipped_mic_only"
            ])
            return nil
        }
        guard let capture = systemAudioCaptureFactory() else { return nil }
        systemAudioCapture = capture
        wireSystemAudioStatusPublisher(from: capture)
        return capture
    }

    func wireSystemAudioStatusPublisher(from capture: any SystemAudioCaptureEngine) {
        systemAudioCancellable = capture.errorMessagePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] errorMessage in
                self?.updateSystemAudioStatus(fromError: errorMessage)
            }
        systemAudioRecoveryEventCancellable = capture.recoveryEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .deviceSwitch:
                    self.recordSystemAudioDeviceSwitch()
                case .systemWake, .fellBehind:
                    // Sleeping the Mac or falling behind is not a route
                    // change. The reconnect's gap is still recorded when its
                    // first buffer lands.
                    break
                case .gap(let duration):
                    // The pad and the hold release already ran on the
                    // sending thread; see `padSystemAudioGapBeforeNextBuffer`.
                    self.appendSystemAudioGap(duration: duration)
                case .recoveryAbandoned:
                    break
                }
            }
        // Arm the write-hold on the sending thread so it is visible before
        // SCK start() can deliver the first post-restart buffer, and release
        // it on the same thread when the recovery ends, with or without a
        // `.gap`, so the first buffer after the pad is written.
        systemAudioRecoveryPadCancellable = capture.recoveryEventPublisher
            .sink { [weak self] event in
                switch event {
                case .deviceSwitch, .systemWake, .fellBehind:
                    self?.armSystemRecoveryWriteHold()
                case .recoveryAbandoned:
                    self?.releaseSystemRecoveryWriteHold()
                case .gap(let duration):
                    self?.padSystemAudioGapBeforeNextBuffer(duration: duration)
                }
            }
    }
}

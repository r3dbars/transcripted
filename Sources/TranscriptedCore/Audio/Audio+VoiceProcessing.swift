import Foundation
import QuartzCore
@preconcurrency import AVFoundation
import CoreAudio
import Combine
import Synchronization

// Apple voice processing (VPIO) arm/disarm, the recording format it
// implies, software AGC refresh, the start-fallback marker, and the
// mid-recording restarts for a processing change or a shared mic.
extension Audio {
    var voiceProcessingStartFallbackValue: String {
        voiceProcessingStartFallbackLock.lock()
        defer { voiceProcessingStartFallbackLock.unlock() }
        return _voiceProcessingStartFallback.rawValue
    }

    func recordVoiceProcessingStartFallback(_ state: VoiceProcessingStartFallbackState) {
        voiceProcessingStartFallbackLock.lock()
        _voiceProcessingStartFallback = state
        voiceProcessingStartFallbackLock.unlock()
    }

    /// Format the mic tap will actually deliver. With VPIO enabled the tap
    /// receives the VPIO output (mono Float32 at the unit's preferred rate),
    /// not the raw hardware format. Without VPIO we keep using the hardware
    /// format read on bus 1 so Bluetooth devices keep working.
    ///
    /// `voiceProcessingEnabled` lets a caller that just received a
    /// `VoiceProcessingBindResult` from `armVoiceProcessing(on:)` pass that
    /// exact value through instead of re-reading the ambient cache; callers
    /// with no bind result in scope (e.g. monitoring, which never arms VPIO)
    /// fall back to the cache as before.
    func recordingFormat(
        for inputNode: AVAudioInputNode,
        voiceProcessingEnabled overrideVoiceProcessingEnabled: Bool? = nil
    ) -> AVAudioFormat {
        if overrideVoiceProcessingEnabled ?? voiceProcessingEnabled {
            return inputNode.outputFormat(forBus: 0)
        }
        return inputNode.inputFormat(forBus: 1)
    }

    func refreshRealtimeAGCForCurrentProcessingMode(resetExisting: Bool = false) {
        if voiceProcessingEnabled || !enableSoftwareAGC {
            realtimeAGC = nil
        } else if let existing = realtimeAGC {
            if resetExisting {
                existing.reset()
            }
        } else {
            realtimeAGC = RealtimeAGC()
        }
    }

    /// Atomic snapshot returned by `armVoiceProcessing(on:)`. Pairs the
    /// physical input device this call observed BEFORE it could wrap the
    /// node in VPIO's private aggregate device with whether VPIO ended up
    /// enabled. `MeetingInputDeviceSelectionPolicy.routeReadiness` treats
    /// `boundInputDeviceIDBeforeWrap` as its only pre-wrap device-identity
    /// input — it must never be re-derived from the node after arming, since
    /// the node's reported device ID is no longer trustworthy once VPIO is
    /// active (see the 1.1.52 fix for the field bug this caused with
    /// third-party HAL drivers).
    struct VoiceProcessingBindResult: Equatable, Sendable {
        let boundInputDeviceIDBeforeWrap: AudioDeviceID
        let enabled: Bool
    }

    /// Pure mirror of what `disarmVoiceProcessing(on:reason:)` leaves in
    /// `voiceProcessingEnabled` once it returns, as a function of whether the
    /// engine was running at call time and what the cache held beforehand.
    /// `disarmVoiceProcessing` itself needs a live `AVAudioInputNode` and so
    /// is not exercised directly by a unit test (this test target does not
    /// construct real `AVAudioEngine` instances); `armVoiceProcessing`'s
    /// preference-off branch instead calls this pure decision to compute the
    /// `VoiceProcessingBindResult` it returns, so `VoiceProcessingDisarmOutcomeTests`
    /// pins the real invariant the branch depends on:
    ///
    /// - `disarmVoiceProcessing` returns immediately, before touching
    ///   `voiceProcessingEnabled` at all, whenever the engine is running
    ///   (VPIO cannot be toggled mid-graph) — the cache is left exactly as
    ///   it was.
    /// - In every other path through `disarmVoiceProcessing` (the
    ///   already-disabled early return, and the full disable attempt on
    ///   either success or failure), it unconditionally ends with
    ///   `voiceProcessingEnabled = false`.
    ///
    /// A hard-coded `false` here — instead of this decision — previously
    /// broke this exact scenario: the opt-in preference toggled off
    /// mid-session while VPIO was still armed and the engine running, which
    /// on `main` left the ambient `voiceProcessingEnabled` cache at `true`
    /// (disarm's early return above never clears it) and so fed `true` into
    /// `recordingFormat`/`routeReadiness` — the exact path the 1.1.52 fix
    /// hardened. Keep this in sync with `disarmVoiceProcessing` if its
    /// branching ever changes.
    static func voiceProcessingEnabledAfterDisarmAttempt(
        engineIsRunning: Bool,
        priorVoiceProcessingEnabled: Bool
    ) -> Bool {
        engineIsRunning ? priorVoiceProcessingEnabled : false
    }

    /// Enable AUVoiceProcessingIO on the meeting input node so Transcripted
    /// gets its own AGC'd copy of the mic stream rather than reading the raw
    /// shared device. Issue #500: when Safari/Firefox WebRTC has VPIO active
    /// on the same physical device, plain AVAudioEngine taps see attenuated
    /// audio and meeting recordings come out very quiet.
    ///
    /// VPIO has a documented side effect: macOS treats any VPIO holder as a
    /// voice-comms app and ducks output from other apps (Zoom playback,
    /// Spotify, etc.). For most users that's worse than the original quiet-
    /// recording bug, so VPIO is now opt-in via `enableVoiceProcessing`. The
    /// software AGC in `RealtimeAGC` (installed in the tap callback when
    /// VPIO is off) handles issue #500 for everyone else without engaging
    /// the system ducking.
    ///
    /// Idempotent and safe to call repeatedly. Skips when the engine is
    /// already running (toggling VPIO requires a stopped engine). Falls back
    /// silently when the device cannot host VPIO (rare, e.g. unusual
    /// aggregate devices) so a VPIO failure never blocks recording.
    ///
    /// Returns a `VoiceProcessingBindResult` pairing the physical device ID
    /// this call observed BEFORE any branch below could wrap the node in
    /// VPIO's private aggregate device, with whether VPIO ended up active.
    /// Callers that need both facts right after arming (route readiness,
    /// format selection) should consume this return value directly rather
    /// than separately reading `inputNode.auAudioUnit.deviceID` beforehand
    /// and `voiceProcessingEnabled` afterward — those two reads are only
    /// guaranteed to agree with this call's outcome because nothing runs
    /// between them, which is exactly the invariant this return value now
    /// encodes explicitly instead of leaving implicit.
    /// `suppressedByStartFallback` forces the preference-off branch for one
    /// graph-build retry after VPIO was requested but did not become active
    /// (see `VoiceProcessingStartFallbackPolicy`). It never mutates
    /// `enableVoiceProcessing`, so diagnostics keep reporting the user's real
    /// request and the next recording start re-reads the preference normally.
    @discardableResult
    func armVoiceProcessing(
        on inputNode: AVAudioInputNode,
        suppressedByStartFallback: Bool = false
    ) -> VoiceProcessingBindResult {
        let boundInputDeviceIDBeforeWrap = inputNode.auAudioUnit.deviceID

        guard shouldArmVoiceProcessing, !suppressedByStartFallback else {
            // Opt-in toggle is off. Be explicit here instead of trusting our
            // cached flag, because a prior route change can leave VPIO armed
            // until the input node is told to release it.
            //
            // Capture the pre-call state `disarmVoiceProcessing` is about to
            // branch on so the returned bind result matches whatever it
            // actually leaves behind — including its own early return when
            // the engine is running, which does NOT clear the cache. See
            // `voiceProcessingEnabledAfterDisarmAttempt`'s doc comment.
            let engineIsRunningBeforeDisarm = engine?.isRunning ?? false
            let voiceProcessingEnabledBeforeDisarm = voiceProcessingEnabled
            disarmVoiceProcessing(
                on: inputNode,
                reason: voiceProcessingSuppressedForMicrophoneSharing ? "shared_microphone"
                    : (suppressedByStartFallback ? "start_fallback_non_vpio" : "preference_off")
            )
            return VoiceProcessingBindResult(
                boundInputDeviceIDBeforeWrap: boundInputDeviceIDBeforeWrap,
                enabled: Self.voiceProcessingEnabledAfterDisarmAttempt(
                    engineIsRunning: engineIsRunningBeforeDisarm,
                    priorVoiceProcessingEnabled: voiceProcessingEnabledBeforeDisarm
                )
            )
        }

        if voiceProcessingEnabled, inputNode.isVoiceProcessingEnabled {
            return VoiceProcessingBindResult(
                boundInputDeviceIDBeforeWrap: boundInputDeviceIDBeforeWrap,
                enabled: true
            )
        }

        if let engine, engine.isRunning {
            // VPIO can only be toggled while the engine is stopped. Defer until
            // the next start cycle re-enters this path.
            return VoiceProcessingBindResult(
                boundInputDeviceIDBeforeWrap: boundInputDeviceIDBeforeWrap,
                enabled: voiceProcessingEnabled
            )
        }

        do {
            try inputNode.setVoiceProcessingEnabled(true)
            inputNode.isVoiceProcessingAGCEnabled = true
            if #available(macOS 14.0, *) {
                inputNode.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
            }
            voiceProcessingEnabled = true
            AppLogger.audioMic.info("Voice processing enabled on meeting mic", [
                "agc": "\(inputNode.isVoiceProcessingAGCEnabled)",
                "ducking": "min",
                "reason": "issue_500_safari_firefox_vpio_contention"
            ])
        } catch {
            voiceProcessingEnabled = false
            AppLogger.audioMic.warning("Voice processing unavailable, continuing without it", [
                "error": error.localizedDescription
            ])
        }

        return VoiceProcessingBindResult(
            boundInputDeviceIDBeforeWrap: boundInputDeviceIDBeforeWrap,
            enabled: voiceProcessingEnabled
        )
    }

    /// Disable VPIO once active meeting capture ends. Leaving it armed after
    /// capture can keep the shared input device in a processed mode, which can
    /// make other mic apps sound quieter.
    func disarmVoiceProcessing(on inputNode: AVAudioInputNode, reason: String = "recording_stopped") {
        if let engine, engine.isRunning { return }
        let wasMarkedEnabled = voiceProcessingEnabled
        let wasActuallyEnabled = inputNode.isVoiceProcessingEnabled
        guard wasMarkedEnabled || wasActuallyEnabled else {
            voiceProcessingEnabled = false
            return
        }

        do {
            try inputNode.setVoiceProcessingEnabled(false)
            AppLogger.audioMic.info("Voice processing disabled on meeting mic", [
                "reason": reason,
                "was_marked_enabled": "\(wasMarkedEnabled)",
                "was_actually_enabled": "\(wasActuallyEnabled)"
            ])
        } catch {
            AppLogger.audioMic.warning("Voice processing disable failed", [
                "error": error.localizedDescription
            ])
        }
        voiceProcessingEnabled = false
    }

    /// Deliberate mid-recording engine restart so a processing-mode change
    /// (arming VPIO for the issue #500 mic boost) takes effect immediately.
    /// Reuses the device-recovery machinery; never runs recovery on the
    /// calling thread (recovery uses Thread.sleep for HAL settle).
    /// Returns false, changing nothing, when nothing is recording or a mic
    /// recovery is already running; the host may try again once it ends.
    @discardableResult
    public func restartCaptureForProcessingChange() -> Bool {
        guard isRecording, !isMicRecovering else { return false }
        enableVoiceProcessing = true
        // Snapshot the generation BEFORE dispatch: stop() bumps it
        // synchronously, so a stop racing the boost aborts cleanly at
        // recovery's existing generation checks.
        let sessionGeneration = recordingSessionGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.recoverFromDeviceChange(sessionGeneration: sessionGeneration, reason: .processingChange)
        }
        return true
    }

    /// Release an active VPIO graph when a call app needs the shared mic.
    /// Recovery preserves the selected input, system stream and saved mic
    /// segments. Check under the graph lock off-main; never touch idle hardware.
    public func reconcileMicrophoneSharing() {
        guard voiceProcessingSuppressedForMicrophoneSharing else { return }
        // A blocked native graph must not accumulate a worker every watchdog
        // tick. The current worker keeps admission until it actually returns.
        guard microphoneSharingReconciliationPending.compareExchange(
            expected: false, desired: true, ordering: .acquiringAndReleasing
        ).exchanged else { return }
        let sessionGeneration = recordingSessionGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            defer { self.microphoneSharingReconciliationPending.store(false, ordering: .releasing) }
            let needsRestart = self.withAudioGraphLock {
                self.recordingSessionGeneration == sessionGeneration
                    && self.isRecording && !self.isMicRecovering
                    && self.voiceProcessingSuppressedForMicrophoneSharing
                    && self.voiceProcessingEnabled
            }
            guard needsRestart else { return }
            self.recoverFromDeviceChange(sessionGeneration: sessionGeneration, reason: .processingChange)
        }
    }
}

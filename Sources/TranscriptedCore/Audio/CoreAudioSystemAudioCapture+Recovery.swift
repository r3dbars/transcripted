import Foundation
@preconcurrency import AVFoundation
import Synchronization
import CoreAudio
import Combine

extension CoreAudioSystemAudioCapture {
    /// A new output route (e.g. AirPods switching to their call profile) can
    /// change the tap's rate. 1.1.61's ScreenCaptureKit path resampled for
    /// us; here the tap is rebuilt and resampled to the recording's format.
    /// Bounded so a route that keeps flapping still ends cleanly.
    func reconnectAfterFormatChange() {
        // Reached from the drain loop too, possibly mid-way through an
        // overflow's queued audio, so the pad start is fixed up here.
        if let ring, let tapFormat {
            backUpStartOverDroppedAudio(ring, format: tapFormat, now: clock())
        }
        guard formatReconnects < Self.maxFormatReconnects else {
            fail("System audio failed - audio format changed; start a new recording.", reason: "format_change_limit")
            return
        }
        formatReconnects += 1
        recover(.formatChange)
    }

    /// Stalls get one reconnect per recording. A system wake is a separate
    /// interruption the user caused, so it reconnects without spending (or
    /// needing) that budget; otherwise a second lid-close ends system audio.
    /// A wake and a format change are explained interruptions, so they
    /// reconnect quietly: the user only hears about it if the reconnect fails
    /// or the tap then stalls.
    func recover(_ trigger: RecoveryTrigger = .stall, isRetry: Bool = false) {
        guard running || releasedForSleep else { return }
        releasedForSleep = false
        pendingRebuildRetry = nil
        // The rebuilt tap gets a fresh silence window.
        silenceWatch?.restartSilence()
        // A wake rebuild is not evidence the silence before the sleep was a
        // lost call: the Mac was asleep. Other rebuilds are.
        if trigger != .systemWake, unheardPlayback.load(ordering: .acquiring) {
            tapChangedSinceUnheardReport = true
        }
        if trigger == .stall {
            guard !recoveryUsed else { fail("System audio failed - no audio buffers after reconnecting.", reason: "no_buffers_after_reconnect"); return }
            recoveryUsed = true
        }
        let recoveryGeneration = generation
        // A retry keeps the write-hold and event its first attempt sent.
        if !isRetry {
            rebuildRetries = 0
            // A reconnect still waiting for its first buffer armed one write-hold.
            // Release it before this attempt arms its own, and keep its start so
            // the eventual pad covers the whole interruption.
            let interruptionStart = recoveryStarted ?? lastBuffer
            if recoveryStarted != nil {
                recoveryStarted = nil
                recovery.send(.recoveryAbandoned)
                guard generation == recoveryGeneration else { return }
            }
            recoveryStarted = interruptionStart
            switch trigger {
            case .stall: tapDiagnostics.stallReconnects += 1
            case .systemWake: tapDiagnostics.wakeReconnects += 1
            case .formatChange: tapDiagnostics.formatReconnects += 1
            case .silentAfterWake: tapDiagnostics.silentAfterWakeReconnects += 1
            case .silentWhilePlaying: tapDiagnostics.silentPlaybackReconnects += 1
            case .overflow: tapDiagnostics.overflowReconnects += 1
            case .noFirstBuffer: tapDiagnostics.noFirstBufferReconnects += 1
            }
            AppLogger.audioSystem.info("System audio reconnecting", ["trigger": trigger.rawValue])
            recovery.send(Self.recoveryEvent(
                for: trigger == .noFirstBuffer ? (noFirstBufferCause ?? .stall) : trigger
            ))
            guard generation == recoveryGeneration else { return }
            if trigger == .stall || trigger == .noFirstBuffer {
                errors.send("System audio reconnecting after capture interruption.")
                guard generation == recoveryGeneration else { return }
            }
        }
        destroyHardware()
        do {
            try createHardware()
            guard generation == recoveryGeneration else { destroyHardware(); return }
            try startHardware()
            awaitingFirstBuffer = trigger
            // A route, stall or overflow rebuild is a new tap with no proof it
            // hears anything yet. A wake arms its own watch; silent-tap
            // reconnects keep the watch (and budget) that asked for them.
            if silenceWatch == nil,
               trigger == .stall || trigger == .formatChange || trigger == .overflow || trigger == .noFirstBuffer {
                silenceWatch = .armed(.rebuild, at: clock())
            }
        }
        catch {
            // Right after a wake or route change the output can still be
            // coming back (e.g. a 0 Hz rate). That is worth another try.
            guard trigger != .stall, generation == recoveryGeneration else {
                fail("System audio failed - could not reconnect. Start a new recording.", reason: "reconnect_failed")
                return
            }
            retryRebuild(trigger)
        }
    }


    /// 1, 2, 4, then 8 seconds of awake time.
    static func rebuildRetryDelay(attempt: Int) -> TimeInterval {
        min(8, TimeInterval(1 << max(0, min(attempt - 1, 3))))
    }

    /// Releases the hardware and schedules another rebuild of the same kind,
    /// or ends system audio once the retries are spent.
    func retryRebuild(_ trigger: RecoveryTrigger) {
        guard rebuildRetries < Self.maxRebuildRetries else {
            fail("System audio failed - could not reconnect. Start a new recording.", reason: "reconnect_failed")
            return
        }
        rebuildRetries += 1
        tapDiagnostics.rebuildRetries += 1
        destroyHardware()
        releasedForSleep = true
        pendingRebuildRetry = (trigger, clock() + Self.rebuildRetryDelay(attempt: rebuildRetries))
        AppLogger.audioSystem.info("System audio rebuild retry scheduled", [
            "trigger": trigger.rawValue,
            "attempt": "\(rebuildRetries)"
        ])
        armReleasedTimer()
    }

    /// While released, a slow timer covers a missing wake notice and any
    /// scheduled rebuild retry. Tests drive `drainForTesting` instead.
    func armReleasedTimer() {
        guard releasedForSleep, hardwareHooks == nil, sleepTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.drainAndCheck() }
        sleepTimer = timer
        timer.resume()
    }

    /// Meetings are latency-critical capture: without this, App Nap can
    /// coalesce the drain timer long enough to overflow the ring (M5). Idle
    /// system sleep stays allowed.
    func beginActivity() {
        guard hardwareHooks == nil, activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Recording meeting audio"
        )
    }

    func endActivity() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }

    func clearRebuildRetryState() {
        rebuildRetries = 0
        pendingRebuildRetry = nil
    }

    func fail(_ message: String, reason: String) {
        let failureGeneration = generation
        tapDiagnostics.endReason = reason
        releasedForSleep = false
        silenceWatch = nil
        removeDefaultOutputListener()
        clearRebuildRetryState()
        AppLogger.audioSystem.warning("System audio capture ended", ["reason": message])
        destroyHardware()
        endActivity()
        if recoveryStarted != nil { recoveryStarted = nil; recovery.send(.recoveryAbandoned) }
        guard generation == failureGeneration else { return }
        errors.send(message)
    }
}

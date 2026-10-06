// DictationAudioMuffler.swift
// Makes other apps' audio sound muffled while the dictation mic is open.
//
// The coordinator: it runs DictationMuffleMachine (the timeline) on one
// serial queue, performs its effects on a DictationMuffleRoute (the Core
// Audio objects), and is the only part that logs. See those two files for the
// design; DictationMuffleFilter is the sound.
//
// Order of work when the mic opens, cheapest first so a take that won't
// muffle costs almost nothing: the policy gate (plain values), the saved
// System Audio Recording decision (a UserDefaults read; the privacy-service
// round trip only when the saved decision isn't a grant), the output route
// checks, a
// one-property "is anything playing" check, then the process scan and the
// route build. All of it runs after the mic is already open, on this queue,
// never on the main thread.
//
// Bluetooth: see DictationMuffleRoute. No input device is ever opened here.

import CoreAudio
import Foundation
import TranscriptedCore

final class DictationAudioMuffler: @unchecked Sendable {
    static let shared = DictationAudioMuffler()

    private let queue = DispatchQueue(label: "com.transcripted.dictation-muffle", qos: .userInitiated)

    // Queue-confined state.
    private var machine = DictationMuffleMachine()
    private var route: DictationMuffleRoute?
    private var routeGeneration = 0
    private var pendingPlan: DictationMuffleRoute.Plan?
    private var pendingInputs: [DictationMuffleInput] = []
    private var draining = false
    private var wakeGeneration = 0
    private var take = TakeTiming()
    /// The cut in the current effect batch failed; its "engaged" report is
    /// dropped (the route-lost report follows).
    private var cutFailed = false

    private struct TakeTiming {
        var requestedAt: UInt64 = 0
        var gatedAt: UInt64 = 0
        var builtAt: UInt64 = 0
    }

    /// The dictation mic is open. Returns at once; never blocks the caller.
    func micOpened(_ context: DictationMuffleContext) {
        let requestedAt = Self.now()
        queue.async { self.handleMicOpened(context, requestedAt: requestedAt) }
    }

    /// The user is done talking (stop admitted) or the mic closed.
    func micClosed() {
        queue.async { self.enqueue(.micClosed) }
    }

    /// The Settings toggle changed. Turning it off mid-take lets the music
    /// back in right away.
    func settingChanged(enabled: Bool) {
        guard !enabled else { return }
        micClosed()
    }

    // MARK: - Queue

    private func handleMicOpened(_ context: DictationMuffleContext, requestedAt: UInt64) {
        guard machine.phase == .idle else {
            // Mid-release or mid-hand-back: the machine resumes without
            // rebuilding anything.
            enqueue(.micOpened)
            return
        }
        if let reason = DictationMufflePolicy.gate(context) {
            // Feature off is the normal case for most people; don't log it.
            if reason != .disabled { logSkip(reason.rawValue) }
            return
        }
        guard isSystemAudioAuthorized() else {
            logSkip(DictationMuffleSkipReason.permissionMissing.rawValue)
            return
        }
        guard let output = DictationMuffleHAL.defaultOutputDevice() else {
            logSkip("no_output")
            return
        }
        let transport = DictationMuffleHAL.transport(of: output)
        if let ineligible = DictationMuffleOutputRoute.ineligibility(
            transport: transport,
            inputStreamCount: DictationMuffleHAL.streamCount(of: output, scope: kAudioObjectPropertyScopeInput),
            outputChannelCount: DictationMuffleHAL.channelCount(of: output, scope: kAudioObjectPropertyScopeOutput)
        ) {
            logSkip(ineligible.rawValue)
            return
        }
        guard let outputUID = DictationMuffleHAL.string(output, kAudioDevicePropertyDeviceUID),
              let own = DictationMuffleHAL.ownProcessObject() else {
            logSkip(DictationMuffleOutputIneligibility.unreadable.rawValue)
            return
        }
        let processes = DictationMuffleHAL.processesPlaying(to: output, excluding: own)
        guard !processes.isEmpty else {
            AppLogger.transcription.debug("DICTATION | muffle skipped", ["reason": DictationMuffleSkipReason.nothingPlaying.rawValue])
            return
        }
        pendingPlan = DictationMuffleRoute.Plan(
            output: output,
            outputUID: outputUID,
            bluetooth: transport == .bluetooth,
            processes: processes
        )
        take = TakeTiming(requestedAt: requestedAt, gatedAt: Self.now(), builtAt: 0)
        enqueue(.micOpened)
    }

    /// Feeds the machine one input at a time, in order, even when an effect
    /// produces the next input (opening the route reports routeOpened).
    private func enqueue(_ input: DictationMuffleInput) {
        pendingInputs.append(input)
        guard !draining else { return }
        draining = true
        while !pendingInputs.isEmpty {
            let next = pendingInputs.removeFirst()
            for effect in machine.handle(next, now: Self.now()) {
                perform(effect)
            }
        }
        draining = false
    }

    private func perform(_ effect: DictationMuffleEffect) {
        switch effect {
        case .openRoute:
            guard let plan = pendingPlan else {
                enqueue(.routeFailed(reason: "no_plan"))
                return
            }
            pendingPlan = nil
            routeGeneration &+= 1
            let generation = routeGeneration
            do {
                route = try DictationMuffleRoute.open(plan, queue: queue) { [weak self] reason in
                    // A late event from a route that already closed must not
                    // end the next one.
                    guard let self, generation == self.routeGeneration, self.route != nil else { return }
                    self.enqueue(.routeLost(reason: reason))
                }
                take.builtAt = Self.now()
                enqueue(.routeOpened(bluetooth: plan.bluetooth))
            } catch let failure as DictationMuffleRoute.OpenFailure {
                enqueue(.routeFailed(reason: failure.step))
            } catch {
                enqueue(.routeFailed(reason: "open"))
            }
        case .cut:
            cutFailed = route?.cut() != true
            if cutFailed {
                enqueue(.routeLost(reason: "mute_failed"))
            }
        case .setMuffled(let muffled):
            route?.setMuffled(muffled)
        case .handBack:
            route?.handBack()
        case .closeRoute:
            route?.close()
            route = nil
        case .wake(let at):
            wakeGeneration &+= 1
            let generation = wakeGeneration
            queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: at)) { [weak self] in
                guard let self, generation == self.wakeGeneration else { return }
                self.enqueue(.tick(self.route?.signals() ?? .none))
            }
        case .report(let report):
            log(report)
        }
    }

    // MARK: - Permission

    /// Reads the app's saved System Audio Recording decision each take (a
    /// UserDefaults read). The app re-reads macOS's real decision when it
    /// becomes active and when a meeting starts, so a grant removed in System
    /// Settings shows up here before the next take. The privacy-service
    /// round trip (which can take hundreds of ms) runs only when the saved
    /// decision isn't a grant, so dictation never builds a tap, and never
    /// triggers macOS's prompt, without a confirmed grant.
    private func isSystemAudioAuthorized() -> Bool {
        if TranscriptedPermissionAccess.systemAudioRecordingGranted() { return true }
        return TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem() == .authorized
    }

    // MARK: - Logging (local only; numbers and fixed reasons, never names)

    private func log(_ report: DictationMuffleReport) {
        switch report {
        case let .engaged(soundWait, quietWait, cutInQuiet):
            guard !cutFailed else { return }
            // A re-cut (mic reopened during the hand back) built nothing new.
            let rebuilt = take.builtAt >= take.gatedAt && take.gatedAt >= take.requestedAt && take.requestedAt > 0
            AppLogger.transcription.info("DICTATION | muffling other audio", [
                "gate_ms": rebuilt ? Self.milliseconds(take.gatedAt - take.requestedAt) : "-",
                "build_ms": rebuilt ? Self.milliseconds(take.builtAt - take.gatedAt) : "-",
                "first_sound_ms": Self.milliseconds(soundWait),
                "quiet_wait_ms": Self.milliseconds(quietWait),
                "cut_in_quiet": String(cutInQuiet),
                "copy_delay_ms": route?.copyDelayNanos.map { Self.milliseconds($0, decimals: 1) } ?? "-",
                "gate_fade_ms": route.map { String(format: "%.1f", $0.gateFadeMilliseconds) } ?? "-",
                "buffer_frames": String(route?.copyBufferFrames ?? 0),
                "bluetooth": String(route?.bluetooth ?? false),
                "apps": String(route?.processCount ?? 0),
            ])
            take = TakeTiming()
        case .skipped(let reason):
            if reason == "tap_silent" {
                // A revoked grant delivers silence; refresh the saved
                // decision so the next take sees it.
                TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem()
            }
            logSkip(reason)
        case .stopped(let reason):
            AppLogger.transcription.info("DICTATION | muffle stopped", ["reason": reason])
        }
    }

    private func logSkip(_ reason: String) {
        AppLogger.transcription.info("DICTATION | muffle skipped", ["reason": reason])
    }

    private static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func milliseconds(_ nanos: UInt64, decimals: Int = 0) -> String {
        String(format: "%.\(decimals)f", Double(nanos) / 1_000_000)
    }
}

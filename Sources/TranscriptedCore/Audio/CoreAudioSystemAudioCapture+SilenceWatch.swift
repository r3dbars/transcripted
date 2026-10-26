import Foundation
@preconcurrency import AVFoundation
import Synchronization
import CoreAudio
import Combine

extension CoreAudioSystemAudioCapture {
    func noteSilenceWatchBuffer(hasSignal: Bool, at now: TimeInterval) {
        guard var watch = silenceWatch else { return }
        guard watch.noteBuffer(hasSignal: hasSignal, at: now) else {
            silenceWatch = nil
            // Signal is back, so the tap isn't stuck silent after the wake.
            tapDiagnostics.silentAfterWakeUnresolved = false
            if unheardPlayback.load(ordering: .acquiring) {
                if tapChangedSinceUnheardReport {
                    // Publish the confirmation before clearing the report:
                    // the host reads the two flags separately, and must never
                    // see "hearing again" without "it was lost".
                    playbackLossConfirmed.store(true, ordering: .releasing)
                    AppLogger.audioSystem.info("System audio signal returned after a new tap")
                } else {
                    // The same tap heard the call: it was quiet, not lost.
                    tapDiagnostics.unheardPlayback = false
                    AppLogger.audioSystem.info("System audio signal returned on the same tap; the call was quiet")
                }
                tapChangedSinceUnheardReport = false
                unheardPlayback.store(false, ordering: .releasing)
            } else if watch.reason == .wake {
                AppLogger.audioSystem.info("System audio signal confirmed after wake")
            }
            return
        }
        silenceWatch = watch
    }

    func checkSilenceWatch(at now: TimeInterval) {
        guard var watch = silenceWatch else { return }
        // A watch that replaced one with an open report must stay to see
        // signal return, whatever its own window says.
        guard !watch.isExpired(at: now) || unheardPlayback.load(ordering: .acquiring) else {
            silenceWatch = nil
            return
        }
        guard watch.wantsPlaybackCheck(at: now) else { return }
        // Zeros are normal on a quiet Mac. Only act when another app is
        // actually playing and the tap still hears nothing.
        let wasExhausted = watch.exhausted
        let action = watch.evaluate(otherAudioPlaying: otherAudioIsPlaying(), at: now)
        silenceWatch = watch
        if watch.exhausted, !wasExhausted {
            if watch.reason == .wake { tapDiagnostics.silentAfterWakeUnresolved = true }
            AppLogger.audioSystem.warning("System audio still silent after reconnects while other audio plays", [
                "watch": watch.reason.rawValue
            ])
        }
        switch action {
        case .none:
            return
        case .reconnect:
            if watch.reason == .lostMidRecording { signalTracker.noteRebuild() }
            recover(watch.reason == .wake ? .silentAfterWake : .silentWhilePlaying)
        case .reportUnheard:
            tapDiagnostics.unheardPlayback = true
            tapChangedSinceUnheardReport = false
            unheardPlayback.store(true, ordering: .releasing)
            AppLogger.audioSystem.warning("System audio hears nothing while another app plays", [
                "watch": watch.reason.rawValue
            ])
        }
    }

    /// True once the tap has heard only digital silence for a while, after
    /// its reconnects, while another app kept playing audio. The call is
    /// probably not being recorded. Cleared when real signal returns.
    public var isNotHearingPlayback: Bool { unheardPlayback.load(ordering: .acquiring) }

    /// True for the rest of the recording once call audio came back only
    /// after a new tap or output, so the silence before it was a real loss.
    public var didLosePlayback: Bool { playbackLossConfirmed.load(ordering: .acquiring) }

    /// The Mac's default output changed. A tap that followed it keeps
    /// working; one that did not goes silent, which the watch catches.
    func defaultOutputDidChange() {
        guard running || releasedForSleep else { return }
        AppLogger.audioSystem.info("Default output changed during recording")
        if unheardPlayback.load(ordering: .acquiring) { tapChangedSinceUnheardReport = true }
        if var watch = silenceWatch {
            watch.restartSilence()
            silenceWatch = watch
        } else {
            silenceWatch = .armed(.outputChange, at: clock())
        }
    }

    func installDefaultOutputListener() {
        guard hardwareHooks == nil, defaultOutputListener == nil else { return }
        var address = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.defaultOutputDidChange()
        }
        // Runs the block on `queue`, so the watch stays single-threaded.
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener) == noErr else { return }
        defaultOutputListener = listener
    }

    func removeDefaultOutputListener() {
        guard let listener = defaultOutputListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        defaultOutputListener = nil
    }


    func otherAudioIsPlaying() -> Bool {
        if let hardwareHooks { return hardwareHooks.otherAudioIsPlaying() }
        return Self.anotherProcessIsPlayingAudio(excluding: getpid())
    }

    /// True when any other process is running audio output. Read-only Core
    /// Audio process objects; nothing is attached or started.
    static func anotherProcessIsPlayingAudio(excluding ownPID: pid_t) -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == noErr, size > 0 else { return false }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &processes) == noErr else { return false }
        for process in processes.prefix(Int(size) / MemoryLayout<AudioObjectID>.size) {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr,
                  running != 0 else { continue }
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid == ownPID { continue }
            return true
        }
        return false
    }
}

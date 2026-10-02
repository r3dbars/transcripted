// MeetingMicCapturePlan.swift
// The mic decisions MeetingCaptureBridge makes at meeting start and when the
// user accepts the in-meeting Boost Mic, pulled out of the bridge so the
// fast-test runner can check them without TranscriptedCore's `Audio`.
// Dependency-free apart from the Support preference types.

import Foundation

/// What a meeting start applies to Core's capture, read once from the saved
/// mic settings.
struct MeetingMicStartPlan: Equatable {
    /// True records the macOS input as-is (`.preserveDefault`); false lets
    /// Core pick the mic (`.automatic`), which keeps meetings off a Bluetooth
    /// headset mic.
    var recordsMacOSInput: Bool
    /// The mic picked in Settings. Only applies while the pinned Mac-mic
    /// recorder shows that picker.
    var preferredInputDeviceUID: String?
    var enableVoiceProcessing: Bool
    var enableSoftwareAGC: Bool
    var usesPinnedMicrophoneCapture: Bool

    /// "Boost mic next meeting" from Home adds voice processing for this
    /// meeting only; it never changes the saved mode.
    static func make(
        processingMode: MicrophoneProcessingMode,
        boostRequestedForThisMeeting: Bool,
        pinnedRecorderOn: Bool,
        microphoneChoice: MicrophoneChoice,
        userDefaults: UserDefaults = .standard
    ) -> MeetingMicStartPlan {
        MeetingMicStartPlan(
            recordsMacOSInput: MeetingMicrophonePreferences.recordsMacOSInput(
                pinnedRecorderOn: pinnedRecorderOn,
                microphoneChoice: microphoneChoice,
                userDefaults: userDefaults
            ),
            preferredInputDeviceUID: pinnedRecorderOn ? microphoneChoice.deviceUID : nil,
            enableVoiceProcessing: processingMode.usesAppleVoiceProcessing || boostRequestedForThisMeeting,
            enableSoftwareAGC: processingMode.allowsSoftwareAutogainFallback,
            usesPinnedMicrophoneCapture: pinnedRecorderOn
        )
    }
}

enum MeetingNextMeetingBoostPolicy {
    /// An open call app wins at start (it may be about to take the mic for
    /// this very call), except that the user's explicit Home request looks
    /// past one that isn't on the mic. The mic scan only runs when it could
    /// change the answer, and a call app launched during the scan keeps the
    /// latch.
    @MainActor
    static func looksPastOpenCallApp(
        callAppRunning: Bool,
        boostRequestedForThisMeeting: Bool,
        callAppIsUsingMicrophone: () async -> Bool,
        callAppLaunchedDuringRecording: () -> Bool
    ) async -> Bool {
        guard callAppRunning, boostRequestedForThisMeeting else { return false }
        guard !(await callAppIsUsingMicrophone()) else { return false }
        return !callAppLaunchedDuringRecording()
    }

    /// The request is used up only by a start that actually ran with the
    /// boost. A failed start, or one where a call app kept voice processing
    /// off, keeps it for the next try.
    static func usesUpRequest(
        started: Bool,
        boostRequestedForThisMeeting: Bool,
        voiceProcessingSuppressedForMicrophoneSharing: Bool
    ) -> Bool {
        started && boostRequestedForThisMeeting && !voiceProcessingSuppressedForMicrophoneSharing
    }
}

enum MeetingMicBoostArmResult: String, Equatable {
    case armed
    /// A call app holds the mic, so Transcripted keeps sharing it on
    /// software autogain.
    case callAppUsingMicrophone = "call_app_using_microphone"
    /// The recording ended, or the mic kept recovering, before the boost
    /// could apply.
    case notApplied = "not_applied"
}

/// The in-meeting Boost Mic steps. The capture sits behind closures so the
/// steps can run against a fake. There's deliberately no way to reach the
/// saved mic preferences from here: a boost lasts one meeting.
@MainActor
struct MeetingMicBoostArming {
    var isRecordingThroughPinnedMicrophone: () -> Bool
    var currentRecordingSessionGeneration: () -> UInt64
    var isStillRecording: (UInt64) -> Bool
    var callAppLaunchedDuringRecording: () -> Bool
    var callAppIsUsingMicrophone: () async -> Bool
    var voiceProcessingSuppressedForMicrophoneSharing: () -> Bool
    var setVoiceProcessingSuppressedForMicrophoneSharing: (Bool) -> Void
    /// Restarts the live engine so the new processing applies. False while a
    /// mic recovery is in progress.
    var restartCaptureForProcessingChange: () -> Bool
    var watchCallAppsWhileBoosted: (UInt64) -> Void
    var sleep: (UInt64) async -> Void

    func arm(micRecoveryRetries: Int, retryDelayNanoseconds: UInt64) async -> MeetingMicBoostArmResult {
        // The pinned Mac-mic recorder can't host voice processing.
        guard !isRecordingThroughPinnedMicrophone() else { return .notApplied }
        let generation = currentRecordingSessionGeneration()
        guard !callAppLaunchedDuringRecording() else { return .callAppUsingMicrophone }
        let wasSharingMicrophone = voiceProcessingSuppressedForMicrophoneSharing()
        // Scan even with nothing latched: a call helper can hold the mic
        // without its app being in the presence list.
        guard !(await callAppIsUsingMicrophone()) else { return .callAppUsingMicrophone }
        guard isStillRecording(generation) else { return .notApplied }
        // A call app launched during the scan latched again; keep that.
        guard !callAppLaunchedDuringRecording(),
              voiceProcessingSuppressedForMicrophoneSharing() == wasSharingMicrophone else {
            return .callAppUsingMicrophone
        }
        var clearedCallAppGuard = false
        if wasSharingMicrophone {
            setVoiceProcessingSuppressedForMicrophoneSharing(false)
            clearedCallAppGuard = true
        }
        for attempt in 0...max(0, micRecoveryRetries) {
            guard isStillRecording(generation) else { break }
            if voiceProcessingSuppressedForMicrophoneSharing() {
                // A call app launched while this was waiting.
                return .callAppUsingMicrophone
            }
            if restartCaptureForProcessingChange() {
                if clearedCallAppGuard { watchCallAppsWhileBoosted(generation) }
                return .armed
            }
            if attempt < micRecoveryRetries {
                await sleep(retryDelayNanoseconds)
            }
        }
        if clearedCallAppGuard, isStillRecording(generation) {
            setVoiceProcessingSuppressedForMicrophoneSharing(true)
        }
        return .notApplied
    }
}

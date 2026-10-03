// DictationMufflePolicy.swift
// Decides whether "muffle other audio while dictating" may run for this take,
// and whether the current output device is one it can safely play through.
//
// Kept apart from DictationAudioMuffler so every rule here is a plain
// function of plain values.

import Foundation

enum DictationMuffleSkipReason: String, Equatable {
    case disabled
    case permissionMissing = "permission_missing"
    case meetingRecording = "meeting_recording"
    case sharedMeetingMic = "shared_meeting_mic"
    case voiceProcessing = "voice_processing"
    case automatedLaunch = "automated_launch"
}

enum DictationMuffleDecision: Equatable {
    case muffle
    case skip(DictationMuffleSkipReason)
}

enum DictationMufflePolicy {
    /// Muffle only runs when the user turned it on, macOS already granted
    /// System Audio Recording (it never prompts mid-dictation), and no meeting
    /// is being captured. During a meeting the other apps' audio is the call,
    /// and the meeting's own system-audio tap is reading it. With Apple voice
    /// processing on, macOS already ducks other apps; re-rendering them from
    /// our process would dodge that ducking and the echo canceller's
    /// reference, so muffle stays out of the way.
    static func decision(
        enabled: Bool,
        systemAudioAuthorized: Bool,
        meetingRecording: Bool,
        dictatingFromSharedMeetingMic: Bool,
        voiceProcessingRequested: Bool,
        automatedLaunch: Bool
    ) -> DictationMuffleDecision {
        if automatedLaunch { return .skip(.automatedLaunch) }
        if !enabled { return .skip(.disabled) }
        if meetingRecording { return .skip(.meetingRecording) }
        if dictatingFromSharedMeetingMic { return .skip(.sharedMeetingMic) }
        if voiceProcessingRequested { return .skip(.voiceProcessing) }
        if !systemAudioAuthorized { return .skip(.permissionMissing) }
        return .muffle
    }
}

/// How the default output device is attached, reduced to what the muffle
/// route cares about.
enum DictationMuffleOutputTransport: Equatable {
    case builtIn
    case usb
    case displayLink
    case thunderbolt
    case pci
    case firewire
    case bluetooth
    case airPlay
    case virtual
    case aggregate
    case unknown
}

enum DictationMuffleOutputIneligibility: String, Equatable {
    case airPlay = "airplay"
    case virtualOrAggregate = "virtual_or_aggregate"
    case unknownTransport = "unknown_transport"
    case hasInputStreams = "has_input_streams"
    case noOutputChannels = "no_output_channels"
}

enum DictationMuffleOutputRoute {
    /// The muffled audio plays through a private aggregate device whose only
    /// sub-device is the current output. Starting that aggregate starts every
    /// stream on the sub-device, input included.
    ///
    /// So the rule that keeps AirPods safe is "the output has no input
    /// stream", not "the output isn't Bluetooth". On macOS 26 AirPods show up
    /// as two devices, an output-only one and a separate mic, so the output
    /// is allowed and starting it never touches the mic. A Bluetooth (or USB)
    /// headset that still exposes its mic on the output device is refused:
    /// starting that input stream is what flips AirPods into call mode and
    /// garbles playback, the same trap behind every AirPods dictation bug.
    /// AirPlay and virtual or aggregate outputs are refused because their
    /// latency and clocking are not something a dictation side effect should
    /// gamble on.
    static func ineligibility(
        transport: DictationMuffleOutputTransport,
        inputStreamCount: Int,
        outputChannelCount: Int
    ) -> DictationMuffleOutputIneligibility? {
        switch transport {
        case .airPlay:
            return .airPlay
        case .virtual, .aggregate:
            return .virtualOrAggregate
        case .unknown:
            return .unknownTransport
        case .builtIn, .usb, .displayLink, .thunderbolt, .pci, .firewire, .bluetooth:
            break
        }
        if inputStreamCount > 0 { return .hasInputStreams }
        if outputChannelCount <= 0 { return .noOutputChannels }
        return nil
    }
}

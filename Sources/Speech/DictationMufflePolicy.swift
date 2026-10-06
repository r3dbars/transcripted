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
    /// No other app is playing to the output (or only apps that are also
    /// using a microphone, which are left alone).
    case nothingPlaying = "nothing_playing"
}

/// What the dictation controller knows when the mic opens, snapshotted on the
/// main actor so the muffler never reads app state from its own queue.
struct DictationMuffleContext: Equatable {
    var enabled: Bool
    var meetingRecording: Bool
    var dictatingFromSharedMeetingMic: Bool
    var voiceProcessingRequested: Bool
    var automatedLaunch: Bool
}

enum DictationMufflePolicy {
    /// The cheap rules, checked before anything touches Core Audio or the
    /// privacy service. Muffle only runs when the user turned it on and no
    /// meeting is being captured: during a meeting the other apps' audio is
    /// the call, and the meeting's own system-audio tap is reading it. With
    /// Apple voice processing on, macOS already ducks other apps; re-rendering
    /// them from our process would dodge that ducking and the echo
    /// canceller's reference, so muffle stays out of the way.
    static func gate(_ context: DictationMuffleContext) -> DictationMuffleSkipReason? {
        if context.automatedLaunch { return .automatedLaunch }
        if !context.enabled { return .disabled }
        if context.meetingRecording { return .meetingRecording }
        if context.dictatingFromSharedMeetingMic { return .sharedMeetingMic }
        if context.voiceProcessingRequested { return .voiceProcessing }
        return nil
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
    case multichannel = "multichannel_output"
    case unreadable = "unreadable_route"
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
    /// garbles playback, the same trap behind every AirPods dictation bug. A
    /// count that can't be read is refused too, so a HAL error can never let
    /// that through.
    ///
    /// AirPlay and virtual or aggregate outputs are refused because their
    /// latency and clocking are not something a dictation side effect should
    /// gamble on. Outputs with more than two channels are refused because the
    /// muffled copy is stereo, and the muted apps' other channels would drop
    /// out for the take.
    static func ineligibility(
        transport: DictationMuffleOutputTransport,
        inputStreamCount: Int?,
        outputChannelCount: Int?
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
        guard let inputStreamCount, let outputChannelCount else { return .unreadable }
        if inputStreamCount > 0 { return .hasInputStreams }
        if outputChannelCount <= 0 { return .noOutputChannels }
        if outputChannelCount > 2 { return .multichannel }
        return nil
    }
}

/// How far the muffled copy lags the original, from what the copy's IOProc
/// sees. The muffler waits for a quiet moment at the cut only when this lag
/// is long enough to hear (see DictationMuffleTiming.quietCutAboveDelayNanos),
/// and the gate fade stretches to cover it.
enum DictationMuffleCopyDelay {
    /// Frames to add to the IOProc's output-minus-input sample time.
    ///
    /// The tap reports the output device's own latency as its input latency.
    /// That latency is shared: the originals and the copy both go through the
    /// same device, so it adds nothing to the lag between them. On wired
    /// outputs it's small and barely matters; on AirPods it's 7,680 frames
    /// (160 ms), which made every Bluetooth take look 170 ms late, so
    /// the cut waited its full 300 ms for a quiet moment that music rarely
    /// has (36 of 45 Bluetooth takes on the owner's Mac, 2026-10-06), while
    /// the real lag is the IOProc's two buffers, about 11 ms. Only tap
    /// latency beyond the device's own counts.
    static func correctionFrames(
        tapInputLatency: Int,
        tapInputSafetyOffset: Int,
        outputLatency: Int,
        driftLatencyFrames: Int
    ) -> Int {
        max(0, tapInputLatency - max(0, outputLatency)) - tapInputSafetyOffset + driftLatencyFrames
    }
}

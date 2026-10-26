import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import Synchronization

extension PinnedMicrophoneCapture {
    // MARK: - HAL reads (no side effects)

    /// The PCM layout the IOProc delivers for `deviceID`'s input streams, or
    /// an error when this backend cannot record it (owners then fall back to
    /// `AVAudioEngine`). Reads properties of that device only.
    public static func inputFormat(of deviceID: AudioDeviceID) throws -> AVAudioFormat {
        let streams = try inputStreams(of: deviceID)
        var descriptions: [AudioStreamBasicDescription] = []
        for stream in streams {
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            try check(AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &asbd), "stream format query")
            descriptions.append(asbd)
        }
        return try deviceFormat(streamDescriptions: descriptions)
    }

    /// Pure mapping from the device's input stream formats to the buffer
    /// layout the ring copies: one interleaved stream, or several mono streams
    /// as non-interleaved channels. Anything else is unsupported.
    static func deviceFormat(streamDescriptions: [AudioStreamBasicDescription]) throws -> AVAudioFormat {
        guard let first = streamDescriptions.first else {
            throw error(-5, "The microphone has no input streams.")
        }
        let rate = first.mSampleRate
        guard rate.isFinite, rate >= 8000, rate <= 384_000 else {
            throw error(-5, "Unsupported microphone sample rate.")
        }
        for description in streamDescriptions {
            let flags = description.mFormatFlags
            guard description.mFormatID == kAudioFormatLinearPCM,
                  flags & kAudioFormatFlagIsFloat != 0,
                  flags & kAudioFormatFlagIsBigEndian == 0,
                  flags & kAudioFormatFlagIsNonInterleaved == 0,
                  description.mBitsPerChannel == 32,
                  description.mChannelsPerFrame >= 1,
                  description.mBytesPerFrame == 4 * description.mChannelsPerFrame,
                  description.mSampleRate == rate else {
                throw error(-5, "Unsupported microphone format.")
            }
        }
        let channels: AVAudioChannelCount
        let interleaved: Bool
        if streamDescriptions.count == 1 {
            channels = first.mChannelsPerFrame
            interleaved = channels > 1
        } else {
            guard streamDescriptions.allSatisfy({ $0.mChannelsPerFrame == 1 }) else {
                throw error(-5, "Unsupported microphone stream layout.")
            }
            channels = AVAudioChannelCount(streamDescriptions.count)
            interleaved = false
        }
        guard channels <= 64 else { throw error(-5, "Unsupported microphone channel count.") }
        let result: AVAudioFormat?
        if channels <= 2 {
            result = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved)
        } else if let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) {
            result = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: interleaved, channelLayout: layout)
        } else {
            result = nil
        }
        guard let result else { throw error(-5, "Unsupported microphone format.") }
        return result
    }

    private static func inputStreams(of deviceID: AudioDeviceID) throws -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size), "stream list size")
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        guard count > 0 else { throw error(-5, "The microphone has no input streams.") }
        var streams = [AudioStreamID](repeating: kAudioObjectUnknown, count: count)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streams), "stream list")
        return Array(streams.prefix(Int(size) / MemoryLayout<AudioStreamID>.size))
    }

    static func bufferFrameSize(of deviceID: AudioDeviceID) -> UInt32? {
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &frames) == noErr, frames > 0 else { return nil }
        return frames
    }

    static func deviceIsAlive(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != kAudioObjectUnknown else { return false }
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive) == noErr else { return false }
        return alive != 0
    }

    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw NSError(domain: "PinnedMicrophoneCapture", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Microphone \(operation) failed (\(status))."])
        }
    }

    static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "PinnedMicrophoneCapture", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

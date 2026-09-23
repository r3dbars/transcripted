import AVFoundation
import CoreAudio
import Darwin
import Synchronization

/// Single Core Audio producer / single serial-queue consumer for
/// `PinnedMicrophoneCapture`. All storage is allocated before the IOProc is
/// installed. The producer only validates, copies, stamps the capture host
/// time and publishes atomically; it never constructs an AVAudio object,
/// locks, or dispatches.
///
/// Unlike `CoreAudioTapBufferRing`, a full or malformed callback does not
/// poison the ring. The buffer is dropped and counted, and the consumer sees
/// the hole through the next buffer's host time, which it pads with silence.
/// A microphone should keep recording through a hiccup; the system-audio ring
/// fails closed for its own reasons.
final class PinnedMicrophoneBufferRing: @unchecked Sendable {
    /// Seconds per `mach_absolute_time` tick. Core Audio host times use the
    /// same clock, which stops while the Mac sleeps, so awake-time gaps line
    /// up with the system-audio track's `.gap` accounting.
    static let secondsPerHostTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return 1e-9 }
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    static func hostSecondsNow() -> TimeInterval {
        Double(mach_absolute_time()) * secondsPerHostTick
    }

    let capacity: Int
    let maximumFrames: Int
    let bufferCount: Int
    let bytesPerFrame: Int
    let channelsPerBuffer: UInt32
    private let secondsPerHostTick: Double
    private let storage: UnsafeMutableRawPointer
    private let lengths: UnsafeMutablePointer<Int>
    private let hostSeconds: UnsafeMutablePointer<Double>
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    let received = Atomic<Int>(0)
    let dropped = Atomic<Int>(0)
    /// Set by the producer when a callback's layout no longer matches, and by
    /// the HAL property listeners when the device's format or liveness may
    /// have changed. While set, the producer drops everything.
    let formatInvalidated = Atomic<Bool>(false)

    init(format: AVAudioFormat, capacity: Int = 64, maximumFrames: Int = 4096) {
        self.capacity = capacity
        self.maximumFrames = maximumFrames
        bufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        channelsPerBuffer = format.isInterleaved ? format.channelCount : 1
        secondsPerHostTick = Self.secondsPerHostTick
        storage = .allocate(byteCount: capacity * bufferCount * maximumFrames * bytesPerFrame, alignment: 16)
        lengths = .allocate(capacity: capacity)
        lengths.initialize(repeating: 0, count: capacity)
        hostSeconds = .allocate(capacity: capacity)
        hostSeconds.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
        lengths.deinitialize(count: capacity)
        lengths.deallocate()
        hostSeconds.deinitialize(count: capacity)
        hostSeconds.deallocate()
    }

    /// IOProc entry point. `inputTime` is the HAL's capture timestamp.
    func push(_ input: UnsafePointer<AudioBufferList>, inputTime: UnsafePointer<AudioTimeStamp>) {
        let stamp = inputTime.pointee
        let valid = stamp.mFlags.contains(.hostTimeValid) && stamp.mHostTime != 0
        push(input, hostSeconds: valid ? Double(stamp.mHostTime) * secondsPerHostTick : 0)
    }

    /// `hostSeconds == 0` means the HAL gave no usable timestamp; the consumer
    /// then skips gap detection for that buffer.
    func push(_ input: UnsafePointer<AudioBufferList>, hostSeconds stampSeconds: Double) {
        received.wrappingAdd(1, ordering: .relaxed)
        guard !formatInvalidated.load(ordering: .acquiring) else {
            dropped.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard list.count == bufferCount, bytesPerFrame > 0 else {
            invalidate()
            return
        }
        let bytes = Int(list[0].mDataByteSize)
        // An empty callback carries no audio and proves nothing; skip it.
        guard bytes > 0 else { return }
        guard bytes % bytesPerFrame == 0, bytes <= maximumFrames * bytesPerFrame else {
            invalidate()
            return
        }
        for index in 0..<bufferCount {
            guard list[index].mData != nil, Int(list[index].mDataByteSize) == bytes,
                  list[index].mNumberChannels == channelsPerBuffer else {
                invalidate()
                return
            }
        }
        let position = written.load(ordering: .relaxed)
        guard position - read.load(ordering: .acquiring) < capacity else {
            // The consumer fell behind. Drop this callback only; its hole
            // shows up in the next buffer's host time.
            dropped.wrappingAdd(1, ordering: .relaxed)
            return
        }
        let slot = position % capacity
        for index in 0..<bufferCount {
            memcpy(storage.advanced(by: (slot * bufferCount + index) * maximumFrames * bytesPerFrame), list[index].mData!, bytes)
        }
        lengths[slot] = bytes / bytesPerFrame
        hostSeconds[slot] = stampSeconds
        written.store(position + 1, ordering: .releasing)
    }

    private func invalidate() {
        formatInvalidated.store(true, ordering: .releasing)
        dropped.wrappingAdd(1, ordering: .relaxed)
    }

    /// Runs off the realtime thread and returns independently owned samples
    /// plus the capture host time in seconds (0 when unknown).
    func pop(format: AVAudioFormat) -> (buffer: AVAudioPCMBuffer, hostSeconds: TimeInterval)? {
        let position = read.load(ordering: .relaxed)
        guard position < written.load(ordering: .acquiring) else { return nil }
        let slot = position % capacity
        let frames = lengths[slot]
        let stamp = hostSeconds[slot]
        guard let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            read.store(position + 1, ordering: .releasing)
            dropped.wrappingAdd(1, ordering: .relaxed)
            return nil
        }
        result.frameLength = AVAudioFrameCount(frames)
        let list = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        for index in 0..<min(bufferCount, list.count) {
            memcpy(list[index].mData!, storage.advanced(by: (slot * bufferCount + index) * maximumFrames * bytesPerFrame), frames * bytesPerFrame)
        }
        read.store(position + 1, ordering: .releasing)
        return (result, stamp)
    }
}

import AVFoundation
import CoreAudio
import Synchronization

/// Single Core Audio producer / single serial-queue consumer. All storage is
/// allocated before installing the IOProc. The producer only validates, copies,
/// and publishes atomically; it never constructs an AVAudio object or dispatches.
final class CoreAudioTapBufferRing: @unchecked Sendable {
    /// About 1.4 s of 512-frame callbacks, so a consumer hiccup of a few
    /// hundred milliseconds no longer overflows (deep review M5).
    static let defaultCapacity = 128
    let capacity: Int
    let maximumFrames: Int
    let bufferCount: Int
    let bytesPerFrame: Int
    let channelsPerBuffer: UInt32
    private let storage: UnsafeMutableRawPointer
    private let lengths: UnsafeMutablePointer<Int>
    private let hostTimes: UnsafeMutablePointer<UInt64>
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    let received = Atomic<Int>(0)
    let dropped = Atomic<Int>(0)
    let formatInvalidated = Atomic<Bool>(false)
    // Once a buffer is lost, never append subsequent samples across that hole.
    let overflowed = Atomic<Bool>(false)
    /// Host time of the first sample of the buffer `pop` last returned, or 0
    /// when the HAL gave none. Consumer-side only.
    private(set) var lastPoppedHostTime: UInt64 = 0

    init(format: AVAudioFormat, capacity: Int = CoreAudioTapBufferRing.defaultCapacity, maximumFrames: Int = 8192) {
        self.capacity = capacity
        self.maximumFrames = maximumFrames
        bufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        channelsPerBuffer = format.isInterleaved ? format.channelCount : 1
        storage = .allocate(byteCount: capacity * bufferCount * maximumFrames * bytesPerFrame, alignment: 16)
        lengths = .allocate(capacity: capacity)
        lengths.initialize(repeating: 0, count: capacity)
        hostTimes = .allocate(capacity: capacity)
        hostTimes.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
        lengths.deinitialize(count: capacity); lengths.deallocate()
        hostTimes.deinitialize(count: capacity); hostTimes.deallocate()
    }

    /// `hostTime` is the HAL's host time for the first input sample, or 0.
    func push(_ input: UnsafePointer<AudioBufferList>, hostTime: UInt64 = 0) {
        received.wrappingAdd(1, ordering: .relaxed)
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let position = written.load(ordering: .relaxed)
        guard !overflowed.load(ordering: .acquiring) else { return }
        // A format change is not lost continuity: the consumer rebuilds the
        // tap and resamples. Marking it an overflow here would end system
        // audio whenever one callback lands before the next drain tick.
        guard !formatInvalidated.load(ordering: .acquiring) else {
            dropped.wrappingAdd(1, ordering: .relaxed); return
        }
        guard list.count == bufferCount,
              position - read.load(ordering: .acquiring) < capacity,
              bytesPerFrame > 0 else {
            overflowed.store(true, ordering: .releasing)
            dropped.wrappingAdd(1, ordering: .relaxed); return
        }
        let bytes = Int(list[0].mDataByteSize)
        guard bytes > 0, bytes % bytesPerFrame == 0, bytes <= maximumFrames * bytesPerFrame else {
            overflowed.store(true, ordering: .releasing)
            dropped.wrappingAdd(1, ordering: .relaxed); return
        }
        for index in 0..<bufferCount {
            guard list[index].mData != nil, Int(list[index].mDataByteSize) == bytes,
                  list[index].mNumberChannels == channelsPerBuffer else {
                overflowed.store(true, ordering: .releasing)
                dropped.wrappingAdd(1, ordering: .relaxed); return
            }
        }
        let slot = position % capacity
        for index in 0..<bufferCount {
            memcpy(storage.advanced(by: (slot * bufferCount + index) * maximumFrames * bytesPerFrame), list[index].mData!, bytes)
        }
        lengths[slot] = bytes / bytesPerFrame
        hostTimes[slot] = hostTime
        written.store(position + 1, ordering: .releasing)
    }

    /// Runs off the realtime thread and returns independently owned samples.
    func pop(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let position = read.load(ordering: .relaxed)
        guard position < written.load(ordering: .acquiring) else { return nil }
        let slot = position % capacity
        let frames = lengths[slot]
        lastPoppedHostTime = hostTimes[slot]
        guard let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            overflowed.store(true, ordering: .releasing)
            read.store(position + 1, ordering: .releasing)
            dropped.wrappingAdd(1, ordering: .relaxed)
            return nil
        }
        result.frameLength = AVAudioFrameCount(frames)
        let list = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        for index in 0..<bufferCount {
            memcpy(list[index].mData!, storage.advanced(by: (slot * bufferCount + index) * maximumFrames * bytesPerFrame), frames * bytesPerFrame)
        }
        read.store(position + 1, ordering: .releasing)
        return result
    }
}

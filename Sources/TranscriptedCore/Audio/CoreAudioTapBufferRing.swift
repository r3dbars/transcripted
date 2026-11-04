import AVFoundation
import CoreAudio
import Synchronization

/// Single Core Audio producer / single serial-queue consumer. All storage is
/// allocated before installing the IOProc. The producer only validates, copies,
/// and publishes atomically; it never constructs an AVAudio object or dispatches.
final class CoreAudioTapBufferRing: @unchecked Sendable {
    let continuityID: UInt64
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
    private let timestamps: UnsafeMutablePointer<AudioTimeStamp>
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    let received = Atomic<Int>(0)
    let dropped = Atomic<Int>(0)
    let formatInvalidated = Atomic<Bool>(false)
    // Once a buffer is lost, never append subsequent samples across that hole.
    let overflowed = Atomic<Bool>(false)
    /// Frames the producer threw away from the overflow on, so the reconnect
    /// pad can cover the whole hole instead of just the rebuild.
    let lostFrames = Atomic<Int>(0)
    /// Host time of the first sample of the buffer `pop` last returned, or 0
    /// when the HAL gave none. Consumer-side only.
    var lastPoppedHostTime: UInt64 {
        lastPoppedTimestamp.mFlags.contains(.hostTimeValid) ? lastPoppedTimestamp.mHostTime : 0
    }
    /// Consumer-only scalar stamp copied with the exact PCM slot. Sample-time
    /// validity is needed to distinguish adjacent audio from a source gap.
    private(set) var lastPoppedTimestamp = AudioTimeStamp()

    init(format: AVAudioFormat, capacity: Int = CoreAudioTapBufferRing.defaultCapacity, maximumFrames: Int = 8192, continuityID: UInt64 = 0) {
        self.continuityID = continuityID
        self.capacity = capacity
        self.maximumFrames = maximumFrames
        bufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        channelsPerBuffer = format.isInterleaved ? format.channelCount : 1
        let byteCount = capacity * bufferCount * maximumFrames * bytesPerFrame
        storage = .allocate(byteCount: byteCount, alignment: 16)
        // Touch every page now so the IOProc never takes a first-touch page
        // fault on the realtime thread.
        memset(storage, 0, byteCount)
        lengths = .allocate(capacity: capacity)
        lengths.initialize(repeating: 0, count: capacity)
        timestamps = .allocate(capacity: capacity)
        timestamps.initialize(repeating: AudioTimeStamp(), count: capacity)
    }

    deinit {
        storage.deallocate()
        lengths.deinitialize(count: capacity); lengths.deallocate()
        timestamps.deinitialize(count: capacity); timestamps.deallocate()
    }

    /// `hostTime` is the HAL's host time for the first input sample, or 0.
    func push(_ input: UnsafePointer<AudioBufferList>, hostTime: UInt64 = 0) {
        var timestamp = AudioTimeStamp()
        if hostTime > 0 {
            timestamp.mHostTime = hostTime
            timestamp.mFlags = .hostTimeValid
        }
        push(input, timestamp: timestamp)
    }

    /// Realtime-safe: the stamp is a C struct copied into preallocated storage.
    /// No allocation, I/O, locking, dispatch or Objective-C work is added.
    func push(_ input: UnsafePointer<AudioBufferList>, timestamp: AudioTimeStamp) {
        received.wrappingAdd(1, ordering: .relaxed)
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let position = written.load(ordering: .relaxed)
        guard !overflowed.load(ordering: .acquiring) else { noteLost(list); return }
        // A format change is not lost continuity: the consumer rebuilds the
        // tap and resamples. Marking it an overflow here would end system
        // audio whenever one callback lands before the next drain tick.
        guard !formatInvalidated.load(ordering: .acquiring) else {
            dropped.wrappingAdd(1, ordering: .relaxed); return
        }
        guard list.count == bufferCount,
              position - read.load(ordering: .acquiring) < capacity,
              bytesPerFrame > 0 else {
            noteLost(list)
            overflowed.store(true, ordering: .releasing)
            dropped.wrappingAdd(1, ordering: .relaxed); return
        }
        let bytes = Int(list[0].mDataByteSize)
        guard bytes > 0, bytes % bytesPerFrame == 0, bytes <= maximumFrames * bytesPerFrame else {
            noteLost(list)
            overflowed.store(true, ordering: .releasing)
            dropped.wrappingAdd(1, ordering: .relaxed); return
        }
        for index in 0..<bufferCount {
            guard list[index].mData != nil, Int(list[index].mDataByteSize) == bytes,
                  list[index].mNumberChannels == channelsPerBuffer else {
                noteLost(list)
                overflowed.store(true, ordering: .releasing)
                dropped.wrappingAdd(1, ordering: .relaxed); return
            }
        }
        let slot = position % capacity
        for index in 0..<bufferCount {
            memcpy(storage.advanced(by: (slot * bufferCount + index) * maximumFrames * bytesPerFrame), list[index].mData!, bytes)
        }
        lengths[slot] = bytes / bytesPerFrame
        timestamps[slot] = timestamp
        written.store(position + 1, ordering: .releasing)
    }

    /// Realtime-safe: one relaxed atomic add.
    @inline(__always)
    private func noteLost(_ list: UnsafeMutableAudioBufferListPointer) {
        guard bytesPerFrame > 0, list.count > 0 else { return }
        lostFrames.wrappingAdd(Int(list[0].mDataByteSize) / bytesPerFrame, ordering: .relaxed)
    }

    /// Runs off the realtime thread and returns independently owned samples.
    func pop(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let position = read.load(ordering: .relaxed)
        guard position < written.load(ordering: .acquiring) else { return nil }
        let slot = position % capacity
        let frames = lengths[slot]
        lastPoppedTimestamp = timestamps[slot]
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

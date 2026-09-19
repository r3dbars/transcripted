import AVFoundation
import CoreAudio
import Synchronization

/// Single Core Audio producer / single serial-queue consumer. All storage is
/// allocated before installing the IOProc. The producer only validates, copies,
/// and publishes atomically; it never constructs an AVAudio object or dispatches.
final class CoreAudioTapBufferRing: @unchecked Sendable {
    let capacity: Int
    let maximumFrames: Int
    let bufferCount: Int
    let bytesPerFrame: Int
    let channelsPerBuffer: UInt32
    private let storage: UnsafeMutableRawPointer
    private let lengths: UnsafeMutablePointer<Int>
    private let written = Atomic<Int>(0)
    private let read = Atomic<Int>(0)
    let received = Atomic<Int>(0)
    let dropped = Atomic<Int>(0)
    let formatInvalidated = Atomic<Bool>(false)
    // Once a buffer is lost, never append subsequent samples across that hole.
    let overflowed = Atomic<Bool>(false)

    init(format: AVAudioFormat, capacity: Int = 32, maximumFrames: Int = 8192) {
        self.capacity = capacity
        self.maximumFrames = maximumFrames
        bufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        channelsPerBuffer = format.isInterleaved ? format.channelCount : 1
        storage = .allocate(byteCount: capacity * bufferCount * maximumFrames * bytesPerFrame, alignment: 16)
        lengths = .allocate(capacity: capacity)
        lengths.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate(); lengths.deinitialize(count: capacity); lengths.deallocate() }

    func push(_ input: UnsafePointer<AudioBufferList>) {
        received.wrappingAdd(1, ordering: .relaxed)
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let position = written.load(ordering: .relaxed)
        guard !overflowed.load(ordering: .acquiring) else { return }
        guard !formatInvalidated.load(ordering: .acquiring), list.count == bufferCount,
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
        written.store(position + 1, ordering: .releasing)
    }

    /// Runs off the realtime thread and returns independently owned samples.
    func pop(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let position = read.load(ordering: .relaxed)
        guard position < written.load(ordering: .acquiring) else { return nil }
        let slot = position % capacity
        let frames = lengths[slot]
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

import AVFoundation
import Synchronization

/// The driver may delay a completed packet or give it another packet's
/// timestamp. Only PCM already in the producer callback before the first
/// mute is provably outside a mute interval. Ring drains, route changes and
/// unmute requests cannot establish a new physical capture boundary.
final class MeetingMicMuteTimeline: Sendable {
    private let closed = Atomic<Bool>(false)

    var isMuted: Bool { closed.load(ordering: .acquiring) }

    func setMuted(_ muted: Bool) {
        if muted { closed.store(true, ordering: .releasing) }
    }

    var admission: MicPacketAdmission { isMuted ? .silence : .retain }
}

/// Snapshot taken once, after the driver has made the whole packet available.
enum MicPacketAdmission {
    case retain, silence

    func apply(to owned: AVAudioPCMBuffer) {
        guard self == .silence else { return }
        for plane in UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList) {
            if let data = plane.mData { memset(data, 0, Int(plane.mDataByteSize)) }
        }
    }
}

/// Used only when installing a tap or changing mute from the UI.
final class MeetingMicMuteSessions: @unchecked Sendable {
    private let state = Mutex((generation: UInt64(0), timeline: MeetingMicMuteTimeline()))

    func timeline(for generation: UInt64) -> MeetingMicMuteTimeline {
        state.withLock { current in
            if generation > current.generation {
                current = (generation, MeetingMicMuteTimeline())
            }
            if generation == current.generation { return current.timeline }
            let retired = MeetingMicMuteTimeline()
            retired.setMuted(true)
            return retired
        }
    }
}

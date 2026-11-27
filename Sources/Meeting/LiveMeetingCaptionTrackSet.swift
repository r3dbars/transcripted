/// The recognizers owned by one recording. An absent capture source never
/// constructs a recognizer, allocates its queue, or loads its model.
struct LiveMeetingCaptionTrackSet<Track: Sendable>: Sendable {
    let microphone: Track
    let system: Track?

    init(capturesSystemAudio: Bool, makeTrack: () -> Track) {
        microphone = makeTrack()
        system = capturesSystemAudio ? makeTrack() : nil
    }
}

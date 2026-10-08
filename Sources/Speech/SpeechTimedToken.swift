/// A token copied from an STT result before its model-backed storage is released.
/// Speech owns this plain value; Meeting adapts it into Core's packing vocabulary.
struct SpeechTimedToken: Equatable, Sendable {
    let text: String
    let startSeconds: Double
}

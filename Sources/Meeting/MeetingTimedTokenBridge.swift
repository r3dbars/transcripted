#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// Preserve token spacing, order and timestamps at the Speech-to-Core boundary.
enum MeetingTimedTokenBridge {
    static func coreTokens(_ tokens: [SpeechTimedToken]) -> [TimedTranscriptToken] {
        tokens.map { TimedTranscriptToken(text: $0.text, startSeconds: $0.startSeconds) }
    }
}

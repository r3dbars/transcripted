import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

func testMeetingTimedTokenBridge() {
    runSuite("Meeting token bridge preserves recognizer text, order and timestamps") {
        let speech = [
            SpeechTimedToken(text: " Hello", startSeconds: 0.125),
            SpeechTimedToken(text: "!", startSeconds: 0.2),
            SpeechTimedToken(text: " 世界", startSeconds: 1.75)
        ]
        let tokens = MeetingTimedTokenBridge.coreTokens(speech)
        assertEqual(tokens.map(\.text), [" Hello", "!", " 世界"], "spacing and recognizer order must survive")
        assertEqual(tokens.map(\.startSeconds), [0.125, 0.2, 1.75], "word timing must survive")
        assertEqual(MeetingTimedTokenBridge.coreTokens([]), [], "an empty recognition stays empty")
    }
    runSuite("Meeting token bridge keeps packed words assigned to their original segments") {
        let speech = [
            SpeechTimedToken(text: " Hello", startSeconds: 0.125),
            SpeechTimedToken(text: "!", startSeconds: 0.2),
            SpeechTimedToken(text: " world", startSeconds: 1.75)
        ]
        let layout = SpeechSegmentPacking.layout([[Float](repeating: 0, count: 16_000), [Float](repeating: 0, count: 16_000)])
        assertEqual(
            SpeechSegmentPacking.split(tokens: MeetingTimedTokenBridge.coreTokens(speech), ranges: layout.ranges),
            ["Hello!", "world"],
            "the Core splitter must see the original token word boundaries and time"
        )
    }
}

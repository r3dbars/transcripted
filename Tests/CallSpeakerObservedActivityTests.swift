import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

func testCallSpeakerObservedActivity() {
    func observation() -> CallSpeakerObservedActivity {
        .init(originHostTime: 108_000, ticksPerSecond: 1_000, relativeActivity: .init(
            intervals: [.init(name: "Test Participant", start: 0, end: 8)],
            coverage: [.init(start: 0, end: 8)],
            rosterNames: ["Test Participant"], selfNames: ["Test Local"], sawSpeakingIndicator: true
        ))
    }
    func timeline(pad: Bool = false) -> RecordedSystemAudioTimeline {
        let identity = RecordedSystemAudioTimeline.Identity(generation: 1, captureAttempt: UUID(), writer: UUID())
        var journal = RecordedSystemAudioTimeline.Journal(identity: identity, sampleRate: 100, maximumSegments: 16)!
        func write(_ start: Int64, _ end: Int64, _ host: UInt64, _ source: Double, epoch: UInt64 = 1) {
            journal.recordWrite(identity: identity, startFrame: start, endFrame: end, frameCount: end - start,
                                succeeded: true, timing: .init(firstSampleHostTime: host, sampleTime: source,
                                                              sampleRate: 100, continuityID: epoch))
        }
        if pad {
            write(0, 1_000, 100_000, 0)
            write(1_000, 1_100, 110_000, 1_000)
            journal.recordWrite(identity: identity, startFrame: 1_100, endFrame: 1_500,
                                frameCount: 400, succeeded: true, timing: .unavailable)
            write(1_500, 1_700, 114_000, 0, epoch: 2)
            write(1_700, 1_800, 116_000, 200, epoch: 2)
        } else {
            write(0, 2_000, 100_000, 0)
            write(2_000, 2_100, 120_000, 2_000)
        }
        return journal.finish()
    }

    runSuite("CallSpeakerObservedActivity: delayed AX startup maps names to saved system frames") {
        let result = observation().aligned(to: timeline())
        assertEqual(result.intervals.first?.start, 8, "capture began eight seconds before AX")
        assertEqual(result.intervals.first?.end, 16, "AX elapsed eight is file second sixteen")
        assertEqual(result.coverage, [.init(start: 8, end: 16)], "coverage uses the same file coordinates")
        assertEqual(result.selfNames, ["Test Local"], "self metadata remains intact")
    }
    runSuite("CallSpeakerObservedActivity: recovery gaps split names and coverage at actual file positions") {
        let result = observation().aligned(to: timeline(pad: true))
        assertEqual(result.intervals.map(\.start), [8, 15], "the resumed file starts after the actual pad")
        assertEqual(result.intervals.map(\.end), [10, 17], "no name is inferred across the hole")
        assertEqual(result.coverage, [.init(start: 8, end: 10), .init(start: 15, end: 17)], "coverage is equally clipped")
    }
    runSuite("CallSpeakerObservedActivity: missing or invalid provenance retains only metadata") {
        let unavailable = observation().aligned(to: nil)
        assertTrue(unavailable.intervals.isEmpty && unavailable.coverage.isEmpty, "no finalized timeline withholds timing")
        for evidence in [CallSpeakerObservedActivity(originHostTime: 0, ticksPerSecond: 1_000,
                                             relativeActivity: observation().relativeActivity),
                         .init(originHostTime: 108_000, ticksPerSecond: .nan,
                               relativeActivity: observation().relativeActivity)] {
            let result = evidence.aligned(to: timeline())
            assertTrue(result.intervals.isEmpty && result.coverage.isEmpty, "unknown coordinates never reach diarization")
            assertEqual(result.rosterNames, ["Test Participant"], "roster is metadata only")
            assertTrue(result.sawSpeakingIndicator, "indicator availability remains truthful")
        }
    }
    runSuite("CallSpeakerActivityStore: finalized timing is keyed, consumed once and preference-gated") {
        let first = Date(timeIntervalSince1970: 100), second = Date(timeIntervalSince1970: 200)
        var store = CallSpeakerActivityStore()
        store.put(observation(), recordingStartedAt: first)
        store.put(observation(), recordingStartedAt: second)
        store.attach(timeline(), recordingStartedAt: first)
        assertTrue(store.take(recordingStartedAt: second)?.intervals.isEmpty == true, "another recording cannot borrow the timeline")
        assertEqual(store.take(recordingStartedAt: first)?.intervals.first?.start, 8, "matching stop supplies timing")
        assertTrue(store.take(recordingStartedAt: first) == nil, "handoff remains one-shot")
        store.put(observation(), recordingStartedAt: first)
        store.attach(timeline(), recordingStartedAt: first)
        assertTrue(store.take(recordingStartedAt: first, enabled: false) == nil, "setting off before handout drops evidence")
    }
}

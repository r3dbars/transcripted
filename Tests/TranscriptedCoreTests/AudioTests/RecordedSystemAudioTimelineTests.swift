import XCTest
@testable import TranscriptedCore

final class RecordedSystemAudioTimelineTests: XCTestCase {
    private let identity = RecordedSystemAudioTimeline.Identity(
        generation: 7, captureAttempt: UUID(), writer: UUID()
    )

    private func journal(capacity: Int = 16) -> RecordedSystemAudioTimeline.Journal {
        RecordedSystemAudioTimeline.Journal(identity: identity, sampleRate: 100, maximumSegments: capacity)!
    }

    private func timing(_ host: UInt64?, _ sample: Double?, epoch: UInt64 = 1, rate: Double = 100) -> SystemAudioBufferTiming {
        .init(firstSampleHostTime: host, sampleTime: sample, sampleRate: rate, continuityID: epoch)
    }

    private func write(_ journal: inout RecordedSystemAudioTimeline.Journal,
                       _ start: Int64, _ end: Int64, _ host: UInt64?, _ sample: Double?,
                       epoch: UInt64 = 1, succeeded: Bool = true, frames: Int64? = nil) {
        journal.recordWrite(identity: identity, startFrame: start, endFrame: end,
                            frameCount: frames ?? end - start, succeeded: succeeded,
                            timing: timing(host, sample, epoch: epoch))
    }

    func testLateAXObservationUsesCommittedFileZero() {
        // Source starts at host 100 s. AX begins eight seconds later. Host
        // ticks here are milliseconds; the saved file is 100 frames/second.
        var journal = journal()
        write(&journal, 0, 2000, 100_000, 0)
        write(&journal, 2000, 2100, 120_000, 2000)
        let timeline = journal.finish()
        let spans = timeline.map(startHostTime: 108_000, endHostTime: 116_000)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.start, 8)
        XCTAssertEqual(spans.first?.end, 16)
        XCTAssertEqual(timeline.unmappedFrameCount, 100, "the final buffer has no proven ending stamp")
    }

    func testDiscardedStartupBufferCannotAnchorTheFile() {
        var journal = journal()
        // A delivered buffer at host 100 was discarded, so there is no write.
        write(&journal, 0, 100, 105_000, 500)
        write(&journal, 100, 200, 106_000, 600)
        let spans = journal.finish().map(startHostTime: 105_000, endHostTime: 106_000)
        XCTAssertEqual(spans.first?.start, 0)
        XCTAssertEqual(spans.first?.end, 1)
    }

    func testFailedAndPartialWriteNeverBecomeAZeroAnchor() {
        for partialFrames: Int64 in [0, 20, 100] {
            var journal = journal()
            write(&journal, 0, partialFrames, 100_000, 0, succeeded: false, frames: 100)
            write(&journal, partialFrames, partialFrames + 100, 101_000, 100)
            write(&journal, partialFrames + 100, partialFrames + 200, 102_000, 200)
            let timeline = journal.finish()
            XCTAssertTrue(timeline.map(startHostTime: 100_000, endHostTime: 101_000).isEmpty)
            let spans = timeline.map(startHostTime: 101_000, endHostTime: 102_000)
            XCTAssertEqual(spans.first?.start, Double(partialFrames) / 100)
            XCTAssertEqual(spans.first?.end, Double(partialFrames + 100) / 100)
        }
    }

    func testSuccessfulButShortWriteDoesNotProveTheBuffer() {
        var journal = journal()
        write(&journal, 0, 20, 100_000, 0, frames: 100)
        write(&journal, 20, 120, 101_000, 100)
        write(&journal, 120, 220, 102_000, 200)
        let timeline = journal.finish()
        XCTAssertTrue(timeline.map(startHostTime: 100_000, endHostTime: 101_000).isEmpty)
        XCTAssertEqual(timeline.map(startHostTime: 101_000, endHostTime: 102_000).first?.start, 0.2)
    }

    func testActualPadPositionsSplitMappingWithoutCoveringTheGap() {
        var journal = journal()
        write(&journal, 0, 100, 100_000, 0)
        write(&journal, 100, 200, 101_000, 100)
        journal.recordWrite(identity: identity, startFrame: 200, endFrame: 250,
                            frameCount: 50, succeeded: true, timing: .unavailable)
        write(&journal, 250, 350, 200_000, 0, epoch: 2)
        write(&journal, 350, 450, 201_000, 100, epoch: 2)
        let timeline = journal.finish()
        let spans = timeline.map(startHostTime: 100_500, endHostTime: 200_500)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans.first?.start, 0.5)
        XCTAssertEqual(spans.first?.end, 1)
        XCTAssertEqual(spans.last?.start, 2.5)
        XCTAssertEqual(spans.last?.end, 3)
        XCTAssertTrue(timeline.map(startHostTime: 101_000, endHostTime: 200_000).isEmpty)
    }

    func testCappedAndPartiallyFailedPadsUseFramesActuallyWritten() {
        for padFrames: Int64 in [25, 18_000] {
            var journal = journal()
            write(&journal, 0, 100, 100_000, 0)
            write(&journal, 100, 200, 101_000, 100)
            journal.recordWrite(identity: identity, startFrame: 200, endFrame: 200 + padFrames,
                                frameCount: 18_000, succeeded: padFrames == 18_000, timing: .unavailable)
            write(&journal, 200 + padFrames, 300 + padFrames, 500_000, 0, epoch: 2)
            write(&journal, 300 + padFrames, 400 + padFrames, 501_000, 100, epoch: 2)
            let spans = journal.finish().map(startHostTime: 500_000, endHostTime: 501_000)
            XCTAssertEqual(spans.first?.start, Double(200 + padFrames) / 100)
            XCTAssertEqual(spans.first?.end, Double(300 + padFrames) / 100)
        }
    }

    func testUnknownConvertedOrInvalidTimingHasNoTrustedCoverage() {
        let unknown = [SystemAudioBufferTiming.unavailable,
                       timing(0, 0), timing(nil, 0), timing(100_000, nil),
                       timing(100_000, .nan), timing(100_000, .infinity),
                       timing(100_000, 0, rate: 200)]
        for unavailable in unknown {
            var journal = journal()
            journal.recordWrite(identity: identity, startFrame: 0, endFrame: 100,
                                frameCount: 100, succeeded: true, timing: unavailable)
            write(&journal, 100, 200, 101_000, 100)
            write(&journal, 200, 300, 102_000, 200)
            let timeline = journal.finish()
            XCTAssertTrue(timeline.map(startHostTime: 100_000, endHostTime: 101_000).isEmpty)
            XCTAssertEqual(timeline.map(startHostTime: 101_000, endHostTime: 102_000).first?.start, 1)
        }
    }

    func testSourceGapAndDiscardBreakPendingCoverage() {
        for explicitDiscard in [false, true] {
            var journal = journal()
            write(&journal, 0, 100, 100_000, 0)
            if explicitDiscard { journal.breakContinuity(identity: identity) }
            write(&journal, 100, 200, 102_000, explicitDiscard ? 100 : 200)
            write(&journal, 200, 300, 103_000, explicitDiscard ? 200 : 300)
            let timeline = journal.finish()
            XCTAssertTrue(timeline.map(startHostTime: 100_000, endHostTime: 102_000).isEmpty)
            XCTAssertEqual(timeline.map(startHostTime: 102_000, endHostTime: 103_000).first?.start, 1)
        }
    }

    func testLateOtherAttemptOrWriterCannotMutateThisRecording() {
        var journal = journal()
        for stale in [RecordedSystemAudioTimeline.Identity(generation: 6, captureAttempt: identity.captureAttempt, writer: identity.writer),
                      .init(generation: 7, captureAttempt: UUID(), writer: identity.writer),
                      .init(generation: 7, captureAttempt: identity.captureAttempt, writer: UUID())] {
            journal.recordWrite(identity: stale, startFrame: 0, endFrame: 500,
                                frameCount: 500, succeeded: true, timing: timing(1, 0))
            journal.breakContinuity(identity: stale)
        }
        write(&journal, 0, 100, 100_000, 0)
        write(&journal, 100, 200, 101_000, 100)
        XCTAssertEqual(journal.finish().map(startHostTime: 100_000, endHostTime: 101_000).first?.start, 0)
    }

    func testBackwardHostOrSampleStampCannotStartAPendingAnchor() {
        for backwardsSample in [false, true] {
            var journal = journal()
            write(&journal, 0, 100, 100_000, 100)
            write(&journal, 100, 200, backwardsSample ? 101_000 : 99_000, backwardsSample ? 0 : 200)
            write(&journal, 200, 300, 102_000, 300)
            write(&journal, 300, 400, 103_000, 400)
            let spans = journal.finish().map(startHostTime: 1, endHostTime: 103_000)
            XCTAssertEqual(spans.count, 1)
            XCTAssertEqual(spans.first?.start, 2)
            XCTAssertEqual(spans.first?.end, 3)
        }
    }

    func testOnlyExactRationalRunsCoalesce() {
        var journal = journal()
        write(&journal, 0, 100, 100_000, 0)
        write(&journal, 100, 200, 101_000, 100)
        write(&journal, 200, 300, 102_000, 200)
        write(&journal, 300, 400, 103_001, 300)
        let timeline = journal.finish()
        XCTAssertEqual(timeline.segmentCount, 2, "nonzero drift is represented, not accepted by a tolerance")
        XCTAssertEqual(timeline.map(startHostTime: 100_000, endHostTime: 103_001).first?.end, 3)
    }

    func testSaturationNeverExtendsAnOldRunAcrossDroppedEntries() {
        var journal = journal(capacity: 1)
        write(&journal, 0, 100, 100_000, 0)
        write(&journal, 100, 200, 101_000, 100)
        write(&journal, 200, 300, 102_001, 200)
        write(&journal, 300, 400, 103_001, 300)
        let timeline = journal.finish()
        XCTAssertTrue(timeline.didReachCapacity)
        XCTAssertEqual(timeline.segmentCount, 1)
        XCTAssertTrue(timeline.map(startHostTime: 101_000, endHostTime: 104_000).isEmpty)
        XCTAssertEqual(timeline.map(startHostTime: 100_000, endHostTime: 101_000).first?.end, 1)
    }

    func testFinishDoesNotInventAnEndOrAcceptLaterWrites() {
        var journal = journal()
        write(&journal, 0, 100, 100_000, 0)
        XCTAssertEqual(journal.finish().segmentCount, 0)
        write(&journal, 100, 200, 101_000, 100)
        write(&journal, 200, 300, 102_000, 200)
        XCTAssertEqual(journal.finish().segmentCount, 0)
    }

    func testRewindingWriterInvalidatesPriorCoordinates() {
        var journal = journal()
        write(&journal, 0, 100, 100_000, 0)
        write(&journal, 100, 200, 101_000, 100)
        write(&journal, 0, 100, 102_000, 200)
        XCTAssertEqual(journal.finish().segmentCount, 0)
    }
}

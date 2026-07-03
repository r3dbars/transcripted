import ArgumentParser
import Foundation
import XCTest
@testable import transcripted_cli

final class TranscribeOutputTests: XCTestCase {

    // MARK: - Format resolution

    func testResolveDefaultsToPlainText() throws {
        XCTAssertEqual(try TranscribeOutputFormat.resolve(json: false, srt: false), .text)
    }

    func testResolvePicksJSONAndSRT() throws {
        XCTAssertEqual(try TranscribeOutputFormat.resolve(json: true, srt: false), .json)
        XCTAssertEqual(try TranscribeOutputFormat.resolve(json: false, srt: true), .srt)
    }

    func testResolveRejectsJSONPlusSRT() {
        XCTAssertThrowsError(try TranscribeOutputFormat.resolve(json: true, srt: true)) { error in
            XCTAssertTrue(error is ValidationError)
        }
    }

    // MARK: - SRT timestamps

    func testSRTTimestampFormatsZero() {
        XCTAssertEqual(TranscribeOutputBuilder.srtTimestamp(0), "00:00:00,000")
    }

    func testSRTTimestampFormatsHoursMinutesSecondsMillis() {
        XCTAssertEqual(TranscribeOutputBuilder.srtTimestamp(3661.5), "01:01:01,500")
        XCTAssertEqual(TranscribeOutputBuilder.srtTimestamp(59.999), "00:00:59,999")
        XCTAssertEqual(TranscribeOutputBuilder.srtTimestamp(600.021), "00:10:00,021")
    }

    func testSRTTimestampClampsNegativeToZero() {
        XCTAssertEqual(TranscribeOutputBuilder.srtTimestamp(-3), "00:00:00,000")
    }

    // MARK: - Segment grouping

    private func token(_ text: String, _ start: Double, _ end: Double) -> TranscribeToken {
        TranscribeToken(text: text, startSeconds: start, endSeconds: end)
    }

    func testSegmentsFromEmptyTokensIsEmpty() {
        XCTAssertEqual(TranscribeOutputBuilder.segments(from: []), [])
    }

    func testSegmentsJoinTokensAndTrimLeadingSpace() {
        let segments = TranscribeOutputBuilder.segments(from: [
            token(" hello", 0.0, 0.4),
            token(" world", 0.5, 0.9),
        ])
        XCTAssertEqual(segments, [
            TranscribeSegment(text: "hello world", startSeconds: 0.0, endSeconds: 0.9)
        ])
    }

    func testSegmentsSplitOnSilenceGap() {
        let segments = TranscribeOutputBuilder.segments(from: [
            token(" first", 0.0, 0.5),
            token(" part", 0.6, 1.0),
            token(" second", 3.0, 3.5),
            token(" part", 3.6, 4.0),
        ])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "first part")
        XCTAssertEqual(segments[0].endSeconds, 1.0)
        XCTAssertEqual(segments[1].text, "second part")
        XCTAssertEqual(segments[1].startSeconds, 3.0)
    }

    func testSegmentsSplitWhenDurationCeilingExceeded() {
        // Continuous speech, no gaps: one token every second for 10 seconds.
        let tokens = (0..<10).map { index in
            token(" w\(index)", Double(index), Double(index) + 1.0)
        }
        let segments = TranscribeOutputBuilder.segments(from: tokens)
        XCTAssertGreaterThan(segments.count, 1)
        for segment in segments {
            XCTAssertLessThanOrEqual(
                segment.endSeconds - segment.startSeconds,
                TranscribeOutputBuilder.defaultMaxSegmentSeconds + 1.0
            )
        }
    }

    func testSegmentsSplitWhenCharacterCeilingExceeded() {
        let longWord = String(repeating: "a", count: 50)
        let segments = TranscribeOutputBuilder.segments(from: [
            token(" \(longWord)", 0.0, 0.5),
            token(" \(longWord)", 0.6, 1.1),
        ])
        XCTAssertEqual(segments.count, 2)
    }

    func testSegmentsSplitAfterSentencePunctuation() {
        let segments = TranscribeOutputBuilder.segments(from: [
            token(" first", 0.0, 1.2),
            token(" sentence.", 1.3, 2.5),
            token(" second", 2.6, 3.0),
            token(" sentence.", 3.1, 3.5),
        ])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "first sentence.")
        XCTAssertEqual(segments[1].text, "second sentence.")
    }

    func testSegmentsSkipWhitespaceOnlyRuns() {
        let segments = TranscribeOutputBuilder.segments(from: [
            token(" ", 0.0, 0.1),
            token(" ", 5.0, 5.1),
        ])
        XCTAssertEqual(segments, [])
    }

    // MARK: - SRT rendering

    func testSRTRenderNumbersEntriesAndFormatsTimes() {
        let srt = TranscribeOutputBuilder.srt(from: [
            TranscribeSegment(text: "hello world", startSeconds: 0.0, endSeconds: 1.5),
            TranscribeSegment(text: "second line", startSeconds: 2.0, endSeconds: 4.25),
        ])
        XCTAssertEqual(srt, """
        1
        00:00:00,000 --> 00:00:01,500
        hello world

        2
        00:00:02,000 --> 00:00:04,250
        second line

        """)
    }

    func testSRTRenderEnforcesMinimumCaptionDuration() {
        let srt = TranscribeOutputBuilder.srt(from: [
            TranscribeSegment(text: "blip", startSeconds: 1.0, endSeconds: 1.0)
        ])
        XCTAssertTrue(srt.contains("00:00:01,000 --> 00:00:01,100"), srt)
    }

    func testSRTRenderMinimumDurationDoesNotOverlapNextCaption() {
        let srt = TranscribeOutputBuilder.srt(from: [
            TranscribeSegment(text: "blip", startSeconds: 1.0, endSeconds: 1.0),
            TranscribeSegment(text: "next", startSeconds: 1.05, endSeconds: 2.0),
        ])
        XCTAssertTrue(srt.contains("00:00:01,000 --> 00:00:01,050"), srt)
    }

    // MARK: - Output paths

    func testOutputURLSwapsExtensionPerFormat() {
        let input = URL(fileURLWithPath: "/downloads/talk.mp4")
        let outputDir = URL(fileURLWithPath: "/tmp/out", isDirectory: true)

        XCTAssertEqual(
            TranscribeOutputBuilder.outputURL(for: input, outputDirectory: outputDir, format: .text).path,
            "/tmp/out/talk.txt"
        )
        XCTAssertEqual(
            TranscribeOutputBuilder.outputURL(for: input, outputDirectory: outputDir, format: .json).path,
            "/tmp/out/talk.json"
        )
        XCTAssertEqual(
            TranscribeOutputBuilder.outputURL(for: input, outputDirectory: outputDir, format: .srt).path,
            "/tmp/out/talk.srt"
        )
    }

    func testOutputURLKeepsMultiDotStems() {
        let input = URL(fileURLWithPath: "/downloads/interview.v2.final.mov")
        let outputDir = URL(fileURLWithPath: "/tmp/out", isDirectory: true)
        XCTAssertEqual(
            TranscribeOutputBuilder.outputURL(for: input, outputDirectory: outputDir, format: .text).path,
            "/tmp/out/interview.v2.final.txt"
        )
    }

    func testBatchOutputURLsDisambiguateCollidingStems() {
        let outputDir = URL(fileURLWithPath: "/tmp/out", isDirectory: true)
        let urls = TranscribeOutputBuilder.outputURLs(
            for: [
                URL(fileURLWithPath: "/a/talk.mp4"),
                URL(fileURLWithPath: "/b/talk.mov"),
                URL(fileURLWithPath: "/c/unique.m4a"),
            ],
            outputDirectory: outputDir,
            format: .text
        )
        XCTAssertEqual(urls.map(\.path), [
            "/tmp/out/talk.mp4.txt",
            "/tmp/out/talk.mov.txt",
            "/tmp/out/unique.txt",
        ])
    }

    // MARK: - JSON encoding

    func testEncodeJSONSingleOutputIsObject() throws {
        let data = try TranscribeOutputBuilder.encodeJSON([
            TranscribeFileOutput(
                file: "/a.wav", text: "hi", durationSeconds: 1, processingSeconds: 0.5,
                speedFactor: 2, confidence: 0.9,
                segments: [TranscribeSegment(text: "hi", startSeconds: 0, endSeconds: 1)]
            )
        ])
        let object = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(object is [String: Any])
        let dictionary = object as? [String: Any]
        XCTAssertEqual(dictionary?["text"] as? String, "hi")
        XCTAssertEqual((dictionary?["segments"] as? [[String: Any]])?.count, 1)
    }

    func testEncodeJSONMultipleOutputsIsArray() throws {
        let one = TranscribeFileOutput(
            file: "/a.wav", text: "a", durationSeconds: 1, processingSeconds: 1,
            speedFactor: 1, confidence: 1, segments: []
        )
        let two = TranscribeFileOutput(
            file: "/b.wav", text: "b", durationSeconds: 2, processingSeconds: 1,
            speedFactor: 2, confidence: 1, segments: []
        )
        let data = try TranscribeOutputBuilder.encodeJSON([one, two])
        let object = try JSONSerialization.jsonObject(with: data)
        XCTAssertEqual((object as? [[String: Any]])?.count, 2)
    }
}

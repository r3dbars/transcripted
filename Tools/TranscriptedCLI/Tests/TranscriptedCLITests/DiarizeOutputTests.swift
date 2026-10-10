import XCTest
@testable import transcripted_cli

/// `diarize --json` may grow new fields. Existing keys stay.
final class DiarizeOutputTests: XCTestCase {
    func testDiarizeJSONKeepsTheExistingKeys() throws {
        let data = try DiarizeOutputBuilder.encode(
            DiarizeFileOutput(
                audioFile: "memo.wav",
                segments: [
                    DiarizeSegmentOutput(
                        speakerId: "SPEAKER_00",
                        startSeconds: 0,
                        endSeconds: 1.5,
                        durationSeconds: 1.5,
                        qualityScore: 0.9
                    )
                ],
                speakerCount: 1,
                processingSeconds: 2.0,
                timings: DiarizeTimingsOutput(
                    segmentationSeconds: 0.1,
                    embeddingSeconds: 0.2,
                    clusteringSeconds: 0.3,
                    totalSeconds: 0.6
                ),
                engine: "nemotron"
            )
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let existingTopLevel: Set<String> = [
            "audioFile", "segments", "speakerCount", "processingSeconds", "timings"
        ]
        XCTAssertEqual(existingTopLevel.subtracting(object.keys), [])
        XCTAssertEqual(object["audioFile"] as? String, "memo.wav")
        XCTAssertEqual((object["speakerCount"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((object["processingSeconds"] as? NSNumber)?.doubleValue, 2.0)

        let segments = try XCTUnwrap(object["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 1)
        let existingSegment: Set<String> = [
            "speakerId", "startSeconds", "endSeconds", "durationSeconds", "qualityScore"
        ]
        XCTAssertEqual(existingSegment.subtracting(segments[0].keys), [])
        XCTAssertEqual(segments[0]["speakerId"] as? String, "SPEAKER_00")

        let timings = try XCTUnwrap(object["timings"] as? [String: Any])
        let existingTimings: Set<String> = [
            "segmentationSeconds", "embeddingSeconds", "clusteringSeconds", "totalSeconds"
        ]
        XCTAssertEqual(existingTimings.subtracting(timings.keys), [])
        XCTAssertEqual((timings["segmentationSeconds"] as? NSNumber)?.doubleValue, 0.1)
        XCTAssertEqual((timings["embeddingSeconds"] as? NSNumber)?.doubleValue, 0.2)
        XCTAssertEqual((timings["clusteringSeconds"] as? NSNumber)?.doubleValue, 0.3)
        XCTAssertEqual((timings["totalSeconds"] as? NSNumber)?.doubleValue, 0.6)

        XCTAssertEqual(object["engine"] as? String, "nemotron")
    }

    func testDiarizeJSONKeepsATimingsObjectWhenTheEngineHasNone() throws {
        let data = try DiarizeOutputBuilder.encode(
            DiarizeFileOutput(
                audioFile: "memo.wav",
                segments: [],
                speakerCount: 0,
                processingSeconds: 0.5,
                timings: .missing,
                engine: "nemotron"
            )
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let timings = try XCTUnwrap(object["timings"] as? [String: Any])
        let existingTimings: Set<String> = [
            "segmentationSeconds", "embeddingSeconds", "clusteringSeconds", "totalSeconds"
        ]
        XCTAssertEqual(existingTimings.subtracting(timings.keys), [])
        XCTAssertEqual(object["engine"] as? String, "nemotron")
        let existingTopLevel: Set<String> = [
            "audioFile", "segments", "speakerCount", "processingSeconds", "timings"
        ]
        XCTAssertEqual(existingTopLevel.subtracting(object.keys), [])
    }
}

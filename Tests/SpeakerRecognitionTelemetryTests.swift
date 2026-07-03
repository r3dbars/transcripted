import Foundation

func testSpeakerRecognitionTelemetry() {
    runSuite("SpeakerRecognitionTelemetry similarity buckets align with matcher gates") {
        assertEqual(SpeakerRecognitionTelemetry.similarityBucket(nil), "none", "no match attempt should read as none")
        assertEqual(SpeakerRecognitionTelemetry.similarityBucket(0.42), "lt_0_60")
        assertEqual(SpeakerRecognitionTelemetry.similarityBucket(0.65), "0_60_69")
        assertEqual(SpeakerRecognitionTelemetry.similarityBucket(0.75), "0_70_79")
        assertEqual(SpeakerRecognitionTelemetry.similarityBucket(0.90), "0_80_91", "the band below the 0.92 auto-accept bar stays distinct")
        assertEqual(SpeakerRecognitionTelemetry.similarityBucket(0.92), "0_92_plus")
        assertEqual(SpeakerRecognitionTelemetry.similarityBucket(0.99), "0_92_plus")
    }

    runSuite("SpeakerRecognitionTelemetry margin buckets split around the 0.12 auto-accept guard") {
        assertEqual(
            SpeakerRecognitionTelemetry.marginBucket(similarity: nil, secondSimilarity: 0.5),
            "none"
        )
        assertEqual(
            SpeakerRecognitionTelemetry.marginBucket(similarity: 0.9, secondSimilarity: nil),
            "no_runner_up"
        )
        assertEqual(
            SpeakerRecognitionTelemetry.marginBucket(similarity: 0.9, secondSimilarity: -1),
            "no_runner_up",
            "the matcher's negative sentinel means nothing else cleared the floor"
        )
        assertEqual(SpeakerRecognitionTelemetry.marginBucket(similarity: 0.9, secondSimilarity: 0.88), "lt_0_05")
        assertEqual(SpeakerRecognitionTelemetry.marginBucket(similarity: 0.9, secondSimilarity: 0.82), "0_05_11")
        assertEqual(SpeakerRecognitionTelemetry.marginBucket(similarity: 0.9, secondSimilarity: 0.75), "0_12_24")
        assertEqual(SpeakerRecognitionTelemetry.marginBucket(similarity: 0.9, secondSimilarity: 0.5), "0_25_plus")
    }
}

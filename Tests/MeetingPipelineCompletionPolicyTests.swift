import Foundation

func testMeetingPipelineCompletionPolicy() {
    let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let identities: [UUID?] = [nil, first, second]

    runSuite("Speaker review saves never complete a pipeline job regardless of task identity") {
        for saved in identities {
            for queued in identities {
                assertEqual(MeetingTranscriptSavedPolicy.completesPipelineJob(
                    origin: .speakerReview, savedTaskID: saved, queuedTaskID: queued
                ), false, "a review save cannot finish pending pipeline work")
            }
        }
    }

    runSuite("A save with no origin never completes a pipeline job") {
        for saved in identities {
            for queued in identities {
                assertEqual(MeetingTranscriptSavedPolicy.completesPipelineJob(
                    origin: nil, savedTaskID: saved, queuedTaskID: queued
                ), false, "matching or missing task IDs cannot replace a pipeline origin")
            }
        }
    }

    runSuite("A queued pipeline job completes only for its exact saved task identity") {
        let cases: [(saved: UUID?, queued: UUID, expected: Bool)] = [
            (first, first, true),
            (second, first, false),
            (nil, first, false),
            (second, second, true),
            (first, second, false),
            (nil, second, false),
        ]
        for item in cases {
            assertEqual(MeetingTranscriptSavedPolicy.completesPipelineJob(
                origin: .pipeline, savedTaskID: item.saved, queuedTaskID: item.queued
            ), item.expected, "a queued job requires its own nonmissing saved task ID")
        }
    }

    runSuite("Pipeline retries and direct saves can complete without a queued task identity") {
        for saved in identities {
            assertEqual(MeetingTranscriptSavedPolicy.completesPipelineJob(
                origin: .pipeline, savedTaskID: saved, queuedTaskID: nil
            ), true, "a legitimate pipeline completion need not carry a task ID when none is queued")
        }
    }
}

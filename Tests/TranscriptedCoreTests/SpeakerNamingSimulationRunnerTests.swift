import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class SpeakerNamingSimulationRunnerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerNamingSimulationRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testDeepSpeakerNamingSimulationSuitePassesWithFullReport() throws {
        let suite = SpeakerNamingSimulationSuite(
            name: "speaker-naming-deep-regression",
            knownSpeakers: [
                SpeakerNamingSimulationKnownSpeaker(
                    displayName: "Pat Chen",
                    embedding: vector(degrees: 160),
                    callCount: 7
                ),
                SpeakerNamingSimulationKnownSpeaker(
                    displayName: "Drew Keeper",
                    embedding: drew,
                    callCount: 7
                )
            ],
            meetings: [
                matureAutoAcceptMeeting(),
                sameProfileFragmentationMeeting(),
                stableTwoSpeakerMeeting(),
                recurringSpeakerNewDiarizerMeeting(),
                localAndRemoteMeeting(),
                noisyShortOverlapMeeting(),
                weakVisibleSpeakerMeeting(),
                channelCollisionMeeting(),
                repeatedTextMeeting(),
                sameReviewCoalescedNameMeeting(),
                deferredReviewMeeting(),
                renamePropagationMeeting(),
                cancellationRollbackMeeting(),
                savedAudioRetranscriptionMeeting()
            ],
            minimumExactLabelAccuracy: 1.0
        )

        let report = try SpeakerNamingSimulationRunner(
            workingDirectory: temporaryDirectory.appendingPathComponent("positive-suite", isDirectory: true)
        ).run(suite)
        let reportURL = temporaryDirectory.appendingPathComponent("positive-suite/report.md")
        try report.writeMarkdown(to: reportURL)

        XCTAssertTrue(report.passed, report.markdown)
        XCTAssertEqual(report.exactLabelAccuracy, 1.0, accuracy: 0.000_1, report.markdown)
        XCTAssertTrue(report.confusionPairs.isEmpty, report.markdown)
        XCTAssertTrue(report.falseMergeIndicators.isEmpty, report.markdown)
        XCTAssertTrue(report.falseSplitIndicators.isEmpty, report.markdown)
        XCTAssertEqual(report.renamedPropagationSuccesses, report.renamedPropagationChecks, report.markdown)
        XCTAssertGreaterThanOrEqual(report.renamedPropagationChecks, 2, report.markdown)
        XCTAssertEqual(report.rollbackSuccesses, report.rollbackChecks, report.markdown)
        XCTAssertEqual(report.replacementSuccesses, report.replacementChecks, report.markdown)
        XCTAssertGreaterThanOrEqual(report.totalEvaluatedUtterances, 18, report.markdown)

        let markdown = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Exact label accuracy:"))
        XCTAssertTrue(markdown.contains("saved-audio-retranscription"))
        XCTAssertTrue(markdown.contains("deferred-review"))
    }

    func testSimulationReportFlagsConfusionFalseMergeAndFalseSplit() throws {
        let suite = SpeakerNamingSimulationSuite(
            name: "speaker-naming-negative-control",
            meetings: [
                SpeakerNamingSimulationMeeting(
                    id: "bad-merge-and-split",
                    title: "Bad Merge And Split",
                    segments: [
                        segment(.system, 1, truth: "alex", expected: "Alex Rivera", text: "alex one", start: 0, embedding: alex),
                        segment(.system, 2, truth: "blair", expected: "Blair Stone", text: "blair one", start: 3, embedding: blair),
                        segment(.system, 3, truth: "alex", expected: "Alex Rivera", text: "alex two", start: 6, embedding: alex)
                    ],
                    actions: [
                        .name(channel: .system, diarizerSpeakerId: 1, as: "Alex Rivera"),
                        .name(channel: .system, diarizerSpeakerId: 2, as: "Alex Rivera"),
                        .name(channel: .system, diarizerSpeakerId: 3, as: "Alicia Rivera")
                    ]
                )
            ],
            minimumExactLabelAccuracy: 1.0
        )

        let report = try SpeakerNamingSimulationRunner(
            workingDirectory: temporaryDirectory.appendingPathComponent("negative-suite", isDirectory: true)
        ).run(suite)

        XCTAssertFalse(report.passed)
        XCTAssertFalse(report.confusionPairs.isEmpty, report.markdown)
        XCTAssertFalse(report.falseMergeIndicators.isEmpty, report.markdown)
        XCTAssertFalse(report.falseSplitIndicators.isEmpty, report.markdown)
        XCTAssertTrue(report.markdown.contains("Confusion Pairs"))
        XCTAssertTrue(report.markdown.contains("False Merge Indicators"))
        XCTAssertTrue(report.markdown.contains("False Split Indicators"))
    }

    func testRunnerPreservesUnrelatedWorkingDirectoryFiles() throws {
        let sentinelURL = temporaryDirectory.appendingPathComponent("keep-me.txt")
        try "do not delete".write(to: sentinelURL, atomically: true, encoding: .utf8)

        let suite = SpeakerNamingSimulationSuite(
            name: "working-directory-safety",
            meetings: [stableTwoSpeakerMeeting()]
        )
        _ = try SpeakerNamingSimulationRunner(workingDirectory: temporaryDirectory).run(suite)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinelURL.path))
        XCTAssertEqual(try String(contentsOf: sentinelURL, encoding: .utf8), "do not delete")
    }

    func testDiscardedMatchedProfileCanStillMergeByNameLater() throws {
        let suite = SpeakerNamingSimulationSuite(
            name: "discarded-matched-profile-regression",
            knownSpeakers: [
                SpeakerNamingSimulationKnownSpeaker(
                    displayName: "Pat Chen",
                    embedding: vector(degrees: 160),
                    callCount: 7
                )
            ],
            meetings: [
                matureAutoAcceptMeeting(),
                discardMatchedPatMeeting(),
                renamePatAfterDiscardMeeting()
            ]
        )

        let report = try SpeakerNamingSimulationRunner(
            workingDirectory: temporaryDirectory.appendingPathComponent("discard-regression", isDirectory: true)
        ).run(suite)

        XCTAssertTrue(report.passed, report.markdown)
        XCTAssertEqual(report.renamedPropagationChecks, 2, report.markdown)
        XCTAssertEqual(report.renamedPropagationSuccesses, 2, report.markdown)
    }

    func testDeferredLowConfidenceMatchDoesNotRenameMatchedProfile() throws {
        let suite = SpeakerNamingSimulationSuite(
            name: "deferred-low-confidence-match-regression",
            knownSpeakers: [
                SpeakerNamingSimulationKnownSpeaker(
                    displayName: "Drew Keeper",
                    embedding: drew,
                    callCount: 7
                )
            ],
            meetings: [
                knownDrewBaselineMeeting(),
                deferredLowConfidenceMatchedDrewMeeting()
            ]
        )

        let report = try SpeakerNamingSimulationRunner(
            workingDirectory: temporaryDirectory.appendingPathComponent("deferred-match-regression", isDirectory: true)
        ).run(suite)

        XCTAssertTrue(report.passed, report.markdown)

        let baselineURL = try XCTUnwrap(report.caseReports.first { $0.id == "known-drew-baseline" }?.transcriptURL)
        let baseline = try String(contentsOf: baselineURL, encoding: .utf8)
        XCTAssertTrue(baseline.contains("Drew Keeper"), baseline)
        XCTAssertFalse(baseline.contains("Riley Park"), baseline)

        let deferredURL = try XCTUnwrap(report.caseReports.first { $0.id == "deferred-low-confidence-match" }?.transcriptURL)
        let deferred = try String(contentsOf: deferredURL, encoding: .utf8)
        XCTAssertTrue(deferred.contains("Riley Park"), deferred)
    }

    func testSimulationReportHonorsRelaxedAccuracyThreshold() {
        let report = SpeakerNamingSimulationReport(
            suiteName: "relaxed-threshold",
            minimumExactLabelAccuracy: 0.5,
            caseReports: [],
            totalEvaluatedUtterances: 2,
            exactMatches: 1,
            confusionPairs: [
                SpeakerNamingSimulationConfusionPair(expected: "Alex", actual: "Blair", count: 1)
            ],
            falseMergeIndicators: [],
            falseSplitIndicators: [],
            renamedPropagationChecks: 0,
            renamedPropagationSuccesses: 0,
            rollbackChecks: 0,
            rollbackSuccesses: 0,
            replacementChecks: 0,
            replacementSuccesses: 0
        )

        XCTAssertTrue(report.passed, report.markdown)
        XCTAssertFalse(report.confusionPairs.isEmpty)
        XCTAssertTrue(report.markdown.contains("Confusion Pairs"))
    }

    private func stableTwoSpeakerMeeting() -> SpeakerNamingSimulationMeeting {
        SpeakerNamingSimulationMeeting(
            id: "stable-two-speakers",
            title: "Stable Two Speakers",
            segments: [
                segment(.system, 1, truth: "alex", expected: "Alex Rivera", text: "alex opens the call", start: 0, embedding: alex),
                segment(.system, 2, truth: "blair", expected: "Blair Stone", text: "blair answers the question", start: 4, embedding: blair),
                segment(.system, 1, truth: "alex", expected: "Alex Rivera", text: "alex closes the loop", start: 8, embedding: alex),
                segment(.system, 2, truth: "blair", expected: "Blair Stone", text: "blair owns follow up", start: 12, embedding: blair)
            ],
            actions: [
                .name(channel: .system, diarizerSpeakerId: 1, as: "Alex Rivera"),
                .name(channel: .system, diarizerSpeakerId: 2, as: "Blair Stone")
            ]
        )
    }

    private func recurringSpeakerNewDiarizerMeeting() -> SpeakerNamingSimulationMeeting {
        SpeakerNamingSimulationMeeting(
            id: "recurring-new-diarizer",
            title: "Recurring New Diarizer",
            segments: [
                segment(.system, 4, truth: "alex", expected: "Alex Rivera", text: "alex returns under a new label", start: 0, embedding: alex),
                segment(.system, 8, truth: "alex", expected: "Alex Rivera", text: "alex second split label", start: 4, embedding: near(alex, degrees: 2)),
                segment(.system, 5, truth: "blair", expected: "Blair Stone", text: "blair is still separate", start: 8, embedding: blair)
            ],
            actions: [
                .confirm(channel: .system, diarizerSpeakerId: 4, as: "Alex Rivera"),
                .confirm(channel: .system, diarizerSpeakerId: 8, as: "Alex Rivera"),
                .confirm(channel: .system, diarizerSpeakerId: 5, as: "Blair Stone")
            ]
        )
    }

    private func localAndRemoteMeeting() -> SpeakerNamingSimulationMeeting {
        SpeakerNamingSimulationMeeting(
            id: "local-and-remote",
            title: "Local And Remote",
            segments: [
                segment(.mic, 1, truth: "justin", expected: "You", text: "local mic owner speaks", start: 0, embedding: justin),
                segment(.mic, 2, truth: "naomi", expected: "Naomi", text: "second room voice speaks", start: 4, embedding: naomi),
                segment(.system, 1, truth: "casey", expected: "Casey Wu", text: "remote participant responds", start: 8, embedding: casey)
            ],
            actions: [
                .name(channel: .mic, diarizerSpeakerId: 1, as: "You"),
                .name(channel: .mic, diarizerSpeakerId: 2, as: "Naomi"),
                .name(channel: .system, diarizerSpeakerId: 1, as: "Casey Wu")
            ]
        )
    }

    private func noisyShortOverlapMeeting() -> SpeakerNamingSimulationMeeting {
        SpeakerNamingSimulationMeeting(
            id: "noisy-short-overlap",
            title: "Noisy Short Overlap",
            segments: [
                segment(.system, 1, truth: "alex", expected: "Alex Rivera", text: "alex gives a long clean explanation", start: 0, duration: 35, embedding: alex),
                segment(.system, 9, truth: "alex", expected: "Alex Rivera", text: "short noisy alex fragment", start: 36, duration: 0.6, embedding: near(alex, degrees: 1), qualityScore: 0.2),
                segment(.system, 2, truth: "casey", expected: "Casey Wu", text: "casey keeps the second voice separate", start: 40, duration: 35, embedding: casey)
            ],
            actions: [
                .confirm(channel: .system, diarizerSpeakerId: 1, as: "Alex Rivera"),
                .name(channel: .system, diarizerSpeakerId: 2, as: "Casey Wu")
            ]
        )
    }

    private func channelCollisionMeeting() -> SpeakerNamingSimulationMeeting {
        SpeakerNamingSimulationMeeting(
            id: "duplicate-channel-labels",
            title: "Duplicate Channel Labels",
            segments: [
                segment(.mic, 1, truth: "jordan-local", expected: "Jordan Local", text: "room speaker one label", start: 0, embedding: jordan),
                segment(.system, 1, truth: "taylor-remote", expected: "Taylor Remote", text: "remote speaker one label", start: 4, embedding: taylor)
            ],
            actions: [
                .name(channel: .mic, diarizerSpeakerId: 1, as: "Jordan Local"),
                .name(channel: .system, diarizerSpeakerId: 1, as: "Taylor Remote")
            ]
        )
    }

    private func repeatedTextMeeting() -> SpeakerNamingSimulationMeeting {
        SpeakerNamingSimulationMeeting(
            id: "repeated-text",
            title: "Repeated Text",
            segments: [
                segment(.system, 31, truth: "alex", expected: "Alex Rivera", text: "okay", start: 0, embedding: alex),
                segment(.system, 32, truth: "blair", expected: "Blair Stone", text: "okay", start: 4, embedding: blair)
            ],
            actions: [
                .name(channel: .system, diarizerSpeakerId: 31, as: "Alex Rivera"),
                .name(channel: .system, diarizerSpeakerId: 32, as: "Blair Stone")
            ]
        )
    }

    private func sameReviewCoalescedNameMeeting() -> SpeakerNamingSimulationMeeting {
        SpeakerNamingSimulationMeeting(
            id: "same-review-coalesced-name",
            title: "Same Review Coalesced Name",
            segments: [
                segment(.system, 41, truth: "sam", expected: "Samuel Lee", text: "sam first split label", start: 0, embedding: samA),
                segment(.system, 42, truth: "sam", expected: "Samuel Lee", text: "sam second split label", start: 4, embedding: samB)
            ],
            actions: [
                .name(channel: .system, diarizerSpeakerId: 41, as: "Sam Lee"),
                .name(channel: .system, diarizerSpeakerId: 42, as: "Sam Lee")
            ],
            postActions: [
                .renameProfile(channel: .system, diarizerSpeakerId: 41, to: "Samuel Lee")
            ]
        )
    }

    private func deferredReviewMeeting() -> SpeakerNamingSimulationMeeting {
        SpeakerNamingSimulationMeeting(
            id: "deferred-review",
            title: "Deferred Review",
            segments: [
                segment(.system, 6, truth: "morgan", expected: "Morgan Lee", text: "morgan waits for people settings", start: 0, embedding: morgan)
            ],
            actions: [.deferAll],
            postActions: [
                .nameDeferred(channel: .system, diarizerSpeakerId: 6, as: "Morgan Lee")
            ]
        )
    }

    private func renamePropagationMeeting() -> SpeakerNamingSimulationMeeting {
        SpeakerNamingSimulationMeeting(
            id: "rename-propagation",
            title: "Rename Propagation",
            segments: [
                segment(.system, 7, truth: "alex", expected: "Alicia Rivera", text: "alex chooses a corrected public name", start: 0, embedding: alex)
            ],
            actions: [
                .confirm(channel: .system, diarizerSpeakerId: 7, as: "Alex Rivera")
            ],
            postActions: [
                .renameProfile(channel: .system, diarizerSpeakerId: 7, to: "Alicia Rivera")
            ]
        )
    }

    private func cancellationRollbackMeeting() -> SpeakerNamingSimulationMeeting {
        SpeakerNamingSimulationMeeting(
            id: "cancelled-retranscription",
            title: "Cancelled Retranscription",
            segments: [
                segment(.system, 3, truth: "alex", expected: "Alicia Rivera", text: "cancelled replacement should not commit", start: 0, embedding: alex)
            ],
            actions: [.cancelBeforeNaming],
            replacementTargetMeetingId: "stable-two-speakers"
        )
    }

    private func savedAudioRetranscriptionMeeting() -> SpeakerNamingSimulationMeeting {
        SpeakerNamingSimulationMeeting(
            id: "saved-audio-retranscription",
            title: "Saved Audio Retranscription",
            segments: [
                segment(.system, 11, truth: "alex", expected: "Alicia Rivera", text: "saved audio alex replacement", start: 0, embedding: alex),
                segment(.system, 12, truth: "blair", expected: "Blair Stone", text: "saved audio blair replacement", start: 4, embedding: blair)
            ],
            actions: [
                .confirm(channel: .system, diarizerSpeakerId: 11, as: "Alicia Rivera"),
                .confirm(channel: .system, diarizerSpeakerId: 12, as: "Blair Stone")
            ],
            replacementTargetMeetingId: "stable-two-speakers"
        )
    }

    private func matureAutoAcceptMeeting() -> SpeakerNamingSimulationMeeting {
        SpeakerNamingSimulationMeeting(
            id: "mature-auto-accept",
            title: "Mature Auto Accept",
            segments: [
                segment(.system, 13, truth: "pat", expected: "Pat Chen", text: "pat should auto accept from mature profile", start: 0, embedding: vector(degrees: 160))
            ],
            actions: []
        )
    }

    private func discardMatchedPatMeeting() -> SpeakerNamingSimulationMeeting {
        SpeakerNamingSimulationMeeting(
            id: "discard-matched-pat",
            title: "Discard Matched Pat",
            segments: [
                segment(.system, 14, truth: "pat", expected: "Pat Chen", text: "pat match is discarded by the reviewer", start: 0, embedding: vector(degrees: 160))
            ],
            actions: [
                .discard(channel: .system, diarizerSpeakerId: 14)
            ]
        )
    }

    private func renamePatAfterDiscardMeeting() -> SpeakerNamingSimulationMeeting {
        SpeakerNamingSimulationMeeting(
            id: "rename-pat-after-discard",
            title: "Rename Pat After Discard",
            segments: [
                segment(.system, 15, truth: "pat", expected: "Patrick Chen", text: "pat is named again after discard", start: 0, embedding: vector(degrees: 160))
            ],
            actions: [
                .name(channel: .system, diarizerSpeakerId: 15, as: "Pat Chen")
            ],
            postActions: [
                .renameProfile(channel: .system, diarizerSpeakerId: 15, to: "Patrick Chen")
            ]
        )
    }

    private func sameProfileFragmentationMeeting() -> SpeakerNamingSimulationMeeting {
        SpeakerNamingSimulationMeeting(
            id: "same-profile-fragmentation",
            title: "Same Profile Fragmentation",
            segments: [
                segment(.system, 18, truth: "drew", expected: "Drew Keeper", text: "drew first low confidence fragment", start: 0, embedding: near(drew, degrees: 30)),
                segment(.system, 19, truth: "drew", expected: "Drew Keeper", text: "drew second low confidence fragment", start: 4, embedding: near(drew, degrees: -30))
            ],
            actions: [
                .confirm(channel: .system, diarizerSpeakerId: 18, as: "Drew Keeper")
            ]
        )
    }

    private func weakVisibleSpeakerMeeting() -> SpeakerNamingSimulationMeeting {
        SpeakerNamingSimulationMeeting(
            id: "weak-visible-speaker",
            title: "Weak Visible Speaker",
            segments: [
                segment(
                    .system,
                    20,
                    truth: "quinn",
                    expected: "Quinn Ray",
                    text: "quinn is short and noisy but visible",
                    start: 0,
                    duration: 0.4,
                    embedding: vector(degrees: 305),
                    qualityScore: 0.1
                )
            ],
            actions: [
                .name(channel: .system, diarizerSpeakerId: 20, as: "Quinn Ray")
            ]
        )
    }

    private func knownDrewBaselineMeeting() -> SpeakerNamingSimulationMeeting {
        SpeakerNamingSimulationMeeting(
            id: "known-drew-baseline",
            title: "Known Drew Baseline",
            segments: [
                segment(.system, 16, truth: "drew", expected: "Drew Keeper", text: "drew should stay named drew", start: 0, embedding: drew)
            ],
            actions: []
        )
    }

    private func deferredLowConfidenceMatchedDrewMeeting() -> SpeakerNamingSimulationMeeting {
        SpeakerNamingSimulationMeeting(
            id: "deferred-low-confidence-match",
            title: "Deferred Low Confidence Match",
            segments: [
                segment(
                    .system,
                    17,
                    truth: "riley",
                    expected: "Riley Park",
                    text: "riley is near drew but should become separate",
                    start: 0,
                    embedding: near(drew, degrees: 30)
                )
            ],
            actions: [.deferAll],
            postActions: [
                .nameDeferred(channel: .system, diarizerSpeakerId: 17, as: "Riley Park")
            ]
        )
    }

    private func segment(
        _ channel: UtteranceChannel,
        _ diarizerSpeakerId: Int,
        truth: String,
        expected: String,
        text: String,
        start: TimeInterval,
        duration: TimeInterval = 2.0,
        embedding: [Float],
        qualityScore: Float = 0.95
    ) -> SpeakerNamingSimulationSegment {
        SpeakerNamingSimulationSegment(
            channel: channel,
            diarizerSpeakerId: diarizerSpeakerId,
            truthSpeakerId: truth,
            expectedDisplayName: expected,
            text: text,
            start: start,
            duration: duration,
            embedding: embedding,
            qualityScore: qualityScore
        )
    }

    private var alex: [Float] { vector(degrees: 0) }
    private var blair: [Float] { vector(degrees: 70) }
    private var casey: [Float] { vector(degrees: 125) }
    private var justin: [Float] { vector(degrees: 210) }
    private var naomi: [Float] { vector(degrees: 250) }
    private var jordan: [Float] { vector(degrees: 290) }
    private var taylor: [Float] { vector(degrees: 330) }
    private var morgan: [Float] { [0, 0, 1] }
    private var samA: [Float] { vector(degrees: 190) }
    private var samB: [Float] { vector(degrees: 115) }
    private var drew: [Float] { vector(degrees: 20) }

    private func vector(degrees: Float) -> [Float] {
        let radians = degrees * .pi / 180
        return [cos(radians), sin(radians)]
    }

    private func near(_ base: [Float], degrees: Float) -> [Float] {
        guard base.count == 2 else { return base }
        let angle = atan2(base[1], base[0]) + degrees * .pi / 180
        return [cos(angle), sin(angle)]
    }
}

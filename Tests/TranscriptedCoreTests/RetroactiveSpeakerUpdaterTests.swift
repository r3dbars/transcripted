import Foundation
import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class RetroactiveSpeakerUpdaterTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var speakerDatabase: SpeakerDatabase!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetroactiveSpeakerUpdaterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        speakerDatabase = SpeakerDatabase(
            path: temporaryDirectory.appendingPathComponent("speakers.sqlite").path
        )
    }

    override func tearDown() {
        speakerDatabase = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        super.tearDown()
    }

    func testRetroactivelyUpdateSpeakerRenamesEscapedQuotes() throws {
        let speakerId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("quoted.md")
        let oldName = #"Dana "D" Smith"#
        let newName = #"Dana Smith"#

        try markdown(
            speakerId: speakerId,
            speakerName: oldName
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)

        TranscriptSaver.retroactivelyUpdateSpeaker(
            dbId: speakerId,
            newName: newName,
            in: temporaryDirectory
        )

        let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updated.contains(#"name: "Dana Smith""#))
        XCTAssertTrue(updated.contains("[System/Dana Smith]"))
        XCTAssertFalse(updated.contains(#"name: "Dana \"D\" Smith""#))
        XCTAssertFalse(updated.contains(#"[System/Dana "D" Smith]"#))
    }

    func testRetroactivelyUpdateSpeakerRestrictsRewrittenTranscript() throws {
        let speakerId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("permissions.md")

        try markdown(
            speakerId: speakerId,
            speakerName: "Speaker 1"
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: transcriptURL.path)

        TranscriptSaver.retroactivelyUpdateSpeaker(
            dbId: speakerId,
            newName: "Jamie",
            in: temporaryDirectory
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: transcriptURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    func testRetroactivelyUpdateSpeakerRenamesEscapedBackslashes() throws {
        let speakerId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("backslash.md")
        let oldName = #"C:\Users\Dana"#
        let newName = #"Dana Laptop"#

        try markdown(
            speakerId: speakerId,
            speakerName: oldName
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)

        TranscriptSaver.retroactivelyUpdateSpeaker(
            dbId: speakerId,
            newName: newName,
            in: temporaryDirectory
        )

        let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updated.contains(#"name: "Dana Laptop""#))
        XCTAssertTrue(updated.contains("[System/Dana Laptop]"))
        XCTAssertFalse(updated.contains(#"name: "C:\\Users\\Dana""#))
        XCTAssertFalse(updated.contains(#"[System/C:\Users\Dana]"#))
    }

    func testRetroactivelyUpdateSpeakerRenamesMicLabels() throws {
        let speakerId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("mic.md")
        try """
        ---
        speakers:
          - id: "1"
            channel: mic
            db_id: "\(speakerId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
        ---

        #### Local Speaker Breakdown

        - **Speaker 1:** 1 utterances, ~2 words, 00:01

        ---

        [00:00] [Mic/Speaker 1] hello there
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        TranscriptSaver.retroactivelyUpdateSpeaker(
            dbId: speakerId,
            newName: "Jamie",
            in: temporaryDirectory
        )

        let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updated.contains(#"name: "Jamie""#))
        XCTAssertTrue(updated.contains("[Mic/Jamie]"))
        XCTAssertTrue(updated.contains("- **Jamie:** 1 utterances"))
        XCTAssertFalse(updated.contains("[Mic/Speaker 1]"))
    }

    func testRetroactivelyUpdateSpeakerDoesNotRenameOtherSpeakerWithSameName() throws {
        let micId = UUID()
        let systemId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("shared-name.md")
        try """
        ---
        speakers:
          - id: "1"
            channel: mic
            db_id: "\(micId.uuidString)"
            name: "John"
            confidence: unknown
            source: db_pending
          - id: "1"
            channel: system
            db_id: "\(systemId.uuidString)"
            name: "John"
            confidence: unknown
            source: db_pending
        ---

        #### Local Speaker Breakdown

        - **John:** 1 utterances, ~2 words, 00:01

        ---

        [00:00] [Mic/John] hello there
        [00:05] [System/John] hi back
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        TranscriptSaver.retroactivelyUpdateSpeaker(
            dbId: micId,
            newName: "Jonathan",
            in: temporaryDirectory
        )

        let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        // The mic row's YAML name and mic body labels move to the new name.
        XCTAssertTrue(updated.contains(#"name: "Jonathan""#))
        XCTAssertTrue(updated.contains("[Mic/Jonathan]"))
        // The system speaker who shares the old display name is untouched.
        XCTAssertTrue(updated.contains(#"name: "John""#))
        XCTAssertTrue(updated.contains("[System/John] hi back"))
        XCTAssertFalse(updated.contains("[System/Jonathan]"))
    }

    func testRetroactivelyUpdateSpeakerFailsClosedForSameChannelSharedName() throws {
        let targetId = UUID()
        let otherId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("same-channel-shared-name.md")
        try """
        ---
        speakers:
          - id: "1"
            channel: system
            db_id: "\(targetId.uuidString)"
            name: "John"
            confidence: unknown
            source: db_pending
          - id: "2"
            channel: system
            db_id: "\(otherId.uuidString)"
            name: "John"
            confidence: unknown
            source: db_pending
        ---

        [00:00] [System/John] which john said this is unknowable
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        TranscriptSaver.retroactivelyUpdateSpeaker(
            dbId: targetId,
            newName: "Jonathan",
            in: temporaryDirectory
        )

        let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        // The target row's YAML metadata is corrected…
        XCTAssertTrue(updated.contains(#"name: "Jonathan""#))
        XCTAssertTrue(updated.contains(#"name: "John""#))
        // …but ambiguous body labels are left alone rather than guessed at.
        XCTAssertTrue(updated.contains("[System/John] which john said this is unknowable"))
        XCTAssertFalse(updated.contains("[System/Jonathan]"))
    }

    func testRetroactivelyUpdateSpeakerScansSubfolders() throws {
        let speakerId = UUID()
        let subfolder = temporaryDirectory.appendingPathComponent("2026/june", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let transcriptURL = subfolder.appendingPathComponent("nested.md")

        try markdown(
            speakerId: speakerId,
            speakerName: "Speaker 1"
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)

        TranscriptSaver.retroactivelyUpdateSpeaker(
            dbId: speakerId,
            newName: "Jamie",
            in: temporaryDirectory
        )

        let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updated.contains(#"name: "Jamie""#))
        XCTAssertFalse(updated.contains(#"name: "Speaker 1""#))
    }

    func testRetroactivelyUpdateSpeakerFindsDbIdDeepInLargeFrontmatter() throws {
        // Guards the frontmatter pre-scan in the retroactive paths: the db_id row
        // must still be found when a large frontmatter (e.g. many gap_events)
        // pushes the speakers block far past the first read chunk.
        let speakerId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("large-frontmatter.md")
        let gapEvents = (0..<3000)
            .map { "  - \"Audio gap \($0) detected while the capture device was switching routes\"" }
            .joined(separator: "\n")
        try """
        ---
        gap_events:
        \(gapEvents)
        speakers:
          - id: "1"
            channel: system
            db_id: "\(speakerId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
        ---

        [00:00] [System/Speaker 1] hello there
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        TranscriptSaver.retroactivelyUpdateSpeaker(
            dbId: speakerId,
            newName: "Jamie",
            in: temporaryDirectory
        )

        let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updated.contains(#"name: "Jamie""#))
        XCTAssertTrue(updated.contains("[System/Jamie]"))
        XCTAssertFalse(updated.contains("[System/Speaker 1]"))
    }

    func testUpdateDeferredSpeakerNameOnlyRenamesQueuedChannelSpeaker() throws {
        let micId = UUID()
        let systemId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("channel-collision.md")
        try """
        ---
        speakers:
          - id: "1"
            channel: mic
            db_id: "\(micId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
          - id: "1"
            channel: system
            db_id: "\(systemId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
        ---

        #### Remote Speaker Breakdown

        - **Speaker 1:** 1 utterances, ~2 words, 00:01

        #### Local Speaker Breakdown

        - **Speaker 1:** 1 utterances, ~2 words, 00:01

        ---

        [00:00] [System/Speaker 1] remote hello
        [00:01] [Mic/Speaker 1] room hello
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let didUpdate = TranscriptSaver.updateDeferredSpeakerName(
            transcriptURL: transcriptURL,
            dbId: systemId,
            diarizerSpeakerId: "1",
            channel: .system,
            newName: "Taylor"
        )

        XCTAssertTrue(didUpdate)
        let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updated.contains(#"db_id: "\#(systemId.uuidString)""#))
        XCTAssertTrue(updated.contains(#"name: "Taylor""#))
        XCTAssertTrue(updated.contains("[System/Taylor]"))
        XCTAssertTrue(updated.contains("- **Taylor:** 1 utterances, ~2 words, 00:01"))
        XCTAssertTrue(updated.contains(#"db_id: "\#(micId.uuidString)""#))
        XCTAssertTrue(updated.contains("[Mic/Speaker 1]"))
        XCTAssertTrue(updated.contains("- **Speaker 1:** 1 utterances, ~2 words, 00:01"))
        XCTAssertFalse(updated.contains("[Mic/Taylor]"))
    }

    func testUpdateDeferredSpeakerNameCanRenameSameProfileAcrossSavedCalls() throws {
        let speakerId = UUID()
        let firstURL = temporaryDirectory.appendingPathComponent("first-call.md")
        let secondURL = temporaryDirectory.appendingPathComponent("second-call.md")
        try pendingSystemMarkdown(
            speakerId: speakerId,
            diarizerSpeakerId: "1",
            speakerName: "Speaker 1",
            sample: "first call"
        ).write(to: firstURL, atomically: true, encoding: .utf8)
        try pendingSystemMarkdown(
            speakerId: speakerId,
            diarizerSpeakerId: "2",
            speakerName: "Speaker 2",
            sample: "second call"
        ).write(to: secondURL, atomically: true, encoding: .utf8)

        let firstUpdated = TranscriptSaver.updateDeferredSpeakerName(
            transcriptURL: firstURL,
            dbId: speakerId,
            diarizerSpeakerId: "1",
            channel: .system,
            newName: "Taylor"
        )
        let secondUpdated = TranscriptSaver.updateDeferredSpeakerName(
            transcriptURL: secondURL,
            dbId: speakerId,
            diarizerSpeakerId: "2",
            channel: .system,
            newName: "Taylor"
        )

        XCTAssertTrue(firstUpdated)
        XCTAssertTrue(secondUpdated)
        let first = try String(contentsOf: firstURL, encoding: .utf8)
        let second = try String(contentsOf: secondURL, encoding: .utf8)
        XCTAssertTrue(first.contains(#"name: "Taylor""#))
        XCTAssertTrue(first.contains("[System/Taylor]"))
        XCTAssertFalse(first.contains("[System/Speaker 1]"))
        XCTAssertTrue(second.contains(#"name: "Taylor""#))
        XCTAssertTrue(second.contains("[System/Taylor]"))
        XCTAssertFalse(second.contains("[System/Speaker 2]"))
    }

    func testUpdateDeferredSpeakerNameTreatsMissingChannelAsLegacySystemAudio() throws {
        let speakerId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("legacy-system.md")
        try """
        ---
        speakers:
          - id: "1"
            db_id: "\(speakerId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
        ---

        #### Remote Speaker Breakdown

        - **Speaker 1:** 1 utterances, ~2 words, 00:01

        ---

        [00:00] [System/Speaker 1] remote hello
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let didUpdate = TranscriptSaver.updateDeferredSpeakerName(
            transcriptURL: transcriptURL,
            dbId: speakerId,
            diarizerSpeakerId: "1",
            channel: .system,
            newName: "Taylor"
        )

        XCTAssertTrue(didUpdate)
        let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updated.contains(#"name: "Taylor""#))
        XCTAssertTrue(updated.contains("source: user_manual"))
        XCTAssertTrue(updated.contains("[System/Taylor]"))
        XCTAssertFalse(updated.contains("[System/Speaker 1]"))
    }

    func testUpdateDeferredSpeakerNameDoesNotRewriteLiteralTextMentions() throws {
        let speakerId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("literal-token.md")
        try """
        ---
        speakers:
          - id: "1"
            channel: system
            db_id: "\(speakerId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
        ---

        #### Remote Speaker Breakdown

        - **Speaker 1:** 1 utterances, ~10 words, 00:03

        ---

        [00:00] [System/Speaker 1] literal token [System/Speaker 1] should stay in spoken text
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let didUpdate = TranscriptSaver.updateDeferredSpeakerName(
            transcriptURL: transcriptURL,
            dbId: speakerId,
            diarizerSpeakerId: "1",
            channel: .system,
            newName: "Taylor"
        )

        XCTAssertTrue(didUpdate)
        let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updated.contains("[00:00] [System/Taylor] literal token [System/Speaker 1] should stay in spoken text"))
        XCTAssertTrue(updated.contains("- **Taylor:** 1 utterances, ~10 words, 00:03"))
    }

    func testUpdateDeferredSpeakerNameConsolidatesDuplicateRemoteBreakdownRows() throws {
        let pendingSpeakerId = UUID()
        let existingSpeakerId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("duplicate-breakdown.md")
        try """
        ---
        system_speakers: 2
        speakers:
          - id: "1"
            channel: system
            db_id: "\(pendingSpeakerId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
          - id: "2"
            channel: system
            db_id: "\(existingSpeakerId.uuidString)"
            name: "Alex"
            confidence: high
            source: db
        ---

        ## Speaker Analytics

        - **Speakers Detected:** 2

        #### Remote Speaker Breakdown

        - **Speaker 1:** 1 utterances, ~2 words, 00:01
        - **Alex:** 2 utterances, ~4 words, 00:03

        ---

        [00:00] [System/Speaker 1] first fragment
        [00:01] [System/Alex] second fragment

        ---

        *2 channels | 3 speakers*
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let didUpdate = TranscriptSaver.updateDeferredSpeakerName(
            transcriptURL: transcriptURL,
            dbId: pendingSpeakerId,
            diarizerSpeakerId: "1",
            channel: .system,
            newName: "Alex"
        )

        XCTAssertTrue(didUpdate)
        let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updated.contains("system_speakers: 1"))
        XCTAssertTrue(updated.contains("- **Speakers Detected:** 1"))
        XCTAssertTrue(updated.contains("- **Alex:** 3 utterances, ~6 words, 00:04"))
        XCTAssertTrue(updated.contains("[00:00] [System/Alex] first fragment"))
        XCTAssertTrue(updated.contains("*2 channels | 2 speakers*"))
        XCTAssertFalse(updated.contains("- **Speaker 1:**"))
        XCTAssertFalse(updated.contains("- **Alex:** 2 utterances, ~4 words, 00:03"))
    }

    func testRetroactivelyMergeSpeakerRepointsDbIdForFutureRenames() throws {
        let sourceId = UUID()
        let targetId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("merge.md")
        try markdown(
            speakerId: sourceId,
            speakerName: "Alex Old"
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)

        TranscriptSaver.retroactivelyMergeSpeaker(
            sourceDbId: sourceId,
            targetDbId: targetId,
            targetName: "Alex",
            in: temporaryDirectory
        )

        var updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertFalse(updated.contains(#"db_id: "\#(sourceId.uuidString)""#))
        XCTAssertTrue(updated.contains(#"db_id: "\#(targetId.uuidString)""#))
        XCTAssertTrue(updated.contains(#"name: "Alex""#))
        XCTAssertTrue(updated.contains("[System/Alex]"))

        TranscriptSaver.retroactivelyUpdateSpeaker(
            dbId: targetId,
            newName: "Alicia",
            in: temporaryDirectory
        )

        updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updated.contains(#"name: "Alicia""#))
        XCTAssertTrue(updated.contains("[System/Alicia]"))
    }

    func testRetroactivelyMergeSpeakerIgnoresDbIdMentionedOnlyInBodyText() throws {
        // db_id references only ever live in the YAML frontmatter speakers block,
        // so a literal mention in spoken transcript text is not a profile link and
        // must not be rewritten by a merge.
        let sourceId = UUID()
        let targetId = UUID()
        let unrelatedId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("body-mention.md")
        let original = """
        ---
        speakers:
          - id: "1"
            channel: system
            db_id: "\(unrelatedId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
        ---

        [00:00] [System/Speaker 1] the yaml row read db_id: "\(sourceId.uuidString)" out loud
        """
        try original.write(to: transcriptURL, atomically: true, encoding: .utf8)

        TranscriptSaver.retroactivelyMergeSpeaker(
            sourceDbId: sourceId,
            targetDbId: targetId,
            targetName: "Alex",
            in: temporaryDirectory
        )

        let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertEqual(updated, original)
    }

    func testUpdateSpeakerNamesInsertsDbIdWhenTranscriptStartedGeneric() throws {
        let speakerId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("generic.md")
        try genericMarkdown().write(to: transcriptURL, atomically: true, encoding: .utf8)
        let updated = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: speakerId,
                    diarizerSpeakerId: "0",
                    newName: "Alex",
                    action: .named
                )
            ],
            speakerStoreForIndex: speakerDatabase
        )

        XCTAssertTrue(updated)

        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains(#"db_id: "\#(speakerId.uuidString)""#))
        XCTAssertTrue(markdown.contains(#"name: "Alex""#))
        XCTAssertTrue(markdown.contains("[System/Alex]"))
    }

    func testUpdateSpeakerNamesKeepsSplitSpeakerSaveWhenBreakdownSpacingDrifts() throws {
        let firstId = UUID()
        let secondId = UUID()
        let thirdId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("split-speaker-drift.md")
        try """
        ---
        transcript_id: "\(UUID().uuidString)"
        system_speakers: 3
        speakers:
          - id: "1"
            channel: system
            db_id: "\(firstId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
          - id: "2"
            channel: system
            db_id: "\(secondId.uuidString)"
            name: "Speaker 2"
            confidence: unknown
            source: db_pending
          - id: "3"
            channel: system
            db_id: "\(thirdId.uuidString)"
            name: "Speaker 3"
            confidence: unknown
            source: db_pending
        ---

        #### Remote Speaker Breakdown

        - **Speaker 1:** 1 utterances, ~2 words, 00:01
        - **Speaker 2:** 1 utterances, ~2 words, 00:01
        - **Speaker 3:** 1 utterances, ~2 words, 00:01
        ## Full Transcript

        [00:00] [System/Speaker 1] first fragment

        [00:02] [System/Speaker 2] second fragment

        [00:04] [System/Speaker 3] third fragment

        ---

        *Generated by Transcripted with Parakeet + PyAnnote (local) | Duration: 0:06 | 6 words | 3 speakers*
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(start: 0, end: 1, channel: 1, speakerId: 1, persistentSpeakerId: firstId, matchSimilarity: nil, transcript: "first fragment"),
                TranscriptionUtterance(start: 2, end: 3, channel: 1, speakerId: 2, persistentSpeakerId: secondId, matchSimilarity: nil, transcript: "second fragment"),
                TranscriptionUtterance(start: 4, end: 5, channel: 1, speakerId: 3, persistentSpeakerId: thirdId, matchSimilarity: nil, transcript: "third fragment"),
            ],
            duration: 6,
            processingTime: 1
        )

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(persistentSpeakerId: firstId, diarizerSpeakerId: "1", newName: "Grigory", action: .named),
                SpeakerNameUpdate(persistentSpeakerId: secondId, diarizerSpeakerId: "2", newName: "Grigory", action: .named),
                SpeakerNameUpdate(persistentSpeakerId: thirdId, diarizerSpeakerId: "3", newName: "Grigory", action: .named),
            ],
            transcriptionResult: result
        )

        XCTAssertTrue(didUpdate)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("[00:00] [System/Grigory] first fragment"), markdown)
        XCTAssertTrue(markdown.contains("[00:02] [System/Grigory] second fragment"), markdown)
        XCTAssertTrue(markdown.contains("[00:04] [System/Grigory] third fragment"), markdown)
        XCTAssertTrue(markdown.contains(#"name: "Grigory""#), markdown)
        XCTAssertFalse(markdown.contains("[System/Speaker 1]"), markdown)
        XCTAssertFalse(markdown.contains("- **Speaker 2:**"), markdown)
    }

    func testUpdateSpeakerNamesConsolidatesFooterlessSplitSpeakerBreakdown() throws {
        let firstId = UUID()
        let secondId = UUID()
        let thirdId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("split-speaker-footerless-breakdown.md")
        try """
        ---
        transcript_id: "\(UUID().uuidString)"
        system_speakers: 3
        speakers:
          - id: "1"
            channel: system
            db_id: "\(firstId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
          - id: "2"
            channel: system
            db_id: "\(secondId.uuidString)"
            name: "Speaker 2"
            confidence: unknown
            source: db_pending
          - id: "3"
            channel: system
            db_id: "\(thirdId.uuidString)"
            name: "Speaker 3"
            confidence: unknown
            source: db_pending
        ---

        ## Full Transcript

        [00:00] [System/Speaker 1] first fragment

        [00:02] [System/Speaker 2] second fragment

        [00:04] [System/Speaker 3] third fragment

        ---

        *Generated by Transcripted with Parakeet + PyAnnote (local) | Duration: 0:06 | 6 words | 3 speakers*

        #### Remote Speaker Breakdown

        - **Speaker 1:** 1 utterances, ~2 words, 00:01
        - **Speaker 2:** 1 utterances, ~2 words, 00:01
        - **Speaker 3:** 1 utterances, ~2 words, 00:01
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(start: 0, end: 1, channel: 1, speakerId: 1, persistentSpeakerId: firstId, matchSimilarity: nil, transcript: "first fragment"),
                TranscriptionUtterance(start: 2, end: 3, channel: 1, speakerId: 2, persistentSpeakerId: secondId, matchSimilarity: nil, transcript: "second fragment"),
                TranscriptionUtterance(start: 4, end: 5, channel: 1, speakerId: 3, persistentSpeakerId: thirdId, matchSimilarity: nil, transcript: "third fragment"),
            ],
            duration: 6,
            processingTime: 1
        )

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(persistentSpeakerId: firstId, diarizerSpeakerId: "1", newName: "Grigory", action: .named),
                SpeakerNameUpdate(persistentSpeakerId: secondId, diarizerSpeakerId: "2", newName: "Grigory", action: .named),
                SpeakerNameUpdate(persistentSpeakerId: thirdId, diarizerSpeakerId: "3", newName: "Grigory", action: .named),
            ],
            transcriptionResult: result
        )

        XCTAssertTrue(didUpdate)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("- **Grigory:** 3 utterances, ~6 words, 00:03"), markdown)
        XCTAssertTrue(markdown.contains("system_speakers: 1"), markdown)
        XCTAssertTrue(markdown.contains("| 6 words | 1 speakers*"), markdown)
        XCTAssertFalse(markdown.contains("- **Speaker 2:**"), markdown)
    }

    func testMarkSpeakerReviewDeferredRepointsPendingDbIdWithoutRenamingTranscript() throws {
        let originalProfileId = UUID()
        let deferredProfileId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("deferred.md")
        try """
        ---
        speakers:
          - id: "1"
            channel: system
            db_id: "\(originalProfileId.uuidString)"
            name: "Speaker 1"
            confidence: medium
            source: db_pending
        ---

        #### Remote Speaker Breakdown

        - **Speaker 1:** 1 utterances, ~2 words, 00:01

        ---

        [00:00] [System/Speaker 1] hello there
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let didUpdate = TranscriptSaver.markSpeakerReviewDeferred(
            transcriptURL: transcriptURL,
            entries: [
                SpeakerNamingEntry(
                    id: originalProfileId,
                    diarizerSpeakerId: "1",
                    channel: .system,
                    clipURL: temporaryDirectory.appendingPathComponent("clip.wav"),
                    sampleText: "hello there",
                    currentName: "Alex",
                    matchSimilarity: 0.9,
                    needsNaming: false,
                    needsConfirmation: true
                )
            ],
            redirectedSpeakerIdsByKey: ["system_1": deferredProfileId]
        )

        XCTAssertTrue(didUpdate)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertFalse(markdown.contains(#"db_id: "\#(originalProfileId.uuidString)""#))
        XCTAssertTrue(markdown.contains(#"db_id: "\#(deferredProfileId.uuidString)""#))
        XCTAssertTrue(markdown.contains(#"name: "Speaker 1""#))
        XCTAssertTrue(markdown.contains("source: db_pending"))
        XCTAssertTrue(markdown.contains("[System/Speaker 1]"))
        XCTAssertFalse(markdown.contains("[System/Alex]"))
    }

    func testMarkSpeakerReviewDeferredKeepsMicLabelsAndLocalBreakdownGeneric() throws {
        let originalProfileId = UUID()
        let deferredProfileId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("deferred-mic.md")
        try """
        ---
        speakers:
          - id: "1"
            channel: mic
            db_id: "\(originalProfileId.uuidString)"
            name: "Speaker 1"
            confidence: medium
            source: db_pending
        ---

        ### Microphone (People in the Room)
        - **Utterances:** 1
        - **Words:** ~2
        - **Speaking Time:** 00:01
        - **Speakers Detected:** 1

        #### Local Speaker Breakdown

        - **Speaker 1:** 1 utterances, ~2 words, 00:01

        ---

        [00:00] [Mic/Speaker 1] hello there
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let didUpdate = TranscriptSaver.markSpeakerReviewDeferred(
            transcriptURL: transcriptURL,
            entries: [
                SpeakerNamingEntry(
                    id: originalProfileId,
                    diarizerSpeakerId: "1",
                    channel: .mic,
                    clipURL: temporaryDirectory.appendingPathComponent("clip-mic.wav"),
                    sampleText: "hello there",
                    currentName: "Alex",
                    matchSimilarity: 0.9,
                    needsNaming: false,
                    needsConfirmation: true
                )
            ],
            redirectedSpeakerIdsByKey: ["mic_1": deferredProfileId]
        )

        XCTAssertTrue(didUpdate)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertFalse(markdown.contains(#"db_id: "\#(originalProfileId.uuidString)""#))
        XCTAssertTrue(markdown.contains(#"db_id: "\#(deferredProfileId.uuidString)""#))
        XCTAssertTrue(markdown.contains(#"name: "Speaker 1""#))
        XCTAssertTrue(markdown.contains("source: db_pending"))
        XCTAssertTrue(markdown.contains("- **Speaker 1:** 1 utterances, ~2 words, 00:01"))
        XCTAssertTrue(markdown.contains("[Mic/Speaker 1]"))
        XCTAssertFalse(markdown.contains("[Mic/Alex]"))
    }

    private struct MarkdownSpeaker {
        let id: String
        let persistentSpeakerId: UUID
        let name: String
        let confidence: String
        let source: String
    }

    private struct MarkdownUtterance {
        let timestamp: String
        let source: String
        let label: String
        let text: String
        let diarizerSpeakerId: Int?
        let speakingSeconds: Double

        init(
            timestamp: String,
            source: String,
            label: String,
            text: String,
            diarizerSpeakerId: Int? = nil,
            speakingSeconds: Double = 3.0
        ) {
            self.timestamp = timestamp
            self.source = source
            self.label = label
            self.text = text
            self.diarizerSpeakerId = diarizerSpeakerId
            self.speakingSeconds = speakingSeconds
        }
    }

    private struct BreakdownEntry {
        let name: String
        let utterances: Int
        let wordCount: Int
        let duration: String
    }

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetroactiveSpeakerUpdaterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testConsolidateSpeakerBreakdownMergesDuplicateNamesAndCounts() {
        let content = """
        ---
        system_speakers: 3
        ---

        ## Speaker Analytics

        - **Speakers Detected:** 3

        #### Remote Speaker Breakdown

        - **Alex:** 2 utterances, ~10 words, 00:30
        - **Alex:** 1 utterances, ~5 words, 00:15
        - **Jordan:** 4 utterances, ~40 words, 01:00

        ---

        *2 channels | 4 speakers*
        """

        let updated = SpeakerBreakdownConsolidator.consolidate(content)

        XCTAssertTrue(updated.contains("system_speakers: 2"))
        XCTAssertTrue(updated.contains("- **Speakers Detected:** 2"))
        XCTAssertTrue(updated.contains("- **Alex:** 3 utterances, ~15 words, 00:45"))
        XCTAssertFalse(updated.contains("- **Alex:** 2 utterances, ~10 words, 00:30"))
        XCTAssertTrue(updated.contains("*2 channels | 3 speakers*"))
    }

    func testConsolidateSpeakerBreakdownLeavesUniqueNamesUntouched() {
        let content = """
        ---
        system_speakers: 2
        ---

        ## Speaker Analytics

        - **Speakers Detected:** 2

        #### Remote Speaker Breakdown

        - **Alex:** 2 utterances, ~10 words, 00:30
        - **Jordan:** 4 utterances, ~40 words, 01:00

        ---

        *2 channels | 3 speakers*
        """

        XCTAssertEqual(SpeakerBreakdownConsolidator.consolidate(content), content)
    }

    func testConsolidateSpeakerBreakdownPreservesFooterlessTrailingNotes() {
        let content = """
        ---
        system_speakers: 3
        ---

        #### Remote Speaker Breakdown

        - **Alex:** 2 utterances, ~10 words, 00:30
        - **Alex:** 1 utterances, ~5 words, 00:15
        - **Jordan:** 4 utterances, ~40 words, 01:00

        Follow-up note I typed after the transcript.
        """

        let updated = SpeakerBreakdownConsolidator.consolidate(content)

        XCTAssertTrue(updated.contains("system_speakers: 2"))
        XCTAssertTrue(updated.contains("- **Alex:** 3 utterances, ~15 words, 00:45"))
        XCTAssertTrue(updated.contains("Follow-up note I typed after the transcript."))
        XCTAssertFalse(updated.contains("- **Alex:** 2 utterances, ~10 words, 00:30"))
    }

    private func markdown(speakerId: UUID, speakerName: String) -> String {
        """
        ---
        speakers:
          - id: "0"
            db_id: "\(speakerId.uuidString)"
            name: "\(TranscriptSaver.escapeYAML(speakerName))"
            confidence: medium
            source: db
        ---

        #### Remote Speaker Breakdown

        - **\(speakerName):** 1 utterances, ~2 words, 00:01

        ---

        [00:00] [System/\(speakerName)] hello there
        """
    }

    private func pendingSystemMarkdown(
        speakerId: UUID,
        diarizerSpeakerId: String,
        speakerName: String,
        sample: String
    ) -> String {
        """
        ---
        speakers:
          - id: "\(diarizerSpeakerId)"
            channel: system
            db_id: "\(speakerId.uuidString)"
            name: "\(speakerName)"
            confidence: unknown
            source: db_pending
        ---

        #### Remote Speaker Breakdown

        - **\(speakerName):** 1 utterances, ~2 words, 00:01

        ---

        [00:00] [System/\(speakerName)] \(sample)
        """
    }

    private func genericMarkdown() -> String {
        """
        ---
        speakers:
          - id: "0"
            name: "Speaker 0"
            confidence: medium
            source: db
        ---

        #### Remote Speaker Breakdown

        - **Speaker 0:** 1 utterances, ~2 words, 00:01

        ---

        ## Full Transcript

        [00:00] [System/Speaker 0] hello there

        ---

        *Generated by Transcripted*
        """
    }

    func testResolveTranscriptURLFindsRenamedTranscriptByStableId() throws {
        let transcriptId = UUID()
        let originalURL = tempDirectory.appendingPathComponent("Call_2026-04-10_15-01-23.md")
        let renamedURL = tempDirectory.appendingPathComponent("Meeting with Sarah Graham.md")

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: [
                MarkdownSpeaker(
                    id: "1",
                    persistentSpeakerId: UUID(),
                    name: "Speaker 1",
                    confidence: "unknown",
                    source: "db_pending"
                )
            ],
            utterances: [
                MarkdownUtterance(
                    timestamp: "00:01",
                    source: "System",
                    label: "Speaker 1",
                    text: "Thanks for joining."
                )
            ],
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        ).write(to: renamedURL, atomically: true, encoding: .utf8)

        let resolved = TranscriptSaver.resolveTranscriptURL(originalURL, transcriptId: transcriptId)

        XCTAssertEqual(resolved, renamedURL)
    }

    func testResolveTranscriptURLFailsWhenStableIdDoesNotMatchAnySibling() throws {
        let transcriptId = UUID()
        let originalURL = tempDirectory.appendingPathComponent("Call_2026-04-10_15-01-23.md")
        let wrongURL = tempDirectory.appendingPathComponent("Meeting with Someone Else.md")

        try sampleTranscript(
            transcriptId: UUID(),
            speakers: [
                MarkdownSpeaker(
                    id: "1",
                    persistentSpeakerId: UUID(),
                    name: "Speaker 1",
                    confidence: "unknown",
                    source: "db_pending"
                )
            ],
            utterances: [
                MarkdownUtterance(
                    timestamp: "00:01",
                    source: "System",
                    label: "Speaker 1",
                    text: "Thanks for joining."
                )
            ],
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        ).write(to: wrongURL, atomically: true, encoding: .utf8)

        let resolved = TranscriptSaver.resolveTranscriptURL(originalURL, transcriptId: transcriptId)

        XCTAssertNil(resolved)
    }

    func testUpdateSpeakerNamesRewritesPreviousSuggestedNameAndPersistentId() throws {
        let transcriptId = UUID()
        let originalPersistentId = UUID()
        let correctedPersistentId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("Meeting with Matt Vlasach.md")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: originalPersistentId,
                name: "Matt Vlasach",
                confidence: "medium",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Matt Vlasach",
                text: "Thanks for joining.",
                speakingSeconds: 12.0
            )
        ]

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Matt Vlasach", utterances: 1, wordCount: 5, duration: "00:12")
            ]
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: originalPersistentId,
                    diarizerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Matt Vlasach",
                    action: .corrected,
                    resolvedPersistentSpeakerId: correctedPersistentId
                )
            ],
            transcriptionResult: transcriptionResult
        )

        XCTAssertTrue(didUpdate)

        let updatedMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updatedMarkdown.contains(#"transcript_id: "\#(transcriptId.uuidString)""#))
        XCTAssertTrue(updatedMarkdown.contains(#"db_id: "\#(correctedPersistentId.uuidString)""#))
        XCTAssertTrue(updatedMarkdown.contains(#"name: "Sarah Graham""#))
        XCTAssertTrue(updatedMarkdown.contains("source: user_manual"))
        XCTAssertTrue(updatedMarkdown.contains("[System/Sarah Graham]"))
        XCTAssertTrue(updatedMarkdown.contains("- **Sarah Graham:** 1 utterances, ~3 words, 00:12"))
    }

    func testUpdateSpeakerNamesSucceedsWithoutJSONSidecar() throws {
        let transcriptId = UUID()
        let persistentSpeakerId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("Meeting with Speaker 1.md")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: persistentSpeakerId,
                name: "Speaker 1",
                confidence: "unknown",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Speaker 1",
                text: "Thanks for joining."
            )
        ]
        let originalMarkdown = sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        )
        try originalMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: persistentSpeakerId,
                    diarizerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Speaker 1",
                    action: .named
                )
            ],
            transcriptionResult: transcriptionResult
        )

        XCTAssertTrue(didUpdate)
        let updatedMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertNotEqual(updatedMarkdown, originalMarkdown)
        XCTAssertTrue(updatedMarkdown.contains("Sarah Graham"))
    }

    func testUpdateSpeakerNamesIgnoresCorruptAdjacentJSON() throws {
        let transcriptId = UUID()
        let persistentSpeakerId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("Meeting with Speaker 1.md")
        let jsonURL = transcriptURL.deletingPathExtension().appendingPathExtension("json")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: persistentSpeakerId,
                name: "Speaker 1",
                confidence: "unknown",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Speaker 1",
                text: "Thanks for joining."
            )
        ]
        let originalMarkdown = sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        )
        try originalMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try "{not-json".write(to: jsonURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: persistentSpeakerId,
                    diarizerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Speaker 1",
                    action: .named
                )
            ],
            transcriptionResult: transcriptionResult
        )

        XCTAssertTrue(didUpdate)
        let updatedMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertNotEqual(updatedMarkdown, originalMarkdown)
        XCTAssertTrue(updatedMarkdown.contains("Sarah Graham"))
        XCTAssertEqual(try String(contentsOf: jsonURL, encoding: .utf8), "{not-json")
    }

    func testUpdateSpeakerNamesIgnoresMismatchedAdjacentJSON() throws {
        let transcriptId = UUID()
        let persistentSpeakerId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("Meeting with Speaker 1.md")
        let jsonURL = transcriptURL.deletingPathExtension().appendingPathExtension("json")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: persistentSpeakerId,
                name: "Speaker 1",
                confidence: "unknown",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Speaker 1",
                text: "Thanks for joining."
            )
        ]
        let originalMarkdown = sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        )
        try originalMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try #"{"transcript_id":"other","speakers":[{"id":"system_2"}]}"#.write(to: jsonURL, atomically: true, encoding: .utf8)

        let originalJSON = try String(contentsOf: jsonURL, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)
        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: persistentSpeakerId,
                    diarizerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Speaker 1",
                    action: .named
                )
            ],
            transcriptionResult: transcriptionResult
        )

        XCTAssertTrue(didUpdate)
        let updatedMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertNotEqual(updatedMarkdown, originalMarkdown)
        XCTAssertTrue(updatedMarkdown.contains("Sarah Graham"))
        XCTAssertEqual(try String(contentsOf: jsonURL, encoding: .utf8), originalJSON)
    }

    func testUpdateSpeakerNamesIgnoresAdjacentJSONWithWrongTranscriptId() throws {
        let transcriptId = UUID()
        let persistentSpeakerId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("Meeting with Speaker 1.md")
        let jsonURL = transcriptURL.deletingPathExtension().appendingPathExtension("json")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: persistentSpeakerId,
                name: "Speaker 1",
                confidence: "unknown",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Speaker 1",
                text: "Thanks for joining."
            )
        ]
        let originalMarkdown = sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        )
        try originalMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try #"{"transcript_id":"wrong-id"}"#.write(to: jsonURL, atomically: true, encoding: .utf8)

        let originalJSON = try String(contentsOf: jsonURL, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)
        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: persistentSpeakerId,
                    diarizerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Speaker 1",
                    action: .named
                )
            ],
            transcriptionResult: transcriptionResult
        )

        XCTAssertTrue(didUpdate)
        let updatedMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertNotEqual(updatedMarkdown, originalMarkdown)
        XCTAssertTrue(updatedMarkdown.contains("Sarah Graham"))
        XCTAssertEqual(try String(contentsOf: jsonURL, encoding: .utf8), originalJSON)
    }

    func testUpdateSpeakerNamesOnlyRewritesTargetSpeakerLinesWhenNamesCollide() throws {
        let transcriptId = UUID()
        let firstPersistentId = UUID()
        let secondPersistentId = UUID()
        let correctedPersistentId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("Meeting with Matt Vlasach.md")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: firstPersistentId,
                name: "Matt Vlasach",
                confidence: "medium",
                source: "db_pending"
            ),
            MarkdownSpeaker(
                id: "2",
                persistentSpeakerId: secondPersistentId,
                name: "Matt Vlasach",
                confidence: "medium",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Matt Vlasach",
                text: "Sarah is actually joining today.",
                diarizerSpeakerId: 1,
                speakingSeconds: 3.0
            ),
            MarkdownUtterance(
                timestamp: "00:05",
                source: "System",
                label: "Matt Vlasach",
                text: "Matt Vlasach is still the label on this other speaker.",
                diarizerSpeakerId: 2,
                speakingSeconds: 4.0
            )
        ]

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Matt Vlasach", utterances: 1, wordCount: 5, duration: "00:03"),
                BreakdownEntry(name: "Matt Vlasach", utterances: 1, wordCount: 7, duration: "00:04")
            ]
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: firstPersistentId,
                    diarizerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Matt Vlasach",
                    action: .corrected,
                    resolvedPersistentSpeakerId: correctedPersistentId
                )
            ],
            transcriptionResult: transcriptionResult
        )

        XCTAssertTrue(didUpdate)

        let updatedMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updatedMarkdown.contains(#"  - id: "1""#))
        XCTAssertTrue(updatedMarkdown.contains(#"    db_id: "\#(correctedPersistentId.uuidString)""#))
        XCTAssertTrue(updatedMarkdown.contains("[00:01] [System/Sarah Graham] Sarah is actually joining today."))
        XCTAssertTrue(updatedMarkdown.contains("[00:05] [System/Matt Vlasach] Matt Vlasach is still the label on this other speaker."))
        XCTAssertTrue(updatedMarkdown.contains("- **Sarah Graham:** 1 utterances, ~5 words, 00:03"))
        XCTAssertTrue(updatedMarkdown.contains("- **Matt Vlasach:** 1 utterances, ~10 words, 00:04"))
    }

    func testUpdateSpeakerNamesDoesNotRewriteLiteralTextMentions() throws {
        let transcriptId = UUID()
        let originalPersistentId = UUID()
        let correctedPersistentId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("Meeting with Matt Vlasach.md")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: originalPersistentId,
                name: "Matt Vlasach",
                confidence: "medium",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "[[Matt Vlasach]]",
                text: #"Literal tokens: [[Matt Vlasach]] [System/Matt Vlasach] **Matt Vlasach:** name: "Matt Vlasach""#,
                diarizerSpeakerId: 1,
                speakingSeconds: 3.0
            )
        ]

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Matt Vlasach", utterances: 1, wordCount: 10, duration: "00:03")
            ]
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: originalPersistentId,
                    diarizerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Matt Vlasach",
                    action: .corrected,
                    resolvedPersistentSpeakerId: correctedPersistentId
                )
            ],
            transcriptionResult: transcriptionResult
        )

        XCTAssertTrue(didUpdate)

        let updatedMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updatedMarkdown.contains(#"name: "Sarah Graham""#))
        XCTAssertTrue(updatedMarkdown.contains("[00:01] [System/[[Sarah Graham]]] Literal tokens: [[Matt Vlasach]] [System/Matt Vlasach] **Matt Vlasach:** name: \"Matt Vlasach\""))
        XCTAssertTrue(updatedMarkdown.contains("- **Sarah Graham:** 1 utterances, ~11 words, 00:03"))
    }

    func testUpdateSpeakerNamesFallbackRenamesWikiLinkedLabels() throws {
        let speakerId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("wiki-fallback.md")
        let speakers = [
            MarkdownSpeaker(id: "1", persistentSpeakerId: speakerId, name: "Matt Vlasach", confidence: "medium", source: "db_pending")
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "[[Matt Vlasach]]",
                text: "Hello there.",
                diarizerSpeakerId: 1
            )
        ]

        try sampleTranscript(
            transcriptId: UUID(),
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Matt Vlasach", utterances: 1, wordCount: 2, duration: "00:03")
            ],
            totalWords: 2
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)

        let driftedResult = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(start: 12, end: 15, channel: 1, speakerId: 1, persistentSpeakerId: speakerId, matchSimilarity: nil, transcript: "Hello there.")
            ],
            duration: 15,
            processingTime: 1
        )

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(persistentSpeakerId: speakerId, diarizerSpeakerId: "1", newName: "Sarah Graham", previousName: "Matt Vlasach", action: .corrected)
            ],
            transcriptionResult: driftedResult
        )

        XCTAssertTrue(didUpdate)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("[00:01] [System/[[Sarah Graham]]] Hello there."), markdown)
        XCTAssertFalse(markdown.contains("[System/[[Matt Vlasach]]]"), markdown)
    }

    func testUpdateSpeakerNamesFallbackFailsClosedWhenLabelsCollide() throws {
        let firstId = UUID()
        let secondId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("colliding-labels.md")
        let speakers = [
            MarkdownSpeaker(id: "1", persistentSpeakerId: firstId, name: "Alex", confidence: "medium", source: "db_pending"),
            MarkdownSpeaker(id: "2", persistentSpeakerId: secondId, name: "Alex", confidence: "medium", source: "db_pending"),
        ]
        let utterances = [
            MarkdownUtterance(timestamp: "00:01", source: "System", label: "Alex", text: "First speaker.", diarizerSpeakerId: 1),
            MarkdownUtterance(timestamp: "00:05", source: "System", label: "Alex", text: "Second speaker.", diarizerSpeakerId: 2),
        ]
        let originalMarkdown = sampleTranscript(
            transcriptId: UUID(),
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Alex", utterances: 1, wordCount: 2, duration: "00:03"),
                BreakdownEntry(name: "Alex", utterances: 1, wordCount: 2, duration: "00:03"),
            ],
            totalWords: 4
        )
        try originalMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let driftedResult = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(start: 12, end: 15, channel: 1, speakerId: 1, persistentSpeakerId: firstId, matchSimilarity: nil, transcript: "First speaker."),
                TranscriptionUtterance(start: 5, end: 8, channel: 1, speakerId: 2, persistentSpeakerId: secondId, matchSimilarity: nil, transcript: "Second speaker."),
            ],
            duration: 15,
            processingTime: 1
        )

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(persistentSpeakerId: firstId, diarizerSpeakerId: "1", newName: "Bob", previousName: "Alex", action: .corrected)
            ],
            transcriptionResult: driftedResult
        )

        XCTAssertFalse(didUpdate)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertEqual(markdown, originalMarkdown)
    }

    func testUpdateSpeakerNamesFallbackAppliesOverlappingRenamesSimultaneously() throws {
        let firstId = UUID()
        let secondId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("overlapping-renames.md")
        let speakers = [
            MarkdownSpeaker(id: "1", persistentSpeakerId: firstId, name: "Matt", confidence: "medium", source: "db_pending"),
            MarkdownSpeaker(id: "2", persistentSpeakerId: secondId, name: "Sarah", confidence: "medium", source: "db_pending"),
        ]
        let utterances = [
            MarkdownUtterance(timestamp: "00:01", source: "System", label: "Matt", text: "First speaker.", diarizerSpeakerId: 1),
            MarkdownUtterance(timestamp: "00:05", source: "System", label: "Sarah", text: "Second speaker.", diarizerSpeakerId: 2),
        ]
        let originalMarkdown = sampleTranscript(
            transcriptId: UUID(),
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Matt", utterances: 1, wordCount: 2, duration: "00:03"),
                BreakdownEntry(name: "Sarah", utterances: 1, wordCount: 2, duration: "00:03"),
            ],
            totalWords: 4
        )
        try originalMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let driftedResult = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(start: 12, end: 15, channel: 1, speakerId: 1, persistentSpeakerId: firstId, matchSimilarity: nil, transcript: "First speaker."),
                TranscriptionUtterance(start: 16, end: 19, channel: 1, speakerId: 2, persistentSpeakerId: secondId, matchSimilarity: nil, transcript: "Second speaker."),
            ],
            duration: 20,
            processingTime: 1
        )

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(persistentSpeakerId: firstId, diarizerSpeakerId: "1", newName: "Sarah", previousName: "Matt", action: .corrected),
                SpeakerNameUpdate(persistentSpeakerId: secondId, diarizerSpeakerId: "2", newName: "Jamie", previousName: "Sarah", action: .corrected),
            ],
            transcriptionResult: driftedResult
        )

        XCTAssertTrue(didUpdate)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("[00:01] [System/Sarah] First speaker."), markdown)
        XCTAssertTrue(markdown.contains("[00:05] [System/Jamie] Second speaker."), markdown)
        XCTAssertFalse(markdown.contains("[00:01] [System/Jamie] First speaker."), markdown)
        XCTAssertTrue(markdown.contains(#"name: "Sarah""#), markdown)
        XCTAssertTrue(markdown.contains(#"name: "Jamie""#), markdown)
    }

    func testUpdateSpeakerNamesBreakdownFallbackAppliesOverlappingRenamesSimultaneously() throws {
        let firstId = UUID()
        let secondId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("overlapping-breakdown-renames.md")
        let originalMarkdown = """
        ---
        transcript_id: "\(UUID().uuidString)"
        speakers:
          - id: "1"
            db_id: "\(firstId.uuidString)"
            name: "Matt"
            confidence: medium
            source: db_pending
          - id: "2"
            db_id: "\(secondId.uuidString)"
            name: "Sarah"
            confidence: medium
            source: db_pending
        ---

        ## Full Transcript

        [00:12] [System/Matt] First speaker.

        [00:16] [System/Sarah] Second speaker.

        ---

        *Generated by Transcripted with Parakeet + PyAnnote (local) | Duration: 0:20 | 4 words | 2 speakers*

        #### Remote Speaker Breakdown

        - **Matt:** 1 utterances, ~2 words, 00:03
        - **Sarah:** 1 utterances, ~2 words, 00:03
        """
        try originalMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(start: 12, end: 15, channel: 1, speakerId: 1, persistentSpeakerId: firstId, matchSimilarity: nil, transcript: "First speaker."),
                TranscriptionUtterance(start: 16, end: 19, channel: 1, speakerId: 2, persistentSpeakerId: secondId, matchSimilarity: nil, transcript: "Second speaker."),
            ],
            duration: 20,
            processingTime: 1
        )

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(persistentSpeakerId: firstId, diarizerSpeakerId: "1", newName: "Sarah", previousName: "Matt", action: .corrected),
                SpeakerNameUpdate(persistentSpeakerId: secondId, diarizerSpeakerId: "2", newName: "Jamie", previousName: "Sarah", action: .corrected),
            ],
            transcriptionResult: result
        )

        XCTAssertTrue(didUpdate)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("- **Sarah:** 1 utterances, ~2 words, 00:03"), markdown)
        XCTAssertTrue(markdown.contains("- **Jamie:** 1 utterances, ~2 words, 00:03"), markdown)
        XCTAssertFalse(markdown.contains("- **Matt:**"), markdown)
        XCTAssertFalse(markdown.contains("- **Sarah:** 2 utterances"), markdown)
    }

    func testUpdateSpeakerNamesBreakdownFallbackFailsClosedWhenRowsCollide() throws {
        let firstId = UUID()
        let secondId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("colliding-breakdown-rows.md")
        let originalMarkdown = """
        ---
        transcript_id: "\(UUID().uuidString)"
        speakers:
          - id: "1"
            db_id: "\(firstId.uuidString)"
            name: "Alex"
            confidence: medium
            source: db_pending
          - id: "2"
            db_id: "\(secondId.uuidString)"
            name: "Alex"
            confidence: medium
            source: db_pending
        ---

        ## Full Transcript

        [00:12] [System/Alex] First speaker.

        [00:16] [System/Alex] Second speaker.

        ---

        *Generated by Transcripted with Parakeet + PyAnnote (local) | Duration: 0:20 | 4 words | 2 speakers*

        #### Remote Speaker Breakdown

        - **Alex:** 1 utterances, ~2 words, 00:03
        - **Alex:** 1 utterances, ~2 words, 00:03
        """
        try originalMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(start: 12, end: 15, channel: 1, speakerId: 1, persistentSpeakerId: firstId, matchSimilarity: nil, transcript: "First speaker."),
                TranscriptionUtterance(start: 16, end: 19, channel: 1, speakerId: 2, persistentSpeakerId: secondId, matchSimilarity: nil, transcript: "Second speaker."),
            ],
            duration: 20,
            processingTime: 1
        )

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(persistentSpeakerId: firstId, diarizerSpeakerId: "1", newName: "Bob", previousName: "Alex", action: .corrected)
            ],
            transcriptionResult: result
        )

        XCTAssertFalse(didUpdate)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertEqual(markdown, originalMarkdown)
    }

    func testUpdateSpeakerNamesBreakdownFallbackSkipsNoOpConfirmations() throws {
        let firstId = UUID()
        let secondId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("no-op-breakdown-confirmation.md")
        let originalMarkdown = sampleTranscript(
            transcriptId: UUID(),
            speakers: [
                MarkdownSpeaker(id: "1", persistentSpeakerId: firstId, name: "Matt", confidence: "medium", source: "db_pending"),
                MarkdownSpeaker(id: "2", persistentSpeakerId: secondId, name: "Sarah", confidence: "medium", source: "db_pending"),
            ],
            utterances: [
                MarkdownUtterance(timestamp: "00:01", source: "System", label: "Matt", text: "First speaker.", diarizerSpeakerId: 1),
                MarkdownUtterance(timestamp: "00:05", source: "System", label: "Sarah", text: "Second speaker.", diarizerSpeakerId: 2),
            ],
            breakdownEntries: [
                BreakdownEntry(name: "Matt", utterances: 1, wordCount: 2, duration: "00:03"),
                BreakdownEntry(name: "Sarah", utterances: 1, wordCount: 2, duration: "00:03"),
            ],
            totalWords: 4
        )
        try originalMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(start: 1, end: 4, channel: 1, speakerId: 1, persistentSpeakerId: firstId, matchSimilarity: nil, transcript: "First speaker."),
                TranscriptionUtterance(start: 5, end: 8, channel: 1, speakerId: 2, persistentSpeakerId: secondId, matchSimilarity: nil, transcript: "Second speaker."),
            ],
            duration: 8,
            processingTime: 1
        )

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(persistentSpeakerId: firstId, diarizerSpeakerId: "1", newName: "Sarah", previousName: "Matt", action: .corrected),
                SpeakerNameUpdate(persistentSpeakerId: secondId, diarizerSpeakerId: "2", newName: "Sarah", previousName: "Sarah", action: .confirmed),
            ],
            transcriptionResult: result
        )

        XCTAssertTrue(didUpdate)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertFalse(markdown.contains("Matt"), markdown)
        XCTAssertTrue(markdown.contains("[00:01] [System/Sarah] First speaker."), markdown)
        XCTAssertTrue(markdown.contains("[00:05] [System/Sarah] Second speaker."), markdown)
        XCTAssertTrue(markdown.contains("- **Sarah:** 2 utterances, ~4 words, 00:06"), markdown)
    }

    private func sampleTranscript(
        transcriptId: UUID,
        speakers: [MarkdownSpeaker],
        utterances: [MarkdownUtterance],
        breakdownEntries: [BreakdownEntry],
        title: String = "Meeting Recording - Apr 10, 2026 at 3:01 PM",
        duration: String = "1:30",
        totalWords: Int = 5
    ) -> String {
        let speakersYAML = speakers.map { speaker in
            """
              - id: "\(speaker.id)"
                db_id: "\(speaker.persistentSpeakerId.uuidString)"
                name: "\(speaker.name)"
                confidence: \(speaker.confidence)
                source: \(speaker.source)
            """
        }.joined(separator: "\n")
        let transcriptBody = utterances.map { utterance in
            "[\(utterance.timestamp)] [\(utterance.source)/\(utterance.label)] \(utterance.text)"
        }.joined(separator: "\n\n")
        let breakdownBody = breakdownEntries.map { entry in
            "- **\(entry.name):** \(entry.utterances) utterances, ~\(entry.wordCount) words, \(entry.duration)"
        }.joined(separator: "\n")

        return """
        ---
        transcript_id: "\(transcriptId.uuidString)"
        date: 2026-04-10
        time: 15:01:23
        duration: "\(duration)"
        processing_time: "3.0s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [mic, system_audio]
        mic_utterances: 0
        system_utterances: \(utterances.count)
        mic_speakers: 0
        system_speakers: \(speakers.count)
        total_word_count: \(totalWords)
        speakers:
        \(speakersYAML)
        ---

        # \(title)

        **Duration:** \(duration) | **Words:** \(totalWords) | **Utterances:** \(utterances.count)

        ---

        ## Channel & Speaker Analytics

        ### Microphone (You)
        - **Utterances:** 0
        - **Words:** ~0
        - **Speaking Time:** 00:00

        ### Meeting Audio (Remote Participants)
        - **Utterances:** \(utterances.count)
        - **Words:** ~\(totalWords)
        - **Speaking Time:** 00:12
        - **Speakers Detected:** \(speakers.count)

        #### Remote Speaker Breakdown

        \(breakdownBody)

        ---

        ## Full Transcript

        \(transcriptBody)

        ---

        *Generated by Transcripted with Parakeet + PyAnnote (local) | Duration: \(duration) | \(totalWords) words | \(speakers.count) speakers*
        """
    }

    private func sampleTranscriptionResult(
        speakers: [MarkdownSpeaker],
        utterances: [MarkdownUtterance],
        duration: TimeInterval = 90
    ) -> TranscriptionResult {
        let speakersById = Dictionary(uniqueKeysWithValues: speakers.compactMap { speaker in
            Int(speaker.id).map { ($0, speaker) }
        })
        let speakersByName = Dictionary(grouping: speakers) { normalizeSpeakerLabel($0.name) }

        let mappedUtterances = utterances.map { utterance -> TranscriptionUtterance in
            let channel = utterance.source.caseInsensitiveCompare("Mic") == .orderedSame ? 0 : 1
            let speakerId = utterance.diarizerSpeakerId
                ?? resolvedSpeakerId(
                    for: utterance,
                    channel: channel,
                    speakersByName: speakersByName
                )
            let persistentSpeakerId = speakersById[speakerId]?.persistentSpeakerId
            let start = timestampSeconds(for: utterance.timestamp)

            return TranscriptionUtterance(
                start: start,
                end: start + utterance.speakingSeconds,
                channel: channel,
                speakerId: speakerId,
                persistentSpeakerId: persistentSpeakerId,
                matchSimilarity: nil,
                transcript: utterance.text
            )
        }

        return TranscriptionResult(
            micUtterances: mappedUtterances.filter { $0.channel == 0 },
            systemUtterances: mappedUtterances.filter { $0.channel == 1 },
            duration: duration,
            processingTime: 3.0
        )
    }

    private func resolvedSpeakerId(
        for utterance: MarkdownUtterance,
        channel: Int,
        speakersByName: [String: [MarkdownSpeaker]]
    ) -> Int {
        if let parsedId = Int(utterance.label.replacingOccurrences(of: "Speaker ", with: "")) {
            return parsedId
        }

        let normalizedLabel = normalizeSpeakerLabel(utterance.label)
        if let match = speakersByName[normalizedLabel], match.count == 1, let id = Int(match[0].id) {
            return id
        }

        return channel == 0 ? 0 : 1
    }

    private func normalizeSpeakerLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func timestampSeconds(for timestamp: String) -> Double {
        let parts = timestamp.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return 0 }
        return (parts[0] * 60) + parts[1]
    }
}

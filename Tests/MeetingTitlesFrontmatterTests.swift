import Foundation

func testMeetingTitlesFrontmatter() {
    let label = MeetingTitlesLabel(
        title: "Vendor contract renewal",
        line: "The renewal goes ahead for one year.",
        summary: "Two bids were compared. The current vendor stays."
    )
    let stamp = Date(timeIntervalSince1970: 1_800_000_000)

    runSuite("Writing adds the ai keys and leaves the body byte for byte") {
        let raw = MeetingTitlesFixtures.meetingMarkdown()
        guard let updated = MeetingTitlesFrontmatterWriter.markdown(
            byApplying: label, replaceableTitle: "Meeting with Priya", to: raw, generatedAt: stamp
        ) else {
            assertTrue(false, "expected a rewrite")
            return
        }
        let values = TranscriptFrontmatter.values(in: updated) ?? [:]
        assertEqual(values["ai_title"], "Vendor contract renewal")
        assertEqual(values["ai_title_replaces"], "Meeting with Priya")
        assertEqual(values["ai_summary_line"], "The renewal goes ahead for one year.")
        assertEqual(values["ai_summary"], "Two bids were compared. The current vendor stays.")
        assertEqual(values["ai_summary_model"], "gemma-4-e2b-it-q4km")
        assertEqual(values["ai_summary_version"], "1")
        assertEqual(values["title"], "Meeting with Priya", "title: is never changed")
        assertEqual(TranscriptFrontmatter.body(in: updated), TranscriptFrontmatter.body(in: raw))
    }

    runSuite("Writing is idempotent: a file with current keys is left alone") {
        let raw = MeetingTitlesFixtures.meetingMarkdown()
        let once = MeetingTitlesFrontmatterWriter.markdown(byApplying: label, replaceableTitle: "Meeting with Priya", to: raw) ?? ""
        let other = MeetingTitlesLabel(title: "Something else", line: nil, summary: "Different.")
        assertNil(MeetingTitlesFrontmatterWriter.markdown(byApplying: other, replaceableTitle: "Meeting with Priya", to: once))
    }

    runSuite("An older version's keys are replaced, not duplicated") {
        let raw = MeetingTitlesFixtures.meetingMarkdown(extraFrontmatter: [
            "ai_title: \"Old title\"", "ai_title_replaces: \"Meeting with Priya\"", "ai_summary_version: \"0\"",
        ])
        let updated = MeetingTitlesFrontmatterWriter.markdown(byApplying: label, replaceableTitle: "Meeting with Priya", to: raw) ?? ""
        assertEqual(updated.components(separatedBy: "\nai_title: ").count, 2, "one ai_title line")
        assertEqual(TranscriptFrontmatter.values(in: updated)?["ai_title"], "Vendor contract renewal")
    }

    runSuite("A renamed meeting never gets ai_title, but still gets its line and summary") {
        let renamed = MeetingTitlesFixtures.meetingMarkdown(title: "Board prep", extraFrontmatter: ["title_set_by_user: true"])
        let updated = MeetingTitlesFrontmatterWriter.markdown(byApplying: label, replaceableTitle: "Board prep", to: renamed) ?? ""
        let values = TranscriptFrontmatter.values(in: updated) ?? [:]
        assertNil(values["ai_title"])
        assertEqual(values["ai_summary_line"], "The renewal goes ahead for one year.")

        let changedSinceSave = MeetingTitlesFixtures.meetingMarkdown(title: "Board prep")
        let second = MeetingTitlesFrontmatterWriter.markdown(byApplying: label, replaceableTitle: "Meeting with Priya", to: changedSinceSave) ?? ""
        assertNil(TranscriptFrontmatter.values(in: second)?["ai_title"], "a title that changed since the save is the person's")
    }

    runSuite("Non-meetings and empty labels write nothing") {
        let dictation = "---\ncapture_type: dictation_day\n---\nhello\n"
        assertNil(MeetingTitlesFrontmatterWriter.markdown(byApplying: label, replaceableTitle: nil, to: dictation))
        let empty = MeetingTitlesLabel(title: nil, line: nil, summary: nil)
        assertNil(MeetingTitlesFrontmatterWriter.markdown(byApplying: empty, replaceableTitle: nil, to: MeetingTitlesFixtures.meetingMarkdown()))
    }

    runSuite("The file write runs under the serializer and keeps the body") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = MeetingTitlesFixtures.meetingMarkdown()
        let url = MeetingTitlesFixtures.writeMeeting(raw, named: "2026-03-04 Meeting with Priya.md", in: directory)
        assertEqual(MeetingTitlesFrontmatterWriter.apply(label, replaceableTitle: "Meeting with Priya", at: url), .written)
        assertEqual(MeetingTitlesFrontmatterWriter.apply(label, replaceableTitle: "Meeting with Priya", at: url), .skipped)
        let saved = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        assertEqual(TranscriptFrontmatter.body(in: saved), TranscriptFrontmatter.body(in: raw))
        assertTrue(FileManager.default.fileExists(atPath: url.path), "the file is not renamed")
    }

    runSuite("A cancel that lands inside the serialized write writes nothing") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = MeetingTitlesFixtures.meetingMarkdown()
        let url = MeetingTitlesFixtures.writeMeeting(raw, named: "a.md", in: directory)
        assertEqual(MeetingTitlesFrontmatterWriter.apply(label, replaceableTitle: "Meeting with Priya", at: url, shouldWrite: { false }), .skipped)
        assertEqual(MeetingTitlesFrontmatterWriter.markTitleSetByUser(at: url, shouldWrite: { false }), .skipped)
        assertEqual(MeetingTitlesFrontmatterWriter.recordNoSummary(.tooShort, at: url, shouldWrite: { false }), .skipped)
        assertEqual(try? String(contentsOf: url, encoding: .utf8), raw)
    }

    runSuite("Nothing to write is recorded once per version without content") {
        let raw = MeetingTitlesFixtures.meetingMarkdown()
        let updated = MeetingTitlesFrontmatterWriter.markdown(recordingNoSummary: .noUsableReply, to: raw, generatedAt: stamp) ?? ""
        let values = TranscriptFrontmatter.values(in: updated) ?? [:]
        assertEqual(values["ai_summary_status"], "no_usable_reply")
        assertEqual(values["ai_summary_version"], "1")
        assertNil(values["ai_title"])
        assertEqual(TranscriptFrontmatter.body(in: updated), TranscriptFrontmatter.body(in: raw))
        assertNil(MeetingTitlesFrontmatterWriter.markdown(recordingNoSummary: .tooShort, to: updated), "already current")
        let newer = updated.replacingOccurrences(of: "ai_summary_version: \"1\"", with: "ai_summary_version: \"0\"")
        let relabeled = MeetingTitlesFrontmatterWriter.markdown(byApplying: label, replaceableTitle: "Meeting with Priya", to: newer) ?? ""
        assertNil(TranscriptFrontmatter.values(in: relabeled)?["ai_summary_status"], "a later summary replaces the status")
    }

    runSuite("Display title: rename wins, then ai_title, then the app's title") {
        let fields = MeetingTitlesFields(aiTitle: "Vendor contract renewal", aiTitleReplaces: "Meeting with Priya")
        assertEqual(fields.displayTitle(savedTitle: "Meeting with Priya"), "Vendor contract renewal")
        assertEqual(fields.displayTitle(savedTitle: "Board prep"), "Board prep", "renamed after the model ran")
        var marked = fields
        marked.titleSetByUser = true
        assertEqual(marked.displayTitle(savedTitle: "Meeting with Priya"), "Meeting with Priya")
        assertEqual(MeetingTitlesFields.empty.displayTitle(savedTitle: "Meeting at 10:05 AM"), "Meeting at 10:05 AM")
    }

    runSuite("Fields read back from frontmatter values") {
        let raw = MeetingTitlesFrontmatterWriter.markdown(
            byApplying: label, replaceableTitle: "Meeting with Priya", to: MeetingTitlesFixtures.meetingMarkdown()
        ) ?? ""
        let fields = MeetingTitlesFields(frontmatterValues: TranscriptFrontmatter.values(in: raw) ?? [:])
        assertEqual(fields.line, "The renewal goes ahead for one year.")
        assertEqual(fields.summary, "Two bids were compared. The current vendor stays.")
        assertEqual(fields.displayTitle(savedTitle: "Meeting with Priya"), "Vendor contract renewal")
    }

    runSuite("Rename's mark goes in once, right after title:") {
        let raw = "---\ntitle: \"Board prep\"\ncapture_type: meeting\n---\nbody\n"
        let marked = MeetingTitlesKeys.markingTitleSetByUser(raw)
        assertEqual(marked, "---\ntitle: \"Board prep\"\ntitle_set_by_user: true\ncapture_type: meeting\n---\nbody\n")
        assertEqual(MeetingTitlesKeys.markingTitleSetByUser(marked), marked)
        assertEqual(MeetingTitlesKeys.markingTitleSetByUser("no frontmatter"), "no frontmatter")
    }

    runSuite("Renaming a saved meeting marks its title as the person's") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = MeetingTitlesFixtures.writeMeeting(
            MeetingTitlesFixtures.meetingMarkdown(),
            named: "2026-03-04 Meeting with Priya.md",
            in: directory
        )
        do {
            let result = try HomeMeetingRename.rename(transcriptAt: url, to: "Board prep", recoveryStoreDirectory: directory)
            let values = TranscriptFrontmatter.values(in: (try? String(contentsOf: result.transcriptURL, encoding: .utf8)) ?? "") ?? [:]
            assertEqual(values["title"], "Board prep")
            assertEqual(values["title_set_by_user"], "true")
        } catch {
            assertTrue(false, "rename failed: \(error)")
        }
    }

    runSuite("The app's own rule title is worked out from the transcript, ignoring title:") {
        let raw = MeetingTitlesFixtures.meetingMarkdown(title: "Board prep", turns: [
            ("00:01", "Mic/You", "Hello there, thanks for coming."),
            ("00:09", "System/Priya", "Glad to be here today."),
            ("00:20", "Mic/You", "Let's start."),
        ])
        let url = URL(fileURLWithPath: "/tmp/unused.md")
        assertEqual(MeetingTranscriptStyler.ruleTitle(forMeetingMarkdown: raw, fallbackURL: url), "Meeting with Priya")
    }
}

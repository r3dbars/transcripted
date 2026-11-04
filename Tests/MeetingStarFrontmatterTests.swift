// Starring a saved meeting writes one `starred: true` line into its Markdown
// frontmatter (MeetingStarFrontmatter). The star is agent-readable, survives
// library moves, and is what automatic meeting-audio deletion checks.

import Foundation

func testMeetingStarFrontmatter() {
    runSuite("Starring a meeting adds one frontmatter line and leaves the rest of the file alone") {
        withStarFixtureDirectory { directory in
            let url = directory.appendingPathComponent("Quarterly Planning.md")
            let original = starFixtureMarkdown(title: "Quarterly Planning")
            try? original.write(to: url, atomically: true, encoding: .utf8)
            let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            try? FileManager.default.setAttributes([.creationDate: createdAt], ofItemAtPath: url.path)

            do {
                try MeetingStarFrontmatter.setStarred(true, transcriptAt: url)
            } catch {
                assertTrue(false, "starring an app-owned meeting should succeed: \(error)")
            }

            let values = try? TranscriptFrontmatter.readValues(from: url)
            assertEqual(values?["starred"], "true", "the frontmatter should carry starred: true")
            assertTrue(MeetingStarFrontmatter.isStarred(values: values ?? [:]), "the starred file should read back as starred")

            let starred = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            assertEqual(
                TranscriptFrontmatter.body(in: starred),
                TranscriptFrontmatter.body(in: original),
                "the transcript body should be byte-identical"
            )
            let originalLines = TranscriptFrontmatter.lines(in: original) ?? []
            let starredLines = TranscriptFrontmatter.lines(in: starred) ?? []
            assertEqual(
                starredLines.filter { $0 != "starred: true" },
                originalLines,
                "every other frontmatter line should stay as it was, in order"
            )
            assertEqual(starredLines.filter { $0 == "starred: true" }.count, 1, "exactly one star line")
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            assertEqual(attributes?[.creationDate] as? Date, createdAt, "starring should not make the meeting look newly created")
        }
    }

    runSuite("Starring an already starred meeting changes nothing on disk") {
        withStarFixtureDirectory { directory in
            let url = directory.appendingPathComponent("Design Review.md")
            try? starFixtureMarkdown(title: "Design Review").write(to: url, atomically: true, encoding: .utf8)
            try? MeetingStarFrontmatter.setStarred(true, transcriptAt: url)
            let once = try? Data(contentsOf: url)
            try? MeetingStarFrontmatter.setStarred(true, transcriptAt: url)
            assertEqual(try? Data(contentsOf: url), once, "a second star should leave the bytes unchanged")
        }
    }

    runSuite("Removing a star gives back the original file exactly") {
        withStarFixtureDirectory { directory in
            let url = directory.appendingPathComponent("Design Review.md")
            let original = starFixtureMarkdown(title: "Design Review")
            try? original.write(to: url, atomically: true, encoding: .utf8)
            try? MeetingStarFrontmatter.setStarred(true, transcriptAt: url)
            do {
                try MeetingStarFrontmatter.setStarred(false, transcriptAt: url)
            } catch {
                assertTrue(false, "unstarring should succeed: \(error)")
            }
            assertEqual(try? String(contentsOf: url, encoding: .utf8), original, "unstar should restore the original bytes")
            let values = try? TranscriptFrontmatter.readValues(from: url)
            assertNil(values?["starred"], "no starred key should remain")
        }
    }

    runSuite("Only an unindented starred: true counts as starred") {
        assertTrue(MeetingStarFrontmatter.isStarred(values: ["starred": "true"]), "bare true")
        assertTrue(MeetingStarFrontmatter.isStarred(values: ["starred": "TRUE"]), "any case")
        let quoted = TranscriptFrontmatter.values(in: "---\nstarred: \"true\"\n---\nbody") ?? [:]
        assertTrue(MeetingStarFrontmatter.isStarred(values: quoted), "a quoted \"true\" reads as starred")
        assertFalse(MeetingStarFrontmatter.isStarred(values: ["starred": "false"]), "false is not starred")
        assertFalse(MeetingStarFrontmatter.isStarred(values: [:]), "a missing key is not starred")
        let indented = TranscriptFrontmatter.values(in: "---\nspeakers:\n  starred: true\n---\nbody") ?? [:]
        assertFalse(MeetingStarFrontmatter.isStarred(values: indented), "a nested starred key is not the meeting's star")
    }

    runSuite("Starring replaces a starred: false line instead of adding a second key") {
        let raw = "---\ncapture_type: meeting\nstarred: false\ntitle: \"Design Review\"\n---\n\n# Design Review\n"
        let rewritten = MeetingStarFrontmatter.rewrite(raw, starred: true)
        assertEqual(
            rewritten,
            "---\ncapture_type: meeting\nstarred: true\ntitle: \"Design Review\"\n---\n\n# Design Review\n",
            "the existing line is replaced in place"
        )
        assertEqual(
            MeetingStarFrontmatter.rewrite(raw, starred: false),
            "---\ncapture_type: meeting\ntitle: \"Design Review\"\n---\n\n# Design Review\n",
            "unstarring drops the line"
        )
    }

    runSuite("Text without frontmatter is never rewritten") {
        assertNil(MeetingStarFrontmatter.rewrite("# Quarterly Planning\n\nNo frontmatter here.\n", starred: true), "no frontmatter, no rewrite")
        assertNil(MeetingStarFrontmatter.rewrite("---\ncapture_type: meeting\n", starred: true), "an unclosed fence is not frontmatter")
    }

    runSuite("Files that aren't app-owned meetings refuse a star and stay unchanged") {
        withStarFixtureDirectory { directory in
            let notesURL = directory.appendingPathComponent("Notes.md")
            let notes = "---\ntitle: \"Notes\"\n---\n\n# Notes\n"
            try? notes.write(to: notesURL, atomically: true, encoding: .utf8)
            assertStarRefused(at: notesURL, expected: notes, "a file without capture_type meeting")

            let noIDURL = directory.appendingPathComponent("No ID.md")
            let noID = "---\ncapture_type: meeting\ntranscript_id: \"not-a-uuid\"\n---\n\n## Full Transcript\n"
            try? noID.write(to: noIDURL, atomically: true, encoding: .utf8)
            assertStarRefused(at: noIDURL, expected: noID, "a meeting without a UUID identifier")
        }
    }
}

private func assertStarRefused(at url: URL, expected: String, _ label: String) {
    do {
        try MeetingStarFrontmatter.setStarred(true, transcriptAt: url)
        assertTrue(false, "\(label) should be refused")
    } catch {
        assertEqual(error as? MeetingStarError, .notOwnedMeeting, "\(label) is refused as not owned")
    }
    assertEqual(try? String(contentsOf: url, encoding: .utf8), expected, "\(label) is left unchanged")
}

private func withStarFixtureDirectory(_ body: (URL) -> Void) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingStarFrontmatterTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    body(directory)
}

private func starFixtureMarkdown(title: String) -> String {
    """
    ---
    capture_id: "\(UUID().uuidString)"
    capture_type: meeting
    transcript_id: "\(UUID().uuidString)"
    title: "\(title)"
    date: "2026-06-05"
    time: "09:00"
    duration: "30:00"
    ---

    # \(title)

    ## Full Transcript

    **[00:00] [Mic/You]**
    Let's start with the roadmap.
    """
}

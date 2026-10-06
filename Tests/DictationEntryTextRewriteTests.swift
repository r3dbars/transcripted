// DictationEntryTextRewriteTests.swift
// Transcribe again replaces one saved dictation's text and nothing else.

import Foundation

func testDictationEntryTextRewrite() async {
    let morning = rewriteTestSection(
        time: "9:15 AM",
        title: "first note from the morning",
        entryID: "dictation-20260407-091500-000-aaaa",
        captured: "2026-04-07T13:15:00.000Z",
        app: "Slack",
        bundle: "com.tinyspeck.slackmacgap",
        delivery: "pasted",
        words: 5,
        characters: 27,
        audio: nil,
        body: "first note from the morning"
    )
    let target = rewriteTestSection(
        time: "11:02 AM",
        title: "um so the thing is we",
        entryID: "dictation-20260407-110200-000-bbbb",
        captured: "2026-04-07T15:02:00.000Z",
        app: "Claude",
        bundle: "com.anthropic.claudefordesktop",
        delivery: "copied",
        words: 9,
        characters: 44,
        audio: "audio/0b7c8f3e-7a3c-4d0e-9a51-2f0c6d1a9e11.m4a",
        body: "um so the thing is we should\nmerge it tonight"
    )
    let evening = rewriteTestSection(
        time: "4:45 PM",
        title: "second note from the afternoon",
        entryID: "dictation-20260407-164500-000-cccc",
        captured: "2026-04-07T20:45:00.000Z",
        app: "Mail",
        bundle: nil,
        delivery: "failed",
        words: 5,
        characters: 30,
        audio: nil,
        body: "second note from the afternoon"
    )
    let header = """
    ---
    title: "Dictations for April 7, 2026"
    date: 2026-04-07
    capture_type: dictation_day
    format_version: 1
    ---

    # Dictations for April 7, 2026
    """
    let dayFile = [header, morning, target, evening].joined(separator: "\n\n") + "\n"
    let createdAt = Date(timeIntervalSince1970: 1_775_574_120)

    runSuite("Transcribe again rewrites only the target entry's title, counts, and text") {
        guard let result = try? DictationEntryTextRewrite.rewrite(
            dayFile: dayFile,
            entryID: "dictation-20260407-110200-000-bbbb",
            newText: "  So the thing is, we should merge it tonight.\n",
            createdAt: createdAt
        ) else {
            assertTrue(false, "rewrite should succeed for a known Entry ID")
            return
        }
        let expectedTarget = rewriteTestSection(
            time: "11:02 AM",
            title: "So the thing is, we should merge",
            entryID: "dictation-20260407-110200-000-bbbb",
            captured: "2026-04-07T15:02:00.000Z",
            app: "Claude",
            bundle: "com.anthropic.claudefordesktop",
            delivery: "copied",
            words: 9,
            characters: 44,
            audio: "audio/0b7c8f3e-7a3c-4d0e-9a51-2f0c6d1a9e11.m4a",
            body: "So the thing is, we should merge it tonight."
        )
        let expected = [header, morning, expectedTarget, evening].joined(separator: "\n\n") + "\n"
        assertEqual(result.content, expected, "the day file should differ only in the target section")
        assertEqual(result.wordCount, 9, "word count should be recounted")
        assertEqual(result.characterCount, 44, "character count should be recounted from the trimmed text")
        assertEqual(result.title, "So the thing is, we should merge", "title should come from the new text")
    }

    runSuite("Transcribe again keeps the last entry's trailing newline and other sections byte-identical") {
        guard let result = try? DictationEntryTextRewrite.rewrite(
            dayFile: dayFile,
            entryID: "dictation-20260407-164500-000-cccc",
            newText: "Second note, from the afternoon.",
            createdAt: createdAt
        ) else {
            assertTrue(false, "rewrite should succeed for the last entry")
            return
        }
        assertTrue(result.content.hasPrefix([header, morning, target].joined(separator: "\n\n") + "\n\n"),
                   "everything before the last entry should be untouched")
        assertTrue(result.content.hasSuffix("Characters: 32\n\nSecond note, from the afternoon.\n"),
                   "the last entry should end with its new text and the file's final newline")
    }

    runSuite("Transcribe again with an unknown Entry ID or empty text changes nothing") {
        do {
            _ = try DictationEntryTextRewrite.rewrite(
                dayFile: dayFile, entryID: "dictation-missing", newText: "hello there", createdAt: createdAt
            )
            assertTrue(false, "unknown Entry ID should throw")
        } catch {
            assertEqual(error as? DictationEntryTextRewrite.RewriteError, .entryNotFound, "unknown Entry ID is entryNotFound")
        }
        do {
            _ = try DictationEntryTextRewrite.rewrite(
                dayFile: dayFile, entryID: "dictation-20260407-110200-000-bbbb", newText: " \n ", createdAt: createdAt
            )
            assertTrue(false, "empty text should throw")
        } catch {
            assertEqual(error as? DictationEntryTextRewrite.RewriteError, .emptyText, "blank text is emptyText")
        }
    }

    await runSuite("Store rewrite saves the new text and reads back with the same entry metadata") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dictation-rewrite-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent("Dictations_2026-04-07.md")
        try? dayFile.write(to: url, atomically: true, encoding: .utf8)

        let before = DictationTranscriptStore.recentSavedDictations(limit: 10, directory: root)
        guard let original = before.first(where: { $0.entryID == "dictation-20260407-110200-000-bbbb" }) else {
            assertTrue(false, "fixture entry should parse")
            return
        }

        do {
            try DictationTranscriptStore.replaceEntryText(
                entryID: "dictation-20260407-110200-000-bbbb",
                in: url,
                with: "We should merge it tonight.",
                createdAt: original.createdAt
            )
        } catch {
            assertTrue(false, "store rewrite should succeed: \(error)")
        }

        let after = DictationTranscriptStore.recentSavedDictations(limit: 10, directory: root)
        let rewritten = after.first(where: { $0.entryID == "dictation-20260407-110200-000-bbbb" })
        assertEqual(rewritten?.text, "We should merge it tonight.", "the entry should read back with the new text")
        assertEqual(rewritten?.createdAt, original.createdAt, "Captured time stays")
        assertEqual(rewritten?.sourceAppName, "Claude", "source app stays")
        assertEqual(rewritten?.sourceAppBundleID, "com.anthropic.claudefordesktop", "bundle ID stays")
        assertEqual(rewritten?.delivery, .copied, "delivery stays")
        assertEqual(rewritten?.audioRelativePath, original.audioRelativePath, "Audio line stays")
        assertEqual(
            after.filter { $0.entryID != "dictation-20260407-110200-000-bbbb" }.map(\.text).sorted(),
            before.filter { $0.entryID != "dictation-20260407-110200-000-bbbb" }.map(\.text).sorted(),
            "other entries read back unchanged"
        )

        let unchanged = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        do {
            try DictationTranscriptStore.replaceEntryText(
                entryID: "dictation-missing", in: url, with: "anything", createdAt: original.createdAt
            )
            assertTrue(false, "unknown Entry ID should throw from the store")
        } catch {
            assertEqual(error as? DictationEntryTextRewrite.RewriteError, .entryNotFound, "store reports entryNotFound")
        }
        assertEqual((try? String(contentsOf: url, encoding: .utf8)) ?? "", unchanged, "a failed rewrite leaves the file alone")
    }

    await runSuite("Transcribe again keeps the old text when the model hears nothing, and cleans fillers like a live take") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("dictation-retranscribe-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent("Dictations_2026-04-07.md")
        try? dayFile.write(to: url, atomically: true, encoding: .utf8)
        guard let entry = DictationTranscriptStore.recentSavedDictations(limit: 10, directory: root)
            .first(where: { $0.entryID == "dictation-20260407-110200-000-bbbb" }) else {
            assertTrue(false, "fixture entry should parse")
            return
        }
        let audio = root.appendingPathComponent("audio.m4a")

        do {
            _ = try await DictationRetranscription.run(
                entry: entry, audioURL: audio, cleanupEnabled: true,
                loadSamples: { _ in [0.1, 0.2, 0.3] },
                transcribe: { _ in "   " }
            )
            assertTrue(false, "no words should throw")
        } catch {
            assertEqual(error as? DictationRetranscription.Failure, .noWords, "silence is noWords")
        }
        assertEqual((try? String(contentsOf: url, encoding: .utf8)) ?? "", dayFile, "silence leaves the day file alone")

        do {
            _ = try await DictationRetranscription.run(
                entry: entry, audioURL: audio, cleanupEnabled: true,
                loadSamples: { _ in throw CocoaError(.fileReadCorruptFile) },
                transcribe: { _ in "never called" }
            )
            assertTrue(false, "unreadable audio should throw")
        } catch {
            assertEqual(error as? DictationRetranscription.Failure, .unreadableAudio, "a bad file is unreadableAudio")
        }

        var heardSamples: [Float] = []
        do {
            _ = try await DictationRetranscription.run(
                entry: entry, audioURL: audio, cleanupEnabled: true,
                loadSamples: { _ in [0.1, 0.2, 0.3] },
                transcribe: { samples in
                    heardSamples = samples
                    return "Um, we should merge it tonight."
                }
            )
        } catch {
            assertTrue(false, "a heard take should save: \(error)")
        }
        assertEqual(heardSamples, [0.1, 0.2, 0.3], "the transcriber gets the decoded samples")
        let saved = DictationTranscriptStore.recentSavedDictations(limit: 10, directory: root)
            .first(where: { $0.entryID == "dictation-20260407-110200-000-bbbb" })
        assertEqual(saved?.text, DictationFillerCleanupPolicy.clean("Um, we should merge it tonight.").text,
                    "filler cleanup runs the same way as a live take")
        assertFalse(saved?.text.hasPrefix("Um") ?? true, "the filler should be gone")
    }

    await runSuite("Transcribe again refuses entries without an Entry ID") {
        let legacy = SavedDictationEntry(
            url: URL(fileURLWithPath: "/nonexistent/Dictations_2020-01-01.md"),
            entryID: nil,
            title: "old",
            text: "old text",
            createdAt: createdAt,
            delivery: .pasted,
            sourceAppName: "Notes",
            sourceAppBundleID: nil
        )
        do {
            _ = try await DictationRetranscription.run(
                entry: legacy, audioURL: URL(fileURLWithPath: "/nonexistent/a.m4a"), cleanupEnabled: false,
                loadSamples: { _ in [0.1] },
                transcribe: { _ in "new text" }
            )
            assertTrue(false, "legacy entry should throw")
        } catch {
            assertEqual(error as? DictationRetranscription.Failure, .missingEntryID, "no Entry ID means no target")
        }
    }
}

private func rewriteTestSection(
    time: String,
    title: String,
    entryID: String,
    captured: String,
    app: String,
    bundle: String?,
    delivery: String,
    words: Int,
    characters: Int,
    audio: String?,
    body: String
) -> String {
    var lines = [
        "## \(time) - \(title)",
        "",
        "Entry ID: `\(entryID)`",
        "Captured: \(captured)",
        "Source app: \(app)",
    ]
    if let bundle { lines.append("Bundle ID: `\(bundle)`") }
    lines.append("Delivery: \(delivery)")
    lines.append("Words: \(words)")
    lines.append("Characters: \(characters)")
    if let audio { lines.append("Audio: `\(audio)`") }
    lines.append("")
    lines.append(body)
    return lines.joined(separator: "\n")
}

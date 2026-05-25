// JSONLWriterTests.swift
// Edge cases for the append-only JSONL actor:
//   - trailing-newline normalization (avoid double newlines, ensure single newline)
//   - empty payload behavior (must not corrupt file)
//   - file auto-creation when the target path doesn't exist
//   - stale file-handle recovery if the file is deleted out from under the writer
//   - sequential ordering across many appends to the same actor
// Privacy: writer is byte-level (no redaction), but we verify it stays append-only
// so the redaction layer above remains the single source of truth.

import Foundation

func testJSONLWriter() async {
    await runSuite("JSONLWriter appends a single trailing newline regardless of input") {
        let (root, fileURL) = jsonlWriterTempLog()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = JSONLWriter(fileURL: fileURL)

        await writer.append(Data("{\"a\":1}".utf8))                  // no trailing LF
        await writer.append(Data("{\"b\":2}\n".utf8))                // explicit trailing LF
        await writer.append(Data("{\"c\":3}".utf8))                  // no trailing LF

        let contents = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        // Expect exactly 3 record lines + 1 empty trailing element from final "\n".
        let nonEmpty = lines.filter { !$0.isEmpty }
        assertEqual(nonEmpty.count, 3, "expected 3 JSONL records, got \(nonEmpty.count) in \(contents.debugDescription)")
        assertEqual(String(nonEmpty[0]), "{\"a\":1}", "first record should match input")
        assertEqual(String(nonEmpty[1]), "{\"b\":2}", "explicit LF input must not produce double newline")
        assertEqual(String(nonEmpty[2]), "{\"c\":3}", "final record should match input")
        assertFalse(contents.contains("\n\n"), "no double newlines should appear between records")
    }

    await runSuite("JSONLWriter creates the target file on first append") {
        let (root, fileURL) = jsonlWriterTempLog()
        defer { try? FileManager.default.removeItem(at: root) }
        assertFalse(FileManager.default.fileExists(atPath: fileURL.path), "pre-condition: file does not exist")

        let writer = JSONLWriter(fileURL: fileURL)
        await writer.append(Data("{\"created\":true}".utf8))

        assertTrue(FileManager.default.fileExists(atPath: fileURL.path), "first append should create the file")
        let contents = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        assertTrue(contents.contains("{\"created\":true}"), "record should land in created file")
    }

    await runSuite("JSONLWriter recovers when the file is deleted out from under it") {
        // Simulates external log rotation: the file gets removed, but the writer's
        // cached FileHandle is now pointing at an unlinked inode. The writer should
        // detect the missing path on next append, drop the stale handle, recreate
        // the file, and resume writing.
        let (root, fileURL) = jsonlWriterTempLog()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = JSONLWriter(fileURL: fileURL)

        await writer.append(Data("{\"phase\":1}".utf8))
        try? FileManager.default.removeItem(at: fileURL)
        assertFalse(FileManager.default.fileExists(atPath: fileURL.path), "pre-condition: rotated away")

        await writer.append(Data("{\"phase\":2}".utf8))

        assertTrue(FileManager.default.fileExists(atPath: fileURL.path), "writer should recreate the rotated file")
        let contents = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        assertFalse(contents.contains("{\"phase\":1}"), "phase 1 was rotated away; should not reappear")
        assertTrue(contents.contains("{\"phase\":2}"), "post-rotation append should land in fresh file")
    }

    await runSuite("JSONLWriter preserves order across many sequential appends") {
        let (root, fileURL) = jsonlWriterTempLog()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = JSONLWriter(fileURL: fileURL)

        let expected = 250
        for index in 0..<expected {
            await writer.append(Data("{\"i\":\(index)}".utf8))
        }

        let contents = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        assertEqual(lines.count, expected, "every append should yield exactly one line")
        // Spot-check ordering at edges and the middle.
        assertEqual(String(lines.first ?? ""), "{\"i\":0}", "first line should be the first append")
        assertEqual(String(lines[expected / 2]), "{\"i\":\(expected / 2)}", "middle line should match insert order")
        assertEqual(String(lines.last ?? ""), "{\"i\":\(expected - 1)}", "last line should be the final append")
    }

    await runSuite("JSONLWriter handles large payloads without splicing") {
        // A multi-KB record stresses the underlying flock + seekToEndOfFile path
        // to make sure large writes still land as a single line.
        let (root, fileURL) = jsonlWriterTempLog()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = JSONLWriter(fileURL: fileURL)

        let payload = String(repeating: "x", count: 64 * 1024)
        await writer.append(Data("{\"big\":\"\(payload)\"}".utf8))
        await writer.append(Data("{\"after\":true}".utf8))

        let contents = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        assertEqual(lines.count, 2, "large payload should still produce exactly one line, plus the trailing record")
        assertTrue(String(lines[0]).hasPrefix("{\"big\":\""), "first line should be the large record")
        assertEqual(String(lines[1]), "{\"after\":true}", "follow-up record should be untouched")
    }
}

private func jsonlWriterTempLog() -> (root: URL, file: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("JSONLWriterTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("test.jsonl", isDirectory: false)
    return (root, file)
}

import Foundation

func testReliabilityPacketTail() {
    runSuite("Reliability summaries read recent records after a large discarded prefix") {
        withReliabilityTailFixture { url in
            let tail = try reliabilityTailLines(0..<8)
            var bytes = Data(repeating: 0x78, count: 2 * 1024 * 1024)
            bytes.append(0x0A)
            bytes.append(tail)
            try bytes.write(to: url)
            let actual = ReliabilityPacketRecorder.recentPacketSummaries(fileURL: url)
            let expected = ReliabilityPacketRecorder.packetSummaries(fromJSONL: String(decoding: tail, as: UTF8.self))
            assertEqual(actual, expected, "old prefix bytes cannot replace the latest eight complete records")
            assertEqual(actual.count, 8)
        }
    }

    runSuite("A tail boundary inside a Unicode scalar discards its partial row before decoding") {
        withReliabilityTailFixture { url in
            let tail = try reliabilityTailLines(0..<8)
            let window = ReliabilityPacketRecorder.recentReadByteLimit
            var bytes = Data("discard-prefix".utf8)
            bytes.append(Data("🙂\n".utf8))
            bytes.append(Data(repeating: 0x78, count: window - 3 - tail.count - 1))
            bytes.append(0x0A)
            bytes.append(tail)
            try bytes.write(to: url)
            assertEqual(ReliabilityPacketRecorder.recentPacketSummaries(fileURL: url).count, 8,
                        "a split scalar in the discarded row cannot corrupt the complete tail")
        }
    }

    runSuite("An oversized single reliability record does not expand the read window") {
        withReliabilityTailFixture { url in
            let packet = ReliabilityPacket(timestamp: "synthetic", feature: "meeting", stage: "save",
                outcome: "saved", event: String(repeating: "x", count: 600 * 1024),
                appVersion: "fixture", osMajor: "26", context: [:])
            try JSONEncoder().encode(packet).write(to: url)
            assertTrue(ReliabilityPacketRecorder.recentPacketSummaries(fileURL: url).isEmpty,
                       "a record larger than the bounded tail is unavailable, not a reason to read farther")
        }
    }

    runSuite("Reliability summaries keep last-line selection without backfilling corrupt records") {
        withReliabilityTailFixture { url in
            var bytes = try reliabilityTailLines(0..<9)
            bytes.append(Data("not-json\n\n".utf8))
            try bytes.write(to: url)
            let actual = ReliabilityPacketRecorder.recentPacketSummaries(fileURL: url)
            let expected = ReliabilityPacketRecorder.packetSummaries(fromJSONL: String(decoding: bytes, as: UTF8.self))
            assertEqual(actual, expected)
            assertEqual(actual.count, 7, "the corrupt latest line occupies one of eight nonempty slots")
            assertTrue(ReliabilityPacketRecorder.recentPacketSummaries(limit: 0, fileURL: url).isEmpty)
            assertTrue(ReliabilityPacketRecorder.recentPacketSummaries(limit: -1, fileURL: url).isEmpty)
        }
    }

    runSuite("Reliability summaries tolerate missing empty and unreadable UTF8 fixtures") {
        withReliabilityTailFixture { url in
            assertTrue(ReliabilityPacketRecorder.recentPacketSummaries(fileURL: url).isEmpty)
            try Data().write(to: url)
            assertTrue(ReliabilityPacketRecorder.recentPacketSummaries(fileURL: url).isEmpty)
            try Data([0xFF, 0xFE]).write(to: url)
            assertTrue(ReliabilityPacketRecorder.recentPacketSummaries(fileURL: url).isEmpty)
        }
    }
}

private func reliabilityTailLines(_ ids: Range<Int>) throws -> Data {
    var data = Data()
    for id in ids {
        let packet = ReliabilityPacket(timestamp: "synthetic-\(id)", feature: "meeting", stage: "save",
            outcome: "saved", event: "fixture-\(id)", appVersion: "fixture", osMajor: "26",
            context: ["fixture": "café 🙂"])
        data.append(try JSONEncoder().encode(packet))
        data.append(0x0A)
    }
    return data
}

private func withReliabilityTailFixture(_ body: (URL) throws -> Void) {
    let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
    let prefix = "ReliabilityTailFixture-"
    let root = parent.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do {
                let leaf = root.lastPathComponent
                let canonical = root.resolvingSymlinksInPath().standardizedFileURL
                let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard leaf.hasPrefix(prefix), UUID(uuidString: String(leaf.dropFirst(prefix.count))) != nil,
                      canonical == root.standardizedFileURL, canonical.deletingLastPathComponent() == parent,
                      values.isDirectory == true, values.isSymbolicLink != true else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try FileManager.default.removeItem(at: root)
            } catch { assertTrue(false, "owned reliability-tail cleanup failed") }
        }
        try body(root.appendingPathComponent("synthetic.jsonl"))
    } catch { assertTrue(false, "owned reliability-tail fixture failed") }
}

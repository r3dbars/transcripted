import Foundation

func testObservabilityLogWriter() {
    runSuite("EventFileWritePolicy buffers only info events") {
        assertTrue(
            EventFileWritePolicy.shouldBuffer(level: "info"),
            "info events should batch to reduce low-priority JSONL write churn"
        )
        assertFalse(
            EventFileWritePolicy.shouldBuffer(level: "warning"),
            "warning events should flush immediately"
        )
        assertFalse(
            EventFileWritePolicy.shouldBuffer(level: "error"),
            "error events should flush immediately"
        )
    }

    runSuite("EventFileWritePolicy flushes info batches at a bounded size") {
        assertFalse(
            EventFileWritePolicy.shouldFlushBufferedInfoEvents(
                count: EventFileWritePolicy.maxBufferedInfoEvents - 1
            ),
            "info events below the batch limit can wait for the short flush timer"
        )
        assertTrue(
            EventFileWritePolicy.shouldFlushBufferedInfoEvents(
                count: EventFileWritePolicy.maxBufferedInfoEvents
            ),
            "info events at the batch limit should flush immediately"
        )
    }

    runSuite("EventReporter exposes shutdown flushing for buffered info events") {
        let reporterSource = readObservabilityTestRepoTextFile("Sources/Observability/EventReporter.swift")
        let appSource = readObservabilityTestRepoTextFile("Sources/TranscriptedApp.swift")

        assertTrue(
            reporterSource.contains("func flushLocalEventsForShutdown() async"),
            "buffered local info events should have an explicit shutdown flush path"
        )
        assertTrue(
            appSource.contains("await EventReporter.shared.flushLocalEventsForShutdown()"),
            "termination cleanup should flush buffered event logs before replying to AppKit"
        )
    }

    runSuite("LockedFileAppender keeps concurrent log records line-delimited") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ObservabilityLogWriterTests-\(UUID().uuidString)", isDirectory: true)
        let logURL = root.appendingPathComponent("events.jsonl", isDirectory: false)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        fm.createFile(atPath: logURL.path, contents: nil)

        guard let first = try? FileHandle(forWritingTo: logURL),
              let second = try? FileHandle(forWritingTo: logURL) else {
            assertTrue(false, "expected to open two file handles")
            return
        }

        let queue = DispatchQueue(label: "test.locked-file-appender", attributes: .concurrent)
        let group = DispatchGroup()
        let expectedCount = 200

        for index in 0..<expectedCount {
            group.enter()
            queue.async {
                let prefix = index.isMultiple(of: 2) ? "a" : "b"
                let payload = String(repeating: prefix, count: 2_048)
                let line = "{\"index\":\(index),\"payload\":\"\(payload)\"}\n"
                LockedFileAppender.append(Data(line.utf8), to: index.isMultiple(of: 2) ? first : second)
                group.leave()
            }
        }

        _ = group.wait(timeout: .now() + 5)
        try? first.close()
        try? second.close()

        let content = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        assertEqual(lines.count, expectedCount, "each concurrent append should produce exactly one line")

        let validLines = lines.filter { line in
            line.hasPrefix("{\"index\":") && (line.hasSuffix("\"}") || line.hasSuffix("\"}\r"))
        }
        assertEqual(validLines.count, expectedCount, "concurrent appends should not concatenate or split JSONL records")
    }
}

private func readObservabilityTestRepoTextFile(_ relativePath: String) -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

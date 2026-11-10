import Foundation

func testDictationRecentChronology() {
    runSuite("Undo after a newer save cannot displace newer takes from limited recent reads") {
        withChronologyFixture { root in
            let base = try chronologyDate("2026-11-10T12:00:00Z")
            let initialTexts = ["synthetic alpha take", "synthetic bravo take", "synthetic charlie take", "synthetic delta take"]
            for (offset, text) in initialTexts.enumerated() {
                try saveChronologyTake(text, at: base.addingTimeInterval(Double(offset)), in: root)
            }
            let before = DictationTranscriptStore.recentSavedDictations(limit: 10, directory: root)
            let initialIDs = Set(before.compactMap(\.entryID))
            // Verify the actual parser sees four different takes before using
            // the real delete path. Three nonmatching entries must remain;
            // this fixture must never reach the sole-entry Trash path.
            guard before.count == 4, initialIDs.count == 4,
                  Set(before.map(\.createdAt)).count == 4,
                  let target = before.first(where: { $0.text == initialTexts[1] }),
                  let targetID = target.entryID,
                  before.filter({ $0.entryID != targetID }).count == 3 else {
                assertTrue(false, "Expected four distinct parsed timestamps and stable IDs before deletion")
                return
            }
            let undo = try DictationTranscriptStore.deleteEntryReversibly(target)
            guard case .rewrote = undo else {
                assertTrue(false, "The owned multi-entry fixture must use the rewrite Undo path")
                return
            }
            let newestText = "synthetic echo newest take"
            try saveChronologyTake(newestText, at: base.addingTimeInterval(4), in: root)
            let duringUndo = DictationTranscriptStore.recentSavedDictations(limit: 10, directory: root)
            guard duringUndo.count == 4,
                  let newTake = duringUndo.first(where: { $0.text == newestText }),
                  let newID = newTake.entryID,
                  !initialIDs.contains(newID), newTake.createdAt == base.addingTimeInterval(4) else {
                assertTrue(false, "Expected a distinct newer saved take during the Undo window")
                return
            }
            try DictationTranscriptStore.restoreDeletedEntry(undo)

            assertEqual(DictationTranscriptStore.latestSavedText(directory: root), newestText)
            assertEqual(DictationTranscriptStore.latestSavedDictation(directory: root)?.entryID, newID)
            assertEqual(DictationTranscriptStore.recentSavedDictations(limit: 1, directory: root).map(\.text), [newestText])
            assertEqual(DictationTranscriptStore.recentSavedDictations(limit: 2, directory: root).map(\.text),
                        [newestText, initialTexts[3]])
            let restored = DictationTranscriptStore.recentSavedDictations(limit: 10, directory: root)
            assertEqual(restored.map(\.text), [newestText] + Array(initialTexts.reversed()))
            assertEqual(Set(restored.compactMap(\.entryID)), initialIDs.union([newID]),
                        "Undo preserves every stable ID exactly once")
            assertEqual(restored.count, 5)
        }
    }

    runSuite("Recent reads rank all sections in the selected day before applying the limit") {
        withChronologyFixture { root in
            try writeChronologyDay("Dictations_2026-11-10.md", in: root, sections: [
                chronologySection("newest", captured: "2026-11-10T13:00:00Z"),
                chronologySection("oldest", captured: "2026-11-10T10:00:00Z"),
                chronologySection("middle", captured: "2026-11-10T12:00:00Z"),
            ])
            assertEqual(DictationTranscriptStore.recentSavedDictations(limit: 1, directory: root).compactMap(\.entryID), ["newest"])
            assertEqual(DictationTranscriptStore.recentSavedDictations(limit: 2, directory: root).compactMap(\.entryID), ["newest", "middle"])
            assertEqual(DictationTranscriptStore.recentSavedDictations(limit: 5, directory: root).compactMap(\.entryID), ["newest", "middle", "oldest"])
        }
    }

    runSuite("Equal parsed instants keep later physical sections first across limits and repeated reads") {
        withChronologyFixture { root in
            try writeChronologyDay("Dictations_2026-11-10.md", in: root, sections: [
                chronologySection("first", captured: "2026-11-10T10:00:00Z"),
                chronologySection("second", captured: "2026-11-10T12:00:00+02:00"),
                chronologySection("last", captured: "2026-11-10T10:00:00.000Z"),
            ])
            let expectedDate = try chronologyDate("2026-11-10T10:00:00Z")
            let all = DictationTranscriptStore.recentSavedDictations(limit: 10, directory: root)
            assertEqual(all.count, 3)
            assertTrue(all.allSatisfy { $0.createdAt == expectedDate }, "The fixtures must actually parse as equal instants")
            assertEqual(all.compactMap(\.entryID), ["last", "second", "first"])
            assertEqual(DictationTranscriptStore.recentSavedDictations(limit: 1, directory: root).compactMap(\.entryID), ["last"])
            assertEqual(DictationTranscriptStore.recentSavedDictations(limit: 2, directory: root).compactMap(\.entryID), ["last", "second"])
            assertEqual(DictationTranscriptStore.recentSavedDictations(limit: 10, directory: root).compactMap(\.entryID), ["last", "second", "first"])
        }
    }

    runSuite("Invalid and missing timestamps retain the existing controlled file-date fallback") {
        withChronologyFixture { root in
            let fallback = try chronologyDate("2026-11-10T12:10:00Z")
            let url = try writeChronologyDay("Dictations_2026-11-10.md", in: root, sections: [
                chronologySection("newest", captured: "2026-11-10T12:20:00Z"),
                chronologySection("invalid", captured: "synthetic-invalid-stamp"),
                chronologySection("oldest", captured: "2026-11-10T12:00:00Z"),
                chronologySection("missing", captured: nil),
            ])
            try FileManager.default.setAttributes([.modificationDate: fallback], ofItemAtPath: url.path)
            let recent = DictationTranscriptStore.recentSavedDictations(limit: 10, directory: root)
            assertEqual(recent.compactMap(\.entryID), ["newest", "missing", "invalid", "oldest"])
            assertEqual(recent.first(where: { $0.entryID == "invalid" })?.createdAt, fallback)
            assertEqual(recent.first(where: { $0.entryID == "missing" })?.createdAt, fallback)
            assertEqual(DictationTranscriptStore.latestSavedDictation(directory: root)?.entryID, "newest")
        }
    }

    runSuite("Normal adjacent-day traversal, limits and non-day file filtering stay intact") {
        withChronologyFixture { root in
            try writeChronologyDay("Dictations_2026-11-09.md", in: root, sections: [
                chronologySection("previous-day", captured: "2026-11-09T23:59:00Z"),
            ])
            try writeChronologyDay("Dictations_2026-11-10.md", in: root, sections: [
                chronologySection("new-day", captured: "2026-11-10T00:01:00Z"),
            ])
            try writeChronologyDay("Unrelated.md", in: root, sections: [
                chronologySection("ignored", captured: "2027-01-01T00:00:00Z"),
            ])
            try writeChronologyDay("Dictations_2026-11-11.txt", in: root, sections: [
                chronologySection("ignored-extension", captured: "2027-01-01T00:00:00Z"),
            ])
            assertEqual(DictationTranscriptStore.recentSavedDictations(limit: 0, directory: root).count, 0)
            assertEqual(DictationTranscriptStore.recentSavedDictations(limit: -1, directory: root).count, 0)
            assertEqual(DictationTranscriptStore.recentSavedDictations(limit: 1, directory: root).compactMap(\.entryID), ["new-day"])
            assertEqual(DictationTranscriptStore.recentSavedDictations(limit: 2, directory: root).compactMap(\.entryID), ["new-day", "previous-day"])
            assertEqual(DictationTranscriptStore.recentSavedDictations(limit: 10, directory: root).compactMap(\.entryID), ["new-day", "previous-day"])
        }
    }
}

private enum ChronologyFixtureError: Error { case invalidDate }

private func chronologyDate(_ value: String) throws -> Date {
    guard let date = ISO8601DateFormatter().date(from: value) else { throw ChronologyFixtureError.invalidDate }
    return date
}

private func saveChronologyTake(_ text: String, at date: Date, in directory: URL) throws {
    try DictationTranscriptWriter.save(text: text, sourceAppName: "Synthetic", sourceBundleID: nil,
                                      delivery: .copied, createdAt: date, directory: directory)
}

private func chronologySection(_ id: String, captured: String?) -> String {
    let timestamp = captured.map { "Captured: \($0)\n" } ?? ""
    return """
    ## 12:00 PM - Synthetic take

    Entry ID: `\(id)`
    \(timestamp)Delivery: copied
    Words: 2
    Characters: 14

    synthetic \(id)
    """
}

@discardableResult
private func writeChronologyDay(_ name: String, in root: URL, sections: [String]) throws -> URL {
    let url = root.appendingPathComponent(name)
    try ("# Synthetic dictation fixtures\n\n" + sections.joined(separator: "\n\n") + "\n")
        .write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func withChronologyFixture(_ body: (URL) throws -> Void) {
    let manager = FileManager.default
    let parent = manager.temporaryDirectory.resolvingSymlinksInPath()
    let prefix = "DictationRecentChronology-"
    let leaf = prefix + UUID().uuidString
    let root = parent.appendingPathComponent(leaf, isDirectory: true)
    do {
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do {
                let resolved = root.resolvingSymlinksInPath()
                let attributes = try manager.attributesOfItem(atPath: root.path)
                if resolved.deletingLastPathComponent() == parent,
                   resolved.lastPathComponent == leaf,
                   UUID(uuidString: String(leaf.dropFirst(prefix.count))) != nil,
                   attributes[.type] as? FileAttributeType == .typeDirectory {
                    try manager.removeItem(at: root)
                } else {
                    assertTrue(false, "Refusing cleanup outside the owned real fixture directory")
                }
            } catch { assertTrue(false, "Could not remove the owned chronology fixture") }
        }
        try body(root)
    } catch { assertTrue(false, "Could not prepare the owned chronology fixture") }
}

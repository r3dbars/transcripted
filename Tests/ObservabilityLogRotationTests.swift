import Foundation

func testObservabilityLogRotation() {
    runSuite("ObservabilityLogRotation — missing files do not rotate") {
        let root = makeObservabilityLogRotationTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("events.jsonl", isDirectory: false)

        assertFalse(
            ObservabilityLogRotation.rotateIfNeeded(at: logURL, threshold: 1),
            "missing logs should be a no-op"
        )
        assertFalse(FileManager.default.fileExists(atPath: logURL.path))
        assertFalse(FileManager.default.fileExists(atPath: logURL.appendingPathExtension("1").path))
    }

    runSuite("ObservabilityLogRotation — files at the threshold stay active") {
        let root = makeObservabilityLogRotationTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("events.jsonl", isDirectory: false)
        try! "12345".write(to: logURL, atomically: true, encoding: .utf8)

        assertFalse(
            ObservabilityLogRotation.rotateIfNeeded(at: logURL, threshold: 5),
            "rotation should happen only after the log exceeds the threshold"
        )
        assertEqual(try? String(contentsOf: logURL, encoding: .utf8), "12345")
        assertFalse(FileManager.default.fileExists(atPath: logURL.appendingPathExtension("1").path))
    }

    runSuite("ObservabilityLogRotation — oversized files move to generation one") {
        let root = makeObservabilityLogRotationTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("events.jsonl", isDirectory: false)
        let rotatedURL = logURL.appendingPathExtension("1")
        let payload = "{\"event\":\"one\"}\n{\"event\":\"two\"}\n"
        try! payload.write(to: logURL, atomically: true, encoding: .utf8)

        assertTrue(
            ObservabilityLogRotation.rotateIfNeeded(at: logURL, threshold: 8),
            "oversized logs should rotate by rename"
        )
        assertFalse(FileManager.default.fileExists(atPath: logURL.path), "active log should be moved away")
        assertEqual(try? String(contentsOf: rotatedURL, encoding: .utf8), payload)
    }

    runSuite("ObservabilityLogRotation — replacement generation is owner-only") {
        let root = makeObservabilityLogRotationTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = root.appendingPathComponent("reliability.jsonl", isDirectory: false)
        let rotatedURL = logURL.appendingPathExtension("1")
        try! "stale\n".write(to: rotatedURL, atomically: true, encoding: .utf8)
        try! "{\"event\":\"fresh\"}\n".write(to: logURL, atomically: true, encoding: .utf8)

        assertTrue(
            ObservabilityLogRotation.rotateIfNeeded(at: logURL, threshold: 1),
            "new rotation should replace the prior generation"
        )
        assertEqual(
            try? String(contentsOf: rotatedURL, encoding: .utf8),
            "{\"event\":\"fresh\"}\n",
            "only one rotated generation should be kept"
        )
        assertEqual(
            posixPermissionsForObservabilityLogRotation(at: rotatedURL),
            0o600,
            "rotated observability logs should be owner-only"
        )
    }
}

private func makeObservabilityLogRotationTempRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ObservabilityLogRotationTests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func posixPermissionsForObservabilityLogRotation(at url: URL) -> Int? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.posixPermissions] as? NSNumber)?.intValue
}

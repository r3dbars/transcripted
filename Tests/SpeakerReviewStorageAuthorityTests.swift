import Foundation

func testSpeakerReviewStorageAuthority() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("SpeakerReviewAuthority-\(UUID())", isDirectory: true)
    defer {
        precondition(root.deletingLastPathComponent() == fm.temporaryDirectory)
        precondition(root.lastPathComponent.hasPrefix("SpeakerReviewAuthority-"))
        try? fm.removeItem(at: root)
    }
    let configured = root.appendingPathComponent("configured", isDirectory: true)
    let other = root.appendingPathComponent("other", isDirectory: true)
    let fallback = root.appendingPathComponent("fallback", isDirectory: true)
    for directory in [configured, other, fallback] {
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    runSuite("Speaker review keeps one configured-root snapshot when preferences change") {
        var reads = 0
        var defaults = 0
        let result = TranscriptedStoragePreferences.speakerReviewMeetingsDirectory(
            readConfiguredPath: { reads += 1; return reads == 1 ? configured.path : other.path },
            defaultLibrary: { defaults += 1; return fallback }
        )
        assertEqual(result, FileManager.meetingsDirectory(in: configured), "the captured authority owns this save")
        assertEqual(reads, 1, "one preference snapshot per resolution")
        assertEqual(defaults, 0, "configured authority never resolves through default storage")
    }

    runSuite("Speaker review never defaults or recreates a custom root that disappears during validation") {
        let disappearing = root.appendingPathComponent("disappearing", isDirectory: true)
        try? fm.createDirectory(at: disappearing, withIntermediateDirectories: true)
        let guarded = DisappearingReviewRootFileManager(root: disappearing)
        var defaults = 0
        let result = TranscriptedStoragePreferences.speakerReviewMeetingsDirectory(
            readConfiguredPath: { disappearing.path },
            defaultLibrary: { defaults += 1; return fallback }, fileManager: guarded
        )
        assertEqual(result, nil, "a lost custom authority must fail closed")
        assertEqual(defaults, 0, "availability loss cannot authorize default storage")
        assertTrue(!fm.fileExists(atPath: disappearing.path), "creating meetings must not recreate a missing custom root")
    }

    runSuite("Speaker review does not reinterpret a concurrent preference reset as default authority") {
        var reads = 0
        var defaults = 0
        let result = TranscriptedStoragePreferences.speakerReviewMeetingsDirectory(
            readConfiguredPath: { reads += 1; return reads == 1 ? configured.path : nil },
            defaultLibrary: { defaults += 1; return fallback }
        )
        assertEqual(result, FileManager.meetingsDirectory(in: configured), "the first configured snapshot stays authoritative")
        assertEqual(defaults, 0, "a later preference reset cannot redirect this save")
    }

    runSuite("Speaker review prepares a missing meetings child only inside its existing chosen root") {
        let result = TranscriptedStoragePreferences.speakerReviewMeetingsDirectory(
            readConfiguredPath: { other.path }, defaultLibrary: { fallback }
        )
        assertEqual(result, FileManager.meetingsDirectory(in: other))
        assertTrue(fm.fileExists(atPath: other.path), "chosen root remains")
        assertTrue(fm.fileExists(atPath: FileManager.meetingsDirectory(in: other).path), "legitimate missing child is prepared")
    }

    runSuite("Speaker review rejects a missing configured root without recreating it or consulting default storage") {
        let missing = root.appendingPathComponent("absent", isDirectory: true)
        var defaults = 0
        let result = TranscriptedStoragePreferences.speakerReviewMeetingsDirectory(
            readConfiguredPath: { missing.path }, defaultLibrary: { defaults += 1; return fallback }
        )
        assertEqual(result, nil)
        assertEqual(defaults, 0)
        assertTrue(!fm.fileExists(atPath: missing.path))
    }

    runSuite("Speaker review uses default storage only when its captured configuration has no custom root") {
        var defaults = 0
        let result = TranscriptedStoragePreferences.speakerReviewMeetingsDirectory(
            readConfiguredPath: { nil }, defaultLibrary: { defaults += 1; return fallback }
        )
        assertEqual(result, FileManager.meetingsDirectory(in: fallback))
        assertEqual(defaults, 1)
    }
}

private final class DisappearingReviewRootFileManager: FileManager, @unchecked Sendable {
    private let root: URL
    private var removed = false
    init(root: URL) { self.root = root; super.init() }
    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        let exists = super.fileExists(atPath: path, isDirectory: isDirectory)
        if path == root.path, exists, !removed {
            removed = true
            try? FileManager.default.removeItem(at: root)
        }
        return exists
    }
}

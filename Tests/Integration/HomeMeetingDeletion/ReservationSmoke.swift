import Foundation
@testable import TranscriptedCore

// Only the scanned row's value carrier is substituted. The deletion planner,
// serializer/error adapter, Core reservation registry, archive resolver and
// Trash/restore implementation are all production sources. This deliberately
// does not claim Home scanning or UI coverage.
struct RecentMeetingItem {
    let transcriptURL: URL
}

private enum SmokeFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private final class Checks {
    private(set) var count = 0

    func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        count += 1
        guard try condition() else { throw SmokeFailure.failed(message) }
    }
}

// The OS Trash location is the only filesystem effect replaced. Production
// CaptureTrashOperation still calls FileManager.trashItem, receives the real
// moved location, and restores those actual files. Never touches the user's
// Trash; all destructive paths are checked against this unique temporary root.
private final class FixtureFileManager: FileManager {
    let root: URL
    let trashDirectory: URL
    private(set) var trashCalls = 0
    private(set) var removalCalls = 0

    init(root: URL) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.trashDirectory = root.appendingPathComponent("fixture-trash", isDirectory: true)
        super.init()
        try createDirectory(at: trashDirectory, withIntermediateDirectories: true)
    }

    private func requireFixturePath(_ url: URL) throws {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(root.path + "/") else {
            throw SmokeFailure.failed("refusing a filesystem mutation outside the synthetic fixture")
        }
    }

    override func trashItem(
        at url: URL,
        resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?
    ) throws {
        try requireFixturePath(url)
        let destination = trashDirectory.appendingPathComponent(UUID().uuidString)
        try moveItem(at: url, to: destination)
        trashCalls += 1
        outResultingURL?.pointee = destination as NSURL
    }

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try requireFixturePath(sourceURL)
        try requireFixturePath(destinationURL)
        try super.moveItem(at: sourceURL, to: destinationURL)
    }

    override func removeItem(at url: URL) throws {
        try requireFixturePath(url)
        removalCalls += 1
        try super.removeItem(at: url)
    }
}

private struct Fixture {
    let transcriptURL: URL
    let summaryURL: URL
    let audioDirectory: URL
    let systemURL: URL
    let microphoneURL: URL
    let unrelatedURL: URL
    let originalBytes: [URL: Data]

    init(root: URL) throws {
        let fm = FileManager.default
        let meetings = root.appendingPathComponent("meetings", isDirectory: true)
        try fm.createDirectory(at: meetings, withIntermediateDirectories: true)
        transcriptURL = meetings.appendingPathComponent("2026-09-21 Synthetic reservation.md")
        summaryURL = meetings.appendingPathComponent("2026-09-21 Synthetic reservation.summary.md")
        // Independent expected path; do not derive the expected ownership set
        // from HomeMeetingDeletion.plan or the production archive-path helper.
        audioDirectory = meetings.appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("2026-09-21 Synthetic reservation_audio", isDirectory: true)
        try fm.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        systemURL = audioDirectory.appendingPathComponent("system_audio.wav")
        microphoneURL = audioDirectory.appendingPathComponent("microphone.wav")
        unrelatedURL = meetings.appendingPathComponent("unrelated.txt")
        let identity = UUID().uuidString
        let transcript = """
        ---
        capture_type: meeting
        capture_id: "\(identity)"
        transcript_id: "\(identity)"
        title: "Synthetic reservation"
        date: "2026-09-21"
        ---

        # Synthetic reservation

        **00:01** [System/Synthetic]
        Only synthetic fixture content.
        """
        let summary = """
        ---
        capture_type: meeting_summary
        source_transcript: "\(transcriptURL.lastPathComponent)"
        ---
        Synthetic summary bytes.
        """
        originalBytes = [
            transcriptURL: Data(transcript.utf8),
            summaryURL: Data(summary.utf8),
            // These are opaque fixture bytes, not playable or customer audio.
            systemURL: Data([0x00, 0x11, 0x22, 0xff]),
            microphoneURL: Data([0xff, 0x42, 0x00, 0x37]),
            unrelatedURL: Data("unrelated fixture must survive".utf8)
        ]
        for (url, bytes) in originalBytes { try bytes.write(to: url) }
    }

    var ownedRoots: Set<URL> { [transcriptURL, summaryURL, audioDirectory] }

    func expectUnchanged(_ checks: Checks, label: String) throws {
        for (url, expected) in originalBytes {
            try checks.expect(
                try Data(contentsOf: url) == expected,
                "\(label): synthetic \(url.lastPathComponent) must remain byte-for-byte unchanged"
            )
        }
    }
}

private func expectHomeReservationError(_ checks: Checks, operation: () throws -> Void) throws {
    do {
        try operation()
    } catch HomeMeetingDeletionError.retranscriptionInProgress {
        try checks.expect(true, "the app must translate Core replacement denial")
        return
    }
    throw SmokeFailure.failed("expected HomeMeetingDeletionError.retranscriptionInProgress")
}

private func exerciseReservation(
    fixture: Fixture,
    fileManager: FixtureFileManager,
    checks: Checks
) throws {
    let item = RecentMeetingItem(transcriptURL: fixture.transcriptURL)
    let plan = HomeMeetingDeletion.plan(for: item, fileManager: fileManager)
    try checks.expect(Set(plan.transcriptURLs + plan.summaryURLs + plan.audioDirectoryURLs) == fixture.ownedRoots,
                      "the actual deletion plan must include all three independently expected owned roots")
    guard let reservation = TranscriptSaver.beginReplacingTranscript(at: fixture.transcriptURL) else {
        throw SmokeFailure.failed("the real Core replacement reservation must be acquired")
    }
    defer { TranscriptSaver.finishReplacingTranscript(reservation) }
    try checks.expect(TranscriptSaver.isReplacingTranscript(at: fixture.transcriptURL),
                      "the real Core reservation must be active before deletion attempts")

    try expectHomeReservationError(checks) {
        _ = try HomeMeetingDeletion.delete(item, fileManager: fileManager)
    }
    try fixture.expectUnchanged(checks, label: "reserved delete")

    try expectHomeReservationError(checks) {
        _ = try HomeMeetingDeletion.trash(item, fileManager: fileManager)
    }
    try fixture.expectUnchanged(checks, label: "reserved Trash")

    // A precomputed plan also has a guard; this overload intentionally exposes
    // the adapter error, while the item-based calls above translate it for UI.
    do {
        _ = try HomeMeetingDeletion.delete(plan, fileManager: fileManager)
        throw SmokeFailure.failed("a precomputed plan must not bypass the Core reservation")
    } catch MeetingTranscriptFileUpdateError.replacementInProgress {
        try checks.expect(true, "the precomputed-plan overload must preserve the guard")
    }
    try fixture.expectUnchanged(checks, label: "reserved planned delete")
    try checks.expect(fileManager.trashCalls == 0, "denied operations must not enter Trash mechanics")
    try checks.expect(fileManager.removalCalls == 0, "denied operations must not start partial removal")
}

private func runSmoke() throws -> Int {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("transcripted-deletion-reservation-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    // This root was created by this process and holds only synthetic artifacts.
    defer { try? fm.removeItem(at: root) }
    setenv("TRANSCRIPTED_CONTAINER_DIR", root.appendingPathComponent("container").path, 1)
    setenv("TRANSCRIPTED_DISABLE_FILE_LOGGER", "1", 1)

    let fixture = try Fixture(root: root)
    let fileManager = try FixtureFileManager(root: root)
    let checks = Checks()
    try exerciseReservation(fixture: fixture, fileManager: fileManager, checks: checks)

    try checks.expect(!TranscriptSaver.isReplacingTranscript(at: fixture.transcriptURL),
                      "the real Core reservation must be released before successful deletion")
    let item = RecentMeetingItem(transcriptURL: fixture.transcriptURL)
    let payload = try HomeMeetingDeletion.trash(item, fileManager: fileManager)
    defer { HomeMeetingDeletion.restore(payload, fileManager: fileManager) }
    try checks.expect(Set(payload.trashedFiles.map(\.originalURL)) == fixture.ownedRoots,
                      "released Trash must move exactly the transcript, summary and audio directory")
    try checks.expect(fileManager.trashCalls == 3, "released Trash must reach production mechanics for every owned root")
    for url in fixture.ownedRoots {
        try checks.expect(!fm.fileExists(atPath: url.path), "successful Trash must remove every original owned root")
    }
    for moved in payload.trashedFiles {
        try checks.expect(fm.fileExists(atPath: moved.trashedURL.path), "Undo must refer to a real moved fixture")
    }

    HomeMeetingDeletion.restore(payload, fileManager: fileManager)
    try fixture.expectUnchanged(checks, label: "Undo after reservation release")
    try checks.expect(try fm.contentsOfDirectory(atPath: fileManager.trashDirectory.path).isEmpty,
                      "Undo must return every moved fixture out of the synthetic Trash")
    HomeMeetingDeletion.restore(payload, fileManager: fileManager)
    try fixture.expectUnchanged(checks, label: "repeated Undo")

    let deleted = try HomeMeetingDeletion.delete(item, fileManager: fileManager)
    try checks.expect(Set(deleted.removedTranscriptURLs + deleted.removedSummaryURLs + deleted.removedAudioDirectoryURLs) == fixture.ownedRoots,
                      "permanent delete must work after reservation release and Undo")
    for url in fixture.ownedRoots {
        try checks.expect(!fm.fileExists(atPath: url.path), "released permanent delete must remove every owned root")
    }
    try checks.expect(try Data(contentsOf: fixture.unrelatedURL) == fixture.originalBytes[fixture.unrelatedURL],
                      "unrelated fixture bytes must survive every operation")
    return checks.count
}

@main
private enum ReservationSmoke {
    static func main() {
        do {
            let count = try runSmoke()
            print("PASS \(count) assertions: real Core replacement reservation blocks Home delete/Trash; release permits deletion and byte-preserving Undo")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}

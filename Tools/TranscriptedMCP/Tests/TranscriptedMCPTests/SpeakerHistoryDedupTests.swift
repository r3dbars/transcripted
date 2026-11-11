import Foundation
import SQLite3
import Darwin
#if !MCP3_COMPONENT
import XCTest
@testable import transcripted_mcp

final class SpeakerHistoryDedupTests: XCTestCase {
    func testHistoryCountsFilesAndProfilesExcludeEveryMatchedName() throws {
        try runSpeakerHistoryDedupFixture { condition, promise in
            XCTAssertTrue(condition, promise)
        }
    }
}
#endif

/// Uses the actual index and SQLite schema in a newly owned directory. No
/// capture enumeration, embedding provider, server, or directory defaults.
func runSpeakerHistoryDedupFixture(check: (Bool, String) -> Void) throws {
    let requestedParent = ProcessInfo.processInfo.environment["TRANSCRIPTED_MCP3_FIXTURE_ROOT"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
    let parent = requestedParent.resolvingSymlinksInPath().standardizedFileURL
    var parentInfo = stat()
    guard lstat(parent.path, &parentInfo) == 0,
          parentInfo.st_mode & S_IFMT == S_IFDIR else {
        throw MCPIndexError.queryFailed("Fixture parent must already be a directory")
    }
    let uuid = UUID().uuidString
    let token = "mcp-speaker-history-" + uuid
    let root = parent.appendingPathComponent(token, isDirectory: true)
    var existing = stat()
    guard lstat(root.path, &existing) != 0, errno == ENOENT else {
        throw MCPIndexError.queryFailed("Fixture directory must not already exist")
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
    defer {
        // Revalidate the exact owned directory before deleting it, including
        // symlinks, ownership and permissions changed while the fixture ran.
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        var info = stat()
        if canonical.path == root.standardizedFileURL.path,
           canonical.deletingLastPathComponent().path == parent.path,
           canonical.lastPathComponent == token,
           UUID(uuidString: String(token.dropFirst("mcp-speaker-history-".count)))?.uuidString == uuid,
           lstat(root.path, &info) == 0,
           info.st_mode & S_IFMT == S_IFDIR,
           info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 {
            do {
                try FileManager.default.removeItem(at: canonical)
            } catch {
                check(false, "the owned fixture directory must be cleaned up")
            }
        } else {
            check(false, "fixture cleanup must refuse an unverified directory")
        }
    }
    try withLogsSuppressed {
        let index = try TranscriptIndex(indexDir: root, embeddingProvider: nil)
        check(index.embeddingStore == nil, "the fixture must not initialize semantic search")
        func meeting(_ file: String, _ date: String) throws {
            try index.queue.sync {
                try sqlBindExec(db: index.db, sql: "INSERT INTO meetings VALUES (?,?,?,?,?,?,?)",
                                bindings: [.text(file), .text(date), .text(date + "T10:00:00"),
                                           .int(600), .int(4), .int(100), .double(0)])
            }
        }
        func speaker(_ file: String, _ name: String, _ id: String?, _ words: Int, _ seconds: Double) throws {
            try index.queue.sync {
                try sqlBindExec(db: index.db, sql: "INSERT INTO meeting_speakers VALUES (?,?,?,?,?)",
                                bindings: [.text(file), .text(name), id.map(SQLBinding.text) ?? .null,
                                           .int(words), .double(seconds)])
                try sqlBindExec(db: index.db, sql: "INSERT INTO utterances (filename,speaker_name,utterance_start,utterance_end,text) VALUES (?,?,?,?,?)",
                                bindings: [.text(file), .text(name), .double(0), .double(seconds), .text("Quote by " + name)])
            }
        }

        let latestID = "11111111-1111-4111-8111-111111111111"
        let olderID = "22222222-2222-4222-8222-222222222222"
        try meeting("casey-new", "2026-06-03")
        try meeting("casey-old", "2026-06-01")
        try speaker("casey-new", "Casey A", nil, 10, 20)
        try speaker("casey-new", "Casey B", latestID, 5, 10)
        try speaker("casey-new", "Taylor", nil, 3, 4)
        try speaker("casey-new", "Morgan", nil, 2, 3)
        try speaker("casey-old", "Casey A", olderID, 7, 14)
        try speaker("casey-old", "Taylor", nil, 3, 4)

        let history = try index.getSpeakerHistory(speaker: "Casey")
        check(history.meetingCount == 2, "two capture files are two meetings even when one has two matched names")
        check(history.meetings.map(\.filename) == ["casey-new", "casey-old"], "each file appears once in existing newest-first order")
        check(history.totalWordCount == 22, "grouping preserves the sum of already-matched word counts")
        check(history.totalSpeakingSeconds == 44, "grouping preserves already-matched speaking time")
        check(history.meetings.first?.wordCount == 15, "a meeting combines its matched rows' words")
        check(history.meetings.first?.speakingSeconds == 30, "a meeting combines its matched rows' time")
        check(history.persistentSpeakerId == latestID, "the first available ID must not disappear when a representative row has no ID")
        if let representative = history.meetings.first {
            check(["Casey A", "Casey B"].contains(representative.speakerName), "the representative remains an existing matched name")
            check(representative.previewSnippet == "Quote by " + representative.speakerName, "representative name and quote stay from the same row")
            check(representative.persistentSpeakerId == (representative.speakerName == "Casey A" ? nil : latestID), "representative identity stays with its original row")
            check(history.matchedName == representative.speakerName, "the profile name stays the first matched row's name")
        } else {
            check(false, "a matched history must have a representative meeting")
        }

        let profile = try index.getPersonProfile(speaker: "Casey")
        check(profile.meetingCount == 2 && profile.recentMeetings.count == 2, "who_is returns one recent entry per capture file")
        check(profile.totalWordCount == 22 && profile.totalSpeakingMinutes == 44.0 / 60, "profile totals preserve matched metrics")
        check(profile.firstSeen == "2026-06-01" && profile.lastSeen == "2026-06-03", "distinct meetings preserve the date range")
        check(Set(profile.frequentCoSpeakers) == ["Taylor", "Morgan"], "all matched names are excluded from frequent co-speakers")
        check(profile.frequentCoSpeakers.first == "Taylor", "an actual co-speaker in two meetings stays more frequent")
        check(Set(profile.recentMeetings.first?.otherSpeakers ?? []) == ["Taylor", "Morgan"], "recent meeting co-speakers exclude both matched names")
        check(profile.representativeQuotes.count == 2, "duplicate matched rows do not duplicate representative meeting quotes")

        let sharedID = "33333333-3333-4333-8333-333333333333"
        try meeting("uuid-new", "2026-07-03")
        try meeting("uuid-old", "2026-07-01")
        try speaker("uuid-new", "Alex Current", sharedID, 8, 16)
        try speaker("uuid-new", "Old Alias", sharedID, 2, 4)
        try speaker("uuid-new", "Riley", nil, 3, 4)
        try speaker("uuid-old", "Old Alias", sharedID, 5, 10)
        try speaker("uuid-old", "Riley", nil, 3, 4)
        let uuidHistory = try index.getSpeakerHistory(speaker: sharedID)
        check(uuidHistory.meetingCount == 2 && uuidHistory.meetings.count == 2, "UUID aliases in one file still count one meeting")
        check(uuidHistory.totalWordCount == 15 && uuidHistory.totalSpeakingSeconds == 30, "UUID matching retains every matching row's metrics")
        check(uuidHistory.meetings.first?.wordCount == 10, "UUID aliases aggregate within their file")
        let uuidProfile = try index.getPersonProfile(speaker: sharedID)
        check(uuidProfile.frequentCoSpeakers == ["Riley"], "UUID lookup excludes every matched alias from co-speakers")
        check(uuidProfile.recentMeetings.allSatisfy { $0.otherSpeakers == ["Riley"] }, "all recent UUID meetings exclude all aliases")

        let empty = try index.getPersonProfile(speaker: "Nobody Matched")
        check(empty.meetingCount == 0 && empty.recentMeetings.isEmpty, "an unknown speaker still has empty history")
        check(empty.frequentCoSpeakers.isEmpty && empty.representativeQuotes.isEmpty, "an unknown speaker has no borrowed co-speakers or quotes")
    }
}

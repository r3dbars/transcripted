import Foundation

func testDictationAudioRetentionPolicy() {
    runSuite("Live dictation retention honors a policy relaxation during inventory") {
        for current in [DictationAudioKeepWindow.thirtyDays, .forever] {
            do {
                let fixture = try DictationRetentionFixture()
                defer { fixture.close() }
                let policy = DictationRetentionPolicy(.sevenDays)
                let fm = DictationRetentionFileManager(audio: fixture.audioFolder, changeOnSecondFile: false) { policy.set(current) }
                let removed = DictationAudioArchive.prune(
                    window: .sevenDays, now: DictationRetentionFixture.now,
                    dictationsFolder: fixture.root, fileManager: fm,
                    currentKeepWindow: { policy.current }
                )
                assertTrue(fm.didInterleave, "the setting changed after the file inventory was read")
                assertEqual(removed, 0, "an obsolete seven-day window cannot delete a twenty-day take")
                assertTrue(FileManager.default.fileExists(atPath: fixture.audio.path))
            } catch { assertTrue(false, "owned dictation inventory fixture failed: \(error)") }
        }
    }
    runSuite("A policy relaxation protects remaining dictation files in the same sweep") {
        do {
            let fixture = try DictationRetentionFixture()
            defer { fixture.close() }
            let second = try fixture.addTake()
            let policy = DictationRetentionPolicy(.sevenDays)
            let fm = DictationRetentionFileManager(audio: fixture.audioFolder, changeOnSecondFile: true) { policy.set(.forever) }
            let removed = DictationAudioArchive.prune(
                window: .sevenDays, now: DictationRetentionFixture.now,
                dictationsFolder: fixture.root, fileManager: fm, currentKeepWindow: { policy.current }
            )
            assertTrue(fm.didInterleave, "the setting changed before the second file's decision")
            assertEqual(removed, 1, "the first authorized deletion does not freeze the remaining policy")
            assertEqual([fixture.audio, second].filter { FileManager.default.fileExists(atPath: $0.path) }.count, 1)
        } catch { assertTrue(false, "owned dictation sweep fixture failed: \(error)") }
    }
    runSuite("An explicit custom-library dictation purge keeps its fixed API window") {
        for window in [DictationAudioKeepWindow.sevenDays, .forever, .off] {
            do {
                let fixture = try DictationRetentionFixture()
                defer { fixture.close() }
                let removed = DictationAudioArchive.prune(
                    window: window, now: DictationRetentionFixture.now, dictationsFolder: fixture.root
                )
                assertEqual(removed, window == .forever ? 0 : 1)
                assertEqual(FileManager.default.fileExists(atPath: fixture.audio.path), window == .forever)
            } catch { assertTrue(false, "owned explicit dictation fixture failed: \(error)") }
        }
    }
    runSuite("Pending committed dictation retention rechecks policy after receipt inventory") {
        for (current, committed) in [(DictationAudioKeepWindow.thirtyDays, true), (.forever, true), (.sevenDays, true), (.off, false)] {
            do {
                let fixture = try DictationRetentionFixture()
                defer { fixture.close() }
                let pending = fixture.root.appendingPathComponent("recovery", isDirectory: true)
                let dictations = fixture.root.appendingPathComponent("pending-dictations", isDirectory: true)
                try FileManager.default.createDirectory(at: dictations, withIntermediateDirectories: true)
                guard let recovery = try DictationStoppedAudioRecoveryStore.persist(
                    samples16k: [0.1, -0.1], sessionID: UUID(),
                    createdAt: DictationRetentionFixture.now.addingTimeInterval(-20 * 86_400),
                    retentionRequested: true, directory: pending
                ) else { assertTrue(false, "the owned checkpoint must persist"); continue }
                // A blocked destination leaves a real committed-text receipt
                // and its protected checkpoint for maintenance to handle.
                try Data("owned archive blocker".utf8).write(to: dictations.appendingPathComponent("audio"))
                if committed {
                    let transcript = dictations.appendingPathComponent("day.md")
                    let saved = DictationTranscriptPersistenceResult.measure {
                        try Data("synthetic saved dictation".utf8).write(to: transcript)
                        return SavedDictationTranscript(url: transcript, title: "Synthetic")
                    }
                    let retired = DictationStoppedAudioRecoveryStore.retire(
                        recovery, afterSaving: saved,
                        keptAudioRelativePath: DictationAudioArchive.relativePath(for: recovery.sessionID),
                        dictationsFolder: dictations, compressKeptAudio: { _ in assertTrue(false, "the blocked archive cannot compress") }
                    )
                    assertFalse(retired, "the checkpoint remains pending after archive failure")
                }
                let policy = DictationRetentionPolicy(.sevenDays)
                let fm = DictationPendingPolicyFileManager(folder: pending) { policy.set(current) }
                var discarded = 0
                let removed = DictationStoppedAudioRecoveryStore.retryPendingAudioRetention(
                    directory: pending, dictationsFolder: dictations, window: .sevenDays,
                    currentKeepWindow: { policy.current }, now: DictationRetentionFixture.now,
                    fileManager: fm, onDiscard: { _ in discarded += 1 },
                    compressKeptAudio: { _ in assertTrue(false, "the blocked archive cannot compress") }
                )
                let shouldRemove = committed && current == .sevenDays
                assertTrue(fm.didInterleave, "the policy changes after the receipt inventory")
                assertEqual(removed, shouldRemove ? 1 : 0)
                assertEqual(discarded, shouldRemove ? 1 : 0)
                assertEqual(FileManager.default.fileExists(atPath: recovery.url.path), !shouldRemove,
                            "relaxed policy and uncommitted text keep the checkpoint")
                assertEqual(FileManager.default.fileExists(atPath: recovery.url.deletingPathExtension().appendingPathExtension("json").path), !shouldRemove,
                            "the matching receipt follows the protected checkpoint")
            } catch { assertTrue(false, "owned pending dictation fixture failed: \(error)") }
        }
    }
}

private struct DictationRetentionFixture {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    let root: URL
    let audioFolder: URL
    let audio: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DictationRetentionPolicy-\(UUID().uuidString)", isDirectory: true)
        audioFolder = root.appendingPathComponent("audio", isDirectory: true)
        audio = audioFolder.appendingPathComponent("\(UUID().uuidString.lowercased()).m4a")
        try FileManager.default.createDirectory(at: audioFolder, withIntermediateDirectories: true)
        try writeTake(audio)
    }
    func addTake() throws -> URL {
        let url = audioFolder.appendingPathComponent("\(UUID().uuidString.lowercased()).m4a")
        try writeTake(url)
        return url
    }
    private func writeTake(_ url: URL) throws {
        try Data("synthetic retained take".utf8).write(to: url)
        let date = Self.now.addingTimeInterval(-20 * 86_400)
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }
    func close() {
        guard root.lastPathComponent.hasPrefix("DictationRetentionPolicy-"),
              root.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL else {
            preconditionFailure("refusing unowned dictation fixture cleanup")
        }
        try? FileManager.default.removeItem(at: root)
    }
}

private final class DictationRetentionPolicy {
    private var window: DictationAudioKeepWindow
    init(_ window: DictationAudioKeepWindow) { self.window = window }
    var current: DictationAudioKeepWindow { window }
    func set(_ window: DictationAudioKeepWindow) { self.window = window }
}

private final class DictationRetentionFileManager: FileManager, @unchecked Sendable {
    private let audio: URL
    private let changeOnSecondFile: Bool
    private let action: () -> Void
    private var fileReads = 0
    private(set) var didInterleave = false
    init(audio: URL, changeOnSecondFile: Bool, action: @escaping () -> Void) {
        self.audio = audio
        self.changeOnSecondFile = changeOnSecondFile
        self.action = action
    }
    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        let names = try super.contentsOfDirectory(atPath: path)
        if path == audio.path, !changeOnSecondFile { didInterleave = true; action() }
        return names
    }
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        let attributes = try super.attributesOfItem(atPath: path)
        if changeOnSecondFile, URL(fileURLWithPath: path).deletingLastPathComponent() == audio,
           URL(fileURLWithPath: path).pathExtension == "m4a" {
            fileReads += 1
            if fileReads == 2 { didInterleave = true; action() }
        }
        return attributes
    }
}

private final class DictationPendingPolicyFileManager: FileManager, @unchecked Sendable {
    private let folder: URL
    private let action: () -> Void
    private(set) var didInterleave = false
    init(folder: URL, action: @escaping () -> Void) { self.folder = folder; self.action = action }
    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        let contents = try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: options)
        if url == folder { didInterleave = true; action() }
        return contents
    }
}

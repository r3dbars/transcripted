import Foundation

@MainActor
func testMeetingAudioRetentionPolicy() async {
    await runSuite("Automatic meeting retention uses the current window after suspended conversion") {
        for current in [AudioRetentionWindow.thirtyDays, .never] {
            do {
                let fixture = try RetentionPolicyFixture(wav: true)
                defer { fixture.close() }
                let policy = RetentionPolicyState(.sevenDays)
                let began = RetentionPolicySignal(), resume = RetentionPolicySignal()
                let work = Task {
                    await MeetingAudioStorageManager.processSavedTranscript(
                        at: fixture.transcript, now: RetentionPolicyFixture.now,
                        converter: RetentionPolicyConverter(began: began, resume: resume),
                        validator: RetentionPolicyValidator(), playbackMixer: RetentionPolicyMixer(),
                        retentionWindowProvider: { policy.current }
                    )
                }
                await began.wait()
                policy.set(current)
                await resume.send()
                _ = await work.value
                let compressedAudio = fixture.audio.deletingPathExtension().appendingPathExtension("m4a")
                assertTrue(FileManager.default.fileExists(atPath: compressedAudio.path), "a completed relaxation must protect the 20-day recording")
                assertTrue(FileManager.default.fileExists(atPath: fixture.transcript.path), "retention never removes the transcript")
            } catch { assertTrue(false, "owned conversion fixture failed: \(error)") }
        }
    }

    runSuite("Automatic meeting retention rechecks policy after its inventory") {
        for current in [AudioRetentionWindow.thirtyDays, .never] {
            do {
                let fixture = try RetentionPolicyFixture()
                defer { fixture.close() }
                let policy = RetentionPolicyState(.sevenDays)
                let fm = RetentionPolicyFileManager(inventory: fixture.root.appendingPathComponent("audio")) {
                    policy.set(current)
                }
                let removed = MeetingAudioStorageManager.pruneRetainedAudio(
                    in: fixture.root, now: RetentionPolicyFixture.now, fileManager: fm,
                    retentionWindowProvider: { policy.current }
                )
                assertTrue(fm.didInterleave, "the policy changed after inventory began")
                assertEqual(removed, 0, "the stale seven-day choice cannot authorize a later automatic deletion")
                assertTrue(FileManager.default.fileExists(atPath: fixture.audio.path))
            } catch { assertTrue(false, "owned inventory fixture failed: \(error)") }
        }
    }

    runSuite("A policy relaxation during a sweep protects its remaining meeting captures") {
        do {
            let fixture = try RetentionPolicyFixture()
            defer { fixture.close() }
            let secondAudio = try fixture.addCapture(stem: "Second")
            let policy = RetentionPolicyState(.sevenDays)
            let fm = RetentionPolicyFileManager(afterAuthorizedInventory: fixture.root) { policy.set(.never) }
            let removed = MeetingAudioStorageManager.pruneRetainedAudio(
                in: fixture.root, now: RetentionPolicyFixture.now, fileManager: fm,
                retentionWindowProvider: { policy.current }
            )
            assertTrue(fm.didInterleave, "the preference changed after one capture's deletion decision")
            assertEqual(removed, 1, "only the capture whose deletion was already authorized is removed")
            let remaining = [fixture.audio, secondAudio].filter { FileManager.default.fileExists(atPath: $0.path) }
            assertEqual(remaining.count, 1, "each remaining capture gets a fresh policy decision")
        } catch { assertTrue(false, "owned multi-capture fixture failed: \(error)") }
    }

    runSuite("An explicitly confirmed meeting purge keeps its chosen window") {
        for window in [AudioRetentionWindow.sevenDays, .never] {
            do {
                let fixture = try RetentionPolicyFixture()
                defer { fixture.close() }
                let policy = RetentionPolicyState(window == .sevenDays ? .never : .sevenDays)
                let removed = MeetingAudioStorageManager.pruneRetainedAudio(
                    in: fixture.root, retentionWindow: window, now: RetentionPolicyFixture.now,
                    retentionWindowProvider: { policy.current }
                )
                assertEqual(removed, window == .sevenDays ? 1 : 0, "the explicit API is the already-confirmed operation")
                assertEqual(policy.readCount, 0, "an explicit purge does not consult automatic policy")
            } catch { assertTrue(false, "owned explicit-purge fixture failed: \(error)") }
        }
    }
}

private struct RetentionPolicyFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    let root: URL
    let transcript: URL
    let audio: URL

    init(wav: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingRetentionPolicy-\(UUID().uuidString)", isDirectory: true)
        transcript = root.appendingPathComponent("Synthetic.md")
        audio = root.appendingPathComponent("audio/Synthetic_audio/\(wav ? "microphone.wav" : "recording.m4a")")
        _ = try addCapture(stem: "Synthetic", wav: wav)
    }

    func addCapture(stem: String, wav: Bool = false) throws -> URL {
        let directory = root.appendingPathComponent("audio/\(stem)_audio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: Self.now.addingTimeInterval(-20 * 86_400))
        let markdown = "---\ncapture_type: meeting\ntranscript_id: \"\(UUID().uuidString)\"\ndate: \"\(day)\"\ntime: \"12:00:00\"\n---\n\n## Full Transcript\n\nSynthetic words.\n"
        try markdown.write(to: root.appendingPathComponent("\(stem).md"), atomically: true, encoding: .utf8)
        let url = directory.appendingPathComponent(wav ? "microphone.wav" : "recording.m4a")
        try Data("synthetic fixture bytes".utf8).write(to: url)
        return url
    }

    func close() {
        guard root.lastPathComponent.hasPrefix("MeetingRetentionPolicy-"),
              root.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL else {
            preconditionFailure("refusing unowned fixture cleanup")
        }
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RetentionPolicyState: @unchecked Sendable {
    private let lock = NSLock()
    private var window: AudioRetentionWindow
    private var reads = 0
    init(_ window: AudioRetentionWindow) { self.window = window }
    var current: AudioRetentionWindow { lock.withLock { reads += 1; return window } }
    var readCount: Int { lock.withLock { reads } }
    func set(_ window: AudioRetentionWindow) { lock.withLock { self.window = window } }
}

private actor RetentionPolicySignal {
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if ready { return }; await withCheckedContinuation { waiters.append($0) } }
    func send() { ready = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

private struct RetentionPolicyConverter: MeetingAudioFileConverting {
    let began: RetentionPolicySignal
    let resume: RetentionPolicySignal
    func convertWAVToM4A(sourceURL: URL, destinationURL: URL) async throws {
        await began.send()
        await resume.wait()
        try Data("synthetic compressed bytes".utf8).write(to: destinationURL)
    }
}

private struct RetentionPolicyValidator: MeetingAudioFileValidating {
    func isUsableAudioFile(at url: URL, fileManager: FileManager) -> Bool { fileManager.fileExists(atPath: url.path) }
    func isCompleteReplacement(at url: URL, for sourceURL: URL, fileManager: FileManager) -> Bool { fileManager.fileExists(atPath: url.path) }
}

private struct RetentionPolicyMixer: MeetingAudioPlaybackMixing {
    func createPlaybackWAV(microphoneURL: URL, systemURL: URL, destinationURL: URL, fileManager: FileManager) async throws {
        preconditionFailure("single-track fixture must not mix")
    }
}

private final class RetentionPolicyFileManager: FileManager, @unchecked Sendable {
    private let inventory: URL?
    private let decisionRoot: URL?
    private let action: @Sendable () -> Void
    private let lock = NSLock()
    private var fired = false
    var didInterleave: Bool { lock.withLock { fired } }
    init(inventory: URL, action: @escaping @Sendable () -> Void) { self.inventory = inventory; decisionRoot = nil; self.action = action }
    init(afterAuthorizedInventory: URL, action: @escaping @Sendable () -> Void) { inventory = nil; decisionRoot = afterAuthorizedInventory; self.action = action }
    private func trigger() { if lock.withLock({ if fired { return false }; fired = true; return true }) { action() } }
    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        let entries = try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: options)
        if url.standardizedFileURL == inventory?.standardizedFileURL { trigger() }
        if let decisionRoot, url.lastPathComponent.hasSuffix("_audio"),
           url.resolvingSymlinksInPath().path.hasPrefix(decisionRoot.resolvingSymlinksInPath().path + "/") { trigger() }
        return entries
    }
}

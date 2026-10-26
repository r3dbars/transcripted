import Darwin
import Foundation

/// Write for Me (Developer Preview) only acts on its own key, never reads where Screen Memory won't,
/// scrubs what it reads, and leaves nothing running or embedding off this Mac.
func testNextSentenceGuards() {
    let fn = NextSentenceHotkey.fn
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    let fnDown = NextSentenceKeyGesture.Input.flagsChanged(keyCode: 63, flags: 0x80_0000)
    let fnUp = NextSentenceKeyGesture.Input.flagsChanged(keyCode: 63, flags: 0)
    let arrowDown = NextSentenceKeyGesture.Input.keyDown(keyCode: 123, flags: 0x80_0000)

    runSuite("Write for Me: ⌃⌥Space (the input-source shortcut) doesn't open it; only its own key does") {
        var gesture = NextSentenceKeyGesture()
        let controlOption = NextSentenceHotkey.control | NextSentenceHotkey.option
        let down = gesture.handle(.keyDown(keyCode: 49, flags: controlOption), key: fn, blocked: false, now: start)
        let up = gesture.handle(.keyUp(keyCode: 49, flags: controlOption), key: fn, blocked: false, now: start + 0.05)
        assertNil(down.event, "⌃⌥Space down does nothing")
        assertNil(up.event, "⌃⌥Space up does nothing")
        assertFalse(down.swallow || up.swallow, "macOS still gets ⌃⌥Space")

        let press = gesture.handle(fnDown, key: fn, blocked: false, now: start + 1)
        let release = gesture.handle(fnUp, key: fn, blocked: false, now: start + 1.1)
        assertNotNil(press.holdCheck, "a press of fn starts the hold check")
        assertEqual(release.event, .tap, "a quick tap of fn opens it")
    }

    runSuite("Write for Me: fn held on its own is push-to-talk, and letting go finishes it") {
        var gesture = NextSentenceKeyGesture()
        let token = gesture.handle(fnDown, key: fn, blocked: false, now: start).holdCheck ?? -1
        assertEqual(gesture.holdTimerFired(token), .holdStart, "still down past the tap limit, alone: a hold")
        assertEqual(gesture.handle(fnUp, key: fn, blocked: false, now: start + 2).event, .holdEnd, "letting go ends the hold")
    }

    runSuite("Write for Me: another key during a fn hold cancels it, so fn-arrow never sends") {
        var gesture = NextSentenceKeyGesture()
        let token = gesture.handle(fnDown, key: fn, blocked: false, now: start).holdCheck ?? -1
        assertEqual(gesture.holdTimerFired(token), .holdStart, "the hold began")
        assertEqual(gesture.handle(arrowDown, key: fn, blocked: false, now: start + 0.6).event, .holdCancel,
                    "an arrow while fn is held cancels the hold")
        assertNil(gesture.handle(fnUp, key: fn, blocked: false, now: start + 1).event,
                  "letting go after the cancel finishes nothing, so nothing is written or sent")

        var viaCard = NextSentenceKeyGesture()
        let cardToken = viaCard.handle(fnDown, key: fn, blocked: false, now: start).holdCheck ?? -1
        _ = viaCard.holdTimerFired(cardToken)
        assertEqual(viaCard.otherKeyWentDown(keyCode: 123, key: fn), .holdCancel, "a key the open card's tap took also cancels the hold")
        assertNil(viaCard.handle(fnUp, key: fn, blocked: false, now: start + 1).event, "and letting go does nothing")
    }

    runSuite("Write for Me: holding a function-key hotkey talks; its own auto-repeat never cancels it") {
        let f5 = NextSentenceHotkey(recorded: 96)!
        var gesture = NextSentenceKeyGesture()
        let token = gesture.handle(.keyDown(keyCode: 96, flags: 0), key: f5, blocked: false, now: start).holdCheck ?? -1
        assertEqual(gesture.holdTimerFired(token), .holdStart, "held past the tap limit: push-to-talk")
        let repeatOutcome = gesture.handle(.keyDown(keyCode: 96, flags: 0), key: f5, blocked: false, now: start + 0.5)
        assertNil(repeatOutcome.event, "an auto-repeat of F5 is the same key, not another")
        assertNil(gesture.otherKeyWentDown(keyCode: 96, key: f5), "nor when the open card's tap reports it")
        assertEqual(gesture.handle(.keyUp(keyCode: 96, flags: 0), key: f5, blocked: false, now: start + 2).event, .holdEnd,
                    "letting go finishes the hold")
        assertTrue(NextSentencePolicy.cardPassesThrough(keyCode: 96, hotkey: f5), "the open card leaves F5 to Write for Me's key")
        let optionD = NextSentenceHotkey(recorded: 2, modifiers: NextSentenceHotkey.option, label: "d")!
        assertFalse(NextSentencePolicy.cardPassesThrough(keyCode: 2, hotkey: optionD), "a plain d still types into the card")
        assertFalse(NextSentencePolicy.cardPassesThrough(keyCode: 123, hotkey: f5), "other keys still go to the card")
    }

    runSuite("Write for Me: fn-arrow before the hold begins is a shortcut, not a tap or a hold") {
        var gesture = NextSentenceKeyGesture()
        let token = gesture.handle(fnDown, key: fn, blocked: false, now: start).holdCheck ?? -1
        _ = gesture.handle(arrowDown, key: fn, blocked: false, now: start + 0.1)
        assertNil(gesture.holdTimerFired(token), "no hold starts after another key")
        assertNil(gesture.handle(fnUp, key: fn, blocked: false, now: start + 0.2).event, "and letting go isn't a tap")
    }

    runSuite("Write for Me: its key does nothing while dictation or meetings use the same key") {
        let suite = "NextSentenceGuardsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        PhysicalDictationTriggerPreferences.savePushToTalk(
            PhysicalDictationTriggerBinding(keyCode: 63, modifiers: PhysicalDictationTriggerModifiers.function),
            userDefaults: defaults
        )
        assertEqual(NextSentencePreferences.hotkeyClash(fn, userDefaults: defaults), "Dictation", "fn is the dictation key too")

        var gesture = NextSentenceKeyGesture()
        let press = gesture.handle(fnDown, key: fn, blocked: true, now: start)
        let release = gesture.handle(fnUp, key: fn, blocked: true, now: start + 0.1)
        assertNil(press.holdCheck, "a blocked press can't become a hold")
        assertNil(release.event, "a blocked tap doesn't open the card")

        let f5 = NextSentenceHotkey(recorded: 96)!
        let f5Press = gesture.handle(.keyDown(keyCode: 96, flags: 0), key: f5, blocked: true, now: start + 1)
        assertFalse(f5Press.swallow, "a blocked function key goes on to dictation")
    }

    runSuite("Write for Me won't read secure input, password managers, or apps excluded from Screen Memory") {
        func block(_ bundle: String?, secure: Bool = false, excluded: Set<String> = [], pid: pid_t? = 42) -> NextSentencePrivacy.Block? {
            NextSentencePrivacy.blockReason(processIdentifier: pid, bundleIdentifier: bundle, ownProcessIdentifier: 7,
                                            secureInput: secure, excludedApps: excluded)
        }
        assertNil(block("com.example.chat"), "an ordinary app is read")
        assertEqual(block("com.example.chat", secure: true), .secureInput, "a password field has the keyboard")
        assertEqual(block("com.example.chat", excluded: ["COM.EXAMPLE.CHAT"]), .excludedApp, "the person's own exclusion list counts")
        assertEqual(block("com.1password.1password"), .excludedApp, "password managers are always out")
        assertEqual(block("com.example.chat", pid: 7), .ownApp, "never Transcripted itself")
        assertEqual(block(nil, pid: nil), .noFrontmostApp, "nothing in front, nothing read")
    }

    runSuite("Write for Me scrubs secrets out of the draft and window text before anything is sent") {
        let key = "sk-ant-api03-" + String(repeating: "Ab3x", count: 12)
        let scrubbed = NextSentencePrivacy.scrub("Here's the key: \(key)\npassword: Tr0ub4dor&3xyz", appBundleIdentifier: "com.example.chat")
        assertFalse(scrubbed.contains(key), "an API key is taken out")
        assertFalse(scrubbed.contains("Tr0ub4dor&3xyz"), "a labeled password is taken out")
        assertTrue(scrubbed.contains("Here's the key"), "the rest of the text stays")
        assertEqual(NextSentencePrivacy.scrub("see you at 5", appBundleIdentifier: nil), "see you at 5", "plain words are untouched")
    }

    runSuite("Write for Me only embeds captures with a server on this Mac") {
        let suite = "NextSentenceGuardsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        assertEqual(NextSentencePreferences.embeddingURL(userDefaults: defaults)?.absoluteString, "http://127.0.0.1:8811", "the default is local")
        for local in ["http://localhost:9000", "http://[::1]:8811"] {
            defaults.set(local, forKey: NextSentencePreferences.embeddingURLKey)
            assertNotNil(NextSentencePreferences.embeddingURL(userDefaults: defaults), "\(local) is on this Mac")
        }
        for remote in ["https://embed.example.com", "http://10.0.0.5:8811", "http://127.0.0.1.example.com", "http://me:pw@127.0.0.1:8811", "file:///tmp/x"] {
            defaults.set(remote, forKey: NextSentencePreferences.embeddingURLKey)
            assertNil(NextSentencePreferences.embeddingURL(userDefaults: defaults), "\(remote) is refused, so nothing is sent there")
        }
    }

    runSuite("Write for Me waits before starting a failed embedding server again, so presses aren't held up") {
        assertTrue(NextSentencePolicy.mayLaunchEmbeddingServer(lastFailure: nil, now: start), "never failed: start it")
        assertFalse(NextSentencePolicy.mayLaunchEmbeddingServer(lastFailure: start, now: start + 30), "just failed: don't wait on it again")
        assertTrue(NextSentencePolicy.mayLaunchEmbeddingServer(lastFailure: start, now: start + NextSentencePolicy.embeddingRetryInterval),
                   "after the retry interval: try again")
    }

    runSuite("Write for Me's meaning index reads the capture library they moved, not the old one") {
        let suite = "NextSentenceGuardsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("ns-library-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: library)
        }
        defaults.set(library.path, forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
        let folders = NextSentenceSemanticIndex.captureDirectories(userDefaults: defaults)
        let root = library.standardizedFileURL.resolvingSymlinksInPath().path
        assertEqual(folders.map(\.kind), ["meeting", "dictation", "writing"], "all three kinds of capture")
        for folder in folders {
            assertTrue(folder.url.resolvingSymlinksInPath().path.hasPrefix(root + "/"), "\(folder.kind) is inside the moved library")
        }
    }

    runSuite("Write for Me only starts a claude or llama-server from settings that this user controls") {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("ns-exec-\(UUID().uuidString)", isDirectory: true)
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: folder) }
        func file(_ name: String, mode: Int) -> String {
            let url = folder.appendingPathComponent(name)
            manager.createFile(atPath: url.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: mode])
            return url.path
        }
        let claude = file("claude", mode: 0o755)
        assertEqual(NextSentenceExecutable.trusted(claude, named: "claude")?.path, claude, "their own claude runs")
        assertNil(NextSentenceExecutable.trusted(file("evil", mode: 0o755), named: "claude"), "another program's name is refused")
        assertNil(NextSentenceExecutable.trusted("bin/claude", named: "claude"), "a relative path is refused")
        let shared = folder.appendingPathComponent("shared", isDirectory: true)
        try? manager.createDirectory(at: shared, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let writable = shared.appendingPathComponent("llama-server").path
        manager.createFile(atPath: writable, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o777])
        _ = chmod(writable, 0o777) // the process umask strips group and other bits at create
        assertNil(NextSentenceExecutable.trusted(writable, named: "llama-server"), "a file anyone can rewrite is refused")
        let notExecutable = shared.appendingPathComponent("claude").path
        manager.createFile(atPath: notExecutable, contents: Data(), attributes: [.posixPermissions: 0o600])
        assertNil(NextSentenceExecutable.trusted(notExecutable, named: "claude"), "a file that isn't a program is refused")
        let link = folder.appendingPathComponent("links", isDirectory: true)
        try? manager.createDirectory(at: link, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let linked = link.appendingPathComponent("claude").path
        try? manager.createSymbolicLink(atPath: linked, withDestinationPath: claude)
        assertEqual(NextSentenceExecutable.trusted(linked, named: "claude")?.path, linked, "a link to their own claude runs")

        let suite = "NextSentenceGuardsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(file("other-tool", mode: 0o755), forKey: NextSentencePreferences.claudePathKey)
        assertNil(NextSentencePreferences.claudePathOverride(userDefaults: defaults), "a claude path naming another program is ignored")
        defaults.set(claude, forKey: NextSentencePreferences.claudePathKey)
        assertEqual(NextSentencePreferences.claudePathOverride(userDefaults: defaults), claude, "their own claude is used")
        defaults.set(writable, forKey: NextSentencePreferences.embeddingServerKey)
        defaults.set("/models/embeddinggemma.gguf", forKey: NextSentencePreferences.embeddingModelKey)
        assertNil(NextSentencePreferences.embeddingLaunch(userDefaults: defaults), "a rewritable llama-server is never started")
    }

    runSuite("Write for Me: stopping ends every Claude process, even one still starting") {
        let pool = NextSentenceWarmPool<String, FakeWarmProcess>(spawn: { _ in FakeWarmProcess() }, background: { FakeBackground.pending.append($0) })
        FakeBackground.pending = []
        let answering = pool.take("stream")
        assertNotNil(answering, "a request gets a process")
        assertEqual(FakeBackground.pending.count, 1, "the next one starts in the background")
        pool.stop()
        assertTrue(answering?.terminated == true, "the one answering is ended")
        let respawn = FakeWarmProcess.made.count
        FakeBackground.pending.forEach { $0() }
        assertEqual(FakeWarmProcess.made.count, respawn + 1, "the respawn that was under way finished starting")
        assertTrue(FakeWarmProcess.made.last?.terminated == true, "and was ended at once, not kept")
        assertEqual(pool.liveCount, 0, "nothing is left running")

        pool.prewarm(["stream", "swaps"])
        assertEqual(pool.liveCount, 2, "a later start (turning it back on) warms again")
        pool.stop()
        assertEqual(pool.liveCount, 0, "and stopping ends those too")
    }

    runSuite("Write for Me's embedding server stops when its tether closes") {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("ns-tether-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let helper = NextSentenceTetheredProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo $$ > '\(pidFile.path)'; exec /bin/sleep 300"]
        )
        do { try helper.start() } catch { return recordFailure("the helper didn't start: \(error)") }
        var pid: pid_t = 0
        for _ in 0..<200 where pid == 0 {
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
            if pid == 0 { Thread.sleep(forTimeInterval: 0.05) }
        }
        guard pid > 0 else { return recordFailure("the helper never wrote its pid") }
        defer { kill(pid, SIGKILL) }
        assertEqual(kill(pid, 0), 0, "the helper is running")
        helper.stop()
        var alive = true
        for _ in 0..<200 where alive {
            alive = kill(pid, 0) == 0
            if alive { Thread.sleep(forTimeInterval: 0.05) }
        }
        assertFalse(alive, "closing the tether ends the helper (as quitting or crashing does)")
    }

    runSuite("Write for Me's tethered helper reports when it exits on its own, so a dead server isn't waited on") {
        let helper = NextSentenceTetheredProcess(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        do { try helper.start() } catch { return recordFailure("the helper didn't start: \(error)") }
        defer { helper.stop() }
        for _ in 0..<200 where helper.isRunning { Thread.sleep(forTimeInterval: 0.05) }
        assertFalse(helper.isRunning, "a helper that exited leaves nothing running, so the index knows it's gone")
    }
}

private final class FakeWarmProcess: NextSentenceWarmProcess, @unchecked Sendable {
    nonisolated(unsafe) static var made: [FakeWarmProcess] = []
    var terminated = false
    var isRunning: Bool { !terminated }
    init() { Self.made.append(self) }
    func terminate() { terminated = true }
}

private enum FakeBackground {
    nonisolated(unsafe) static var pending: [@Sendable () -> Void] = []
}

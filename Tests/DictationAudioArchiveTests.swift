// DictationAudioArchiveTests.swift
// Kept dictation audio: the Audio: line, the archive (keep, resolve, prune,
// compress), the save-then-retire rule, the setting, and library relocation.
// Everything runs against fresh temp folders; nothing touches the real library.

import Foundation

func testDictationAudioArchive() async {
    let fm = FileManager.default

    func makeRoot(_ label: String) -> URL {
        fm.temporaryDirectory.appendingPathComponent(
            "DictationAudioArchiveTests-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    func makeRecovery(in root: URL, sessionID: UUID = UUID()) -> DictationStoppedAudioRecovery? {
        try? DictationStoppedAudioRecoveryStore.persist(
            samples16k: [0.1, -0.1, 0.2],
            sessionID: sessionID,
            directory: root.appendingPathComponent("recovery", isDirectory: true)
        )
    }

    func write(_ text: String, to url: URL) {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
    }

    func age(_ url: URL, days: Double, from now: Date) {
        let date = now.addingTimeInterval(-days * 86_400)
        try? fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }

    func savedResult(_ url: URL) -> DictationTranscriptPersistenceResult {
        DictationTranscriptPersistenceResult.measure { SavedDictationTranscript(url: url, title: "Synthetic") }
    }

    func failedResult() -> DictationTranscriptPersistenceResult {
        DictationTranscriptPersistenceResult.measure { throw CocoaError(.fileWriteNoPermission) }
    }

    // MARK: Writer and reader

    runSuite("A saved dictation records its Audio path only when audio is kept") {
        let root = makeRoot("writer")
        defer { try? fm.removeItem(at: root) }
        let createdAt = Date(timeIntervalSince1970: 1_790_000_000)

        let withAudio = try? DictationTranscriptWriter.save(
            text: "note with audio kept",
            sourceAppName: "Notes",
            sourceBundleID: "com.apple.Notes",
            delivery: .pasted,
            createdAt: createdAt,
            directory: root.appendingPathComponent("with", isDirectory: true),
            audioRelativePath: "audio/8c1f3a52-6a1e-4c55-9f0b-2d3b1c4e5f60.m4a"
        )
        let withoutAudio = try? DictationTranscriptWriter.save(
            text: "note with audio kept",
            sourceAppName: "Notes",
            sourceBundleID: "com.apple.Notes",
            delivery: .pasted,
            createdAt: createdAt,
            directory: root.appendingPathComponent("without", isDirectory: true)
        )

        let kept = withAudio.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } ?? ""
        let plain = withoutAudio.flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } ?? ""
        assertTrue(
            kept.contains("Characters: 20\nAudio: `audio/8c1f3a52-6a1e-4c55-9f0b-2d3b1c4e5f60.m4a`\n\nnote with audio kept"),
            "the Audio line follows Characters, then the text after a blank line"
        )
        assertFalse(plain.contains("Audio:"), "no kept audio means no Audio line")
        assertTrue(
            plain.contains("Characters: 20\n\nnote with audio kept"),
            "without kept audio the section keeps its old shape"
        )
        let strip: (String) -> String = { text in
            text.components(separatedBy: "\n")
                .filter { !$0.hasPrefix("Audio:") && !$0.hasPrefix("Entry ID:") }
                .joined(separator: "\n")
        }
        assertEqual(strip(kept), strip(plain), "the Audio line is the only difference")
    }

    runSuite("Reading a day file returns each entry's Audio path, and nil for older entries") {
        let root = makeRoot("reader")
        defer { try? fm.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try? DictationTranscriptStore.save(
            text: "older entry without audio",
            sourceApp: nil,
            delivery: .pasted,
            createdAt: base,
            directory: root
        )
        _ = try? DictationTranscriptStore.save(
            text: "newer entry with audio",
            sourceApp: nil,
            delivery: .pasted,
            createdAt: base.addingTimeInterval(60),
            directory: root,
            audioRelativePath: "audio/0b7c2d1e-1111-4222-8333-944455556666.m4a"
        )

        let entries = DictationTranscriptStore.recentSavedDictations(limit: 5, directory: root)
        assertEqual(entries.count, 2)
        assertEqual(entries.first?.text, "newer entry with audio", "the Audio line is not body text")
        assertEqual(entries.first?.audioRelativePath, "audio/0b7c2d1e-1111-4222-8333-944455556666.m4a")
        assertNil(entries.last?.audioRelativePath ?? nil, "an entry saved without audio has no path")

        if let withAudio = entries.first {
            assertTrue((try? DictationTranscriptStore.deleteEntry(withAudio)) != nil, "an entry with an Audio line can still be deleted")
            let left = DictationTranscriptStore.recentSavedDictations(limit: 5, directory: root)
            assertEqual(left.map(\.text), ["older entry without audio"], "deleting it leaves the other entry")
        }
    }

    runSuite("Once a dictation's delete is final, its kept audio goes, and only its own") {
        let root = makeRoot("delete")
        defer { try? fm.removeItem(at: root) }
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        let mine = UUID().uuidString.lowercased()
        let other = UUID().uuidString.lowercased()
        let audio = DictationAudioArchive.audioFolder(in: root)
        write("m4a", to: audio.appendingPathComponent("\(mine).m4a"))
        write("wav", to: audio.appendingPathComponent("\(mine).wav"))
        write("m4a", to: audio.appendingPathComponent("\(other).m4a"))
        _ = try? DictationTranscriptStore.save(
            text: "the one to delete", sourceApp: nil, delivery: .pasted,
            createdAt: base, directory: root, audioRelativePath: "audio/\(mine).m4a"
        )
        _ = try? DictationTranscriptStore.save(
            text: "the one to keep", sourceApp: nil, delivery: .pasted,
            createdAt: base.addingTimeInterval(60), directory: root, audioRelativePath: "audio/\(other).m4a"
        )
        guard let doomed = DictationTranscriptStore.recentSavedDictations(limit: 5, directory: root)
            .first(where: { $0.text == "the one to delete" }) else { return assertTrue(false, "entry saved") }

        assertTrue((try? DictationTranscriptStore.deleteEntryReversibly(doomed)) != nil)
        assertEqual(
            ((try? fm.contentsOfDirectory(atPath: audio.path)) ?? []).count,
            3,
            "the undo window keeps the audio so Undo can bring the entry back whole"
        )
        DictationAudioArchive.deleteKeptAudio(for: doomed)
        assertEqual(
            Set((try? fm.contentsOfDirectory(atPath: audio.path)) ?? []),
            ["\(other).m4a"],
            "the deleted entry's M4A and WAV are gone; the other take's audio stays"
        )
    }

    // MARK: Keep and resolve

    runSuite("Keeping a take moves its WAV into the audio folder and drops the recovery reminder") {
        let root = makeRoot("keep")
        defer { try? fm.removeItem(at: root) }
        let dictations = root.appendingPathComponent("dictations", isDirectory: true)
        guard let recovery = makeRecovery(in: root) else { return assertTrue(false, "recovery WAV should persist") }
        let path = DictationAudioArchive.relativePath(for: recovery.sessionID)

        let kept = DictationAudioArchive.keep(recovery: recovery, relativePath: path, dictationsFolder: dictations)

        assertNotNil(kept, "keep returns the kept file")
        assertFalse(fm.fileExists(atPath: recovery.url.path), "the recovery WAV moved out")
        assertTrue(
            DictationStoppedAudioRecoveryStore.pendingRecoveries(directory: recovery.url.deletingLastPathComponent()).isEmpty,
            "the launch reminder no longer offers a kept take"
        )
        assertEqual(
            DictationAudioArchive.resolveURL(relativePath: path, dictationsFolder: dictations)?.lastPathComponent,
            "\(recovery.sessionID.uuidString.lowercased()).wav",
            "before compression the WAV resolves"
        )
        if let kept {
            let permissions = (try? fm.attributesOfItem(atPath: kept.path))?[.posixPermissions] as? NSNumber
            assertEqual(permissions?.intValue, 0o600, "kept audio is owner-only")
        }
    }

    runSuite("Resolving kept audio prefers the M4A, falls back to the WAV, and is nil once it's gone") {
        let root = makeRoot("resolve")
        defer { try? fm.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let audio = DictationAudioArchive.audioFolder(in: root)
        let path = "audio/\(id).m4a"

        assertNil(DictationAudioArchive.resolveURL(relativePath: path, dictationsFolder: root), "nothing kept yet")
        write("wav", to: audio.appendingPathComponent("\(id).wav"))
        assertEqual(DictationAudioArchive.resolveURL(relativePath: path, dictationsFolder: root)?.lastPathComponent, "\(id).wav")
        write("m4a", to: audio.appendingPathComponent("\(id).m4a"))
        assertEqual(DictationAudioArchive.resolveURL(relativePath: path, dictationsFolder: root)?.lastPathComponent, "\(id).m4a")
    }

    runSuite("Resolving never leaves the audio folder") {
        let root = makeRoot("escape")
        defer { try? fm.removeItem(at: root) }
        let dictations = root.appendingPathComponent("dictations", isDirectory: true)
        let id = UUID().uuidString.lowercased()
        let outside = root.appendingPathComponent("\(id).m4a")
        write("secret", to: outside)
        write("nested", to: dictations.appendingPathComponent("audio/sub/\(id).m4a"))

        for bad in [
            "../\(id).m4a",
            "audio/../../\(id).m4a",
            outside.path,
            "audio/sub/\(id).m4a",
            "audio/notes.m4a",
            "audio/\(id).txt",
            "meetings/\(id).m4a",
        ] {
            assertNil(DictationAudioArchive.resolveURL(relativePath: bad, dictationsFolder: dictations), "rejects \(bad)")
        }

        let link = DictationAudioArchive.audioFolder(in: dictations).appendingPathComponent("\(id).m4a")
        try? fm.createSymbolicLink(at: link, withDestinationURL: outside)
        assertNil(
            DictationAudioArchive.resolveURL(relativePath: "audio/\(id).m4a", dictationsFolder: dictations),
            "a symlink in the audio folder does not resolve"
        )

        let linkedRoot = makeRoot("escape-linked")
        defer { try? fm.removeItem(at: linkedRoot) }
        try? fm.createDirectory(at: linkedRoot, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(
            at: DictationAudioArchive.audioFolder(in: linkedRoot),
            withDestinationURL: root
        )
        assertNil(
            DictationAudioArchive.resolveURL(relativePath: "audio/\(id).m4a", dictationsFolder: linkedRoot),
            "a symlinked audio folder does not resolve"
        )
    }

    // MARK: Prune

    runSuite("Pruning deletes only kept audio older than the window") {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for window in DictationAudioKeepWindow.allCases {
            let root = makeRoot("prune-\(window.rawValue)")
            defer { try? fm.removeItem(at: root) }
            let audio = DictationAudioArchive.audioFolder(in: root)
            let fresh = audio.appendingPathComponent("\(UUID().uuidString.lowercased()).m4a")
            let tenDays = audio.appendingPathComponent("\(UUID().uuidString.lowercased()).wav")
            let fortyDays = audio.appendingPathComponent("\(UUID().uuidString.lowercased()).m4a")
            let foreign = audio.appendingPathComponent("notes.m4a")
            for url in [fresh, tenDays, fortyDays, foreign] { write("x", to: url) }
            age(fresh, days: 1, from: now)
            age(tenDays, days: 10, from: now)
            age(fortyDays, days: 40, from: now)
            age(foreign, days: 400, from: now)

            DictationAudioArchive.prune(window: window, now: now, dictationsFolder: root)

            let left = Set(((try? fm.contentsOfDirectory(atPath: audio.path)) ?? []))
            let expected: Set<String>
            switch window {
            case .off: expected = [foreign.lastPathComponent]
            case .sevenDays: expected = [fresh.lastPathComponent, foreign.lastPathComponent]
            case .thirtyDays: expected = [fresh.lastPathComponent, tenDays.lastPathComponent, foreign.lastPathComponent]
            case .forever: expected = Set([fresh, tenDays, fortyDays, foreign].map(\.lastPathComponent))
            }
            assertEqual(left, expected, "\(window.rawValue) keeps the right files and never touches foreign ones")
        }
    }

    runSuite("Pruning never follows a symlink") {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let root = makeRoot("prune-links")
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("elsewhere/\(UUID().uuidString.lowercased()).m4a")
        write("keep me", to: target)
        age(target, days: 100, from: now)
        let audio = DictationAudioArchive.audioFolder(in: root.appendingPathComponent("dictations", isDirectory: true))
        try? fm.createDirectory(at: audio, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: audio.appendingPathComponent(target.lastPathComponent), withDestinationURL: target)

        DictationAudioArchive.prune(window: .off, now: now, dictationsFolder: root.appendingPathComponent("dictations"))
        assertTrue(fm.fileExists(atPath: target.path), "a symlinked file's target survives")

        let linkedDictations = root.appendingPathComponent("linked-dictations", isDirectory: true)
        try? fm.createDirectory(at: linkedDictations, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(
            at: DictationAudioArchive.audioFolder(in: linkedDictations),
            withDestinationURL: target.deletingLastPathComponent()
        )
        assertEqual(
            DictationAudioArchive.prune(window: .off, now: now, dictationsFolder: linkedDictations),
            0,
            "a symlinked audio folder is not pruned"
        )
        assertTrue(fm.fileExists(atPath: target.path), "files behind a symlinked folder survive")
    }

    // MARK: Compress

    await runSuite("Compressing swaps the WAV for an M4A only when the M4A is good") {
        let root = makeRoot("compress")
        defer { try? fm.removeItem(at: root) }
        let audio = DictationAudioArchive.audioFolder(in: root)
        let id = UUID().uuidString.lowercased()
        let wav = audio.appendingPathComponent("\(id).wav")
        let m4a = audio.appendingPathComponent("\(id).m4a")

        write("wav", to: wav)
        let ok = await DictationAudioArchive.compress(
            wav,
            convert: { _, destination in try Data("aac".utf8).write(to: destination) },
            isUsable: { _, _ in true }
        )
        assertTrue(ok)
        assertTrue(fm.fileExists(atPath: m4a.path), "the M4A is in place")
        assertFalse(fm.fileExists(atPath: wav.path), "the WAV is gone after a good M4A")

        try? fm.removeItem(at: m4a)
        write("wav", to: wav)
        let failedConvert = await DictationAudioArchive.compress(
            wav,
            convert: { _, _ in throw CocoaError(.fileWriteUnknown) },
            isUsable: { _, _ in true }
        )
        let emptyOutput = await DictationAudioArchive.compress(
            wav,
            convert: { _, destination in try Data().write(to: destination) },
            isUsable: { _, _ in true }
        )
        let badOutput = await DictationAudioArchive.compress(
            wav,
            convert: { _, destination in try Data("junk".utf8).write(to: destination) },
            isUsable: { _, _ in false }
        )
        assertFalse(failedConvert || emptyOutput || badOutput, "a failed, empty, or unusable export is not a replacement")
        assertTrue(fm.fileExists(atPath: wav.path), "the WAV stays when compression fails")
        assertEqual(
            (try? fm.contentsOfDirectory(atPath: audio.path)) ?? [],
            ["\(id).wav"],
            "no M4A or temp file is left behind"
        )
    }

    await runSuite("A real kept WAV compresses to a playable M4A of the same length") {
        let root = makeRoot("compress-real")
        defer { try? fm.removeItem(at: root) }
        let samples = (0..<16_000).map { Float(sin(Double($0) * 0.05)) * 0.3 }
        guard let recovery = try? DictationStoppedAudioRecoveryStore.persist(
            samples16k: samples,
            sessionID: UUID(),
            directory: root.appendingPathComponent("recovery", isDirectory: true)
        ),
            let wav = DictationAudioArchive.keep(
                recovery: recovery,
                relativePath: DictationAudioArchive.relativePath(for: recovery.sessionID),
                dictationsFolder: root
            ) else { return assertTrue(false, "a one-second take should be kept") }

        let ok = await DictationAudioArchive.compress(wav)
        assertTrue(ok, "AVFoundation exports the take")
        let resolved = DictationAudioArchive.resolveURL(
            relativePath: DictationAudioArchive.relativePath(for: recovery.sessionID),
            dictationsFolder: root
        )
        assertEqual(resolved?.pathExtension, "m4a", "the entry's path now resolves to the M4A")
        assertFalse(fm.fileExists(atPath: wav.path), "the WAV is gone")
    }

    // MARK: Save, then retire

    runSuite("A saved take keeps its audio when the setting is on, and drops it when off") {
        for window in [DictationAudioKeepWindow.thirtyDays, .off] {
            let root = makeRoot("retire-\(window.rawValue)")
            defer { try? fm.removeItem(at: root) }
            let dictations = root.appendingPathComponent("dictations", isDirectory: true)
            guard let recovery = makeRecovery(in: root) else { return assertTrue(false, "recovery WAV should persist") }
            var compressed: [URL] = []

            let result = DictationStoppedAudioRecoveryStore.saveTranscriptAndRetire(
                recovery: recovery,
                keepWindow: window,
                dictationsFolder: dictations,
                compressKeptAudio: { compressed.append($0) }
            ) { audioPath in
                try DictationTranscriptWriter.save(
                    text: "a finished take",
                    sourceAppName: "Notes",
                    sourceBundleID: nil,
                    delivery: .pasted,
                    directory: dictations,
                    audioRelativePath: audioPath
                )
            }

            assertNotNil(result.saved, "the transcript saved")
            assertFalse(fm.fileExists(atPath: recovery.url.path), "a saved take leaves recovery either way")
            let entry = DictationTranscriptStore.latestSavedDictation(directory: dictations)
            if window == .off {
                assertNil(entry?.audioRelativePath ?? nil, "Don't keep writes no Audio line")
                assertTrue(compressed.isEmpty, "nothing to compress")
                assertFalse(fm.fileExists(atPath: DictationAudioArchive.audioFolder(in: dictations).path), "no audio folder")
            } else {
                let path = entry?.audioRelativePath ?? ""
                assertEqual(path, DictationAudioArchive.relativePath(for: recovery.sessionID), "the entry points at its audio")
                let resolved = DictationAudioArchive.resolveURL(relativePath: path, dictationsFolder: dictations)
                assertNotNil(resolved, "the kept audio resolves from the entry's path")
                assertEqual(compressed, resolved.map { [$0] } ?? [], "the kept WAV is handed to compression once")
            }
        }
    }

    runSuite("A failed save keeps the recovery WAV whatever the setting") {
        for window in DictationAudioKeepWindow.allCases {
            let root = makeRoot("retire-failed-\(window.rawValue)")
            defer { try? fm.removeItem(at: root) }
            let dictations = root.appendingPathComponent("dictations", isDirectory: true)
            guard let recovery = makeRecovery(in: root) else { return assertTrue(false, "recovery WAV should persist") }

            let retired = DictationStoppedAudioRecoveryStore.retire(
                recovery,
                afterSaving: failedResult(),
                keptAudioRelativePath: DictationAudioArchive.plannedRelativePath(for: recovery, window: window),
                dictationsFolder: dictations,
                compressKeptAudio: { _ in }
            )

            assertFalse(retired)
            assertTrue(fm.fileExists(atPath: recovery.url.path), "\(window.rawValue): the WAV stays in recovery")
            assertEqual(
                DictationStoppedAudioRecoveryStore.pendingRecoveries(directory: recovery.url.deletingLastPathComponent()).count,
                1,
                "\(window.rawValue): the take can still be recovered"
            )
            assertFalse(fm.fileExists(atPath: DictationAudioArchive.audioFolder(in: dictations).path), "nothing archived")
        }
    }

    runSuite("A saved take without a kept path is deleted as before") {
        let root = makeRoot("retire-plain")
        defer { try? fm.removeItem(at: root) }
        guard let recovery = makeRecovery(in: root) else { return assertTrue(false, "recovery WAV should persist") }
        let retired = DictationStoppedAudioRecoveryStore.retire(
            recovery,
            afterSaving: savedResult(root.appendingPathComponent("day.md")),
            compressKeptAudio: { _ in assertTrue(false, "nothing kept, nothing compressed") }
        )
        assertTrue(retired)
        assertFalse(fm.fileExists(atPath: recovery.url.path), "the WAV is deleted")
    }

    // MARK: Setting

    runSuite("Dictation audio is kept for 30 days unless the user picks otherwise") {
        let suite = "DictationAudioArchiveTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return assertTrue(false, "suite defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }

        assertEqual(AudioStoragePreferences.dictationAudioKeepWindow(userDefaults: defaults), .thirtyDays)
        AudioStoragePreferences.setDictationAudioKeepWindow(.forever, userDefaults: defaults)
        assertEqual(AudioStoragePreferences.dictationAudioKeepWindow(userDefaults: defaults), .forever)
        assertEqual(
            AudioStoragePreferences.deleteAudioAfter(userDefaults: defaults),
            .never,
            "the dictation setting does not change the meeting one"
        )
        assertEqual(DictationAudioKeepWindow.allCases.map(\.title), ["Don't keep", "7 days", "30 days", "Forever"])
    }

    runSuite("Only a shorter window or Don't keep asks before deleting kept audio") {
        assertTrue(DictationAudioKeepWindow.thirtyDays.deletesKeptAudio(switchingTo: .sevenDays))
        assertTrue(DictationAudioKeepWindow.thirtyDays.deletesKeptAudio(switchingTo: .off))
        assertTrue(DictationAudioKeepWindow.forever.deletesKeptAudio(switchingTo: .thirtyDays))
        assertFalse(DictationAudioKeepWindow.sevenDays.deletesKeptAudio(switchingTo: .thirtyDays))
        assertFalse(DictationAudioKeepWindow.thirtyDays.deletesKeptAudio(switchingTo: .forever))
        assertFalse(DictationAudioKeepWindow.off.deletesKeptAudio(switchingTo: .sevenDays))
    }

    // MARK: Library relocation

    runSuite("Moving the capture library brings kept dictation audio along") {
        let source = makeRoot("relocate-from")
        let destination = makeRoot("relocate-to")
        defer {
            try? fm.removeItem(at: source)
            try? fm.removeItem(at: destination)
        }
        let id = UUID().uuidString.lowercased()
        let sourceDictations = source.appendingPathComponent("dictations", isDirectory: true)
        write("day", to: sourceDictations.appendingPathComponent("Dictations_2026-10-05.md"))
        write("aac", to: DictationAudioArchive.audioFolder(in: sourceDictations).appendingPathComponent("\(id).m4a"))

        let planner = CaptureLibraryMigrationPlanner()
        let plan = planner.makePlan(from: source, to: destination)
        _ = try? planner.copy(plan)

        let destinationDictations = destination.appendingPathComponent("dictations", isDirectory: true)
        assertNotNil(
            DictationAudioArchive.resolveURL(relativePath: "audio/\(id).m4a", dictationsFolder: destinationDictations),
            "the day file's relative Audio path resolves in the new library"
        )
    }

    runSuite("Moving the library leaves audio behind when its day file stays behind") {
        let source = makeRoot("collide-from")
        let destination = makeRoot("collide-to")
        defer {
            try? fm.removeItem(at: source)
            try? fm.removeItem(at: destination)
        }
        let staying = UUID().uuidString.lowercased()
        let moving = UUID().uuidString.lowercased()
        let sourceDictations = source.appendingPathComponent("dictations", isDirectory: true)
        let sourceAudio = DictationAudioArchive.audioFolder(in: sourceDictations)
        write("## 9:15 AM - note\n\nEntry ID: `dictation-1`\nAudio: `audio/\(staying).m4a`\n\nnote\n",
              to: sourceDictations.appendingPathComponent("Dictations_2026-10-05.md"))
        write("## 9:15 AM - note\n\nEntry ID: `dictation-2`\nAudio: `audio/\(moving).m4a`\n\nnote\n",
              to: sourceDictations.appendingPathComponent("Dictations_2026-10-06.md"))
        write("other day", to: destination.appendingPathComponent("dictations/Dictations_2026-10-05.md"))
        write("aac", to: sourceAudio.appendingPathComponent("\(staying).m4a"))
        write("aac", to: sourceAudio.appendingPathComponent("\(moving).m4a"))

        let planner = CaptureLibraryMigrationPlanner()
        let plan = planner.makePlan(from: source, to: destination)
        let copied = (try? planner.copy(plan))?.copiedItems ?? []
        _ = planner.removeOriginals(of: copied)

        assertNotNil(
            DictationAudioArchive.resolveURL(relativePath: "audio/\(staying).m4a", dictationsFolder: sourceDictations),
            "audio named by the day file that stayed behind is still next to it"
        )
        assertNotNil(
            DictationAudioArchive.resolveURL(
                relativePath: "audio/\(moving).m4a",
                dictationsFolder: destination.appendingPathComponent("dictations", isDirectory: true)
            ),
            "audio named by a moved day file moved with it"
        )
    }
}

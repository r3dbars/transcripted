import Foundation
import Security

func testLegacyWritingDataCleanup() {
    runSuite("LegacyWritingDataCleanup removes legacy folders and Keychain items while keeping active writing files") {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("LegacyWritingDataCleanupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let appSupport = tempRoot.appendingPathComponent("Transcripted", isDirectory: true)
        let personalHistory = appSupport.appendingPathComponent("writing/Personal History", isDirectory: true)
        let outcomeLedger = appSupport.appendingPathComponent("writing/Outcome Ledger", isDirectory: true)
        let wordDiary = appSupport.appendingPathComponent("writing/Word Diary", isDirectory: true)
        let nextSentence = appSupport.appendingPathComponent("next-sentence", isDirectory: true)
        let pendingEntries = appSupport.appendingPathComponent("writing/Pending Entries", isDirectory: true)
        let capturesWriting = appSupport.appendingPathComponent("captures/writing", isDirectory: true)

        for dir in [personalHistory, outcomeLedger, wordDiary, nextSentence, pendingEntries, capturesWriting] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? Data("encrypted".utf8).write(to: personalHistory.appendingPathComponent("history.enc"))
        try? Data("events".utf8).write(to: outcomeLedger.appendingPathComponent("events.jsonl"))
        try? Data("diary".utf8).write(to: wordDiary.appendingPathComponent("diary.json"))
        try? Data("embeddings".utf8).write(to: nextSentence.appendingPathComponent("embeddings-256.json"))
        let pendingFile = pendingEntries.appendingPathComponent("pending-writing.json")
        try? Data("{}".utf8).write(to: pendingFile)
        let dayFile = capturesWriting.appendingPathComponent("Writing_2026-11-26.md")
        try? Data("# Writing\n\nhello\n".utf8).write(to: dayFile)

        var deletedServices: [String] = []
        var deletedAccounts: [String] = []
        var deletedClasses: [String] = []
        var deletedSyncFlags: [Bool] = []

        let result = LegacyWritingDataCleanup.cleanUp(
            appSupportRoot: appSupport,
            fileManager: fm,
            deleteKeychainItem: { query in
                if let cls = query[kSecClass] as? String { deletedClasses.append(cls) }
                if let service = query[kSecAttrService] as? String { deletedServices.append(service) }
                if let account = query[kSecAttrAccount] as? String { deletedAccounts.append(account) }
                if let sync = query[kSecAttrSynchronizable] as? Bool { deletedSyncFlags.append(sync) }
                return (query[kSecAttrService] as? String) == "com.justinbetker.draft.writing.personal-history"
                    ? errSecSuccess
                    : errSecItemNotFound
            }
        )

        assertTrue(result.succeeded, "cleanup should succeed on real legacy directories")
        assertEqual(
            Set(result.removedRelativePaths),
            Set(LegacyWritingDataCleanup.legacyRelativePaths),
            "every legacy directory should be reported removed"
        )
        assertEqual(result.refusedUnsafePaths, [], "no safe paths should be refused")
        assertEqual(result.failedRelativePaths, [], "no removals should fail")
        assertEqual(result.keychainItemsDeleted, 1, "production keychain key deletion should be counted")
        assertFalse(result.keychainDeleteFailed, "errSecItemNotFound for preview key is not a failure")

        assertFalse(fm.fileExists(atPath: personalHistory.path), "Personal History folder should be deleted")
        assertFalse(fm.fileExists(atPath: outcomeLedger.path), "Outcome Ledger folder should be deleted")
        assertFalse(fm.fileExists(atPath: wordDiary.path), "Word Diary folder should be deleted")
        assertFalse(fm.fileExists(atPath: nextSentence.path), "next-sentence folder should be deleted")
        assertTrue(fm.fileExists(atPath: pendingFile.path), "active Pending Entries recovery journal must stay untouched")
        assertTrue(fm.fileExists(atPath: dayFile.path), "captures/writing day files must stay untouched during launch cleanup")

        assertEqual(
            deletedServices,
            [
                "com.justinbetker.draft.writing.personal-history",
                "com.justinbetker.draft.preview9b.writing.personal-history",
            ],
            "cleanup must query exact production and preview Personal History keychain services"
        )
        assertEqual(deletedAccounts, ["aes-gcm-key-v1", "aes-gcm-key-v1"], "cleanup must match exact keychain account")
        assertEqual(
            deletedClasses,
            [kSecClassGenericPassword as String, kSecClassGenericPassword as String],
            "cleanup must delete generic password items"
        )
        assertEqual(deletedSyncFlags, [false, false], "cleanup must match non-synchronizable local key")
    }

    runSuite("LegacyWritingDataCleanup refuses symlinks and out-of-root paths") {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("LegacyWritingDataCleanupSafety-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let appSupport = tempRoot.appendingPathComponent("Transcripted", isDirectory: true)
        let outsideTarget = tempRoot.appendingPathComponent("OutsideTarget", isDirectory: true)
        let outsideFile = outsideTarget.appendingPathComponent("precious.txt")
        let writingDir = appSupport.appendingPathComponent("writing", isDirectory: true)
        try? fm.createDirectory(at: writingDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: outsideTarget, withIntermediateDirectories: true)
        try? Data("keep me".utf8).write(to: outsideFile)

        // Leaf symlink pointing outside root
        let leafLink = writingDir.appendingPathComponent("Personal History")
        try? fm.createSymbolicLink(at: leafLink, withDestinationURL: outsideTarget)

        // Dangling leaf symlink
        let danglingLink = appSupport.appendingPathComponent("next-sentence")
        try? fm.createSymbolicLink(
            at: danglingLink,
            withDestinationURL: tempRoot.appendingPathComponent("does-not-exist")
        )

        let result = LegacyWritingDataCleanup.cleanUp(
            appSupportRoot: appSupport,
            relativePaths: [
                "writing/Personal History",
                "next-sentence",
                "../OutsideTarget",
                outsideTarget.path,
            ],
            fileManager: fm,
            deleteKeychainItem: { _ in errSecItemNotFound }
        )

        assertFalse(result.succeeded, "unsafe paths should be reported as refused")
        assertEqual(result.removedRelativePaths, [], "no unsafe targets may be deleted")
        assertEqual(
            Set(result.refusedUnsafePaths),
            Set(["writing/Personal History", "next-sentence", "../OutsideTarget", outsideTarget.path]),
            "symlinks, dangling symlinks, parent traversal, and absolute paths must all be refused"
        )
        assertTrue(fm.fileExists(atPath: outsideFile.path), "symlink target outside appSupportRoot must remain intact")
        assertTrue(
            (try? fm.destinationOfSymbolicLink(atPath: leafLink.path)) != nil,
            "refused symlink itself must be left untouched"
        )
        assertTrue(
            (try? fm.destinationOfSymbolicLink(atPath: danglingLink.path)) != nil,
            "refused dangling symlink must be left untouched"
        )
    }

    runSuite("LegacyWritingDataCleanup refuses symlinked intermediate directory and symlinked root") {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("LegacyWritingDataCleanupRootLink-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let outside = tempRoot.appendingPathComponent("Outside", isDirectory: true)
        let outsidePH = outside.appendingPathComponent("Personal History", isDirectory: true)
        try? fm.createDirectory(at: outsidePH, withIntermediateDirectories: true)
        let outsideFile = outsidePH.appendingPathComponent("keep.dat")
        try? Data("keep".utf8).write(to: outsideFile)

        // Intermediate symlink: Transcripted/writing -> Outside
        let appSupport = tempRoot.appendingPathComponent("Transcripted", isDirectory: true)
        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let writingLink = appSupport.appendingPathComponent("writing")
        try? fm.createSymbolicLink(at: writingLink, withDestinationURL: outside)

        let intermediateResult = LegacyWritingDataCleanup.cleanUp(
            appSupportRoot: appSupport,
            relativePaths: ["writing/Personal History"],
            fileManager: fm,
            deleteKeychainItem: { _ in errSecItemNotFound }
        )
        assertEqual(intermediateResult.refusedUnsafePaths, ["writing/Personal History"], "symlinked intermediate folder must be refused")
        assertTrue(fm.fileExists(atPath: outsideFile.path), "files behind symlinked intermediate folder must stay untouched")

        // Symlinked appSupportRoot itself
        let linkedRoot = tempRoot.appendingPathComponent("LinkedSupport")
        try? fm.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
        let rootLinkResult = LegacyWritingDataCleanup.cleanUp(
            appSupportRoot: linkedRoot,
            relativePaths: ["Personal History"],
            fileManager: fm,
            deleteKeychainItem: { _ in errSecItemNotFound }
        )
        assertEqual(rootLinkResult.refusedUnsafePaths, ["Personal History"], "symlinked appSupportRoot must refuse all paths")
        assertTrue(fm.fileExists(atPath: outsideFile.path), "files behind symlinked root must stay untouched")
    }

    runSuite("LegacyWritingDataCleanup is a clean no-op on missing root and surfaces keychain errors") {
        let fm = FileManager.default
        let missingRoot = fm.temporaryDirectory
            .appendingPathComponent("LegacyWritingDataCleanupMissing-\(UUID().uuidString)", isDirectory: true)

        let clean = LegacyWritingDataCleanup.cleanUp(
            appSupportRoot: missingRoot,
            fileManager: fm,
            deleteKeychainItem: { _ in errSecItemNotFound }
        )
        assertTrue(clean.succeeded, "missing root and missing keychain items are a clean no-op")
        assertEqual(clean.removedRelativePaths, [], "nothing removed when root is missing")
        assertFalse(fm.fileExists(atPath: missingRoot.path), "cleanup must not create missing root")

        let failedKeychain = LegacyWritingDataCleanup.cleanUp(
            appSupportRoot: missingRoot,
            fileManager: fm,
            deleteKeychainItem: { _ in errSecAuthFailed }
        )
        assertTrue(failedKeychain.keychainDeleteFailed, "unexpected SecItemDelete status should be reported")
        assertFalse(failedKeychain.succeeded, "failed keychain deletion should mark result unsuccessful")
    }
}

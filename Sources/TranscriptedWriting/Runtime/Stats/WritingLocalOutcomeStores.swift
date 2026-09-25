#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// Wipes the text-free outcome ledger and the local word diary.
/// Called from Delete Personalization Data. Lab never reads the diary.
enum TildeLocalOutcomeStores {
    static func eventURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        profile: TildeProductProfile = .current
    ) -> URL {
        TextFreeOnlineEventFile.url(
            homeDirectory: homeDirectory,
            supportDirectoryName: profile.supportDirectoryName
        )
    }

    static func diaryURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        profile: TildeProductProfile = .current
    ) -> URL {
        LocalOutcomeDiaryFile.url(
            homeDirectory: homeDirectory,
            supportDirectoryName: profile.supportDirectoryName
        )
    }

    static func approximateBytes(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        profile: TildeProductProfile = .current
    ) -> Int64 {
        fileSize(eventURL(homeDirectory: homeDirectory, profile: profile))
            + fileSize(diaryURL(homeDirectory: homeDirectory, profile: profile))
    }

    @discardableResult
    static func deleteAll(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        profile: TildeProductProfile = .current
    ) -> Bool {
        bumpGeneration()
        return removeIfPresent(eventURL(homeDirectory: homeDirectory, profile: profile))
            && removeIfPresent(diaryURL(homeDirectory: homeDirectory, profile: profile))
    }

    static func bumpGeneration(
        suiteName: String = PersonalHistorySettingsContract.keyboardSuiteName
    ) {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let next = defaults.integer(
            forKey: PersonalHistorySettingsContract.outcomeLedgerGenerationKey
        ) &+ 1
        defaults.set(next, forKey: PersonalHistorySettingsContract.outcomeLedgerGenerationKey)
    }

    private static func removeIfPresent(_ url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) { return true }
        return SecureLocalStorage.removeOwnerOnlyFile(at: url)
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return 0 }
        return Int64(values?.fileSize ?? 0)
    }
}

import Foundation
import Testing
@testable import TranscriptedWritingRuntime
@testable import TranscriptedWritingCore

@Suite("Local outcome stores")
struct TildeLocalOutcomeStoresTests {
    @Test("Event and diary paths stay in separate owner-only folders")
    func pathsAreProfileScopedAndSeparate() {
        let home = URL(fileURLWithPath: "/tmp/tilde-outcome-home", isDirectory: true)
        let events = TildeLocalOutcomeStores.eventURL(homeDirectory: home, profile: .production)
        let diary = TildeLocalOutcomeStores.diaryURL(homeDirectory: home, profile: .production)
        #expect(events.lastPathComponent == "events.jsonl")
        #expect(diary.lastPathComponent == "diary.v1.jsonl")
        #expect(events.path.contains("Outcome Ledger"))
        #expect(diary.path.contains("Word Diary"))
        #expect(events.path.contains("Transcripted/writing"))
        #expect(!events.path.contains("acceptedText"))
        #expect(
            TildeLocalOutcomeStores.approximateBytes(homeDirectory: home, profile: .production) == 0
        )
    }

    @Test("A wipe bump is what the IME uses to stop rewriting deleted files")
    func wipeBumpsGeneration() {
        let suite = "tilde.test.outcome-ledger.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(3, forKey: PersonalHistorySettingsContract.outcomeLedgerGenerationKey)
        TildeLocalOutcomeStores.bumpGeneration(suiteName: suite)
        #expect(defaults.integer(forKey: PersonalHistorySettingsContract.outcomeLedgerGenerationKey) == 4)
        defaults.removePersistentDomain(forName: suite)
    }
}

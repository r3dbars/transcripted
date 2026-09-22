#if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT && canImport(TranscriptedCore)
import Foundation
import TranscriptedCore

/// Resolves saved names without promoting profiles created in the CLI's temporary
/// database into apparent app-owned identities. Matching has already happened in
/// Core; this applies the app's normal silent-recognition policy to those results.
enum MeetingImportSpeakerMapping {
    static func resolve(
        result: TranscriptionResult,
        originalProfiles: [SpeakerProfile],
        store: any SpeakerStore
    ) -> (
        mappings: [String: SpeakerMapping],
        sources: [String: String],
        databaseIDs: [String: UUID]
    ) {
        let profilesByID = Dictionary(
            originalProfiles.map { ($0.id, $0) },
            uniquingKeysWith: { original, _ in original }
        )
        var mappings: [String: SpeakerMapping] = [:]
        var sources: [String: String] = [:]
        var databaseIDs: [String: UUID] = [:]
        var outcomesByProfile: [UUID: [SpeakerMatchOutcomeKind]] = [:]

        for speakerID in result.systemSpeakerIds.sorted() {
            let key = "system_\(speakerID)"
            mappings[key] = SpeakerMapping(speakerId: speakerID)
            sources[key] = "unknown"

            let context = result.systemSpeakerContexts[speakerID]
            let utterance = result.systemUtterances.first { String($0.speakerId) == speakerID }
            guard let profileID = context?.persistentSpeakerId ?? utterance?.persistentSpeakerId,
                  let profile = profilesByID[profileID],
                  let name = profile.displayName,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            // These IDs existed in the app before this run. Newly created and
            // unnamed snapshot profiles deliberately have no persisted db_id.
            databaseIDs[key] = profileID
            sources[key] = "db_pending"

            let similarity: Double
            let secondSimilarity: Double?
            let marginSimilarities: (best: Double, secondBest: Double)?
            if let context,
               context.matchedProfileSnapshot?.id == profileID,
               let matchedSimilarity = context.matchSimilarity {
                similarity = matchedSimilarity
                secondSimilarity = context.matchSecondSimilarity
                if let average = context.matchAverageSimilarity,
                   let secondAverage = context.matchSecondBestAverageSimilarity {
                    marginSimilarities = (average, secondAverage)
                } else {
                    marginSimilarities = nil
                }
            } else if utterance?.persistentSpeakerId == profileID,
                      let matchedSimilarity = utterance?.matchSimilarity {
                // The app also treats the utterance-only fallback as unknown
                // margin, so it cannot silently name a person.
                similarity = matchedSimilarity
                secondSimilarity = nil
                marginSimilarities = nil
            } else {
                continue
            }

            let recentOutcomes: [SpeakerMatchOutcomeKind]
            if let cached = outcomesByProfile[profileID] {
                recentOutcomes = cached
            } else {
                recentOutcomes = store.recentMatchOutcomes(
                    profileId: profileID,
                    limit: SpeakerProfileHealth.recentOutcomeWindow
                ).map(\.kind)
                outcomesByProfile[profileID] = recentOutcomes
            }

            // The writable snapshot store may have adapted a profile during
            // matching. Use its original state for maturity, health, and name.
            let mapping = SpeakerNamingPolicy.initialMapping(
                speakerId: speakerID,
                profile: profile,
                similarity: similarity,
                secondBestSimilarity: secondSimilarity,
                recentOutcomes: recentOutcomes,
                marginSimilarities: marginSimilarities
            )
            mappings[key] = mapping
            sources[key] = mapping.isConfirmedIdentity ? "db" : "db_pending"
        }

        return (mappings, sources, databaseIDs)
    }
}
#endif

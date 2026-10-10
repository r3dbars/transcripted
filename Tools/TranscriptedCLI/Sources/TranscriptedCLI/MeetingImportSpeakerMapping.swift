#if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT && canImport(TranscriptedCore)
import Foundation
import TranscriptedCore

/// Resolves saved names without promoting profiles created in the CLI's temporary
/// database into apparent app-owned identities. Matching has already happened in
/// Core; this applies the app's normal silent-recognition policy to those results,
/// with the active voiceprint model's bars, and says why each numbered speaker
/// stayed numbered.
enum MeetingImportSpeakerMapping {
    struct Resolution {
        var mappings: [String: SpeakerMapping] = [:]
        var sources: [String: String] = [:]
        var databaseIDs: [String: UUID] = [:]
        /// One line per speaker that isn't silently named: why it stayed numbered,
        /// or why it is only a likely name. Keyed like `mappings`.
        var reasons: [String: String] = [:]
    }

    /// Suffix on a likely name (`--name-likely-speakers`), so a reader can tell it
    /// from a silent name. The frontmatter source stays `db_pending` (not `db`), so
    /// tools and the voiceprint migration never treat it as a confirmed identity.
    static let likelyNameSuffix = SpeakerMapping.likelyNameSuffix

    static func resolve(
        result: TranscriptionResult,
        originalProfiles: [SpeakerProfile],
        store: any SpeakerStore,
        thresholds: SpeakerEmbeddingThresholds = .weSpeaker,
        nameLikelySpeakers: Bool = false,
        unavailableReason: String? = nil
    ) -> Resolution {
        let profilesByID = Dictionary(
            originalProfiles.map { ($0.id, $0) },
            uniquingKeysWith: { original, _ in original }
        )
        var resolution = Resolution()
        var outcomesByProfile: [UUID: [SpeakerMatchOutcomeKind]] = [:]

        for speakerID in result.systemSpeakerIds.sorted() {
            let key = "system_\(speakerID)"
            resolution.mappings[key] = SpeakerMapping(speakerId: speakerID)
            resolution.sources[key] = "unknown"

            if let unavailableReason {
                resolution.reasons[key] = unavailableReason
                continue
            }

            let context = result.systemSpeakerContexts[speakerID]
            let utterance = result.systemUtterances.first { String($0.speakerId) == speakerID }
            guard let profileID = context?.persistentSpeakerId ?? utterance?.persistentSpeakerId,
                  let profile = profilesByID[profileID] else {
                resolution.reasons[key] = "didn't match anyone saved in this voiceprint database"
                continue
            }
            guard let name = profile.displayName,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                resolution.reasons[key] = "matched a saved voice that has no name yet"
                continue
            }

            // These IDs existed in the app before this run. Newly created and
            // unnamed snapshot profiles deliberately have no persisted db_id.
            resolution.databaseIDs[key] = profileID
            resolution.sources[key] = "db_pending"

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
                resolution.reasons[key] = "was linked to \(name) without a match score, so it isn't named"
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
                marginSimilarities: marginSimilarities,
                thresholds: thresholds
            )
            resolution.mappings[key] = mapping
            resolution.sources[key] = mapping.isConfirmedIdentity ? "db" : "db_pending"
            guard !mapping.isConfirmedIdentity else { continue }

            let blockers = SpeakerNamingPolicy.silentNamingBlockers(
                profile: profile,
                similarity: similarity,
                secondBestSimilarity: secondSimilarity,
                recentOutcomes: recentOutcomes,
                marginSimilarities: marginSimilarities,
                thresholds: thresholds
            )
            // Opt-in: a match held back only by confirmation count and/or a
            // similarity between the model's invitee bar and the silent bar,
            // and only when the top match also beats the runner-up by
            // inviteeMarginMin. Never a confirmed identity.
            if nameLikelySpeakers,
               SpeakerNamingPolicy.shouldNameAsLikely(blockers: blockers, thresholds: thresholds) {
                resolution.mappings[key] = SpeakerMapping(
                    speakerId: speakerID,
                    identifiedName: name + likelyNameSuffix,
                    confidence: .medium,
                    isConfirmedIdentity: false
                )
                resolution.reasons[key] = likelyReason(name: name, blockers: blockers)
                continue
            }
            resolution.reasons[key] = "matched \(name), but " + blockers.map { describe($0) }.joined(separator: "; ")
        }

        return resolution
    }

    static func likelyReason(name: String, blockers: [SpeakerNamingBlocker]) -> String {
        let parts = blockers.map { blocker -> String in
            switch blocker {
            case .needsConfirmations(let have, let need):
                return "\(have) of \(need) confirmed meetings"
            default:
                return describe(blocker)
            }
        }
        return "named \(name) as likely: \(parts.joined(separator: "; ")) (--name-likely-speakers)"
    }

    static func describe(_ blocker: SpeakerNamingBlocker) -> String {
        switch blocker {
        case .unnamed:
            return "the saved voice has no name"
        case .needsConfirmations(let have, let need):
            return "only \(have) of \(need) confirmed meetings"
        case .recentCorrections:
            return "recent corrections or a dispute mean it needs a fresh confirmation in the app"
        case .similarityBelowBar(let similarity, let bar):
            return String(format: "similarity %.3f is not above the %.3f silent-naming bar", similarity, bar)
        case .runnerUpUnknown:
            return "the runner-up score is unknown"
        case .runnerUpTooClose(let margin, let needed):
            return String(format: "another saved person scored too close (margin %.3f, needs %.3f)", margin, needed)
        }
    }
}
#endif

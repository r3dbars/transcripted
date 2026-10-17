import Foundation

// MARK: - Call-app speaker names (after Phase 1.5 classification)

extension TranscriptionTaskManager {

    /// What applying call-app names did, for counts-only logging and Phase 3.
    struct CallSpeakerNamesApplied: Sendable, Equatable {
        /// Diarizer id of each call-audio voice now shown with a call-app name.
        var namesBySpeakerId: [String: String] = [:]
        /// Named by the policy but the voiceprint already auto-named the voice.
        var autoAcceptedSkipped = 0
        /// Named by the policy but the voice gets no review row (no voiceprint
        /// profile), so nothing would ever confirm or correct the name.
        var noReviewRowSkipped = 0
        /// Named by the policy but the voiceprint suggests someone else.
        var voiceprintConflicts = 0
        /// Named by the policy but withheld here, with the reason.
        var withheld: [String: CallSpeakerAttributionPolicy.WithheldReason] = [:]
    }

    /// Diarized call-audio voices as speech spans keyed by diarizer id: the
    /// policy's input.
    nonisolated static func callSpeakerClusters(
        from systemUtterances: [TranscriptionUtterance]
    ) -> [String: [CallSpeakerAttributionPolicy.SpeechSpan]] {
        var clusters: [String: [CallSpeakerAttributionPolicy.SpeechSpan]] = [:]
        for utterance in systemUtterances where utterance.end > utterance.start {
            clusters[String(utterance.speakerId), default: []].append(
                CallSpeakerAttributionPolicy.SpeechSpan(start: utterance.start, end: utterance.end)
            )
        }
        return clusters
    }

    /// Shows each policy-named call-audio voice under its call-app name while
    /// keeping it in review. A name is applied only when:
    /// - the voiceprint didn't auto-accept the voice (its name always wins);
    /// - the voice gets a review row (`reviewIds`), so the name is a prefill
    ///   the user confirms or corrects;
    /// - the voiceprint doesn't suggest a different person;
    /// - no other call-audio voice in this meeting would show the same name:
    ///   neither another voice's current shown name (auto-accepted, likely,
    ///   or placeholder) nor another voice's call-app name. Body labels are
    ///   `[System/<name>]`, so two voices under one name can't be told apart
    ///   and renaming one would rename both. Every voice in such a clash is
    ///   withheld (`nameShared`).
    ///
    /// Applied voices get `source: db_pending`, confidence `.medium`, and
    /// `name_source: call_app`.
    ///
    /// - Parameter voiceprintNames: the name the voiceprint suggests for a
    ///   diarizer id that was not auto-accepted, if any.
    nonisolated static func applyCallSpeakerNames(
        _ outcome: CallSpeakerAttributionPolicy.Outcome,
        autoAcceptedIds: Set<String>,
        reviewIds: Set<String>,
        voiceprintNames: [String: String],
        speakerMappings: inout [String: SpeakerMapping],
        speakerSources: inout [String: String]
    ) -> CallSpeakerNamesApplied {
        typealias Policy = CallSpeakerAttributionPolicy
        var applied = CallSpeakerNamesApplied()
        var candidates: [String: String] = [:]
        for speakerId in outcome.names.keys.sorted() {
            guard let callName = outcome.names[speakerId] else { continue }
            if autoAcceptedIds.contains(speakerId) {
                applied.autoAcceptedSkipped += 1
                continue
            }
            guard reviewIds.contains(speakerId) else {
                applied.noReviewRowSkipped += 1
                continue
            }
            if let voiceprintName = voiceprintNames[speakerId],
               !Policy.normalizedKey(voiceprintName).isEmpty,
               Policy.normalizedKey(voiceprintName) != Policy.normalizedKey(callName) {
                applied.voiceprintConflicts += 1
                continue
            }
            candidates[speakerId] = callName
        }

        // Every call-audio voice in this meeting, named or not.
        var allSpeakerIds = Set(outcome.names.keys).union(outcome.withheld.keys)
        for key in speakerMappings.keys where key.hasPrefix("system_") {
            allSpeakerIds.insert(String(key.dropFirst("system_".count)))
        }
        let candidateCountByKey = Dictionary(grouping: candidates.values, by: Policy.normalizedKey).mapValues(\.count)

        for (speakerId, callName) in candidates {
            let key = Policy.normalizedKey(callName)
            let sharedWithCandidate = (candidateCountByKey[key] ?? 0) > 1
            let sharedWithShownName = allSpeakerIds.contains { otherId in
                otherId != speakerId
                    && shownNameKeys(speakerId: otherId, mapping: speakerMappings["system_\(otherId)"]).contains(key)
            }
            if sharedWithCandidate || sharedWithShownName {
                applied.withheld[speakerId] = .nameShared
            }
        }

        for speakerId in candidates.keys.sorted() where applied.withheld[speakerId] == nil {
            guard let callName = candidates[speakerId] else { continue }
            let key = "system_\(speakerId)"
            speakerMappings[key] = SpeakerMapping(
                speakerId: speakerId,
                identifiedName: callName,
                confidence: .medium,
                isConfirmedIdentity: false,
                shownNameSource: .callApp
            )
            speakerSources[key] = "db_pending"
            applied.namesBySpeakerId[speakerId] = callName
        }
        return applied
    }

    /// Normalized names a voice's body label could be confused with: what it
    /// shows now (placeholder included) and that name without the
    /// likely-name hedge.
    private nonisolated static func shownNameKeys(speakerId: String, mapping: SpeakerMapping?) -> Set<String> {
        let shown = (mapping ?? SpeakerMapping(speakerId: speakerId)).displayName
        var keys: Set<String> = [CallSpeakerAttributionPolicy.normalizedKey(shown)]
        if shown.hasSuffix(SpeakerMapping.likelyNameSuffix) {
            let unhedged = String(shown.dropLast(SpeakerMapping.likelyNameSuffix.count))
            keys.insert(CallSpeakerAttributionPolicy.normalizedKey(unhedged))
        }
        return keys
    }

    /// Phase 3: call-audio review rows for voices shown with a call-app name
    /// carry it as the name-field prefill.
    nonisolated static func withCallAppSuggestedNames(
        _ entries: [SpeakerNamingEntry],
        _ namesBySpeakerId: [String: String]
    ) -> [SpeakerNamingEntry] {
        guard !namesBySpeakerId.isEmpty else { return entries }
        return entries.map { entry in
            guard entry.channel == .system, let name = namesBySpeakerId[entry.diarizerSpeakerId] else { return entry }
            var entry = entry
            entry.callAppSuggestedName = name
            return entry
        }
    }

    /// The whole call-app naming step without the host: runs the policy on
    /// this meeting's activity, looks up what the voiceprint suggests for
    /// each named voice (classification knowledge first, then the voice's
    /// profile through `profileName`), and applies what survives
    /// (`applyCallSpeakerNames`). Imports never get call-app names: an
    /// import's date can't name a call. Returns nil when nothing ran.
    nonisolated static func callSpeakerNames(
        isImport: Bool,
        activity: CallSpeakerActivity?,
        systemUtterances: [TranscriptionUtterance],
        dbKnowledge: [SpeakerClassificationKnowledge],
        autoAcceptedIds: Set<String>,
        reviewIds: Set<String>,
        profileName: (UUID) -> String?,
        speakerMappings: inout [String: SpeakerMapping],
        speakerSources: inout [String: String]
    ) -> (outcome: CallSpeakerAttributionPolicy.Outcome, applied: CallSpeakerNamesApplied)? {
        guard !isImport, let activity, !activity.isEmpty else { return nil }
        let outcome = CallSpeakerAttributionPolicy.attribute(
            activity: activity,
            clusters: callSpeakerClusters(from: systemUtterances)
        )
        var voiceprintNames: [String: String] = [:]
        for speakerId in outcome.names.keys {
            if let entry = dbKnowledge.first(where: { $0.speakerId == speakerId }) {
                voiceprintNames[speakerId] = entry.profile.displayName
            } else if let profileId = systemUtterances.first(where: {
                String($0.speakerId) == speakerId && $0.persistentSpeakerId != nil
            })?.persistentSpeakerId {
                voiceprintNames[speakerId] = profileName(profileId)
            }
        }
        let applied = applyCallSpeakerNames(
            outcome,
            autoAcceptedIds: autoAcceptedIds,
            reviewIds: reviewIds,
            voiceprintNames: voiceprintNames,
            speakerMappings: &speakerMappings,
            speakerSources: &speakerSources
        )
        return (outcome, applied)
    }

    /// Asks the host for this meeting's call-app activity and applies the
    /// names it supports (`callSpeakerNames`). Live meetings only; the
    /// provider isn't even asked for an import. Logs counts and reason
    /// codes, never names.
    nonisolated func resolveCallSpeakerNames(
        isImport: Bool,
        recordingDate: Date?,
        result: TranscriptionResult,
        dbKnowledge: [SpeakerClassificationKnowledge],
        autoAcceptedIds: Set<String>,
        reviewIds: Set<String>,
        speakerDB: any SpeakerStore,
        speakerMappings: inout [String: SpeakerMapping],
        speakerSources: inout [String: String]
    ) async -> [String: String] {
        guard !isImport, let provider = await MainActor.run(body: { self.callSpeakerActivityProvider }) else {
            return [:]
        }
        let activity = await provider(recordingDate)
        guard let resolved = Self.callSpeakerNames(
            isImport: isImport,
            activity: activity,
            systemUtterances: result.systemUtterances,
            dbKnowledge: dbKnowledge,
            autoAcceptedIds: autoAcceptedIds,
            reviewIds: reviewIds,
            profileName: { speakerDB.getSpeaker(id: $0)?.displayName },
            speakerMappings: &speakerMappings,
            speakerSources: &speakerSources
        ) else {
            return [:]
        }
        let (outcome, applied) = resolved
        var reasonCounts: [String: Int] = [:]
        for reason in outcome.withheld.values { reasonCounts[reason.rawValue, default: 0] += 1 }
        for reason in applied.withheld.values { reasonCounts[reason.rawValue, default: 0] += 1 }
        AppLogger.speakers.info("Call app speaker attribution", [
            "voices": "\(outcome.names.count + outcome.withheld.count)",
            "labeled": "\(applied.namesBySpeakerId.count)",
            "autoAcceptedKept": "\(applied.autoAcceptedSkipped)",
            "noReviewRow": "\(applied.noReviewRowSkipped)",
            "voiceprintConflicts": "\(applied.voiceprintConflicts)",
            "withheldReasons": reasonCounts.keys.sorted().map { "\($0)=\(reasonCounts[$0] ?? 0)" }.joined(separator: ","),
            "indicatorSeen": "\(activity?.sawSpeakingIndicator ?? false)"
        ])
        return applied.namesBySpeakerId
    }
}

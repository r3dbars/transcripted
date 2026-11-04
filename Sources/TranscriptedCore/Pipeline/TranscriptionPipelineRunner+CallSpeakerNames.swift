import Foundation

// MARK: - Call-app speaker evidence (after Phase 1.5 classification)

extension TranscriptionTaskManager {

    /// What recording call-app evidence did, for counts-only logging and
    /// Phase 3. Nothing here ever changed a speaker's label.
    struct CallSpeakerEvidenceRecorded: Sendable, Equatable {
        /// Diarizer id of each call-audio voice the call app named, to that
        /// name: the review's hint (never a prefill or a label).
        var hintNamesBySpeakerId: [String: String] = [:]
        /// Named voices by how the call-app name compares with the voiceprint.
        var agreements: [CallAppSpeakerEvidence.Agreement: Int] = [:]
        /// Voices withheld by the policy for a reason worth saving.
        var withheldRecorded = 0
        /// Voices with evidence but no speaker row to save it on.
        var noSpeakerRow = 0
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

    /// Saves what the call app showed next to each call-audio voice's
    /// speaker row (`SpeakerMapping.callAppEvidence`), compared with the
    /// voiceprint's own answer. Only `callAppEvidence` is ever set: names,
    /// confidence, confirmation and `source:` stay exactly as the voiceprint
    /// left them, so a call-app name can only add context, never relabel a
    /// voice or displace a voiceprint guess. Nothing is learned from it.
    ///
    /// - Named voices get the name, its strength and the agreement
    ///   (`agrees`, `conflicts`, `no_voiceprint_guess`).
    /// - Withheld voices get the reason, except `no_evidence` (nothing was
    ///   shown, so there's nothing to say).
    /// - A voice with no speaker row (no voiceprint profile and no name)
    ///   gets nothing; a row is never created just for evidence.
    ///
    /// - Parameter voiceprintNames: the name the voiceprint gives or
    ///   suggests for a diarizer id, if any.
    nonisolated static func recordCallSpeakerEvidence(
        _ outcome: CallSpeakerAttributionPolicy.Outcome,
        voiceprintNames: [String: String],
        speakerMappings: inout [String: SpeakerMapping]
    ) -> CallSpeakerEvidenceRecorded {
        var recorded = CallSpeakerEvidenceRecorded()
        for speakerId in outcome.names.keys.sorted() {
            guard let callName = outcome.names[speakerId] else { continue }
            let evidence = CallAppSpeakerEvidence.named(
                callName,
                strength: outcome.evidence[speakerId],
                voiceprintName: voiceprintNames[speakerId]
            )
            recorded.hintNamesBySpeakerId[speakerId] = callName
            if let agreement = evidence.agreement {
                recorded.agreements[agreement, default: 0] += 1
            }
            let key = "system_\(speakerId)"
            guard speakerMappings[key] != nil else {
                recorded.noSpeakerRow += 1
                continue
            }
            speakerMappings[key]?.callAppEvidence = evidence
        }
        for speakerId in outcome.withheld.keys.sorted() {
            guard let reason = outcome.withheld[speakerId], reason != .noEvidence else { continue }
            let key = "system_\(speakerId)"
            guard speakerMappings[key] != nil else {
                recorded.noSpeakerRow += 1
                continue
            }
            speakerMappings[key]?.callAppEvidence = CallAppSpeakerEvidence(withheld: reason)
            recorded.withheldRecorded += 1
        }
        return recorded
    }

    /// Phase 3: call-audio review rows the call app named carry that name
    /// as a hint (`SpeakerNamingEntry.callAppShownName`). The review shows
    /// it; it fills the name field only when the person taps it.
    nonisolated static func withCallAppHints(
        _ entries: [SpeakerNamingEntry],
        _ namesBySpeakerId: [String: String]
    ) -> [SpeakerNamingEntry] {
        guard !namesBySpeakerId.isEmpty else { return entries }
        return entries.map { entry in
            guard entry.channel == .system, let name = namesBySpeakerId[entry.diarizerSpeakerId] else { return entry }
            var entry = entry
            entry.callAppShownName = name
            return entry
        }
    }

    /// The whole call-app evidence step without the host: runs the policy
    /// on this meeting's activity, looks up the voiceprint's answer for each
    /// named voice (its saved mapping name, then classification knowledge,
    /// then the voice's profile through `profileName`), and records the
    /// evidence (`recordCallSpeakerEvidence`). Imports never get call-app
    /// evidence: an import's date can't name a call. Returns nil when
    /// nothing ran.
    nonisolated static func callSpeakerEvidence(
        isImport: Bool,
        activity: CallSpeakerActivity?,
        systemUtterances: [TranscriptionUtterance],
        dbKnowledge: [SpeakerClassificationKnowledge],
        profileName: (UUID) -> String?,
        speakerMappings: inout [String: SpeakerMapping]
    ) -> (outcome: CallSpeakerAttributionPolicy.Outcome, recorded: CallSpeakerEvidenceRecorded)? {
        guard !isImport, let activity, !activity.isEmpty else { return nil }
        let outcome = CallSpeakerAttributionPolicy.attribute(
            activity: activity,
            clusters: callSpeakerClusters(from: systemUtterances)
        )
        var voiceprintNames: [String: String] = [:]
        for speakerId in outcome.names.keys {
            if let name = speakerMappings["system_\(speakerId)"]?.identifiedName,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                voiceprintNames[speakerId] = name
            } else if let entry = dbKnowledge.first(where: { $0.speakerId == speakerId }) {
                voiceprintNames[speakerId] = entry.profile.displayName
            } else if let profileId = systemUtterances.first(where: {
                String($0.speakerId) == speakerId && $0.persistentSpeakerId != nil
            })?.persistentSpeakerId {
                voiceprintNames[speakerId] = profileName(profileId)
            }
        }
        let recorded = recordCallSpeakerEvidence(
            outcome,
            voiceprintNames: voiceprintNames,
            speakerMappings: &speakerMappings
        )
        return (outcome, recorded)
    }

    /// Asks the host for this meeting's call-app activity and saves what it
    /// shows as evidence (`callSpeakerEvidence`). Live meetings only; the
    /// provider isn't even asked for an import. Returns the review hints.
    /// Logs counts and reason codes, never names.
    nonisolated func resolveCallSpeakerEvidence(
        isImport: Bool,
        recordingDate: Date?,
        result: TranscriptionResult,
        dbKnowledge: [SpeakerClassificationKnowledge],
        speakerDB: any SpeakerStore,
        speakerMappings: inout [String: SpeakerMapping]
    ) async -> [String: String] {
        guard !isImport, let provider = await MainActor.run(body: { self.callSpeakerActivityProvider }) else {
            return [:]
        }
        let activity = await provider(recordingDate)
        guard let resolved = Self.callSpeakerEvidence(
            isImport: isImport,
            activity: activity,
            systemUtterances: result.systemUtterances,
            dbKnowledge: dbKnowledge,
            profileName: { speakerDB.getSpeaker(id: $0)?.displayName },
            speakerMappings: &speakerMappings
        ) else {
            return [:]
        }
        let (outcome, recorded) = resolved
        var reasonCounts: [String: Int] = [:]
        for reason in outcome.withheld.values { reasonCounts[reason.rawValue, default: 0] += 1 }
        AppLogger.speakers.info("Call app speaker evidence", [
            "voices": "\(outcome.names.count + outcome.withheld.count)",
            "hinted": "\(recorded.hintNamesBySpeakerId.count)",
            "agrees": "\(recorded.agreements[.agrees] ?? 0)",
            "conflicts": "\(recorded.agreements[.conflicts] ?? 0)",
            "noVoiceprintGuess": "\(recorded.agreements[.noVoiceprintGuess] ?? 0)",
            "noSpeakerRow": "\(recorded.noSpeakerRow)",
            "withheldReasons": reasonCounts.keys.sorted().map { "\($0)=\(reasonCounts[$0] ?? 0)" }.joined(separator: ","),
            "indicatorSeen": "\(activity?.sawSpeakingIndicator ?? false)"
        ])
        return recorded.hintNamesBySpeakerId
    }
}

import Foundation
import SQLite3

// MARK: - Profile Management & Merging

@available(macOS 14.0, *)
extension SpeakerDatabase {

    /// Set the display name for a speaker with provenance tracking
    /// - Parameters:
    ///   - id: Speaker profile UUID
    ///   - name: Display name to set
    ///   - source: Where the name came from (NameSource.userManual or NameSource.qwenInferred)
    func setDisplayName(id: UUID, name: String, source: String = NameSource.qwenInferred) {
        queue.sync {
            setDisplayNameImpl(id: id, name: name, source: source)
        }
    }

    func setDisplayNameImpl(id: UUID, name: String, source: String) {
        guard isDatabaseOpen else {
            AppLogger.speakers.error("setDisplayName failed — database not open", ["speakerId": id.uuidString, "name": name])
            return
        }
        let sql = "UPDATE speakers SET display_name = ?, name_source = ? WHERE id = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, (source as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) != SQLITE_DONE {
                AppLogger.speakers.error("Failed to set display name", ["sqlite_error": dbErrorMessage(), "id": id.uuidString])
            }
        } else {
            AppLogger.speakers.error("Failed to prepare setDisplayName", ["sqlite_error": dbErrorMessage()])
        }
        sqlite3_finalize(statement)
    }

    /// Increment the dispute count for a speaker (inference disagreed with DB name)
    func incrementDisputeCount(id: UUID) {
        queue.sync { [self] in
            guard isDatabaseOpen else { return }
            let sql = "UPDATE speakers SET dispute_count = dispute_count + 1 WHERE id = ?;"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                if sqlite3_step(statement) != SQLITE_DONE {
                    AppLogger.speakers.error("Failed to increment dispute count", ["sqlite_error": dbErrorMessage()])
                }
            } else {
                AppLogger.speakers.error("Failed to prepare incrementDisputeCount", ["sqlite_error": dbErrorMessage()])
            }
            sqlite3_finalize(statement)
        }
    }

    /// Reset dispute count (after user manual rename or name confirmed)
    func resetDisputeCount(id: UUID) {
        queue.sync { [self] in
            guard isDatabaseOpen else { return }
            let sql = "UPDATE speakers SET dispute_count = 0 WHERE id = ?;"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                if sqlite3_step(statement) != SQLITE_DONE {
                    AppLogger.speakers.error("Failed to reset dispute count", ["sqlite_error": dbErrorMessage()])
                }
            } else {
                AppLogger.speakers.error("Failed to prepare resetDisputeCount", ["sqlite_error": dbErrorMessage()])
            }
            sqlite3_finalize(statement)
        }
    }

    // MARK: - Profile Lookup by Name

    /// Find all profiles whose display name matches the query (using fuzzy name variant matching).
    /// Returns matching profiles sorted by call count descending (strongest profile first).
    func findProfilesByName(_ name: String) -> [SpeakerProfile] {
        return queue.sync {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }

            return allSpeakersImpl()
                .filter { profile in
                    guard let displayName = profile.displayName else { return false }
                    return SpeakerDatabase.areNameVariants(trimmed, displayName)
                }
                .sorted { $0.callCount > $1.callCount }
        }
    }

    // MARK: - Explicit Profile Merge

    /// Merge source profile into target profile.
    /// Blends embeddings weighted by call count, sums call counts, bumps confidence.
    /// Transfers name from source if target has none. Deletes source profile.
    func mergeProfiles(sourceId: UUID, into targetId: UUID) {
        queue.sync {
            mergeProfilesImpl(sourceId: sourceId, into: targetId)
        }
    }

    func mergeProfilesImpl(sourceId: UUID, into targetId: UUID) {
        guard let source = getSpeakerImpl(id: sourceId),
              let target = getSpeakerImpl(id: targetId) else {
            AppLogger.speakers.warning("Merge failed — profile not found", [
                "sourceId": "\(sourceId)", "targetId": "\(targetId)"
            ])
            return
        }

        // Blend embeddings weighted by call count (stronger profile dominates)
        let totalCalls = Float(source.callCount + target.callCount)
        guard totalCalls > 0, source.embedding.count == target.embedding.count else {
            AppLogger.speakers.warning("Merge aborted — embedding dimension mismatch or zero calls", [
                "sourceId": "\(sourceId)",
                "targetId": "\(targetId)",
                "sourceDim": "\(source.embedding.count)",
                "targetDim": "\(target.embedding.count)",
                "totalCalls": "\(Int(totalCalls))"
            ])
            return
        }

        let sourceWeight = Float(source.callCount) / totalCalls
        let targetWeight = Float(target.callCount) / totalCalls
        let blended = zip(source.embedding, target.embedding).map { s, t in
            s * sourceWeight + t * targetWeight
        }
        let normalized = l2Normalize(blended)

        // Transfer name from source if target has none
        if target.displayName == nil, let name = source.displayName {
            setDisplayNameImpl(id: targetId, name: name, source: source.nameSource ?? NameSource.userManual)
        }

        // Update target: blended embedding, summed call count, bumped confidence
        let isoFormatter = ISO8601DateFormatter()
        let now = isoFormatter.string(from: Date())
        let newCallCount = target.callCount + source.callCount
        let newConfidence = min(1.0, target.confidence + 0.15)

        // Wrap UPDATE + DELETE in a transaction so a crash between them can't orphan data
        transaction {
            let sql = """
            UPDATE speakers SET embedding = ?, last_seen = ?, call_count = ?, confidence = ?
            WHERE id = ?;
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                let embeddingData = normalized.withUnsafeBufferPointer { Data(buffer: $0) }
                sqlite3_bind_blob(statement, 1, (embeddingData as NSData).bytes, Int32(embeddingData.count), SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(statement, 3, Int32(newCallCount))
                sqlite3_bind_double(statement, 4, newConfidence)
                sqlite3_bind_text(statement, 5, (targetId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                if sqlite3_step(statement) != SQLITE_DONE {
                    AppLogger.speakers.error("Failed to update target in merge", ["sqlite_error": dbErrorMessage(), "targetId": targetId.uuidString])
                }
            } else {
                AppLogger.speakers.error("Failed to prepare merge update", ["sqlite_error": dbErrorMessage()])
            }
            sqlite3_finalize(statement)

            // Delete source profile
            let deleteSql = "DELETE FROM speakers WHERE id = ?;"
            var deleteStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(deleteStmt, 1, (sourceId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                if sqlite3_step(deleteStmt) != SQLITE_DONE {
                    AppLogger.speakers.error("Failed to delete source in merge", ["sqlite_error": dbErrorMessage(), "sourceId": sourceId.uuidString])
                }
            } else {
                AppLogger.speakers.error("Failed to prepare merge delete", ["sqlite_error": dbErrorMessage()])
            }
            sqlite3_finalize(deleteStmt)
        }

        AppLogger.speakers.info("Merged profiles", [
            "source": source.displayName ?? "\(sourceId)",
            "target": target.displayName ?? "\(targetId)",
            "newCallCount": "\(newCallCount)"
        ])
    }

    // MARK: - Duplicate Merging

    /// Scan all profiles for likely duplicates and merge them.
    /// Keeps the profile with more calls (better embedding). Transfers display name if the
    /// weaker profile has one and the stronger doesn't. Call after each recording.
    func mergeDuplicates(threshold: Double = 0.6) {
        queue.sync {
            mergeDuplicatesImpl(threshold: threshold)
        }
    }

    private func mergeDuplicatesImpl(threshold: Double) {
        let speakers = allSpeakersImpl()
        guard speakers.count > 1 else { return }

        var mergedIds: Set<UUID> = []
        var mergeCount = 0

        // Each mergeProfilesImpl call is individually transactional (UPDATE + DELETE).
        // No outer transaction — SQLite doesn't support nested BEGIN EXCLUSIVE.
        for i in 0..<speakers.count {
            guard !mergedIds.contains(speakers[i].id) else { continue }

            for j in (i + 1)..<speakers.count {
                guard !mergedIds.contains(speakers[j].id) else { continue }

                let similarity = cosineSimilarity(speakers[i].embedding, speakers[j].embedding)
                guard similarity >= threshold else { continue }

                // Determine which profile to keep (more calls = better data)
                let keeper: SpeakerProfile
                let absorbed: SpeakerProfile
                if speakers[i].callCount >= speakers[j].callCount {
                    keeper = speakers[i]
                    absorbed = speakers[j]
                } else {
                    keeper = speakers[j]
                    absorbed = speakers[i]
                }

                // Merge via mergeProfilesImpl (blends embeddings, transfers name, deletes source)
                mergeProfilesImpl(sourceId: absorbed.id, into: keeper.id)

                mergedIds.insert(absorbed.id)
                mergeCount += 1
                AppLogger.speakers.info("Merged duplicate speaker", ["absorbed": absorbed.displayName ?? "unnamed", "keeper": keeper.displayName ?? "unnamed", "similarity": String(format: "%.3f", similarity)])
            }
        }

        if mergeCount > 0 {
            AppLogger.speakers.info("Duplicate merge complete", ["merged": "\(mergeCount)", "remaining": "\(speakers.count - mergeCount)"])
        }
    }

    // MARK: - Same-Name Profile Merging

    /// Merge all profiles that share the same display name.
    /// After user naming, multiple profiles may end up with the same name (e.g., 4 profiles
    /// all named "Jenny Wen"). This merges them into a single profile — the one with the
    /// highest call count — using the existing weighted embedding blend from mergeProfilesImpl().
    func mergeProfilesByName() {
        queue.sync {
            mergeProfilesByNameImpl()
        }
    }

    private func mergeProfilesByNameImpl() {
        let speakers = allSpeakersImpl()

        // Group named profiles by lowercased display name
        var byName: [String: [SpeakerProfile]] = [:]
        for speaker in speakers {
            guard let name = speaker.displayName?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            byName[name, default: []].append(speaker)
        }

        var mergeCount = 0
        for (name, profiles) in byName {
            guard profiles.count > 1 else { continue }

            // Keep the profile with the highest call count (best embedding data)
            let sorted = profiles.sorted { $0.callCount > $1.callCount }
            let keeper = sorted[0]

            for source in sorted.dropFirst() {
                mergeProfilesImpl(sourceId: source.id, into: keeper.id)
                mergeCount += 1
            }

            AppLogger.speakers.info("Merged same-name profiles", [
                "name": name,
                "merged": "\(sorted.count - 1)",
                "keeperId": "\(keeper.id)"
            ])
        }

        if mergeCount > 0 {
            AppLogger.speakers.info("Same-name merge complete", ["merged": "\(mergeCount)"])
        }
    }

    // MARK: - Weak Profile Pruning

    /// Remove unnamed, low-confidence, single-call profiles older than 1 hour.
    /// These are typically noise from AHC over-splitting one speaker into multiple clusters.
    /// Safe to call after each transcription — only prunes stale orphans, never recent profiles.
    func pruneWeakProfiles() {
        queue.sync {
            pruneWeakProfilesImpl()
        }
    }

    private func pruneWeakProfilesImpl() {
        guard isDatabaseOpen else { return }
        // Only prune profiles created more than 1 hour ago — don't prune profiles from
        // the current recording that are about to be named in the speaker naming flow.
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))

        let sql = """
        DELETE FROM speakers
        WHERE display_name IS NULL
          AND call_count <= 1
          AND confidence <= 0.5
          AND first_seen < ?;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (cutoff as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) != SQLITE_DONE {
                AppLogger.speakers.error("Failed to prune weak profiles", ["sqlite_error": dbErrorMessage()])
            } else {
                let pruned = Int(sqlite3_changes(db))
                if pruned > 0 {
                    AppLogger.speakers.info("Pruned weak profiles", ["count": "\(pruned)"])
                }
            }
        } else {
            AppLogger.speakers.error("Failed to prepare pruneWeakProfiles", ["sqlite_error": dbErrorMessage()])
        }
        sqlite3_finalize(statement)
    }

    // MARK: - Name Variant Detection

    /// Common English name variants (informal -> formal and vice versa)
    private static let nameVariants: [String: Set<String>] = [
        "mike": ["michael", "mike", "mikey"],
        "michael": ["michael", "mike", "mikey"],
        "nate": ["nate", "nathan", "nathaniel"],
        "nathan": ["nate", "nathan", "nathaniel"],
        "nathaniel": ["nate", "nathan", "nathaniel"],
        "dave": ["dave", "david"],
        "david": ["dave", "david"],
        "alex": ["alex", "alexander", "alexandra"],
        "alexander": ["alex", "alexander"],
        "alexandra": ["alex", "alexandra"],
        "dan": ["dan", "daniel", "danny"],
        "daniel": ["dan", "daniel", "danny"],
        "danny": ["dan", "daniel", "danny"],
        "matt": ["matt", "matthew"],
        "matthew": ["matt", "matthew"],
        "chris": ["chris", "christopher", "christine", "christina"],
        "christopher": ["chris", "christopher"],
        "christine": ["chris", "christine"],
        "christina": ["chris", "christina"],
        "nick": ["nick", "nicholas", "nic"],
        "nicholas": ["nick", "nicholas", "nic"],
        "rob": ["rob", "robert", "robbie", "bob", "bobby"],
        "robert": ["rob", "robert", "robbie", "bob", "bobby"],
        "bob": ["rob", "robert", "bob", "bobby"],
        "ed": ["ed", "edward", "eddie"],
        "edward": ["ed", "edward", "eddie"],
        "joe": ["joe", "joseph", "joey"],
        "joseph": ["joe", "joseph", "joey"],
        "tom": ["tom", "thomas", "tommy"],
        "thomas": ["tom", "thomas", "tommy"],
        "sam": ["sam", "samuel", "samantha"],
        "samuel": ["sam", "samuel"],
        "samantha": ["sam", "samantha"],
        "jen": ["jen", "jennifer", "jenny"],
        "jennifer": ["jen", "jennifer", "jenny"],
        "will": ["will", "william", "bill", "billy"],
        "william": ["will", "william", "bill", "billy"],
        "bill": ["will", "william", "bill", "billy"],
        "jim": ["jim", "james", "jimmy"],
        "james": ["jim", "james", "jimmy"],
        "tony": ["tony", "anthony"],
        "anthony": ["tony", "anthony"],
        "steve": ["steve", "steven", "stephen"],
        "steven": ["steve", "steven", "stephen"],
        "stephen": ["steve", "steven", "stephen"],
        "ben": ["ben", "benjamin", "benny"],
        "benjamin": ["ben", "benjamin", "benny"],
        "andy": ["andy", "andrew", "drew"],
        "andrew": ["andy", "andrew", "drew"],
        "drew": ["andy", "andrew", "drew"],
        "marques": ["marques", "marquez"],
        "marquez": ["marques", "marquez"],
    ]

    /// Check if two names are variants of each other (e.g., "Nate" and "Nathan")
    static func areNameVariants(_ name1: String, _ name2: String) -> Bool {
        let a = name1.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let b = name2.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard !a.isEmpty, !b.isEmpty else { return false }

        // Exact match (case-insensitive)
        if a == b { return true }

        // Check variant table
        if let variants = nameVariants[a], variants.contains(b) { return true }
        if let variants = nameVariants[b], variants.contains(a) { return true }

        // Check if one contains the other (handles "Marques Brownlee" vs "Marques")
        if a.contains(b) || b.contains(a) { return true }

        return false
    }
}

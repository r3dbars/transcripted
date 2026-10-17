import Foundation

// MARK: - Frontmatter speaker row writes (moved from RetroactiveSpeakerUpdater.swift)

extension TranscriptSaver {

    /// Rewrites one `speakers:` row (matched by diarizer id and channel) with
    /// the given db_id, name and source. `nameSource` sets the row's
    /// `name_source:`; nil removes it, so naming or confirming a voice through
    /// review drops a `call_app` marker.
    static func writeFrontmatterSpeakerMetadata(
        in content: inout String,
        diarizerSpeakerId: String,
        channel: UtteranceChannel,
        persistentSpeakerId: UUID,
        name: String,
        source: String,
        nameSource: String? = nil
    ) {
        guard let frontmatterRange = frontmatterContentRange(in: content) else { return }

        var lines = String(content[frontmatterRange])
            .components(separatedBy: "\n")

        let targetIdLine = #"id: "\#(diarizerSpeakerId)""#
        let resolvedPersistentId = persistentSpeakerId.uuidString
        var lineIndex = 0

        while lineIndex < lines.count {
            let trimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- "),
                  trimmed.contains(targetIdLine) else {
                lineIndex += 1
                continue
            }

            let nextEntryIndex: Int
            if lineIndex + 1 < lines.count {
                nextEntryIndex = lines[(lineIndex + 1)..<lines.count].firstIndex(where: { candidate in
                    candidate.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
                }) ?? lines.count
            } else {
                nextEntryIndex = lines.count
            }

            let block = lines[lineIndex..<nextEntryIndex]
            guard speakerBlockMatchesChannel(block, channel: channel) else {
                lineIndex = nextEntryIndex
                continue
            }

            // Drop the old `name_source:` first; it is re-added after `source:`
            // when this write still has one.
            var blockEnd = nextEntryIndex
            if lineIndex + 1 < blockEnd {
                for index in stride(from: blockEnd - 1, to: lineIndex, by: -1)
                where lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("name_source:") {
                    lines.remove(at: index)
                    blockEnd -= 1
                }
            }

            var dbIdIndex: Int?
            var nameIndex: Int?
            var sourceIndex: Int?

            if lineIndex + 1 < blockEnd {
                for index in (lineIndex + 1)..<blockEnd {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix("db_id:") {
                        dbIdIndex = index
                    } else if candidate.hasPrefix("name:") {
                        nameIndex = index
                    } else if candidate.hasPrefix("source:") {
                        sourceIndex = index
                    }
                }
            }

            let dbIdLine = #"    db_id: "\#(resolvedPersistentId)""#
            let nameLine = #"    name: "\#(escapeYAML(name))""#
            let sourceLine = "    source: \(source)"
            var nextInsertIndex = lineIndex + 1

            if let dbIdIndex {
                lines[dbIdIndex] = dbIdLine
                nextInsertIndex = dbIdIndex + 1
            } else {
                lines.insert(dbIdLine, at: nextInsertIndex)
                if let existingNameIndex = nameIndex, existingNameIndex >= nextInsertIndex {
                    nameIndex = existingNameIndex + 1
                }
                if let existingSourceIndex = sourceIndex, existingSourceIndex >= nextInsertIndex {
                    sourceIndex = existingSourceIndex + 1
                }
                nextInsertIndex += 1
            }

            if let nameIndex {
                lines[nameIndex] = nameLine
                nextInsertIndex = nameIndex + 1
            } else {
                lines.insert(nameLine, at: nextInsertIndex)
                if let existingSourceIndex = sourceIndex, existingSourceIndex >= nextInsertIndex {
                    sourceIndex = existingSourceIndex + 1
                }
                nextInsertIndex += 1
            }

            let writtenSourceIndex: Int
            if let sourceIndex {
                lines[sourceIndex] = sourceLine
                writtenSourceIndex = sourceIndex
            } else {
                lines.insert(sourceLine, at: nextInsertIndex)
                writtenSourceIndex = nextInsertIndex
            }

            if let nameSource {
                lines.insert("    name_source: \(nameSource)", at: writtenSourceIndex + 1)
            }

            content.replaceSubrange(frontmatterRange, with: lines.joined(separator: "\n"))
            return
        }
    }

    static func frontmatterContentRange(in content: String) -> Range<String.Index>? {
        guard content.hasPrefix("---\n"),
              let endRange = content.range(
                of: "\n---\n",
                range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex
              ) else {
            return nil
        }

        return content.index(content.startIndex, offsetBy: 4)..<endRange.lowerBound
    }

    static func speakerBlockMatchesChannel(
        _ block: ArraySlice<String>,
        channel: UtteranceChannel
    ) -> Bool {
        let expectedLine = "channel: \(channel.rawValue)"
        let normalizedBlock = block.map { $0.trimmingCharacters(in: .whitespaces) }
        if normalizedBlock.contains(expectedLine) {
            return true
        }

        // Older transcripts predate explicit channel metadata. Treat a missing channel
        // line as the legacy system-audio case so historical rename flows still work.
        if channel == .system {
            return !normalizedBlock.contains(where: { $0.hasPrefix("channel:") })
        }

        return false
    }
}

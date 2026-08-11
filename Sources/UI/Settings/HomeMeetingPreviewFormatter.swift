import Foundation

enum HomeMeetingSpeakerChannel: String, Equatable, Hashable, Sendable {
    case mic
    case system
}

struct HomeMeetingSpeakerIdentity: Equatable, Hashable, Sendable {
    let displayName: String
    /// Exact label inside the transcript's brackets, including source and any
    /// Obsidian link syntax. This lets legacy transcript-scoped edits stay exact.
    let rawLabel: String
    let channel: HomeMeetingSpeakerChannel?
    let diarizerSpeakerID: String?
    let persistentSpeakerID: UUID?

    /// Stable UI/persistence key for one detected voice. The rendered name is
    /// intentionally not part of the key: correcting a name must not create a
    /// different row, and duplicate visible names must stay distinguishable.
    var stableID: String {
        if let persistentSpeakerID {
            return "profile:\(persistentSpeakerID.uuidString.lowercased())"
        }
        if let diarizerSpeakerID {
            return "voice:\(channel?.rawValue ?? "unknown"):\(diarizerSpeakerID)"
        }
        return "label:\(channel?.rawValue ?? "unknown"):\(rawLabel)"
    }
}

/// One explicit speaker correction staged by the meeting transcript UI.
/// `targetProfileID` is preserved separately from `newName`, so choosing one
/// of two saved people with the same display name never becomes ambiguous.
struct HomeMeetingSpeakerAssignment: Equatable, Sendable {
    let identity: HomeMeetingSpeakerIdentity
    let newName: String
    let targetProfileID: UUID?
    /// True only when a transcript references a profile that no longer exists.
    /// Keeps stale-link repair explicit instead of inferring it from a missing
    /// identity, which could otherwise unlink a profile added after preview load.
    let removesPersistentSpeakerLink: Bool

    init(
        identity: HomeMeetingSpeakerIdentity,
        newName: String,
        targetProfileID: UUID?,
        removesPersistentSpeakerLink: Bool = false
    ) {
        self.identity = identity
        self.newName = newName
        self.targetProfileID = targetProfileID
        self.removesPersistentSpeakerLink = removesPersistentSpeakerLink
    }
}

struct HomeMeetingSpeakerAssignmentPlan: Equatable, Sendable {
    let localAssignments: [HomeMeetingSpeakerAssignment]
    let savedAssignments: [HomeMeetingSpeakerAssignment]
}

struct HomeMeetingSpeakerNamingDraft: Identifiable, Equatable, Sendable {
    var id: String { identity.stableID }
    let identity: HomeMeetingSpeakerIdentity
    let sampleTexts: [String]
    var name: String
    var selectedProfileID: UUID?
}

enum HomeMeetingSpeakerNamingPolicy {
    private static let sampleLimit = 2

    /// Builds one first-seen row per actual voice, with up to two useful quotes
    /// to make identification possible without scrubbing through the meeting.
    static func drafts(from lines: [HomeMeetingTranscriptLine]) -> [HomeMeetingSpeakerNamingDraft] {
        var drafts: [HomeMeetingSpeakerNamingDraft] = []
        var indexByID: [String: Int] = [:]

        for line in lines {
            let id = line.identity.stableID
            let sample = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = indexByID[id] {
                if !sample.isEmpty,
                   drafts[index].sampleTexts.count < sampleLimit,
                   !drafts[index].sampleTexts.contains(sample) {
                    drafts[index] = HomeMeetingSpeakerNamingDraft(
                        identity: drafts[index].identity,
                        sampleTexts: drafts[index].sampleTexts + [sample],
                        name: drafts[index].name,
                        selectedProfileID: drafts[index].selectedProfileID
                    )
                }
                continue
            }

            indexByID[id] = drafts.count
            drafts.append(HomeMeetingSpeakerNamingDraft(
                identity: line.identity,
                sampleTexts: sample.isEmpty ? [] : [sample],
                name: line.identity.displayName,
                selectedProfileID: nil
            ))
        }

        return drafts
    }

    static func assignment(from draft: HomeMeetingSpeakerNamingDraft) -> HomeMeetingSpeakerAssignment? {
        let normalizedName = normalize(draft.name)
        guard !normalizedName.isEmpty else { return nil }

        let selectedDifferentProfile = draft.selectedProfileID != nil
            && draft.selectedProfileID != draft.identity.persistentSpeakerID
        guard selectedDifferentProfile || normalizedName != draft.identity.displayName else { return nil }

        return HomeMeetingSpeakerAssignment(
            identity: draft.identity,
            newName: normalizedName,
            targetProfileID: selectedDifferentProfile ? draft.selectedProfileID : nil
        )
    }

    static func assignments(from drafts: [HomeMeetingSpeakerNamingDraft]) -> [HomeMeetingSpeakerAssignment] {
        drafts.compactMap(assignment(from:))
    }

    /// Routes each edit through the strongest persistence path that still
    /// exists. Older transcripts can retain a `db_id` after that profile was
    /// merged or deleted. Those stale links must fall back to an exact,
    /// transcript-local rewrite instead of making Save fail forever.
    ///
    /// A stale saved identity can cover more than one diarizer row in the
    /// meeting, so expand it back to every matching row before clearing the
    /// dead link. Selected target profiles still have to exist; otherwise the
    /// whole plan fails before any file or database mutation begins.
    static func assignmentPlan(
        for assignments: [HomeMeetingSpeakerAssignment],
        transcriptLines: [HomeMeetingTranscriptLine],
        availableProfileIDs: Set<UUID>
    ) -> HomeMeetingSpeakerAssignmentPlan? {
        var localAssignments: [HomeMeetingSpeakerAssignment] = []
        var savedAssignments: [HomeMeetingSpeakerAssignment] = []

        for assignment in assignments {
            if let targetProfileID = assignment.targetProfileID,
               !availableProfileIDs.contains(targetProfileID) {
                return nil
            }

            guard let sourceProfileID = assignment.identity.persistentSpeakerID else {
                localAssignments.append(assignment)
                continue
            }
            guard !availableProfileIDs.contains(sourceProfileID) else {
                savedAssignments.append(assignment)
                continue
            }

            let matchingIdentities = transcriptLines
                .map(\.identity)
                .filter { $0.persistentSpeakerID == sourceProfileID }
            let distinctIdentities = uniqueLocalIdentities(
                matchingIdentities.isEmpty ? [assignment.identity] : matchingIdentities
            )
            localAssignments.append(contentsOf: distinctIdentities.map { identity in
                HomeMeetingSpeakerAssignment(
                    identity: identity,
                    newName: assignment.newName,
                    targetProfileID: assignment.targetProfileID,
                    removesPersistentSpeakerLink: true
                )
            })
        }

        return HomeMeetingSpeakerAssignmentPlan(
            localAssignments: localAssignments,
            savedAssignments: savedAssignments
        )
    }

    /// Returns a safe sequential order for saved-profile mutations. Renames
    /// happen first, then merge chains run from their leaves toward the final
    /// target (A -> B before B -> C). Cycles and duplicate source mutations
    /// fail closed before any profile is changed.
    static func savedAssignmentsInCommitOrder(
        _ assignments: [HomeMeetingSpeakerAssignment]
    ) -> [HomeMeetingSpeakerAssignment]? {
        var sourceIDs = Set<UUID>()
        for assignment in assignments {
            guard let sourceID = assignment.identity.persistentSpeakerID,
                  sourceIDs.insert(sourceID).inserted else { return nil }
        }

        let renames = assignments.filter {
            $0.targetProfileID == nil || $0.targetProfileID == $0.identity.persistentSpeakerID
        }
        let merges = assignments.enumerated().compactMap { index, assignment
            -> (index: Int, assignment: HomeMeetingSpeakerAssignment)? in
            guard let sourceID = assignment.identity.persistentSpeakerID,
                  let targetID = assignment.targetProfileID,
                  targetID != sourceID else { return nil }
            return (index, assignment)
        }
        guard let mergeTargets = mergeTargetsBySource(from: assignments) else { return nil }

        var orderedMerges: [(index: Int, depth: Int, assignment: HomeMeetingSpeakerAssignment)] = []
        for merge in merges {
            guard let sourceID = merge.assignment.identity.persistentSpeakerID,
                  let depth = mergeDepth(from: sourceID, mergeTargets: mergeTargets) else {
                return nil
            }
            orderedMerges.append((merge.index, depth, merge.assignment))
        }
        orderedMerges.sort { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth > rhs.depth }
            return lhs.index < rhs.index
        }
        return renames + orderedMerges.map(\.assignment)
    }

    /// A local transcript row may be linked to a profile that the same batch
    /// merges into another profile. Point that row at the final surviving UUID
    /// so the saved Markdown never receives a dangling `db_id`.
    static func remappingLocalTargets(
        _ assignments: [HomeMeetingSpeakerAssignment],
        after savedAssignments: [HomeMeetingSpeakerAssignment]
    ) -> [HomeMeetingSpeakerAssignment]? {
        guard let mergeTargets = mergeTargetsBySource(from: savedAssignments) else { return nil }
        var remapped: [HomeMeetingSpeakerAssignment] = []
        for assignment in assignments {
            guard let targetID = assignment.targetProfileID else {
                remapped.append(assignment)
                continue
            }
            guard let resolvedTargetID = finalTarget(
                from: targetID,
                mergeTargets: mergeTargets
            ) else { return nil }
            remapped.append(HomeMeetingSpeakerAssignment(
                identity: assignment.identity,
                newName: assignment.newName,
                targetProfileID: resolvedTargetID,
                removesPersistentSpeakerLink: assignment.removesPersistentSpeakerLink
            ))
        }
        return remapped
    }

    private static func normalize(_ raw: String) -> String {
        raw
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func uniqueLocalIdentities(
        _ identities: [HomeMeetingSpeakerIdentity]
    ) -> [HomeMeetingSpeakerIdentity] {
        var seen = Set<String>()
        return identities.filter { identity in
            let key = [
                identity.channel?.rawValue ?? "unknown",
                identity.diarizerSpeakerID ?? "",
                identity.rawLabel,
            ].joined(separator: "|")
            return seen.insert(key).inserted
        }
    }

    private static func mergeTargetsBySource(
        from assignments: [HomeMeetingSpeakerAssignment]
    ) -> [UUID: UUID]? {
        var result: [UUID: UUID] = [:]
        for assignment in assignments {
            guard let sourceID = assignment.identity.persistentSpeakerID,
                  let targetID = assignment.targetProfileID,
                  targetID != sourceID else { continue }
            if let existing = result[sourceID], existing != targetID { return nil }
            result[sourceID] = targetID
        }
        for sourceID in result.keys {
            guard finalTarget(from: sourceID, mergeTargets: result) != nil else { return nil }
        }
        return result
    }

    private static func mergeDepth(
        from sourceID: UUID,
        mergeTargets: [UUID: UUID]
    ) -> Int? {
        var currentID = sourceID
        var visited = Set<UUID>()
        var depth = 0
        while let targetID = mergeTargets[currentID] {
            guard visited.insert(currentID).inserted else { return nil }
            currentID = targetID
            depth += 1
        }
        return depth
    }

    private static func finalTarget(
        from sourceID: UUID,
        mergeTargets: [UUID: UUID]
    ) -> UUID? {
        var currentID = sourceID
        var visited = Set<UUID>()
        while let targetID = mergeTargets[currentID] {
            guard visited.insert(currentID).inserted else { return nil }
            currentID = targetID
        }
        return currentID
    }
}

struct HomeMeetingPreviewContent {
    let fallbackText: String
    let transcriptLines: [HomeMeetingTranscriptLine]

    static func make(from markdown: String) -> HomeMeetingPreviewContent {
        let readableLines = readableMarkdownLines(from: markdown)
        let speakers = frontmatterSpeakers(from: markdown)
        return HomeMeetingPreviewContent(
            fallbackText: readableLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            transcriptLines: parseTranscriptLines(readableLines, speakers: speakers)
        )
    }

    private static func readableMarkdownLines(from markdown: String) -> [String] {
        var lines = markdown.components(separatedBy: .newlines)

        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
           let endIndex = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) {
            lines.removeSubrange(...endIndex)
        }

        if let transcriptIndex = lines.firstIndex(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == "## Full Transcript" || trimmed == "## Transcript"
        }) {
            lines = Array(lines.dropFirst(transcriptIndex + 1))
        }

        return lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed != "---" && !trimmed.hasPrefix("*Generated by Transcripted")
        }
    }

    private static func parseTranscriptLines(
        _ lines: [String],
        speakers: [FrontmatterSpeaker]
    ) -> [HomeMeetingTranscriptLine] {
        var parsed: [HomeMeetingTranscriptLine] = []
        var pending: PendingTranscriptLine?

        func flushPending() {
            guard let current = pending else { return }
            let text = current.textParts
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                parsed.append(HomeMeetingTranscriptLine(
                    time: current.time,
                    startTimeSeconds: timestampSeconds(current.time),
                    identity: current.identity,
                    text: text
                ))
            }
            pending = nil
        }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let marker = parseTranscriptMarker(trimmed) {
                flushPending()
                pending = PendingTranscriptLine(
                    time: marker.time,
                    identity: speakerIdentity(for: marker.rawSpeakerLabel, speakers: speakers),
                    textParts: marker.remainder.isEmpty ? [] : [marker.remainder]
                )
                continue
            }

            if pending != nil, !isSectionNoise(trimmed) {
                pending?.textParts.append(trimmed)
            }
        }

        flushPending()
        return parsed
    }

    private static func parseTranscriptMarker(_ line: String) -> TranscriptMarker? {
        if line.hasPrefix("**") {
            return parseBoldTimestampMarker(line)
        }
        if line.hasPrefix("[") {
            return parseBracketTimestampMarker(line)
        }
        return nil
    }

    private static func parseBoldTimestampMarker(_ line: String) -> TranscriptMarker? {
        let timeStart = line.index(line.startIndex, offsetBy: 2)
        guard let timeEnd = line[timeStart...].range(of: "**")?.lowerBound else { return nil }
        let time = String(line[timeStart..<timeEnd])
        guard looksLikeTimestamp(time) else { return nil }
        let remainderStart = line.index(timeEnd, offsetBy: 2)
        let remainder = String(line[remainderStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return parseSpeakerAndText(time: time, remainder: remainder)
    }

    private static func parseBracketTimestampMarker(_ line: String) -> TranscriptMarker? {
        // Defensive parity with RecentCaptureScanners' sibling parser: this function
        // assumes a leading "[". Without the hasPrefix guard, firstIndex(of: "]")
        // landing at startIndex (a line that never had a leading "[") would make
        // line.index(after: line.startIndex) step past it, producing an inverted
        // range and trapping.
        guard line.hasPrefix("["), let timeEnd = line.firstIndex(of: "]") else { return nil }
        let time = String(line[line.index(after: line.startIndex)..<timeEnd])
        guard looksLikeTimestamp(time) else { return nil }
        let remainder = line[line.index(after: timeEnd)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return parseSpeakerAndText(time: time, remainder: remainder)
    }

    private static func parseSpeakerAndText(time: String, remainder: String) -> TranscriptMarker {
        var rawSpeakerLabel = "Speaker"
        var text = remainder

        if text.hasPrefix("["),
           let speakerEnd = matchingClosingBracket(in: text) {
            rawSpeakerLabel = String(text[text.index(after: text.startIndex)..<speakerEnd])
            text = text[text.index(after: speakerEnd)...].trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return TranscriptMarker(time: time, rawSpeakerLabel: rawSpeakerLabel, remainder: text)
    }

    /// Finds the outer closing bracket, so `[System/[[Alex]]]` does not stop
    /// at the first bracket in the nested Obsidian link.
    private static func matchingClosingBracket(in value: String) -> String.Index? {
        var depth = 0
        for index in value.indices {
            switch value[index] {
            case "[":
                depth += 1
            case "]":
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
        }
        return nil
    }

    private static func speakerIdentity(
        for rawLabel: String,
        speakers: [FrontmatterSpeaker]
    ) -> HomeMeetingSpeakerIdentity {
        let trimmedRawLabel = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let split = trimmedRawLabel.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)

        let channel: HomeMeetingSpeakerChannel?
        let sourceName: String
        if split.count == 2,
           let parsedChannel = sourceChannel(String(split[0])) {
            channel = parsedChannel
            sourceName = cleanSpeaker(String(split[1]))
        } else {
            channel = nil
            sourceName = cleanSpeaker(trimmedRawLabel)
        }

        let displayName = sourceName.isEmpty ? "Speaker" : sourceName
        let candidates = speakers.filter { speaker in
            speaker.name == displayName && (channel == nil || speaker.channel == channel)
        }
        let matchedSpeaker: FrontmatterSpeaker?
        if candidates.count == 1 {
            matchedSpeaker = candidates[0]
        } else if let genericID = genericSpeakerID(from: displayName) {
            let matchingIDs = candidates.filter { $0.id == genericID }
            matchedSpeaker = matchingIDs.count == 1 ? matchingIDs[0] : nil
        } else {
            matchedSpeaker = nil
        }

        return HomeMeetingSpeakerIdentity(
            displayName: displayName,
            rawLabel: trimmedRawLabel,
            channel: channel,
            diarizerSpeakerID: matchedSpeaker?.id,
            persistentSpeakerID: matchedSpeaker?.dbID
        )
    }

    private static func sourceChannel(_ value: String) -> HomeMeetingSpeakerChannel? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "mic": return .mic
        case "system": return .system
        default: return nil
        }
    }

    private static func cleanSpeaker(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func genericSpeakerID(from name: String) -> String? {
        let prefix = "Speaker "
        guard name.hasPrefix(prefix) else { return nil }
        let suffix = String(name.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? nil : suffix
    }

    private static func looksLikeTimestamp(_ value: String) -> Bool {
        let parts = value.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func timestampSeconds(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":").compactMap { TimeInterval($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        if parts.count == 3 {
            return (parts[0] * 3_600) + (parts[1] * 60) + parts[2]
        }
        return (parts[0] * 60) + parts[1]
    }

    private static func isSectionNoise(_ line: String) -> Bool {
        line.hasPrefix("#") || line.hasPrefix("Recorded ")
    }

    private struct FrontmatterSpeaker {
        let id: String
        let channel: HomeMeetingSpeakerChannel
        let dbID: UUID?
        let name: String
    }

    private static func frontmatterSpeakers(from markdown: String) -> [FrontmatterSpeaker] {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return [] }

        var speakers: [FrontmatterSpeaker] = []
        var inSpeakersBlock = false
        var current: [String: String]?

        func finishCurrent() {
            guard let current,
                  let id = current["id"],
                  let name = current["name"] else { return }
            let channel = current["channel"]
                .flatMap(sourceChannel) ?? .system
            speakers.append(FrontmatterSpeaker(
                id: id,
                channel: channel,
                dbID: current["db_id"].flatMap(UUID.init(uuidString:)),
                name: cleanSpeaker(name)
            ))
        }

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                finishCurrent()
                break
            }
            if trimmed == "speakers:" {
                inSpeakersBlock = true
                continue
            }
            guard inSpeakersBlock else { continue }

            if !line.hasPrefix("  "), !trimmed.isEmpty {
                finishCurrent()
                break
            }
            if trimmed.hasPrefix("- ") {
                finishCurrent()
                current = [:]
                writeKeyValue(String(trimmed.dropFirst(2)), into: &current)
            } else if current != nil {
                writeKeyValue(trimmed, into: &current)
            }
        }

        return speakers
    }

    private static func writeKeyValue(_ line: String, into current: inout [String: String]?) {
        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = parts[1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
        current?[key] = value
    }
}

struct HomeMeetingTranscriptLine: Equatable {
    let time: String
    let startTimeSeconds: TimeInterval?
    let identity: HomeMeetingSpeakerIdentity
    let text: String

    var speaker: String { identity.displayName }
}

enum HomeMeetingTranscriptPlaybackSource: Equatable {
    case all
    case mic
    case system
}

enum HomeMeetingTranscriptPlaybackPolicy {
    static func source(forPlaybackChoiceID choiceID: String?) -> HomeMeetingTranscriptPlaybackSource {
        guard let stem = choiceID?.split(separator: ":", maxSplits: 1).first else { return .all }
        switch stem {
        case "microphone": return .mic
        case "system_audio": return .system
        default: return .all
        }
    }

    static func activeLineIndices(
        lines: [HomeMeetingTranscriptLine],
        currentTime: TimeInterval,
        source: HomeMeetingTranscriptPlaybackSource
    ) -> Set<Int> {
        let eligible = lines.enumerated().compactMap { index, line -> (Int, TimeInterval)? in
            guard let start = line.startTimeSeconds,
                  start <= currentTime,
                  sourceMatches(line.identity.channel, source: source) else { return nil }
            return (index, start)
        }
        guard let activeTime = eligible.map(\.1).max() else { return [] }
        return Set(eligible.filter { $0.1 == activeTime }.map(\.0))
    }

    static func visibleLineIndices(
        totalCount: Int,
        activeIndices: Set<Int>,
        limit: Int
    ) -> [Int] {
        guard totalCount > 0, limit > 0 else { return [] }
        guard totalCount > limit else { return Array(0..<totalCount) }
        guard let firstActive = activeIndices.min() else { return Array(0..<limit) }

        let lastActive = activeIndices.max() ?? firstActive
        var start = max(0, firstActive - (limit / 2))
        start = min(start, totalCount - limit)
        if lastActive >= start + limit {
            start = min(lastActive - limit + 1, totalCount - limit)
        }
        return Array(start..<(start + limit))
    }

    private static func sourceMatches(
        _ channel: HomeMeetingSpeakerChannel?,
        source: HomeMeetingTranscriptPlaybackSource
    ) -> Bool {
        switch source {
        case .all:
            return true
        case .mic:
            return channel == .mic || channel == nil
        case .system:
            return channel == .system || channel == nil
        }
    }
}

private struct PendingTranscriptLine {
    let time: String
    let identity: HomeMeetingSpeakerIdentity
    var textParts: [String]
}

private struct TranscriptMarker {
    let time: String
    let rawSpeakerLabel: String
    let remainder: String
}

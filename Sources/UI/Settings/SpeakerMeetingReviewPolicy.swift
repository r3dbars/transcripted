// SpeakerMeetingReviewPolicy.swift
// Settings › Speakers asks "Who spoke?" one saved meeting at a time, with the
// island's own review drawn as a card (NotchIslandSpeakerReviewView,
// `Chrome.page`). This file is what the page says around it and what its
// answers save as:
//   - the headline ("12 voices from your meetings need a name"), "Meeting 1
//     of 8" and the segmented bar;
//   - the card's title, Skip and "Done, next meeting";
//   - a likely name for a voice ("Marcus Reed?") from the saved voice
//     matches, so the card can ask ✓ / ✕ the way the island does;
//   - how the island's `SpeakerReviewUpdate`s turn into the page's saves;
//   - the Meetings row's "2 to name".
// `SpeakerMeetingReviewState` is one visit's progress: meetings done, the one
// just finished (Undo puts it back until its answers save), and a meeting the
// Meetings page asked for. Foundation-only so the fast tests can compile it.

import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

enum SpeakerMeetingReviewPolicy {
    /// How long "Weekly sync is done" offers Undo before its answers save.
    static let undoSeconds: Double = 6
    /// The longest Quit waits for answers already given to save.
    static let terminationWaitSeconds: Double = 5
    /// The bar never gets busier than this; with more meetings each segment
    /// stands for several.
    static let maxSegments = 12

    // MARK: Around the card

    /// "12 voices from your meetings need a name", or nil when none do.
    static func headline(voiceCount: Int) -> String? {
        switch voiceCount {
        case ..<1: return nil
        case 1: return "1 voice from your meetings needs a name"
        default: return "\(voiceCount) voices from your meetings need a name"
        }
    }

    struct Position: Equatable {
        /// 1-based: the meeting on the card now.
        let current: Int
        let total: Int
    }

    /// Where this visit is: meetings done so far plus the one on the card.
    static func position(meetingsDone: Int, meetingsLeft: Int) -> Position? {
        guard meetingsLeft > 0 else { return nil }
        let done = max(0, meetingsDone)
        return Position(current: done + 1, total: done + meetingsLeft)
    }

    /// "Meeting 1 of 8"
    static func positionLine(_ position: Position) -> String {
        "Meeting \(position.current) of \(position.total)"
    }

    struct Progress: Equatable {
        let segments: Int
        /// Segments lit, counting the meeting on the card.
        let lit: Int
    }

    static func progress(_ position: Position) -> Progress {
        let total = max(1, position.total)
        let segments = min(total, maxSegments)
        let current = min(max(1, position.current), total)
        let lit = Int((Double(current) / Double(total) * Double(segments)).rounded(.up))
        return Progress(segments: segments, lit: min(max(1, lit), segments))
    }

    // MARK: The card

    /// "Who spoke? · Weekly sync"
    static func cardTitle(meetingTitle: String) -> String {
        let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Who spoke?" : "Who spoke? \u{00B7} \(title)"
    }

    /// The main button: on to the next meeting, or just Done on the last one.
    static func doneTitle(meetingsAfterThis: Int) -> String {
        meetingsAfterThis > 0 ? "Done, next meeting" : "Done"
    }

    static let skipTitle = "Skip"
    static let skipHelp = "Save what you answered and stop asking about this meeting. Its other voices stay under Not named yet."

    /// The finished card's second line.
    static func doneDetail(names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: ", ")
        let rest = names.count - min(names.count, 3)
        let list = rest > 0 ? "\(shown) and \(rest) more" : shown
        return list.isEmpty ? "Saving in a moment." : "\(list). Saving in a moment."
    }

    /// Some answers didn't save. The voices are still unnamed, so their
    /// meeting's card comes back.
    static func saveFailedLine(meetingTitle: String, failed: Int) -> String {
        let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = failed == 1 ? "1 name" : "\(max(failed, 0)) names"
        let from = title.isEmpty ? "" : " from \(title)"
        return "Couldn't save \(names)\(from). Its card is back so you can try again."
    }

    /// The list under the cards: "People Transcripted knows".
    static let directoryTitle = "People Transcripted knows"

    // MARK: A likely name

    /// A saved person this unnamed voice probably is: the closest named
    /// profile the duplicate check matched by voice. Nil when there's none.
    static func guess(for voiceID: UUID, among candidates: [SpeakerDuplicateCandidate]) -> (person: SpeakerProfile, similarity: Double)? {
        var best: (person: SpeakerProfile, similarity: Double)?
        for candidate in candidates {
            guard candidate.reason.includesVoiceMatch, let similarity = candidate.voiceSimilarity else { continue }
            let other: SpeakerProfile
            if candidate.source.id == voiceID {
                other = candidate.target
            } else if candidate.target.id == voiceID {
                other = candidate.source
            } else {
                continue
            }
            guard let name = other.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  !SpeakerNameSelectionPolicy.isOwnerLabel(name) else { continue }
            if best == nil || similarity > best!.similarity {
                best = (other, similarity)
            }
        }
        return best
    }

    // MARK: Saving

    /// One save the page runs for an answer on the card.
    enum Step: Equatable {
        /// A typed name: a new person, or someone saved when exactly one has it.
        case name(voiceID: UUID, name: String)
        /// ✓ on a guess, or a saved person picked from the list.
        case join(voiceID: UUID, personID: UUID, name: String)
        /// "All me", or picking Me.
        case markAsMe(voiceID: UUID)
        /// "Not a person": the voice is deleted from People.
        case notAPerson(voiceID: UUID)

        var voiceID: UUID {
            switch self {
            case .name(let id, _), .join(let id, _, _), .markAsMe(let id), .notAPerson(let id): return id
            }
        }

        /// The name it saves under, for the finished card's line.
        var savedName: String? {
            switch self {
            case .name(_, let name), .join(_, _, let name): return name
            case .markAsMe: return SpeakerNameSelectionPolicy.ownerLabel
            case .notAPerson: return nil
            }
        }
    }

    /// When a `.join` target is gone from People, name the voice only if this
    /// is still a real name. Nil leaves the voice unresolved.
    static func fallbackNameAfterMissingJoin(_ name: String) -> String? {
        name
    }

    /// The island's answers as the page's saves, one per voice, in order.
    static func steps(for updates: [SpeakerReviewUpdate]) -> [Step] {
        var seen = Set<UUID>()
        return updates.compactMap { update in
            let voiceID = update.persistentSpeakerId
            guard seen.insert(voiceID).inserted else { return nil }
            let name = update.newName.trimmingCharacters(in: .whitespacesAndNewlines)
            switch update.action {
            case .merged(let target):
                return target == voiceID ? .name(voiceID: voiceID, name: name) : .join(voiceID: voiceID, personID: target, name: name)
            case .collapsedToMe:
                return .markAsMe(voiceID: voiceID)
            case .discardedFromDatabase:
                return .notAPerson(voiceID: voiceID)
            case .named, .confirmed, .corrected:
                guard !name.isEmpty else { return nil }
                return SpeakerNameSelectionPolicy.isOwnerLabel(name) ? .markAsMe(voiceID: voiceID) : .name(voiceID: voiceID, name: name)
            }
        }
    }

    /// Voices the steps give a name ("Not a person" doesn't count).
    static func namedCount(_ steps: [Step]) -> Int {
        steps.filter { $0.savedName != nil }.count
    }

    // MARK: Meetings page

    /// The row's pill: "2 to name", or nil.
    static func rowPill(voicesToName: Int) -> String? {
        voicesToName > 0 ? "\(voicesToName) to name" : nil
    }
}

/// One visit to the Speakers page's "Who spoke?" cards.
struct SpeakerMeetingReviewState: Equatable {
    /// A card just finished: its answers wait `undoSeconds` before saving.
    struct Finished: Equatable {
        let callKey: String
        let title: String
        let names: [String]
        let personIDs: [UUID]
        let token: UUID
    }

    private(set) var meetingsDone = 0
    /// Finished, still undoable.
    private(set) var finished: Finished?
    /// Finished cards whose answers are saving; they stay off the stack
    /// until the refreshed queue no longer lists them.
    private(set) var savingCallKeys: Set<String> = []
    /// A card the Meetings page asked for.
    private(set) var focusedCallKey: String?

    /// Cards kept off the stack: the one that can still be undone and the
    /// ones saving.
    var heldOutCallKeys: Set<String> {
        var keys = savingCallKeys
        if let finished { keys.insert(finished.callKey) }
        return keys
    }

    mutating func focus(_ callKey: String?) {
        focusedCallKey = callKey
    }

    /// Done on a card. Returns the card that was waiting on Undo, if any,
    /// which must save now.
    mutating func finish(_ next: Finished) -> Finished? {
        let previous = finished
        if let previous { savingCallKeys.insert(previous.callKey) }
        finished = next
        meetingsDone += 1
        if focusedCallKey == next.callKey { focusedCallKey = nil }
        return previous
    }

    /// Undo on the finished card: it comes back to the top.
    mutating func undo(token: UUID) -> Finished? {
        guard let finished, finished.token == token else { return nil }
        self.finished = nil
        meetingsDone = max(0, meetingsDone - 1)
        focusedCallKey = finished.callKey
        return finished
    }

    /// The finished card's time ran out (or the page closed): it saves now.
    mutating func startSaving(token: UUID) -> Finished? {
        guard let finished, finished.token == token else { return nil }
        self.finished = nil
        savingCallKeys.insert(finished.callKey)
        return finished
    }

    /// Its saves finished; the refreshed queue decides whether it's gone.
    mutating func saved(callKey: String) {
        savingCallKeys.remove(callKey)
    }

    /// Skip on a card: it counts as done for this visit and stays off the
    /// stack while its answers save.
    mutating func skipped(callKey: String) {
        meetingsDone += 1
        savingCallKeys.insert(callKey)
        if focusedCallKey == callKey { focusedCallKey = nil }
    }

    /// A skipped card's answers didn't all save: it isn't skipped after all.
    mutating func skipFailed(callKey: String) {
        guard savingCallKeys.remove(callKey) != nil else { return }
        meetingsDone = max(0, meetingsDone - 1)
    }

    /// Nothing left to ask: the next visit starts from Meeting 1.
    mutating func resetProgressIfIdle(meetingsLeft: Int) {
        guard meetingsLeft == 0, finished == nil, savingCallKeys.isEmpty else { return }
        meetingsDone = 0
        focusedCallKey = nil
    }
}

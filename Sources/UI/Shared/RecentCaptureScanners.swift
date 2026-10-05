import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

struct RecentMeetingItem: Identifiable, Sendable {
    let title: String
    let date: Date
    let startDate: Date?
    let endDate: Date?
    let transcriptURL: URL
    var audio: MeetingAudioAttachment?
    let speakerStatus: RecentMeetingSpeakerStatus
    var audioHealth: RecentMeetingAudioHealth? = nil
    /// Nil is legacy/imported/unknown; only explicit false warrants the hint.
    var systemAudioSignalVerified: Bool? = nil
    /// Named speakers from the transcript body, for the Home meetings search.
    /// Generic labels ("You", "Speaker 2") are left out.
    var speakerNames: [String] = []
    /// Raw `transcription_engine` frontmatter id (e.g. `parakeet_local`), or
    /// nil for files saved without one.
    var transcriptionEngine: String? = nil
    /// When an imported file was transcribed (`imported_at`), nil otherwise.
    var importedAt: Date? = nil

    /// Where Home lists the row: an import sits under the day it was
    /// imported, so it shows up at the top instead of weeks back. Everything
    /// else (Today, copy for agents, row times) keeps using the recording
    /// time in `date`.
    var listDate: Date { importedAt ?? date }

    var systemAudioVerificationWarning: String? {
        systemAudioSignalVerified == false ? "System audio unverified" : nil
    }

    var id: String { transcriptURL.path }

    /// The same row with a freshly resolved audio attachment. The search index
    /// keeps rows without audio and resolves it only for the matches it shows.
    func withAudio(_ audio: MeetingAudioAttachment?) -> RecentMeetingItem {
        var copy = self
        copy.audio = audio
        return copy
    }
}

/// Issue #500 post-meeting surfacing: facts read back from the saved
/// transcript's `audio_health` / `mic_boost_prompt` frontmatter keys.
struct RecentMeetingAudioHealth: Equatable, Sendable {
    let micBoostPromptOutcome: String?  // raw frontmatter value; nil when key absent

    static func detect(frontmatter: TranscriptFrontmatterDocument?) -> RecentMeetingAudioHealth? {
        guard frontmatter?.values["audio_health"] == "mic_attenuated_by_call_app" else { return nil }
        return RecentMeetingAudioHealth(micBoostPromptOutcome: frontmatter?.values["mic_boost_prompt"])
    }
}

enum RecentMeetingMicBoostHintPolicy {
    /// Offers "Boost mic next meeting" on a saved meeting whose mic was
    /// muffled by another call app.
    static func shouldOfferEnableAction(
        audioHealth: RecentMeetingAudioHealth?,
        meetingDate: Date,
        voiceProcessingPreferenceEnabled: Bool,
        hintsHiddenThrough: Date?
    ) -> Bool {
        guard let audioHealth else { return false }
        // Boost Mic was accepted in that meeting, so it was already boosted.
        guard audioHealth.micBoostPromptOutcome != "accepted" else { return false }
        // Frontmatter is immutable history. Boost now lasts one meeting, so the
        // preference alone can't tell answered rows from new ones: rows saved
        // before the user last asked for a boost (or before the 1.1.63 move
        // off a saved boost) stay quiet, and later muffled meetings hint again.
        if let hintsHiddenThrough, meetingDate <= hintsHiddenThrough { return false }
        return !voiceProcessingPreferenceEnabled
    }
}

enum RecentMeetingSpeakerStatus: Equatable, Sendable {
    case ready
    case needsReview(Int)

    var summary: String {
        switch self {
        case .ready:
            return "Speakers ready"
        case .needsReview(let count):
            return count == 1 ? "1 speaker label needs a name" : "\(count) speaker labels need names"
        }
    }

    var needsReview: Bool {
        if case .needsReview = self { return true }
        return false
    }

    static func detect(in markdown: String) -> RecentMeetingSpeakerStatus {
        detect(speakerLabels: transcriptSpeakerLabels(in: markdown))
    }

    /// Same as `detect(in:)`, for callers that already pulled the labels out
    /// with `transcriptSpeakerLabels(in:)` (the scanner reuses them for names).
    static func detect(speakerLabels: [String]) -> RecentMeetingSpeakerStatus {
        let genericSpeakers = genericSpeakerLabels(in: speakerLabels)
        guard !genericSpeakers.isEmpty else { return .ready }
        return .needsReview(genericSpeakers.count)
    }

    /// Distinct named speakers, in first-seen order, from labels returned by
    /// `transcriptSpeakerLabels(in:)`. Drops the "Mic/" / "System/" channel
    /// prefix and every generic label, so searching "system" or "speaker"
    /// doesn't match every meeting. Capped so one odd transcript can't bloat
    /// the Home cache.
    static func speakerNames(fromLabels speakerLabels: [String]) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for rawLabel in speakerLabels {
            let name = nameWithoutChannelPrefix(rawLabel)
            guard !name.isEmpty, !isGenericSpeakerName(name) else { continue }
            let key = name.lowercased()
            guard seen.insert(key).inserted else { continue }
            names.append(name)
            if names.count >= maxSpeakerNames { break }
        }
        return names
    }

    private static let maxSpeakerNames = 24

    private static func nameWithoutChannelPrefix(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = trimmed.firstIndex(of: "/") else { return trimmed }
        let channel = trimmed[..<slash].lowercased()
        guard channel == "mic" || channel == "system" else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Placeholder labels that name nobody. "Remote" matches the placeholder
    /// `MeetingTranscriptStyler.buildTitle` skips when naming a meeting.
    private static let placeholderSpeakerNames: Set<String> = ["you", "remote", "remote participant"]

    private static func isGenericSpeakerName(_ name: String) -> Bool {
        if placeholderSpeakerNames.contains(name.lowercased()) { return true }
        return !genericSpeakerLabels(in: [name]).isEmpty
    }

    private static let genericSpeakerRegexes: [NSRegularExpression] = [
        #"(?i)(?:^|[/\[\s])Speaker\s+\d+\b"#,
        #"(?i)\bUnknown speaker\b"#,
        #"(?i)\bReview later\b"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static func genericSpeakerLabels(in speakerLabels: [String]) -> Set<String> {
        var labels = Set<String>()

        let text = speakerLabels.joined(separator: "\n")
        for regex in genericSpeakerRegexes {
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            regex.enumerateMatches(in: text, range: nsRange) { match, _, _ in
                guard let matchRange = match?.range,
                      let range = Range(matchRange, in: text) else { return }
                labels.insert(String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
        }

        return labels
    }

    static func transcriptSpeakerLabels(in markdown: String) -> [String] {
        markdown
            .components(separatedBy: .newlines)
            .compactMap { speakerLabel(fromTranscriptLine: $0) }
    }

    private static func speakerLabel(fromTranscriptLine rawLine: String) -> String? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        if line.hasPrefix("**") {
            let unbolded = line
                .dropFirst(2)
                .trimmingCharacters(in: CharacterSet(charactersIn: "*"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return speakerLabel(fromBoldTimestampLine: line) ?? speakerLabel(fromBracketTimestampLine: unbolded)
        }

        if line.hasPrefix("[") {
            return speakerLabel(fromBracketTimestampLine: line)
        }

        return nil
    }

    private static func speakerLabel(fromBoldTimestampLine line: String) -> String? {
        let timeStart = line.index(line.startIndex, offsetBy: 2)
        guard let timeEnd = line[timeStart...].range(of: "**")?.lowerBound else { return nil }
        let time = String(line[timeStart..<timeEnd])
        guard looksLikeTimestamp(time) else { return nil }
        let remainderStart = line.index(timeEnd, offsetBy: 2)
        return leadingBracketLabel(in: String(line[remainderStart...]))
    }

    private static func speakerLabel(fromBracketTimestampLine line: String) -> String? {
        // Callers besides the direct "[" dispatch (e.g. the bold-prefix fallback in
        // speakerLabel(fromTranscriptLine:)) can hand this a string that never had a
        // leading "[". Without this guard, a line whose first character is "]" (e.g. the
        // malformed "**]" transcript line, which unbolds to "]") makes firstIndex(of: "]")
        // land at startIndex while line.index(after: line.startIndex) steps one past it,
        // producing an inverted range and trapping.
        guard line.hasPrefix("["), let timeEnd = line.firstIndex(of: "]") else { return nil }
        let time = String(line[line.index(after: line.startIndex)..<timeEnd])
        guard looksLikeTimestamp(time) else { return nil }
        let remainder = String(line[line.index(after: timeEnd)...])
        return leadingBracketLabel(in: remainder)
    }

    private static func leadingBracketLabel(in raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("["),
              let end = text.firstIndex(of: "]") else { return nil }
        let rawLabel = String(text[text.index(after: text.startIndex)..<end])
        let label = rawLabel
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }

    private static func looksLikeTimestamp(_ value: String) -> Bool {
        let parts = value.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}

enum RecentMeetingRetranscriptionMenuActionPolicy {
    static func isEnabled(globalUnavailableReason: String?) -> Bool {
        globalUnavailableReason == nil
    }

    /// A greyed-out menu item can't show a tooltip, so a disabled item says
    /// in its own title when it will work again.
    static func title(globalUnavailableReason: String?) -> String {
        guard let globalUnavailableReason else { return "Re-transcribe" }
        return "Re-transcribe (\(SavedMeetingRetranscriptionAvailabilityPolicy.menuHint(for: globalUnavailableReason)))"
    }
}

enum SavedMeetingRetranscriptionAvailabilityPolicy {
    static let dictationActiveReason = "Wait for the current dictation to finish before re-transcribing saved audio."
    static let meetingRecordingReason = "Stop the current recording before re-transcribing saved audio."
    static let preparingModelsReason = "Preparing models..."
    static let meetingWorkReason = "Wait for the current meeting to finish saving or transcribing before re-transcribing saved audio."

    static func unavailableReason(
        isDictationActive: Bool,
        isMeetingRecording: Bool,
        isPreparingModels: Bool,
        hasMeetingWork: Bool
    ) -> String? {
        if isDictationActive {
            return dictationActiveReason
        }
        if isMeetingRecording {
            return meetingRecordingReason
        }
        if isPreparingModels {
            return preparingModelsReason
        }
        if hasMeetingWork {
            return meetingWorkReason
        }
        return nil
    }

    /// The short form of an unavailable reason, for a menu item title.
    static func menuHint(for reason: String) -> String {
        switch reason {
        case dictationActiveReason:
            return "after this dictation"
        case meetingRecordingReason:
            return "after this recording"
        case preparingModelsReason:
            return "once models load"
        case meetingWorkReason:
            return "after the current meeting saves"
        default:
            return "not available right now"
        }
    }
}

/// One row of the Home meetings search index: the row plus the file stamp
/// that lets the next rebuild reuse it without touching disk or SQLite.
struct RecentMeetingIndexEntry: Sendable {
    let path: String
    let stamp: RecentMeetingCacheStamp
    let item: RecentMeetingItem
}

struct RecentCaptureSnapshot: Sendable {
    let meetings: [RecentMeetingItem]
    let dictations: [SavedDictationEntry]
    let dictationCounts: DictationTranscriptCounts
    /// Set only for a `.todayOnly` load: entries in today's day file. A
    /// `.todayOnly` load leaves `dictationCounts` all zeros.
    var todayDictationCount: Int? = nil
    var meetingScanDiagnosis: RecentMeetingsScanDiagnosis = .ok
}

/// How much of the dictation library a recent-captures load counts.
enum DictationCountScope: Sendable {
    case none
    /// Today's day file only (Home's "N today"): one file, however large the library.
    case todayOnly
    /// Every day file: totals, today, and words.
    case fullLibrary
}

enum RecentCaptureLoader {
    static func load(
        dictationLimit: Int,
        meetingLimit: Int,
        includeDictationCounts: Bool = false,
        meetingDirectory: URL? = nil,
        dictationDirectory: URL? = nil,
        today: Date = Date()
    ) async -> RecentCaptureSnapshot {
        await load(
            dictationLimit: dictationLimit,
            meetingLimit: meetingLimit,
            dictationCountScope: includeDictationCounts ? .fullLibrary : .none,
            meetingDirectory: meetingDirectory,
            dictationDirectory: dictationDirectory,
            today: today
        )
    }

    static func load(
        dictationLimit: Int,
        meetingLimit: Int,
        dictationCountScope: DictationCountScope,
        meetingDirectory: URL? = nil,
        dictationDirectory: URL? = nil,
        today: Date = Date()
    ) async -> RecentCaptureSnapshot {
        let taskBox = LoadTaskBox()

        return await withTaskCancellationHandler {
            // A Home refresh cancelled before it even started (the benchmark's
            // cancel, or a refresh replaced right away) never spawns the scan.
            guard !Task.isCancelled else {
                return emptySnapshot()
            }

            // Home drops a cancelled refresh's result, so a cancel hands back an
            // empty snapshot right away instead of waiting on the scan. A big
            // library's directory listing can't be interrupted part way; the
            // scan notices the cancel once that listing returns and stops.
            return await withCheckedContinuation { continuation in
                guard taskBox.install(continuation) else { return }

                let task = Task.detached(priority: .utility) {
                    // The detached task can start before `taskBox.task` is set, so
                    // its own flag may not show a cancel that already happened.
                    // The box's flag is set first, under its lock, so check both.
                    guard !Task.isCancelled, !taskBox.isCancelled else {
                        taskBox.finish(with: emptySnapshot())
                        return
                    }

                    async let meetingScan = RecentMeetingsScanner.loadRecentWithDiagnosis(
                        limit: meetingLimit,
                        directory: meetingDirectory
                    )
                    async let dictations = DictationTranscriptStore.recentSavedDictations(
                        limit: dictationLimit,
                        directory: dictationDirectory
                    )
                    async let dictationCounts = dictationCountScope == .fullLibrary
                        ? DictationTranscriptStore.savedDictationCounts(directory: dictationDirectory, today: today)
                        : DictationTranscriptCounts(total: 0, today: 0, totalWords: 0)
                    async let todayDictationCount: Int? = dictationCountScope == .todayOnly
                        ? DictationTranscriptStore.savedDictationCount(forDayOf: today, directory: dictationDirectory)
                        : nil

                    let snapshot = await RecentCaptureSnapshot(
                        meetings: meetingScan.items,
                        dictations: dictations,
                        dictationCounts: dictationCounts,
                        todayDictationCount: todayDictationCount,
                        meetingScanDiagnosis: meetingScan.diagnosis
                    )
                    guard !Task.isCancelled, !taskBox.isCancelled else {
                        taskBox.finish(with: emptySnapshot())
                        return
                    }

                    taskBox.finish(with: snapshot)
                }

                taskBox.task = task
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    fileprivate static func emptySnapshot() -> RecentCaptureSnapshot {
        RecentCaptureSnapshot(
            meetings: [],
            dictations: [],
            dictationCounts: DictationTranscriptCounts(total: 0, today: 0, totalWords: 0)
        )
    }
}

private final class LoadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<RecentCaptureSnapshot, Never>?
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    var task: Task<Void, Never>? {
        get {
            lock.withLock { storedTask }
        }
        set {
            lock.withLock {
                storedTask = newValue
                if cancelled {
                    newValue?.cancel()
                }
            }
        }
    }

    /// Holds the caller's continuation until the scan finishes or the load is
    /// cancelled. Returns false, having already answered empty, when the
    /// cancel landed first; the caller then must not start a scan.
    func install(_ continuation: CheckedContinuation<RecentCaptureSnapshot, Never>) -> Bool {
        let alreadyCancelled = lock.withLock { () -> Bool in
            if cancelled { return true }
            self.continuation = continuation
            return false
        }
        if alreadyCancelled {
            continuation.resume(returning: RecentCaptureLoader.emptySnapshot())
        }
        return !alreadyCancelled
    }

    /// Answers the caller once; whichever of the scan and the cancel comes
    /// first wins and the other is a no-op.
    func finish(with snapshot: RecentCaptureSnapshot) {
        let pending = lock.withLock { () -> CheckedContinuation<RecentCaptureSnapshot, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: snapshot)
    }

    func cancel() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            cancelled = true
            return storedTask
        }
        task?.cancel()
        finish(with: RecentCaptureLoader.emptySnapshot())
    }
}

/// Why the meetings-folder scan could not list rows. Separates the benign
/// "folder isn't there yet" empty state from a genuinely damaged/broken path
/// (the path exists but isn't a directory, or it can't be read) so Home can
/// surface a named warning only in the second case.
enum RecentMeetingsScanDiagnosis: Equatable, Sendable {
    case ok
    /// Folder does not exist yet — normal first-run empty state, not a warning.
    case missingFolder
    /// The path exists but the app cannot scan it as a meetings folder.
    case damagedPath(reason: RecentMeetingsScanDamageReason)
}

enum RecentMeetingsScanDamageReason: Equatable, Sendable {
    /// The capture-library meetings path resolves to a file, not a folder.
    case notADirectory
    /// The folder exists but its contents could not be listed.
    case unreadable
}

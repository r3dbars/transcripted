// meeting-series: run simulated meetings through the REAL Transcripted meeting
// pipeline and answer the real naming sheet like a user would.
//
// Input is a set written by scripts/speaker_lab/meeting_sim.py:
//   <set>/series.json, <set>/<meeting>/{mic.wav, system.wav, truth.json, calendar.json}
//
// For each meeting, in order:
//   1. Build a real TranscriptionTaskManager (real DiarizationService, real Parakeet
//      via FluidAudio's AsrManager, real SpeakerDatabase) over throwaway temp paths.
//      Fresh-DB meetings get a brand-new database; series meetings share one, so the
//      speaker DB learns across meetings the way it does for a real user.
//   2. startTranscription(micURL:systemURL:splitLocalSpeakers:) on copies of the audio.
//   3. Capture the Phase 1 result (pipelineResultObserver), the naming sheet rows
//      (speakerNamingRequest), and which voices were named silently (frontmatter
//      source "db").
//   4. A simulated user answers every row from the answer key, building updates the
//      same way SpeakerNamingSheet does (Confirm Match -> merged/confirmed; a typed
//      name -> SpeakerNamingPolicy.typedNameUpdate), then calls the request's own
//      onComplete, exactly like pressing Save.
//   5. Write <set>/<meeting>/lab_result.json for scripts/speaker_lab/score.py.
//
// Nothing here touches real user state: every path is under --work (default
// data/eval/yodas3/runs/<set>), stats go to a stub store, and the file logger is off.

import AVFoundation
import FluidAudio
import Foundation
import TranscriptedCore

// MARK: - Answer key (truth.json)

struct LabTruth: Codable {
    struct Participant: Codable {
        let pid: String
        let identity: String
        let name: String
        let role: String
        let channel: String
    }
    struct Segment: Codable {
        let pid: String
        let start: Double
        let end: Double
        let kind: String
    }
    let meeting: String
    let family: String
    let duration_s: Double
    let split_local_speakers: Bool
    let participants: [Participant]
    let segments: [Segment]
}

struct LabSeries: Codable {
    struct Meeting: Codable {
        let id: String
        let family: String
        let split_local_speakers: Bool
        let fresh_db: Bool?
    }
    let set: String
    let meetings: [Meeting]
}

// MARK: - Output (lab_result.json)

struct LabUtterance: Codable {
    let channel: String
    let speakerId: Int
    let persistentId: String?
    let matchSimilarity: Double?
    let start: Double
    let end: Double
    let text: String
}

struct LabRow: Codable {
    let channel: String
    let diarizerSpeakerId: String
    let persistentId: String
    let suggestedProfileId: String?
    let currentName: String?
    let needsNaming: Bool
    let needsConfirmation: Bool
    let matchSimilarity: Double?
    let matchSecondSimilarity: Double?
    let callCount: Int
    let sessionEmbedding: [Float]?
    // answer key
    let truthPid: String?
    let truthName: String?
    let truthShare: Double
    let secondPid: String?
    let secondShare: Double
    // simulated user
    let userAction: String
    let userName: String?
}

struct LabSilentName: Codable {
    let channel: String
    let diarizerSpeakerId: String
    let name: String
    let dbId: String?
    let truthPid: String?
    let truthName: String?
    let truthShare: Double
    let correct: Bool
}

/// Every diarized speaker's voice evidence for this meeting (rows and silent names
/// alike), so naming policies can be replayed offline without rerunning audio.
struct LabSpeakerContext: Codable {
    let channel: String
    let diarizerSpeakerId: String
    let persistentId: String
    let sessionEmbedding: [Float]?
    let matchedProfileId: String?
    let matchedName: String?
    let matchedCallCount: Int?
    let matchSimilarity: Double?
    let matchSecondSimilarity: Double?
    let matchAverageSimilarity: Double?
    let matchSecondBestAverageSimilarity: Double?
    let talkSeconds: Double
    let truthPid: String?
    let truthIdentity: String?
    let truthShare: Double
}

struct LabMeetingResult: Codable {
    let meeting: String
    let family: String
    let freshDB: Bool
    let splitLocalSpeakers: Bool
    let outcome: String
    let processingSeconds: Double
    let systemSpeakerCount: Int
    let micSpeakerCount: Int
    let rows: [LabRow]
    let silentNames: [LabSilentName]
    let utterances: [LabUtterance]
    let profilesAfter: Int
    var speakers: [LabSpeakerContext] = []
    var speakerHint: String = "none"
    var speakerBoundsMin: Int?
    var speakerBoundsMax: Int?
}

// MARK: - Plumbing

final class LabResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TranscriptionResult?
    func set(_ result: TranscriptionResult) { lock.lock(); value = result; lock.unlock() }
    func take() -> TranscriptionResult? { lock.lock(); defer { value = nil; lock.unlock() }; return value }
}

/// Never let a lab run write the user's real StatsDatabase.shared.
final class LabStatsStore: StatsStore {
    func recordSession(_ metadata: RecordingMetadata) {}
    func getTotalRecordingsCount() -> Int { 0 }
    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] { [] }
    func recordingExists(transcriptPath: String) -> Bool { false }
}

/// Parakeet through FluidAudio's AsrManager, packed exactly like the app and
/// `transcripted import-audio` (Tools/TranscriptedCLI MeetingImportSpeechEngine).
@MainActor
final class LabParakeetEngine: SpeechToTextEngine {
    let manager: AsrManager
    var isReady: Bool { true }
    init(manager: AsrManager) { self.manager = manager }
    func initialize() async {}
    func cleanup() {}

    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        var audio = samples
        if audio.count < 16_000 { audio.append(contentsOf: repeatElement(0, count: 16_000 - audio.count)) }
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var packedSegmentWindowSamples: Int? {
        ASRConstants.maxModelSamples - ASRConstants.samplesPerEncoderFrame
    }

    func transcribePackedSegments(
        _ segments: [[Float]],
        source: AudioSource,
        language: TranscriptionLanguageContext
    ) async throws -> [String]? {
        guard segments.count > 1 else { return nil }
        let layout = SpeechSegmentPacking.layout(segments)
        guard layout.samples.count <= ASRConstants.maxModelSamples else { return nil }
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(layout.samples, decoderState: &state)
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Array(repeating: "", count: segments.count) : nil
        }
        let tokens = timings.map { TimedTranscriptToken(text: $0.token, startSeconds: $0.startTime) }
        return SpeechSegmentPacking.split(tokens: tokens, ranges: layout.ranges)
    }
}

/// Which true person each diarizer speaker mostly is, by overlap with the answer key.
struct LabAttribution {
    struct Share { let pid: String?; let share: Double; let secondPid: String?; let secondShare: Double }
    private var shares: [String: Share] = [:]

    init(result: TranscriptionResult, truth: LabTruth) {
        let channelOf = Dictionary(uniqueKeysWithValues: truth.participants.map { ($0.pid, $0.channel) })
        var overlap: [String: [String: Double]] = [:]
        var total: [String: Double] = [:]
        for utterance in result.allUtterances {
            let channel = utterance.channel == 0 ? "mic" : "system"
            let key = "\(channel)_\(utterance.speakerId)"
            total[key, default: 0] += max(0, utterance.end - utterance.start)
            for segment in truth.segments where channelOf[segment.pid] == channel {
                let o = min(utterance.end, segment.end) - max(utterance.start, segment.start)
                if o > 0 { overlap[key, default: [:]][segment.pid, default: 0] += o }
            }
        }
        for (key, byPid) in overlap {
            let ranked = byPid.sorted { $0.value > $1.value }
            let sum = byPid.values.reduce(0, +)
            guard sum > 0 else { continue }
            shares[key] = Share(
                pid: ranked.first?.key, share: (ranked.first?.value ?? 0) / sum,
                secondPid: ranked.count > 1 ? ranked[1].key : nil,
                secondShare: ranked.count > 1 ? ranked[1].value / sum : 0
            )
        }
        for key in total.keys where shares[key] == nil {
            shares[key] = Share(pid: nil, share: 0, secondPid: nil, secondShare: 0)
        }
    }

    func share(channel: String, diarizerSpeakerId: String) -> Share {
        shares["\(channel)_\(diarizerSpeakerId)"] ?? Share(pid: nil, share: 0, secondPid: nil, secondShare: 0)
    }
}

/// Same labels SpeakerNamingSheet shows in its name combobox
/// (Sources/Support/SpeakerNameSelectionPolicy.makeIdentityLabels, app target).
func labIdentityLabels(_ options: [SpeakerIdentityOption]) -> [String: SpeakerIdentityOption] {
    func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    let dupes = Dictionary(grouping: options, by: { norm($0.displayName) }).mapValues(\.count)
    var lookup: [String: SpeakerIdentityOption] = [:]
    for option in options {
        let label: String
        if dupes[norm(option.displayName), default: 0] > 1 {
            let calls = option.callCount == 1 ? "1 call" : "\(option.callCount) calls"
            label = "\(option.displayName) • \(calls) • \(option.id.uuidString.prefix(8))"
        } else {
            label = option.displayName
        }
        lookup[label] = option
    }
    return lookup
}

/// `speakers:` block of a saved transcript's frontmatter.
func labFrontmatterSpeakers(_ url: URL) -> [(id: String, channel: String, dbId: String?, name: String, source: String)] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var out: [(String, String, String?, String, String)] = []
    var current: [String: String] = [:]
    var inSpeakers = false
    func flush() {
        if let id = current["id"], let name = current["name"] {
            out.append((id, current["channel"] ?? "system", current["db_id"], name, current["source"] ?? "unknown"))
        }
        current = [:]
    }
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(raw)
        if line == "---", inSpeakers { flush(); break }
        if line == "speakers:" { inSpeakers = true; continue }
        guard inSpeakers else { continue }
        if !line.hasPrefix("  ") { flush(); break }
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("- ") { flush(); body.removeFirst(2) }
        guard let colon = body.firstIndex(of: ":") else { continue }
        let key = String(body[..<colon])
        var value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
        current[key] = value
    }
    return out
}

/// Speaker-count bounds for one meeting from its invite (calendar.json), or from the
/// answer key for the "oracle" ceiling. Only the call channel is bounded; runs that
/// split local speakers are left alone because the bounds apply to every offline call.
///   cal-min1  at least (invited people - 1): tolerates one no-show
///   cal-min   at least invited people
///   cal-range invited - 1 ... invited + 1
///   oracle    exactly the true number of remote people
func labSpeakerBounds(mode: String, meetingDir: URL, truth: LabTruth) -> DiarizationSpeakerBounds? {
    guard mode != "none", !truth.split_local_speakers else { return nil }
    if mode == "oracle" {
        let n = truth.participants.filter { $0.role == "remote" }.count
        return DiarizationSpeakerBounds(min: n, max: n)
    }
    struct Invite: Codable { struct Invitee: Codable { let is_person: Bool }; let invitees: [Invitee] }
    guard let data = try? Data(contentsOf: meetingDir.appendingPathComponent("calendar.json")),
          let invite = try? JSONDecoder().decode(Invite.self, from: data) else { return nil }
    let n = invite.invitees.filter(\.is_person).count
    guard n > 0 else { return nil }
    switch mode {
    case "cal-min1": return DiarizationSpeakerBounds(min: max(1, n - 1), max: nil)
    case "cal-min": return DiarizationSpeakerBounds(min: n, max: nil)
    case "cal-range": return DiarizationSpeakerBounds(min: max(1, n - 1), max: n + 1)
    // Cap only: at most the invite size (+1 room for an uninvited guest on bigger calls).
    // Pairs with a generous clustering threshold: split freely, never beyond the invite.
    case "cal-cap": return DiarizationSpeakerBounds(min: nil, max: n + (n >= 3 ? 1 : 0))
    default: die("unknown --speaker-hint \(mode) (none|cal-min1|cal-min|cal-range|cal-cap|oracle)")
    }
}

/// People on a meeting's simulated invite (calendar.json), the same count the app
/// takes from EventKit.
func labInvitedPeople(meetingDir: URL) -> Int? {
    struct Invite: Codable { struct Invitee: Codable { let is_person: Bool }; let invitees: [Invitee] }
    guard let data = try? Data(contentsOf: meetingDir.appendingPathComponent("calendar.json")),
          let invite = try? JSONDecoder().decode(Invite.self, from: data) else { return nil }
    return invite.invitees.filter(\.is_person).count
}

/// Invitee display names from calendar.json, the way the app's invite lookup
/// cleans them: people only, email-only invitees named from the email when it reads
/// like a name ("sam.lee@..." -> "Sam Lee").
func labInviteeNames(meetingDir: URL) -> [String] {
    struct Invite: Codable {
        struct Invitee: Codable { let name: String?; let email: String?; let is_person: Bool }
        let invitees: [Invitee]
    }
    guard let data = try? Data(contentsOf: meetingDir.appendingPathComponent("calendar.json")),
          let invite = try? JSONDecoder().decode(Invite.self, from: data) else { return [] }
    return invite.invitees.filter(\.is_person).compactMap { invitee in
        if let name = invitee.name, !name.isEmpty { return name }
        guard let local = invitee.email?.split(separator: "@").first else { return nil }
        let parts = local.split(whereSeparator: { $0 == "." || $0 == "_" })
        guard parts.count >= 2 else { return nil }
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

@MainActor
func labWait(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return condition()
}

// MARK: - Command

@available(macOS 26.0, *)
func runMeetingSeries(_ args: [String]) async {
    setenv("TRANSCRIPTED_DISABLE_FILE_LOGGER", "1", 1)
    guard let setPath = argValue("--series", in: args) else {
        die("meeting-series requires --series <data/eval/yodas3/sim/SET>")
    }
    let setDir = URL(fileURLWithPath: setPath, isDirectory: true)
    let seriesURL = setDir.appendingPathComponent("series.json")
    guard let seriesData = try? Data(contentsOf: seriesURL),
          let series = try? JSONDecoder().decode(LabSeries.self, from: seriesData) else {
        die("could not read \(seriesURL.path)")
    }
    let only = argValue("--only", in: args).map { Set($0.split(separator: ",").map(String.init)) }
    let limit = argValue("--limit", in: args).flatMap(Int.init) ?? Int.max
    let force = args.contains("--force")
    let speakerHint = argValue("--speaker-hint", in: args) ?? "none"
    // --separation lab: install TranscriptionTaskManager.speakerSeparationProvider the
    // way the app does (SpeakerSeparationOptions.labTuned, capped by the invite size).
    // --separation nocap: same settings with no calendar cap.
    let separation = argValue("--separation", in: args) ?? "none"
    // --calendar-naming: install TranscriptionTaskManager.lineupNamingProvider with the
    // invite's display names (calendar.json), as the app does from EventKit.
    // --no-invite: same, but as if no meeting had an invite (random Zooms), so the
    // lineup falls back to recently heard people.
    let calendarNaming = args.contains("--calendar-naming")
    let noInvite = args.contains("--no-invite")
    let workRoot = URL(fileURLWithPath: argValue("--work", in: args)
        ?? setDir.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runs").appendingPathComponent(series.set).path, isDirectory: true)
    let fm = FileManager.default
    try? fm.createDirectory(at: workRoot, withIntermediateDirectories: true)

    log("[lab] loading Parakeet (FluidAudio cache)...")
    let asr: AsrManager
    do {
        let directory = try await AsrModels.download(version: .v3)
        let models = try await AsrModels.load(from: directory, version: .v3)
        asr = AsrManager(config: .default)
        try await asr.loadModels(models)
    } catch {
        die("Parakeet load failed: \(error.localizedDescription)")
    }
    let engine = await MainActor.run { LabParakeetEngine(manager: asr) }
    let diarization = await DiarizationService()
    await diarization.initialize()
    guard await MainActor.run(body: { diarization.isReady }) else { die("diarizer failed to initialize") }

    // A shared DB for series meetings (fresh_db == false) persists across the run.
    let sharedDBDir = workRoot.appendingPathComponent("shared-db", isDirectory: true)
    var done = 0
    for meeting in series.meetings {
        if done >= limit { break }
        if let only, !only.contains(meeting.id) { continue }
        let meetingDir = setDir.appendingPathComponent(meeting.id, isDirectory: true)
        let outURL = meetingDir.appendingPathComponent("lab_result.json")
        if !force, fm.fileExists(atPath: outURL.path) { continue }
        guard let truthData = try? Data(contentsOf: meetingDir.appendingPathComponent("truth.json")),
              let truth = try? JSONDecoder().decode(LabTruth.self, from: truthData) else {
            log("[lab] \(meeting.id): missing truth.json, skipped"); continue
        }
        let freshDB = meeting.fresh_db ?? true
        let runDir = workRoot.appendingPathComponent(meeting.id, isDirectory: true)
        try? fm.removeItem(at: runDir)
        let dbDir = freshDB ? runDir.appendingPathComponent("db", isDirectory: true) : sharedDBDir
        let paths = CoreStoragePaths(
            transcripts: runDir.appendingPathComponent("transcripts"),
            speakerDB: dbDir.appendingPathComponent("speakers.sqlite"),
            statsDB: runDir.appendingPathComponent("stats.sqlite"),
            failedQueue: runDir.appendingPathComponent("failed_transcriptions.json"),
            speakerClips: dbDir.appendingPathComponent("speaker_clips"),
            audioCaptures: runDir.appendingPathComponent("audio"),
            logs: runDir.appendingPathComponent("logs")
        )
        for dir in [paths.transcripts, paths.speakerClips, paths.audioCaptures, paths.logs] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // The pipeline may clean up its scratch inputs, so hand it copies.
        let micURL = paths.audioCaptures.appendingPathComponent("mic.wav")
        let systemURL = paths.audioCaptures.appendingPathComponent("system.wav")
        do {
            try fm.copyItem(at: meetingDir.appendingPathComponent("mic.wav"), to: micURL)
            try fm.copyItem(at: meetingDir.appendingPathComponent("system.wav"), to: systemURL)
        } catch {
            log("[lab] \(meeting.id): audio copy failed: \(error.localizedDescription)"); continue
        }

        let speakerDB = SpeakerDatabase(path: paths.speakerDB.path)
        let box = LabResultBox()
        let manager = await MainActor.run { () -> TranscriptionTaskManager in
            let m = TranscriptionTaskManager(
                failedTranscriptionManager: FailedTranscriptionManager(paths: paths),
                speechToText: engine,
                diarization: diarization,
                speakerStore: speakerDB,
                speakerClipsDirectory: paths.speakerClips,
                cleanupDirectories: [paths.audioCaptures, paths.speakerClips],
                statsStore: LabStatsStore()
            )
            m.pipelineResultObserver = { box.set($0) }
            if separation != "none" {
                let cap = separation == "nocap" ? nil : labInvitedPeople(meetingDir: meetingDir).flatMap {
                    SpeakerSeparationOptions.speakerCap(invitedPeople: $0)
                }
                m.speakerSeparationProvider = { _ in SpeakerSeparationOptions.labTuned(maxSpeakers: cap) }
            }
            if calendarNaming {
                let names = noInvite ? [] : labInviteeNames(meetingDir: meetingDir)
                m.lineupNamingProvider = { _ in SpeakerNamingPolicy.LineupRequest(invitedNames: names, recentPeopleLimit: 12) }
            }
            return m
        }

        let bounds = labSpeakerBounds(mode: speakerHint, meetingDir: meetingDir, truth: truth)
        await MainActor.run { diarization.labSpeakerBounds = bounds }
        let t0 = Date()
        await MainActor.run {
            manager.startTranscription(
                micURL: micURL, systemURL: systemURL, outputFolder: paths.transcripts,
                meetingTitle: meeting.id, splitLocalSpeakers: truth.split_local_speakers,
                recordingDate: Date(), sessionLength: truth.duration_s
            )
        }
        var result: TranscriptionResult?
        let finished = await labWait(timeout: 3600) {
            if manager.speakerNamingRequest != nil { return true }
            switch manager.displayStatus {
            case .transcriptSaved, .failed, .discardedAccidentalStart: return manager.activeCount == 0
            default: return false
            }
        }
        result = box.take()
        let processing = Date().timeIntervalSince(t0)
        guard finished, let result else {
            let status = await MainActor.run { "\(manager.displayStatus)" }
            log("[lab] \(meeting.id): pipeline did not produce a result (\(status))")
            write(LabMeetingResult(meeting: meeting.id, family: meeting.family, freshDB: freshDB,
                                   splitLocalSpeakers: truth.split_local_speakers, outcome: "failed: \(status)",
                                   processingSeconds: processing, systemSpeakerCount: 0, micSpeakerCount: 0,
                                   rows: [], silentNames: [], utterances: [], profilesAfter: 0), to: outURL)
            continue
        }

        let attribution = LabAttribution(result: result, truth: truth)
        let byPid = Dictionary(uniqueKeysWithValues: truth.participants.map { ($0.pid, $0) })
        let request = await MainActor.run { manager.speakerNamingRequest }
        let savedURL = await MainActor.run { request?.transcriptURL ?? manager.lastSavedTranscriptURL }

        // Voices named silently: frontmatter source "db" on the first save.
        var silent: [LabSilentName] = []
        if let savedURL {
            for s in labFrontmatterSpeakers(savedURL) where s.source == "db" {
                let share = attribution.share(channel: s.channel, diarizerSpeakerId: s.id)
                let truthName = share.pid.flatMap { byPid[$0]?.name }
                silent.append(LabSilentName(channel: s.channel, diarizerSpeakerId: s.id, name: s.name, dbId: s.dbId,
                                            truthPid: share.pid, truthName: truthName, truthShare: share.share,
                                            correct: truthName == s.name))
            }
        }

        var rows: [LabRow] = []
        if let request {
            var updates: [SpeakerNameUpdate] = []
            for entry in request.speakers {
                let channel = entry.channel == .mic ? "mic" : "system"
                let share = attribution.share(channel: channel, diarizerSpeakerId: entry.diarizerSpeakerId)
                let person = share.pid.flatMap { byPid[$0] }
                let options = labIdentityLabels(request.knownPeople.filter { $0.id != entry.id })
                var action = "skip"
                var typed: String?
                var update: SpeakerNameUpdate?
                if person == nil {
                    // A voice with no real speaker behind it (noise, echo): keep it out of the DB.
                    action = "discard"
                    update = SpeakerNameUpdate(persistentSpeakerId: entry.id, diarizerSpeakerId: entry.diarizerSpeakerId,
                                               channel: entry.channel,
                                               newName: entry.currentName ?? "Speaker \(entry.diarizerSpeakerId)",
                                               previousName: entry.currentName, action: .discardedFromDatabase)
                } else if let person, person.role == "you", entry.channel == .mic {
                    action = "keep_as_you"
                    update = SpeakerNameUpdate(persistentSpeakerId: entry.id, diarizerSpeakerId: entry.diarizerSpeakerId,
                                               channel: entry.channel, newName: "You", previousName: entry.currentName,
                                               action: .collapsedToMe)
                } else if let person, entry.needsConfirmation, let current = entry.currentName, current == person.name {
                    // "Confirm Match", built the way SpeakerNamingSheet.buildUpdate does.
                    action = "confirm"
                    if let suggested = entry.suggestedProfileId {
                        update = SpeakerNameUpdate(persistentSpeakerId: entry.id, diarizerSpeakerId: entry.diarizerSpeakerId,
                                                   channel: entry.channel, newName: current,
                                                   action: .merged(targetProfileId: suggested))
                    } else {
                        update = SpeakerNameUpdate(persistentSpeakerId: entry.id, diarizerSpeakerId: entry.diarizerSpeakerId,
                                                   channel: entry.channel, newName: current, previousName: current,
                                                   action: .confirmed)
                    }
                } else if let person {
                    // Type the name; pick the existing person from the combobox when there is one
                    // (the most-used profile if a name is duplicated).
                    let existing = options.filter { $0.value.displayName == person.name }
                        .max { $0.value.callCount < $1.value.callCount }
                    typed = existing?.key ?? person.name
                    action = entry.needsConfirmation ? "correct" : (existing != nil ? "pick_existing" : "type_new")
                    update = SpeakerNamingPolicy.typedNameUpdate(entry: entry, typedName: typed!, optionsByLabel: options)
                }
                if let update { updates.append(update) }
                rows.append(LabRow(
                    channel: channel, diarizerSpeakerId: entry.diarizerSpeakerId, persistentId: entry.id.uuidString,
                    suggestedProfileId: entry.suggestedProfileId?.uuidString, currentName: entry.currentName,
                    needsNaming: entry.needsNaming, needsConfirmation: entry.needsConfirmation,
                    matchSimilarity: entry.matchSimilarity, matchSecondSimilarity: entry.matchSecondSimilarity,
                    callCount: entry.callCount, sessionEmbedding: entry.sessionEmbedding,
                    truthPid: share.pid, truthName: person?.name, truthShare: share.share,
                    secondPid: share.secondPid, secondShare: share.secondShare,
                    userAction: action, userName: typed ?? (action == "confirm" ? entry.currentName : nil)
                ))
            }
            await MainActor.run { request.onComplete(updates) }
            let saved = await labWait(timeout: 600) {
                manager.speakerNamingRequest == nil && manager.activeCount == 0
                    && (manager.displayStatus == .transcriptSaved || manager.displayStatus == .idle)
            }
            if !saved { log("[lab] \(meeting.id): naming completion did not settle in time") }
        }

        let utterances = result.allUtterances.map {
            LabUtterance(channel: $0.channel == 0 ? "mic" : "system", speakerId: $0.speakerId,
                         persistentId: $0.persistentSpeakerId?.uuidString, matchSimilarity: $0.matchSimilarity,
                         start: $0.start, end: $0.end, text: $0.transcript)
        }
        var out = LabMeetingResult(
            meeting: meeting.id, family: meeting.family, freshDB: freshDB,
            splitLocalSpeakers: truth.split_local_speakers, outcome: "ok", processingSeconds: processing,
            systemSpeakerCount: result.systemSpeakerCount, micSpeakerCount: result.micSpeakerCount,
            rows: rows, silentNames: silent, utterances: utterances,
            profilesAfter: speakerDB.allSpeakers().count
        )
        out.speakerHint = [separation == "none" ? speakerHint : "separation-\(separation)",
                           calendarNaming ? (noInvite ? "lineup-naming-no-invite" : "lineup-naming") : nil]
            .compactMap { $0 }.joined(separator: "+")
        out.speakerBoundsMin = bounds?.min
        out.speakerBoundsMax = bounds?.max
        for (channel, contexts) in [("system", result.systemSpeakerContexts), ("mic", result.micSpeakerContexts)] {
            for (sid, ctx) in contexts.sorted(by: { $0.key < $1.key }) {
                let share = attribution.share(channel: channel, diarizerSpeakerId: sid)
                let talk = result.allUtterances
                    .filter { ($0.channel == 0 ? "mic" : "system") == channel && String($0.speakerId) == sid }
                    .reduce(0.0) { $0 + ($1.end - $1.start) }
                out.speakers.append(LabSpeakerContext(
                    channel: channel, diarizerSpeakerId: sid, persistentId: ctx.persistentSpeakerId.uuidString,
                    sessionEmbedding: ctx.sessionEmbedding,
                    matchedProfileId: ctx.matchedProfileSnapshot?.id.uuidString,
                    matchedName: ctx.matchedProfileSnapshot?.displayName,
                    matchedCallCount: ctx.matchedProfileSnapshot?.callCount,
                    matchSimilarity: ctx.matchSimilarity, matchSecondSimilarity: ctx.matchSecondSimilarity,
                    matchAverageSimilarity: ctx.matchAverageSimilarity,
                    matchSecondBestAverageSimilarity: ctx.matchSecondBestAverageSimilarity,
                    talkSeconds: talk, truthPid: share.pid,
                    truthIdentity: share.pid.flatMap { byPid[$0]?.identity }, truthShare: share.share))
            }
        }
        write(out, to: outURL)
        let remote = truth.participants.filter { $0.role == "remote" }.count
        log(String(format: "[lab] %@: %.0fs audio in %.1fs | remote true %d, found %d | rows %d, silent %d",
                   meeting.id, truth.duration_s, processing, remote, result.systemSpeakerCount, rows.count, silent.count))
        done += 1
    }
    log("[lab] done: \(done) meeting(s)")
}

private func write<T: Encodable>(_ value: T, to url: URL) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do { try encoder.encode(value).write(to: url) } catch { log("[lab] write failed: \(error.localizedDescription)") }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

import AppKit
import Foundation
import SwiftUI
import TranscriptedCore

/// Settings › Speakers, scrolled like a person with a long list would: the
/// real page (`PeopleSettingsPage`: "Who spoke?" cards, then the directory of
/// real person rows) over the real model and store, a fresh temporary speaker
/// database, a UserDefaults suite and fictional people. A user report on
/// 1.1.75: with 55 people the app froze while scrolling this list and had to
/// be force quit.
///
/// Promises, for several list sizes:
/// - a forward scroll reaches the bottom of the list;
/// - the scroll offset never jumps back while scrolling forward;
/// - each step costs a few layout passes, and the page goes quiet once
///   scrolling stops (no update loop).
///
/// Before the fix (a LazyVStack per section) macOS 27 jumped the scroll back
/// at every size here and macOS 26.6.2 never returned from one step.
///
/// A hang guard turns a frozen main thread into a failure that names the
/// step; it never checks how long a step took.
@main struct SpeakersDirectoryScrollSmoke {
    struct Scenario {
        let named: Int
        let unnamed: Int
        let pendingMeetings: Int
        var label: String { "\(named) named, \(unnamed) unnamed, \(pendingMeetings) meetings to review" }
    }

    /// Several sizes: whether a broken layout stalls depends on the list's
    /// geometry, so one size alone can pass by luck.
    static let scenarios = [
        Scenario(named: 80, unnamed: 30, pendingMeetings: 6),
        Scenario(named: 100, unnamed: 40, pendingMeetings: 6),
        Scenario(named: 55, unnamed: 40, pendingMeetings: 4),
        Scenario(named: 55, unnamed: 18, pendingMeetings: 0),
        Scenario(named: 100, unnamed: 40, pendingMeetings: 0),
    ]
    static let stepPoints: CGFloat = 40
    /// Further than any real list here, so a stuck scroll fails instead of looping.
    static let maximumSteps = 800
    /// A backward move bigger than this while scrolling forward is a jump.
    static let allowedBackwardPoints: CGFloat = 100
    /// One 40 pt step lays the page out a handful of times; a loop does far more.
    static let maximumLayoutsPerStep = 20
    /// Layout passes allowed in a quiet second once scrolling stops (seen: 0).
    static let maximumIdleLayouts = 3

    static func main() {
        precondition(ProcessInfo.processInfo.environment["TRANSCRIPTED_AUTOMATED_HARNESS"] == "1")
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let guardian = HangGuard()
        guardian.start()
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated {
                // Every size runs, so one report names each size that breaks.
                let failures = scenarios.compactMap { run($0, guardian: guardian) }
                for failure in failures { print("FAIL: \(failure)") }
                guard failures.isEmpty else { exit(1) }
                print("PASS: Speakers directory scroll smoke (\(scenarios.count) list sizes)")
                exit(0)
            }
        }
        app.run()
    }

    /// The fixture itself is broken; nothing after this would mean anything.
    @MainActor static func setupFailed(_ message: String) -> Never {
        print("FAIL: setup: \(message)")
        exit(1)
    }

    /// Scrolls one list size from top to bottom. Returns why it failed, or nil.
    @MainActor static func run(_ scenario: Scenario, guardian: HangGuard) -> String? {
        guardian.note("building \(scenario.label)")
        let fixture: Fixture
        do {
            fixture = try Fixture(scenario: scenario)
        } catch {
            setupFailed("fixture for \(scenario.label) could not be written: \(error)")
        }
        defer { fixture.close() }

        let store = SpeakerSettingsStore(
            speakerDatabase: fixture.database,
            transcriptDirectory: fixture.transcripts,
            preferredClipsDirectory: fixture.clips,
            legacyClipsDirectory: fixture.clips
        )
        let model = SpeakerPeopleSettingsViewModel(
            speakerDatabase: store,
            transcriptDirectory: fixture.transcripts,
            preferredClipsDirectory: fixture.clips,
            legacyClipsDirectory: fixture.clips,
            reviewDefaults: fixture.defaults
        )
        model.setShown(true)
        guardian.note("loading \(scenario.label)")
        while !model.hasLoadedProfiles || model.reviewStack.calls.count < scenario.pendingMeetings { pump(0.02) }
        let sections = SpeakerPrintDirectory.sections(model.directoryProfiles) { model.namingStanding(for: $0) }
        guard Set(sections.map(\.section)) == Set(SpeakerPrintDirectory.Section.allCases) else {
            setupFailed("\(scenario.label) should fill every section, got \(sections.map { "\($0.section)" })")
        }

        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 900, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // The real pointer must not hover rows while the smoke scrolls.
        window.ignoresMouseEvents = true
        let hosting = LayoutCountingHostingView(rootView: SpeakersPageShell(model: model))
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        pump(0.5)

        guard let scroll = firstScrollView(in: hosting) else {
            setupFailed("\(scenario.label): no scroll view under the page")
        }
        let clip = scroll.contentView
        var lastY = clip.bounds.origin.y
        var step = 0
        var worstLayouts = 0
        while true {
            let maxY = (scroll.documentView?.frame.height ?? 0) - clip.bounds.height
            if lastY >= maxY - 1 { break }
            if step >= maximumSteps {
                return "\(scenario.label): after \(step) steps the scroll is at y=\(Int(lastY)) of \(Int(maxY)), never reaching the bottom"
            }
            guardian.note("\(scenario.label): step \(step) from y=\(Int(lastY))")
            let layoutsBefore = hosting.layoutPasses
            clip.scroll(to: NSPoint(x: 0, y: min(lastY + stepPoints, maxY)))
            scroll.reflectScrolledClipView(clip)
            pump(0.03)
            let y = clip.bounds.origin.y
            if y < lastY - allowedBackwardPoints {
                return "\(scenario.label): at step \(step) the scroll jumped back from y=\(Int(lastY)) to y=\(Int(y))"
            }
            let layouts = hosting.layoutPasses - layoutsBefore
            worstLayouts = max(worstLayouts, layouts)
            if layouts > maximumLayoutsPerStep {
                return "\(scenario.label): step \(step) at y=\(Int(y)) laid the page out \(layouts) times"
            }
            lastY = y
            step += 1
        }

        // Settled: once nothing scrolls, the page stops laying out. A loop
        // repeats every frame; a stray pass or two is not a loop.
        guardian.note("\(scenario.label): settling at the bottom")
        pump(1.0)
        let settled = hosting.layoutPasses
        pump(1.0)
        let idleLayouts = hosting.layoutPasses - settled
        if idleLayouts > maximumIdleLayouts {
            return "\(scenario.label): the page kept laying out after scrolling stopped (\(idleLayouts) passes)"
        }
        print("ok: \(scenario.label): reached the bottom (y=\(Int(lastY))) in \(step) steps, at most \(worstLayouts) layouts per step")
        return nil
    }

    @MainActor static func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: min(until, Date().addingTimeInterval(0.005)))
        }
    }

    @MainActor static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}

/// The real Speakers page inside the same scroll shell as the Settings
/// window's detail column (`TranscriptedSettingsView.detailColumn`).
private struct SpeakersPageShell: View {
    @ObservedObject var model: SpeakerPeopleSettingsViewModel

    var body: some View {
        ZStack {
            LibraryTokens.contentBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PeopleSettingsPage(speakerPeopleModel: model, onStartMeeting: {})
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 28)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Counts the page's layout passes, the work an update loop repeats.
private final class LayoutCountingHostingView<Content: View>: NSHostingView<Content> {
    private(set) var layoutPasses = 0

    override func layout() {
        layoutPasses += 1
        super.layout()
    }
}

/// Watches the main thread from a background thread. If the smoke stops
/// making progress, it prints the last thing main was doing and fails.
final class HangGuard: @unchecked Sendable {
    /// Long enough that a busy runner never trips it; a frozen layout loop
    /// never comes back at all.
    private let quietLimit: TimeInterval = 60
    private let lock = NSLock()
    private var lastNote = "starting"
    private var lastProgress = Date()

    func note(_ text: String) {
        lock.lock()
        lastNote = text
        lastProgress = Date()
        lock.unlock()
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 1)
                lock.lock()
                let quiet = Date().timeIntervalSince(lastProgress)
                let note = lastNote
                lock.unlock()
                if quiet > quietLimit {
                    print("FAIL: the main thread stopped answering (\(note))")
                    exit(1)
                }
            }
        }
    }
}

@MainActor private final class Fixture {
    let root: URL
    let transcripts: URL
    let clips: URL
    let database: SpeakerDatabase
    let defaults: UserDefaults
    let suite: String
    private static let rootPrefix = "SpeakersDirectoryScroll-"

    init(scenario: SpeakersDirectoryScrollSmoke.Scenario) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.rootPrefix)\(UUID().uuidString)", isDirectory: true)
        transcripts = root.appendingPathComponent("transcripts", isDirectory: true)
        clips = root.appendingPathComponent("clips", isDirectory: true)
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        database = SpeakerDatabase(path: root.appendingPathComponent("speakers.sqlite").path, adoptCanonicalModelIdentity: false)
        suite = "SpeakersDirectoryScroll.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        try populate(scenario)
    }

    func close() {
        defaults.removePersistentDomain(forName: suite)
        guard root.lastPathComponent.hasPrefix(Self.rootPrefix),
              root.deletingLastPathComponent().standardizedFileURL
                == FileManager.default.temporaryDirectory.standardizedFileURL
        else { fatalError("Refusing to clean outside the smoke's temporary root") }
        try? FileManager.default.removeItem(at: root)
    }

    private static let firstNames = ["Avery", "Blake", "Casey", "Devon", "Emery", "Finley", "Harper", "Jordan",
                                     "Kendall", "Logan", "Morgan", "Parker", "Quinn", "Reese", "Rowan", "Sage"]
    private static let lastNames = ["Applewood", "Brightwater", "Cobblestone", "Dovetail",
                                    "Elmsworth", "Fernhill", "Glimmer", "Hollowbrook"]

    private func populate(_ scenario: SpeakersDirectoryScrollSmoke.Scenario) throws {
        var seed: UInt64 = 42
        var named: [SpeakerProfile] = []
        for index in 0..<scenario.named {
            let first = Self.firstNames[index % Self.firstNames.count]
            let last = Self.lastNames[(index / Self.firstNames.count + index) % Self.lastNames.count]
            let person = try voice(
                name: "\(first) \(last)",
                embedding: Self.embedding(seed: &seed),
                quote: index % 3 == 0 ? nil : "A made-up sample sentence, number \(index), for this voice."
            )
            // 0...6 confirmed meetings, so people land in every named section.
            let confirmations = index % 7
            if confirmations > 0 {
                try database.recordUserConfirmations((0..<confirmations).map { _ in
                    SpeakerUserConfirmation(profileId: person.id, transcriptId: UUID(), kind: .confirmed)
                })
            }
            named.append(person)
        }
        var unnamed: [SpeakerProfile] = []
        for index in 0..<scenario.unnamed {
            var embedding = Self.embedding(seed: &seed)
            // Some unnamed voices sit near a named person, so guesses and duplicates show.
            if index % 4 == 0, let near = named.first?.embedding {
                embedding = zip(near, embedding).map { $0 + 0.05 * $1 }
            }
            unnamed.append(try voice(name: nil, embedding: embedding, quote: "Unnamed voice \(index) says something ordinary."))
        }
        for meeting in 0..<scenario.pendingMeetings {
            let voices = Array(unnamed.dropFirst(meeting * 3).prefix(3))
            guard !voices.isEmpty else { break }
            try writeMeeting(voices: voices, filename: "meeting-\(meeting)", title: "Made-up sync \(meeting)")
        }
    }

    private static func embedding(seed: inout UInt64) -> [Float] {
        (0..<192).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed >> 11) % 2000) / 1000 - 1
        }
    }

    private func voice(name: String?, embedding: [Float], quote: String?) throws -> SpeakerProfile {
        let profile = database.addOrUpdateSpeaker(embedding: embedding, existingId: nil)
        if let name { database.setDisplayName(id: profile.id, name: name, source: NameSource.userManual) }
        let wav = clips.appendingPathComponent("\(profile.id.uuidString).wav")
        try Data([1, 2, 3, 4, 5]).write(to: wav)
        if let quote {
            let sidecar = SpeakerClipSidecar(
                channel: "system",
                diarizerSpeakerId: "1",
                segments: [.init(start: 0, end: 1, text: quote)],
                sampleText: quote
            )
            guard let stamped = sidecar.stamped(withWavAt: wav) else {
                fatalError("quoted clip must stamp against its wav")
            }
            try stamped.write(nextTo: wav)
        }
        return database.getSpeaker(id: profile.id)!
    }

    /// A saved meeting whose voices wait in "Who spoke?" (`db_pending`).
    private func writeMeeting(voices: [SpeakerProfile], filename: String, title: String) throws {
        let url = transcripts.appendingPathComponent(filename).appendingPathExtension("md")
        let speakers = voices.enumerated().map { index, voice in
            """
              - id: "\(index + 1)"
                channel: system
                db_id: "\(voice.id.uuidString)"
                name: "Speaker \(index + 1)"
                source: db_pending
            """
        }.joined(separator: "\n")
        let lines = voices.indices.map {
            "[00:0\($0 + 1)] [System/Speaker \($0 + 1)] Made-up words for the fixture."
        }.joined(separator: "\n")
        try """
        ---
        title: "\(title)"
        transcript_id: "\(UUID().uuidString)"
        capture_type: meeting
        date: "2026-10-2\(filename.count % 9)"
        duration: "00:30"
        speakers:
        \(speakers)
        ---
        ## Full Transcript
        \(lines)
        """.write(to: url, atomically: true, encoding: .utf8)
    }
}

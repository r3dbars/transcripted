import AppKit
import TranscriptedCore

/// Drives the real review page component with call-app hints (fictional names)
/// and checks: the name box is never filled by the call app, Done with an
/// untouched hint saves nothing, a tap on the hint fills the box and then
/// Done saves it, and guessed rows keep their question. Renders PNGs to
/// the owned output directory. This is page-component action/render proof,
/// not island timers, telemetry, physical gestures or whole-app acceptance.
@main
struct CallAppHintHarness {
    @MainActor static func main() throws {
        let isolation = try CallAppHintHarnessIsolation(environment: ProcessInfo.processInfo.environment)
        try isolation.withPreferences(.standard) { try run(isolation) }
    }

    @MainActor private static func run(_ isolation: CallAppHintHarnessIsolation) throws {
        precondition(FileManager.default.transcriptedAppSupportRootURL == isolation.container)
        _ = NSApplication.shared
        let fixture = isolation.fixture
        let clip = fixture.appendingPathComponent("synthetic.wav")
        var unknown = SpeakerNamingEntry(id: UUID(), diarizerSpeakerId: "1", clipURL: clip,
            sampleText: "Let's start with the budget.", currentName: nil, matchSimilarity: nil,
            needsNaming: true, needsConfirmation: false)
        unknown.callAppShownName = "Maya Lindqvist"
        var agrees = SpeakerNamingEntry(id: UUID(), diarizerSpeakerId: "2", clipURL: clip,
            sampleText: "Sounds good to me.", currentName: "Marcus Reed", matchSimilarity: 0.6,
            needsNaming: false, needsConfirmation: true)
        agrees.callAppShownName = "Marcus Reed"
        var differs = SpeakerNamingEntry(id: UUID(), diarizerSpeakerId: "3", clipURL: clip,
            sampleText: "I can take that one.", currentName: "Ana Lima", matchSimilarity: 0.6,
            needsNaming: false, needsConfirmation: true)
        differs.callAppShownName = "Rina Okafor"
        let request = SpeakerNamingRequest(speakers: [unknown, agrees, differs],
            transcriptURL: fixture.appendingPathComponent("synthetic.md"),
            transcriptId: UUID(), systemAudioURL: clip, micAudioURL: nil,
            onComplete: { _ in fatalError("Harness must not submit Core naming answers") })
        // Page chrome skips trackShown and island timers entirely. No shared
        // reporter, store, calendar reader or real submit callback is reached.
        let input = NotchIslandSpeakerReviewView.Input(id: request.id, speakers: request.speakers, knownPeople: [])
        let view = NotchIslandSpeakerReviewView(input: input, chrome: .page(.init(
            title: "Synthetic planning call", detail: nil, doneTitle: "Done", skipTitle: "Skip", skipHelp: "Synthetic only"
        )))
        view.onDone = { _, _ in fatalError("Harness never presses Done") }
        view.onLater = { _ in fatalError("Harness never presses Later") }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 620))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        host.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 28),
                                     view.topAnchor.constraint(equalTo: host.topAnchor, constant: 28)])
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        func descendants(_ node: NSView) -> [NSView] { [node] + node.subviews.flatMap(descendants) }
        func texts() -> [String] {
            descendants(view).compactMap { ($0 as? NSTextField)?.stringValue }
                + descendants(view).compactMap { ($0 as? NSButton)?.title }
        }
        func render(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            let size = view.fittingSize
            host.setFrameSize(NSSize(width: size.width + 56, height: size.height + 56))
            window.setContentSize(host.frame.size)
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to:
                isolation.output.appendingPathComponent("call-app-hint-\(name).png"))
        }
        var completed = 0
        var assertions = 0
        @MainActor func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            assertions += 1
        }
        func finishGroup(_ name: String) {
            completed += 1
            print("PASS: \(name)")
        }
        guard let unknownRow = view.rows.first(where: { $0.entry.diarizerSpeakerId == "1" }) else { fatalError("Missing row") }

        check(unknownRow.nameField.stringValue.isEmpty, "the call app's name must never fill the box on its own")
        check(view.collectUpdates(finish: .done).updates.isEmpty, "Done with only hints saves nothing")
        check(view.collectUpdates(finish: .later).updates.isEmpty, "Later with only hints saves nothing")
        finishGroup("untouched hint stays empty on Done and Later")
        let shown = texts()
        check(shown.contains("Call app showed: Maya Lindqvist"), "unnamed voice shows the hint: \(shown)")
        check(shown.contains("Call app showed Marcus Reed too"), "agreement shows as corroboration: \(shown)")
        check(shown.contains("Call app showed: Rina Okafor"), "a different name is shown next to the guess: \(shown)")
        check(shown.contains("Marcus Reed?") && shown.contains("Ana Lima?"), "voiceprint questions stay: \(shown)")
        finishGroup("voiceprint questions and corroborating hints stay independent")
        try render("before")

        guard let hint = descendants(view).compactMap({ $0 as? NSButton })
            .first(where: { $0.title == "Call app showed: Maya Lindqvist" }) else { fatalError("Missing hint button") }
        check(descendants(view).compactMap({ $0 as? NSButton })
            .first(where: { $0.title == "Call app showed: Rina Okafor" }) == nil, "a conflicting name is not a button")
        hint.performClick(nil)
        check(unknownRow.nameField.stringValue == "Maya Lindqvist", "a tap fills the box")
        finishGroup("explicit hint button fills the name box")
        let updates = view.collectUpdates(finish: .done).updates
        check(updates.count == 1 && updates[0].newName == "Maya Lindqvist", "after a tap, Done saves it like a typed name")
        finishGroup("explicit hint choice creates only its selected update")
        try render("after-tap")
        window.close()
        let environment = ProcessInfo.processInfo.environment
        guard let completionPath = environment["TRANSCRIPTED_FAST_TEST_COMPLETION_PATH"],
              let runID = environment["TRANSCRIPTED_FAST_TEST_COMPLETION_RUN_ID"],
              let selection = environment["CALL_APP_HINT_SELECTION_DIGEST"] else { fatalError("Missing completion contract") }
        let receipt: [String: Any] = ["version": 1, "run_id": runID, "selection_digest": selection,
            "selected_functions": 4, "executed_functions": completed, "assertions": assertions,
            "passed_assertions": assertions, "failed_assertions": 0, "quarantined_suites": 0]
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: completionPath), options: .atomic)
        try data.write(to: isolation.output.appendingPathComponent("completion.json"), options: .atomic)
        print("PASS: call-app hint page component completed all four checks; two owned PNGs generated.")
    }
}

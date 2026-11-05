import AppKit
import TranscriptedCore

/// Drives the real island review view with call-app hints (fictional names)
/// and checks: the name box is never filled by the call app, Done with an
/// untouched hint saves nothing, a tap on the hint fills the box and then
/// Done saves it, and guessed rows keep their question. Renders PNGs to
/// .agent-review/visuals for a look by eye.
@main
struct CallAppHintHarness {
    @MainActor static func main() async throws {
        precondition(ProcessInfo.processInfo.environment["TRANSCRIPTED_AUTOMATED_HARNESS"] == "1")
        _ = NSApplication.shared
        let fixture = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CALL_APP_HINT_FIXTURE_ROOT"]!)
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
        let view = NotchIslandSpeakerReviewView(request: request)
        view.setMeetingTitle("Synthetic planning call")
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
                URL(fileURLWithPath: ".agent-review/visuals/call-app-hint-\(name).png"))
        }
        guard let unknownRow = view.rows.first(where: { $0.entry.diarizerSpeakerId == "1" }) else { fatalError("Missing row") }

        precondition(unknownRow.nameField.stringValue.isEmpty, "the call app's name must never fill the box on its own")
        precondition(view.collectUpdates(finish: .done).updates.isEmpty, "Done with only hints saves nothing")
        precondition(view.collectUpdates(finish: .later).updates.isEmpty, "Later with only hints saves nothing")
        let shown = texts()
        precondition(shown.contains("Call app showed: Maya Lindqvist"), "unnamed voice shows the hint: \(shown)")
        precondition(shown.contains("Call app showed Marcus Reed too"), "agreement shows as corroboration: \(shown)")
        precondition(shown.contains("Call app showed: Rina Okafor"), "a different name is shown next to the guess: \(shown)")
        precondition(shown.contains("Marcus Reed?") && shown.contains("Ana Lima?"), "voiceprint questions stay: \(shown)")
        try render("before")

        guard let hint = descendants(view).compactMap({ $0 as? NSButton })
            .first(where: { $0.title == "Call app showed: Maya Lindqvist" }) else { fatalError("Missing hint button") }
        precondition(descendants(view).compactMap({ $0 as? NSButton })
            .first(where: { $0.title == "Call app showed: Rina Okafor" }) == nil, "a conflicting name is not a button")
        hint.performClick(nil)
        precondition(unknownRow.nameField.stringValue == "Maya Lindqvist", "a tap fills the box")
        let updates = view.collectUpdates(finish: .done).updates
        precondition(updates.count == 1 && updates[0].newName == "Maya Lindqvist", "after a tap, Done saves it like a typed name")
        try render("after-tap")
        print("PASS: call-app hint never prefills or saves untouched; tap fills the box; guessed rows keep their question. Two synthetic PNGs generated.")
        window.close()
    }
}

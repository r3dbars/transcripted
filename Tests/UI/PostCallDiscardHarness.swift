import AppKit
import TranscriptedCore

@main
struct PostCallDiscardHarness {
    @MainActor static func main() async throws {
        precondition(ProcessInfo.processInfo.environment["TRANSCRIPTED_AUTOMATED_HARNESS"] == "1")
        _ = NSApplication.shared
        let fixture = URL(fileURLWithPath: ProcessInfo.processInfo.environment["POST_CALL_FIXTURE_ROOT"]!)
        let entry = SpeakerNamingEntry(id: UUID(), diarizerSpeakerId: "1",
            clipURL: fixture.appendingPathComponent("synthetic.wav"), sampleText: "A synthetic review example.",
            currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false)
        let request = SpeakerNamingRequest(speakers: [entry], transcriptURL: fixture.appendingPathComponent("synthetic.md"),
            transcriptId: UUID(), systemAudioURL: fixture.appendingPathComponent("synthetic.wav"), micAudioURL: nil,
            onComplete: { _ in fatalError("Harness must not submit Core naming answers") })
        let view = NotchIslandSpeakerReviewView(request: request)
        view.setMeetingTitle("Synthetic planning call")
        var submissions = 0
        view.onDone = { _, _ in submissions += 1 }
        view.onLater = { _ in submissions += 1 }
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
        func button(_ title: String) -> NSButton {
            guard let result = descendants(view).compactMap({ $0 as? NSButton }).first(where: { $0.title == title })
            else { fatalError("Missing button: \(title)") }
            return result
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
                URL(fileURLWithPath: ".agent-review/visuals/post-call-discard-\(name).png"))
        }
        view.rows[0].nameField.stringValue = "Synthetic draft"
        try render("review")
        let staleDone = button("Done")
        let staleLater = button("Later")
        button(NotchIslandSpeakerReviewPolicy.deleteTitle).performClick(nil)
        precondition(submissions == 0)
        try render("confirmation")
        button("Keep recording").performClick(nil)
        precondition(!view.isFinished && submissions == 0)
        _ = button("Done")
        precondition(view.rows[0].nameField.stringValue == "Synthetic draft", "Keep must preserve the draft")
        var attempts = 0
        var pending: CheckedContinuation<String?, Never>?
        view.onDeleteRecording = {
            attempts += 1
            return await withCheckedContinuation { pending = $0 }
        }
        button(NotchIslandSpeakerReviewPolicy.deleteTitle).performClick(nil)
        let confirm = button("Move to Trash")
        confirm.performClick(nil)
        while pending == nil { await Task.yield() }
        confirm.performClick(nil)
        staleDone.performClick(nil)
        staleLater.performClick(nil)
        precondition(attempts == 1 && submissions == 0 && !view.isFinished)
        try render("pending")
        pending?.resume(returning: "Synthetic failure. Please try again.")
        pending = nil
        while !descendants(view).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue.contains("Synthetic failure") }) {
            await Task.yield()
        }
        try render("error")
        button("Keep recording").performClick(nil)
        precondition(!view.isFinished && submissions == 0)
        view.onDeleteRecording = { attempts += 1; return nil }
        button(NotchIslandSpeakerReviewPolicy.deleteTitle).performClick(nil)
        button("Move to Trash").performClick(nil)
        while attempts != 2 { await Task.yield() }
        precondition(submissions == 0)
        print("PASS: actual review Delete/Keep/confirmation; pending duplicate and Done/Later blocked; error recovery and successful retry. Four synthetic PNGs generated.")
        window.close()
    }
}

import AppKit
import Foundation

// Native component-only visual check; no production app or customer data.
private enum Variant: String {
    case quitPaused = "quit-paused"
    case activeUnsaved = "active-unsaved"
    case retrySaving = "retry-saving"

    var message: String {
        switch self {
        case .quitPaused:
            return "Quit paused. Audio isn't saved yet; your recording wasn't discarded. Try Quit again shortly."
        case .activeUnsaved:
            return "Quit paused. This recording isn't safely saved. Keep Transcripted open until dictation finishes."
        case .retrySaving:
            return "Audio is only in memory. Keep Transcripted open; check storage, then Retry Saving."
        }
    }

    var actionTitle: String? { self == .retrySaving ? "Retry Saving" : nil }
}

@main
struct OverlayTerminationFixture {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 3,
              let variant = Variant(rawValue: CommandLine.arguments[1]) else {
            fatalError("Usage: fixture <quit-paused|active-unsaved|retry-saving> <output.png>")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let panelHeight: CGFloat = variant.actionTitle == nil ? 110 : 140
        let contentHeight = panelHeight - OverlayTokens.headerHeight - OverlayTokens.dividerHeight
        let bounds = NSRect(x: 0, y: 0, width: OverlayTokens.panelWidth, height: contentHeight)
        let window = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        let body = NSView(frame: bounds)
        body.wantsLayer = true
        body.layer?.backgroundColor = OverlayTokens.panelBg.cgColor
        body.layer?.masksToBounds = true
        window.contentView = body
        let drafting = OverlayDraftingView(frame: bounds)
        body.addSubview(drafting)
        var actionInvoked = false
        drafting.update(
            message: variant.message,
            errorActionTitle: variant.actionTitle,
            onErrorAction: variant.actionTitle == nil ? nil : { actionInvoked = true },
            onErrorDismiss: {}
        )
        drafting.layoutSubtreeIfNeeded()
        body.layoutSubtreeIfNeeded()
        window.orderFrontRegardless()
        drafting.needsDisplay = true
        window.displayIfNeeded()
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        window.displayIfNeeded()
        guard let bitmap = body.bitmapImageRepForCachingDisplay(in: body.bounds) else { fatalError("bitmap unavailable") }
        body.cacheDisplay(in: body.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG unavailable") }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
        let label = drafting.subviews.compactMap { $0 as? NSTextField }.first
        let button = drafting.subviews.compactMap { $0 as? NSButton }
            .first { $0.title == "Retry Saving" }
        button?.performClick(nil)
        print("variant=\(variant.rawValue) panel=360x\(Int(panelHeight)) body=360x\(Int(contentHeight)) labelFrame=\(String(describing: label?.frame)) labelInside=\(label.map { drafting.bounds.contains($0.frame) } ?? false) buttonFrame=\(String(describing: button?.frame)) buttonInside=\(button.map { drafting.bounds.contains($0.frame) } ?? false) actionInvoked=\(actionInvoked)")
    }
}

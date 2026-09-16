import AppKit
import Foundation

// Component-only, sanitized renderer. It links the production AppKit drafting
// view/tokens; it does not instantiate Transcripted or touch its data.
private enum FixtureVariant: String {
    case undecodedAudio = "undecoded-audio"
    case startupPendingRecovery = "startup-pending-recovery"
    case missingRecovery = "missing-recovery"
    case modelFailure = "model-failure"

    var message: String {
        switch self {
        case .undecodedAudio:
            return "The speech model returned no words. Retry the saved audio with Capture → Transcribe Audio File."
        case .startupPendingRecovery:
            return "A stopped dictation recording is available. Retry it with Capture → Transcribe Audio File in Transcripted."
        case .missingRecovery:
            return "The speech model returned no words, but the audio could not be saved for recovery. Try again."
        case .modelFailure:
            return "The local speech model failed. Try again, or switch transcription models in Settings."
        }
    }

    var actionTitle: String? {
        self == .missingRecovery ? nil : "Show Audio"
    }
}

@MainActor
private func renderFixture(variant: FixtureVariant, output: URL) throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    // FloatingOverlayController.errorPanelSize uses 140pt for these long,
    // actionable messages and 110pt for the long no-action fallback.
    let panelHeight: CGFloat = variant.actionTitle == nil ? 110 : 140
    let contentHeight = panelHeight - OverlayTokens.headerHeight - OverlayTokens.dividerHeight
    let contentRect = NSRect(x: 0, y: 0, width: OverlayTokens.panelWidth, height: contentHeight)
    let window = NSWindow(
        contentRect: contentRect,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))

    let body = NSView(frame: contentRect)
    body.wantsLayer = true
    body.layer?.backgroundColor = OverlayTokens.panelBg.cgColor
    body.layer?.masksToBounds = true // OverlayRootView contentContainer behavior
    window.contentView = body

    let drafting = OverlayDraftingView(frame: body.bounds)
    body.addSubview(drafting)
    var actionInvoked = false
    drafting.update(
        message: variant.message,
        errorActionTitle: variant.actionTitle,
        onErrorAction: variant.actionTitle == nil ? nil : { actionInvoked = true },
        onErrorDismiss: {},
    )
    drafting.layoutSubtreeIfNeeded()
    body.layoutSubtreeIfNeeded()
    // Layer-backed symbols/buttons sometimes miss a cacheDisplay snapshot of
    // an unordered window. Order this prohibited-activation window far offscreen
    // and flush AppKit/Core Animation before caching its pixels.
    window.orderFrontRegardless()
    drafting.needsDisplay = true
    body.needsDisplay = true
    window.displayIfNeeded()
    CATransaction.flush()
    RunLoop.current.run(until: Date().addingTimeInterval(0.08))
    window.displayIfNeeded()

    guard let bitmap = body.bitmapImageRepForCachingDisplay(in: body.bounds) else {
        throw NSError(domain: "OverlayRecoveryFixture", code: 1)
    }
    body.cacheDisplay(in: body.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "OverlayRecoveryFixture", code: 2)
    }
    try png.write(to: output, options: .atomic)

    let label = drafting.subviews.compactMap { $0 as? NSTextField }.first
    let actionButton = drafting.subviews.compactMap { $0 as? NSButton }
        .first { $0.title == "Show Audio" }
    if let actionButton { actionButton.performClick(nil) }
    let actionInsideBounds = actionButton.map { drafting.bounds.contains($0.frame) } ?? false
    let labelInsideBounds = label.map { drafting.bounds.contains($0.frame) } ?? false
    print("variant=\(variant.rawValue) panel=360x\(Int(panelHeight)) body=360x\(Int(contentHeight))")
    print("labelFrame=\(String(describing: label?.frame)) labelInside=\(labelInsideBounds)")
    print("actionFrame=\(String(describing: actionButton?.frame)) actionInside=\(actionInsideBounds) actionInvoked=\(actionInvoked)")
    print("png=\(output.path)")
}

@main
private struct OverlayRecoveryFixtureApp {
    @MainActor
    static func main() {
        guard CommandLine.arguments.count == 3,
              let variant = FixtureVariant(rawValue: CommandLine.arguments[1]) else {
    fputs("Usage: overlay-recovery-fixture <undecoded-audio|startup-pending-recovery|missing-recovery|model-failure> <output.png>\n", stderr)
            exit(2)
        }
        do {
            try renderFixture(
                variant: variant,
                output: URL(fileURLWithPath: CommandLine.arguments[2])
            )
        } catch {
            fputs("Fixture render failed: \(error)\n", stderr)
            exit(1)
        }
    }
}

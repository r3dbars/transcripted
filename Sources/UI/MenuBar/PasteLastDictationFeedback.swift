import AppKit

enum PasteLastDictationFeedbackTone: Equatable {
    case success
    case caution
}

struct PasteLastDictationFeedback: Equatable {
    let title: String
    let detail: String
    let tone: PasteLastDictationFeedbackTone
    let dismissDelayNanoseconds: UInt64

    var accessibilityValue: String {
        detail.isEmpty ? title : "\(title). \(detail)"
    }

    static let noSavedDictation = PasteLastDictationFeedback(
        title: "No saved dictation yet",
        detail: "Dictate once, then use Paste Last.",
        tone: .caution,
        dismissDelayNanoseconds: 3_000_000_000
    )

    static func presentation(for outcome: TextPasteOutcome) -> PasteLastDictationFeedback {
        switch outcome {
        case .pasted:
            return PasteLastDictationFeedback(
                title: "Last dictation pasted",
                detail: "Text went to the focused app.",
                tone: .success,
                dismissDelayNanoseconds: 1_500_000_000
            )
        case .copied(let message, reason: _):
            return PasteLastDictationFeedback(
                title: "Copied instead",
                detail: message,
                tone: .caution,
                dismissDelayNanoseconds: 4_000_000_000
            )
        case .failed(let message):
            return PasteLastDictationFeedback(
                title: "Paste Last failed",
                detail: message,
                tone: .caution,
                dismissDelayNanoseconds: 4_500_000_000
            )
        }
    }
}

@MainActor
final class PasteLastDictationFeedbackPresenter {
    static let shared = PasteLastDictationFeedbackPresenter()

    private var panel: PasteLastDictationFeedbackPanel?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func present(_ feedback: PasteLastDictationFeedback) {
        dismissTask?.cancel()
        dismissTask = nil

        let panel = panel ?? makePanel()
        self.panel = panel
        let view = PasteLastDictationFeedbackView(feedback: feedback)
        panel.contentView = view
        panel.setContentSize(PasteLastDictationFeedbackView.size)
        panel.setFrameOrigin(origin(for: PasteLastDictationFeedbackView.size))
        // Ease the notice in instead of snapping to full opacity. If it is already
        // on screen (a back-to-back notice), keep it visible and skip the fade.
        let wasVisible = panel.isVisible
        panel.alphaValue = wasVisible ? 1 : 0
        panel.orderFrontRegardless()
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        NSAccessibility.post(
            element: panel,
            notification: .announcementRequested,
            userInfo: [.announcement: feedback.accessibilityValue]
        )

        dismissTask = Task { @MainActor [weak self, weak panel] in
            do {
                try await Task.sleep(nanoseconds: feedback.dismissDelayNanoseconds)
            } catch {
                return
            }
            guard let self, let panel, self.panel === panel else { return }
            self.dismissTask = nil
            // Ease the notice out so it does not vanish mid-read.
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self, weak panel] in
                Task { @MainActor [weak self, weak panel] in
                    guard let self, let panel, self.panel === panel else { return }
                    // A newer notice re-presented during the fade restores full
                    // opacity; only tear down if we actually faded all the way out.
                    guard panel.alphaValue == 0 else { return }
                    panel.orderOut(nil)
                    panel.alphaValue = 1
                }
            })
        }
    }

    private func makePanel() -> PasteLastDictationFeedbackPanel {
        PasteLastDictationFeedbackPanel(
            contentRect: NSRect(origin: .zero, size: PasteLastDictationFeedbackView.size),
            styleMask: [],
            backing: .buffered,
            defer: true
        )
    }

    private func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let inset: CGFloat = 12
        let preferred = NSPoint(x: mouse.x - size.width / 2, y: mouse.y + 18)
        let x = min(max(preferred.x, visible.minX + inset), visible.maxX - size.width - inset)
        let y = min(max(preferred.y, visible.minY + inset), visible.maxY - size.height - inset)
        return NSPoint(x: x, y: y)
    }
}

private final class PasteLastDictationFeedbackPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: flag
        )
        level = .popUpMenu
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PasteLastDictationFeedbackView: NSView {
    static let size = NSSize(width: 292, height: 76)

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let indicator = NSView(frame: .zero)

    init(feedback: PasteLastDictationFeedback) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.32).cgColor

        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 4
        indicator.layer?.backgroundColor = indicatorColor(for: feedback.tone).cgColor
        addSubview(indicator)

        titleLabel.stringValue = feedback.title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        detailLabel.stringValue = feedback.detail
        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2
        addSubview(detailLabel)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Paste Last Dictation")
        setAccessibilityValue(feedback.accessibilityValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let pad: CGFloat = 14
        let indicatorSize = NSSize(width: 8, height: 32)
        indicator.frame = NSRect(
            x: pad,
            y: (bounds.height - indicatorSize.height) / 2,
            width: indicatorSize.width,
            height: indicatorSize.height
        )

        let textX = indicator.frame.maxX + 10
        let textWidth = bounds.width - textX - pad
        titleLabel.frame = NSRect(x: textX, y: bounds.height - pad - 18, width: textWidth, height: 18)
        detailLabel.frame = NSRect(x: textX, y: pad, width: textWidth, height: 34)
    }

    private func indicatorColor(for tone: PasteLastDictationFeedbackTone) -> NSColor {
        switch tone {
        case .success:
            return NSColor.systemGreen.withAlphaComponent(0.88)
        case .caution:
            return NSColor.systemOrange.withAlphaComponent(0.90)
        }
    }
}

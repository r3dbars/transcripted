import AppKit

@available(macOS 14.0, *)
@MainActor
final class CapturePillController {
    private var panel: CapturePillPanel?
    private var pillView: CapturePillView?
    private var representedCandidate: MeetingPromptDetector.Candidate?
    private var dismissTask: Task<Void, Never>?
    private var eventMonitor: Any?

    var onRecord: ((MeetingPromptDetector.Candidate) -> Void)?
    var onDismiss: ((MeetingPromptDetector.Candidate) -> Void)?
    var onRemind: ((MeetingPromptDetector.Candidate) -> Void)?
    var onExpired: ((MeetingPromptDetector.Candidate) -> Void)?

    deinit {
        dismissTask?.cancel()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    @discardableResult
    func present(
        candidate: MeetingPromptDetector.Candidate,
        timeout: TimeInterval = 30
    ) -> Bool {
        ensurePanel()
        guard let panel, let pillView else { return false }

        representedCandidate = candidate
        pillView.update(candidate: candidate)
        panel.onCancel = { [weak self] in self?.dismiss(notify: true) }
        panel.onDefault = { [weak self] in self?.record() }

        position(panel: panel)
        panel.orderFrontRegardless()

        installEventMonitor()
        scheduleDismiss(timeout: timeout)
        return true
    }

    func dismiss(notify: Bool) {
        dismissTask?.cancel()
        dismissTask = nil

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }

        let candidate = representedCandidate
        representedCandidate = nil
        panel?.orderOut(nil)

        if notify, let candidate {
            onDismiss?(candidate)
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }

        let frame = NSRect(origin: .zero, size: CapturePillView.preferredSize)
        let panel = CapturePillPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: true
        )
        let pillView = CapturePillView(frame: NSRect(origin: .zero, size: CapturePillView.preferredSize))
        pillView.autoresizingMask = [.width, .height]
        pillView.onRecord = { [weak self] in self?.record() }
        pillView.onDismiss = { [weak self] in self?.dismiss(notify: true) }
        pillView.onRemind = { [weak self] in self?.remind() }
        panel.contentView = pillView

        self.panel = panel
        self.pillView = pillView
    }

    private func record() {
        guard let candidate = representedCandidate else { return }
        dismiss(notify: false)
        onRecord?(candidate)
    }

    private func remind() {
        guard let candidate = representedCandidate else { return }
        dismiss(notify: false)
        onRemind?(candidate)
    }

    private func scheduleDismiss(timeout: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(1, timeout) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            guard let self, let candidate = self.representedCandidate else { return }
            self.dismiss(notify: false)
            self.onExpired?(candidate)
        }
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible else { return event }
            // Only handle Return/Escape once the pill itself owns the key event.
            // Keystrokes aimed at Home, Settings, or a speaker-review field must pass through.
            guard event.window === panel || panel.isKeyWindow else { return event }
            switch event.keyCode {
            case 36:
                self.record()
                return nil
            case 53:
                self.dismiss(notify: true)
                return nil
            default:
                return event
            }
        }
    }

    private func position(panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let selectedFrame = CapturePillPlacementPolicy.selectedScreenFrame(
            mouseLocation: mouseLocation,
            screenFrames: NSScreen.screens.map(\.frame),
            fallbackScreenFrame: NSScreen.main?.frame
        )
        let screen = selectedFrame.flatMap { frame in
            NSScreen.screens.first { $0.frame == frame }
        } ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        let origin = CapturePillPlacementPolicy.origin(panelSize: size, visibleFrame: visibleFrame)
        panel.setFrameOrigin(origin)
    }
}

@available(macOS 14.0, *)
final class CapturePillPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onDefault: (() -> Void)?

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
            defer: true
        )
        self.level = .popUpMenu
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.sharingType = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36:
            onDefault?()
        case 53:
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }
}

@available(macOS 14.0, *)
private final class CapturePillView: NSView {
    static let preferredSize = NSSize(width: 540, height: 74)

    var onRecord: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onRemind: (() -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let dismissButton = NSButton(title: "Not now", target: nil, action: nil)
    private let remindButton = NSButton(title: "Remind me soon", target: nil, action: nil)
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.98).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor

        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(detailLabel)

        configureButton(dismissButton, title: "Not now", isPrimary: false, action: #selector(dismissTapped))
        configureButton(remindButton, title: "Remind me soon", isPrimary: false, action: #selector(remindTapped))
        configureButton(recordButton, title: "Record", isPrimary: true, action: #selector(recordTapped))

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Meeting capture prompt")
        setAccessibilityHelp("Choose whether Transcripted should record this meeting.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()

        let pad: CGFloat = 14
        let iconSize: CGFloat = 36
        iconView.frame = NSRect(x: pad, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)

        let recordSize = NSSize(width: 72, height: 32)
        let remindSize = NSSize(width: 118, height: 32)
        let dismissSize = NSSize(width: 82, height: 32)
        recordButton.frame = NSRect(
            x: bounds.width - pad - recordSize.width,
            y: (bounds.height - recordSize.height) / 2,
            width: recordSize.width,
            height: recordSize.height
        )
        remindButton.frame = NSRect(
            x: recordButton.frame.minX - 8 - remindSize.width,
            y: (bounds.height - remindSize.height) / 2,
            width: remindSize.width,
            height: remindSize.height
        )
        dismissButton.frame = NSRect(
            x: remindButton.frame.minX - 8 - dismissSize.width,
            y: (bounds.height - dismissSize.height) / 2,
            width: dismissSize.width,
            height: dismissSize.height
        )

        let textX = iconView.frame.maxX + 12
        let textWidth = dismissButton.frame.minX - 12 - textX
        titleLabel.frame = NSRect(x: textX, y: 38, width: max(40, textWidth), height: 18)
        detailLabel.frame = NSRect(x: textX, y: 18, width: max(40, textWidth), height: 16)
    }

    func update(candidate: MeetingPromptDetector.Candidate) {
        let meetingName = candidate.suggestedTranscriptTitle ?? candidate.title
        titleLabel.stringValue = meetingName
        detailLabel.stringValue = candidate.detail
        setAccessibilityValue("\(meetingName). \(candidate.detail)")
        needsLayout = true
    }

    private func configureButton(
        _ button: NSButton,
        title: String,
        isPrimary: Bool,
        action: Selector
    ) {
        button.title = title
        button.target = self
        button.action = action
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = isPrimary
            ? NSColor.controlAccentColor.cgColor
            : NSColor.controlColor.withAlphaComponent(0.85).cgColor
        button.contentTintColor = isPrimary ? .white : .labelColor
        button.setAccessibilityLabel(title)
        let help: String
        switch title {
        case "Record":
            help = "Start recording this meeting."
        case "Remind me soon":
            help = "Ask again soon."
        default:
            help = "Dismiss this meeting prompt."
        }
        button.setAccessibilityHelp(help)
        addSubview(button)
    }

    @objc private func recordTapped() {
        onRecord?()
    }

    @objc private func remindTapped() {
        onRemind?()
    }

    @objc private func dismissTapped() {
        onDismiss?()
    }
}

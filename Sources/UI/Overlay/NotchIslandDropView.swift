// NotchIslandDropView.swift
// The island's drop-down below the wings: titles, lanes and buttons for
// whatever NotchIslandPresentation put in the drop. Split out of
// NotchIslandView.swift.

import AppKit

final class NotchIslandDropView: NSView {
    static let contentWidth = NotchIslandGeometry.dropWidth - 40

    var onAction: ((NotchIslandAction) -> Void)?
    private(set) var drop: NotchIslandDrop
    let stack = NSStackView()
    private var youLane: NotchIslandBarsView?
    private var callLane: NotchIslandBarsView?
    private var countdownButton: NotchIslandButton?
    /// A dictation message's words and hint. A click on them is someone
    /// reading, so it never reaches the island's click-to-dismiss.
    var readableText: [NSView] = []

    func setCountdownPaused(_ paused: Bool) {
        countdownButton?.setCountdownPaused(paused)
    }

    /// The island's "Who was on this call?" view, kept alive by the
    /// controller so typing and playback survive the drop-down being rebuilt.
    private let speakerReviewView: NSView?
    /// The live transcript, kept alive by the controller like the review.
    private let liveTranscriptView: NotchIslandLiveTranscriptView?
    /// The dictation's live words, kept alive by the controller the same way.
    let dictationPreviewView: NotchIslandDictationPreviewView?

    init(
        drop: NotchIslandDrop,
        live: NotchIslandLiveValues,
        targetIcon: () -> NSImage?,
        speakerReviewView: NSView? = nil,
        liveTranscriptView: NotchIslandLiveTranscriptView? = nil,
        dictationPreviewView: NotchIslandDictationPreviewView? = nil
    ) {
        self.drop = drop
        self.speakerReviewView = speakerReviewView
        self.liveTranscriptView = liveTranscriptView
        self.dictationPreviewView = dictationPreviewView
        super.init(frame: NSRect(x: 0, y: 0, width: NotchIslandGeometry.dropWidth, height: 10))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.widthAnchor.constraint(equalToConstant: NotchIslandGeometry.dropWidth),
        ])
        build(live: live, targetIcon: targetIcon)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    var fittingHeight: CGFloat { ceil(stack.fittingSize.height) }

    /// Measured once per island render (`NotchIslandView.measureDropHeight`),
    /// so the island's layout passes don't each solve the stack again.
    private(set) var measuredHeight: CGFloat?

    func measureHeight() -> CGFloat {
        let height = fittingHeight
        measuredHeight = height
        return height
    }

    /// A meeting prompt whose countdown only moved is updated in place, so
    /// its buttons are not rebuilt under the pointer each second; the ring
    /// keeps running on its own.
    func adoptIfOnlyCountdownChanged(_ newDrop: NotchIslandDrop) -> Bool {
        guard case .meetingPrompt(let old) = drop,
              case .meetingPrompt(let new) = newDrop,
              old.matchesIgnoringCountdown(new) else { return false }
        drop = newDrop
        return true
    }

    func pushLevels(mic: Float, system: Float) {
        youLane?.push(mic)
        callLane?.push(system)
    }

    // MARK: Building

    private func build(live: NotchIslandLiveValues, targetIcon: () -> NSImage?) {
        switch drop {
        case .dictationTarget(let appName, let showsPreview, let isWriting):
            buildDictationTarget(appName: appName, icon: targetIcon, showsPreview: showsPreview, isWriting: isWriting)
            return
        case .dictationLoading(let title, let detail):
            add(titleBlock(title, detail, wrapsDetail: true))
        case .dictationNote(let text):
            let note = body(text)
            readableText = [note]
            add(note)
        case .dictationMessage(let message) where message.preview != nil:
            // Every "your words didn't land" notice: the words, one line on
            // what happened or what to do, then Dismiss (ring) and Paste.
            let quote = body("\u{201C}\(message.preview ?? "")\u{201D}", maxLines: 2)
            let hint = NotchIslandPalette.label(
                message.hint ?? "Click where it goes, then press ⌘V.",
                font: TextRole.meta.nsFont(weight: .regular),
                color: NotchIslandPalette.secondaryText
            )
            readableText = [quote, hint]
            add(quote)
            add(hint)
        case .dictationMessage(let message):
            let text = body(message.text)
            readableText = [text]
            add(text)
        case .justInserted(let text, _):
            buildJustInserted(text: text)
            return
        case .meetingPreparing(let title, let detail):
            add(titleBlock(title, detail, wrapsDetail: true))
        case .meetingControls(let note, let unverified, let showsTranscript, _, let micAction):
            let muted: Bool
            if case .meetingMicUnmute? = micAction { muted = true } else { muted = false }
            let subtitle: String
            if unverified {
                subtitle = NotchIslandMeetingCopy.cantConfirmCallAudio
            } else {
                switch note {
                case .off?: subtitle = NotchIslandMeetingCopy.callAudioOff
                case .onForNextMeeting?: subtitle = NotchIslandMeetingCopy.callAudioNextMeeting
                case nil: subtitle = muted ? NotchIslandMeetingCopy.micMuted : NotchIslandMeetingCopy.bothSides
                }
            }
            add(titleBlock("Recording", subtitle))
            if showsTranscript, let liveTranscriptView {
                liveTranscriptView.removeFromSuperview()
                stack.addArrangedSubview(liveTranscriptView) // not add(): it pins its own size
                readableText.append(liveTranscriptView)
                DispatchQueue.main.async { [weak liveTranscriptView] in liveTranscriptView?.scrollToNewest() }
            } else {
                let you = NotchIslandBarsView(count: 46, maxHeight: 20, color: NotchIslandPalette.accent)
                let call = NotchIslandBarsView(count: 46, maxHeight: 20, color: NSColor(white: 1, alpha: 0.8))
                youLane = you
                callLane = call
                add(lane("You", you))
                add(lane(NotchIslandMeetingCopy.otherSideLane, call))
            }
        case .meetingPrompt(let prompt):
            // A countdown is the ring on the button that fires, never a line.
            add(titleBlock(prompt.title, prompt.detail, wrapsDetail: true))
        case .meetingSaved(let title):
            // "Meeting saved · Saved to Meetings" said it twice.
            add(titleBlock(title ?? "Meeting saved", title == nil ? "" : "Saved to Meetings"))
        case .meetingError(let title, let message, _, _):
            add(titleBlock(title, message, wrapsDetail: true))
        case .callPrompt(let title, let detail):
            add(titleBlock(title, detail))
        case .meetingCallAudioAsk:
            add(titleBlock(
                NotchIslandMeetingCopy.callAudioOff,
                "Turn it on for your next meeting.",
                wrapsDetail: true
            ))
        case .speakerReview:
            if let speakerReviewView {
                speakerReviewView.removeFromSuperview()
                stack.addArrangedSubview(speakerReviewView)
            }
            return
        }
        addButtons(NotchIslandDropButtons.buttons(for: drop, callSecondsLeft: live.callSecondsLeft), targetIcon: targetIcon)
    }

    /// Draws the drop-down's buttons from their plain description.
    func addButtons(_ specs: [NotchIslandDropButton], targetIcon: () -> NSImage?) {
        guard !specs.isEmpty else { return }
        var leading: [NSView] = []
        var trailing: [NSView] = []
        for spec in specs {
            let view: NotchIslandButton
            if spec.action == .meetingCopyTranscript {
                view = copyTranscriptButton()
            } else {
                view = button(spec.title, Self.style(for: spec.role), spec.action, symbol: spec.symbol,
                              appIcon: spec.showsTargetAppIcon ? targetIcon() : nil,
                              accessibilityLabel: spec.accessibilityLabel)
            }
            if let ring = spec.countdown {
                let action = spec.action
                view.startCountdown(seconds: ring.secondsLeft, fromFraction: ring.fraction) { secondsLeft in
                    NotchIslandDropButtons.countdownAccessibilityValue(for: action, secondsLeft: secondsLeft)
                }
                // Only a ring whose timer holds on hover is paused by it.
                if ring.holdsWhileHovered { countdownButton = view }
            }
            if spec.placement == .leading { leading.append(view) } else { trailing.append(view) }
        }
        add(buttonRow(leading: leading, trailing: trailing))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A control-click still reaches the island for its menu.
        if !event.modifierFlags.contains(.control),
           readableText.contains(where: { $0.convert($0.bounds, to: self).contains(point) }) {
            return
        }
        super.mouseDown(with: event)
    }

    func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentWidth).isActive = true
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    func buttonRow(leading: [NSView], trailing: [NSView]) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let row = NSStackView(views: leading + [spacer] + trailing)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return row
    }

    private func titleBlock(_ title: String, _ detail: String, wrapsDetail: Bool = false) -> NSView {
        let titleLabel = NotchIslandPalette.label(title, font: TextRole.heading.nsFont(weight: .bold), color: NotchIslandPalette.primaryText)
        titleLabel.lineBreakMode = .byTruncatingTail
        var views: [NSView] = [titleLabel]
        if !detail.isEmpty {
            let detailLabel = NotchIslandPalette.label(
                detail,
                font: TextRole.meta.nsFont(weight: .regular),
                color: NotchIslandPalette.secondaryText,
                wraps: wrapsDetail,
                width: Self.contentWidth - 48
            )
            if !wrapsDetail { detailLabel.lineBreakMode = .byTruncatingTail }
            views.append(detailLabel)
        }
        let block = NSStackView(views: views)
        block.orientation = .vertical
        block.alignment = .leading
        block.spacing = 2
        return block
    }

    func body(_ text: String, maxLines: Int = 0) -> NSTextField {
        let label = NotchIslandPalette.label(
            text,
            font: TextRole.body.nsFont(weight: .regular),
            color: NotchIslandPalette.bodyText,
            wraps: true,
            width: Self.contentWidth
        )
        label.maximumNumberOfLines = maxLines
        // Wrap, and put the ellipsis on the last line that fits.
        label.cell?.truncatesLastVisibleLine = maxLines > 0
        return label
    }

    private func lane(_ name: String, _ bars: NotchIslandBarsView) -> NSView {
        let label = NotchIslandPalette.label(name, font: TextRole.small.nsFont(weight: .semibold), color: NotchIslandPalette.secondaryText)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 40).isActive = true
        return row([label, bars])
    }

    /// Copy all, which says "Copied" for a beat.
    private func copyTranscriptButton() -> NotchIslandButton {
        let button = NotchIslandButton(title: "Copy all", style: .plain, symbolName: "doc.on.doc")
        button.onPress = { [weak self, weak button] in
            self?.onAction?(.meetingCopyTranscript)
            button?.replaceTitle("Copied")
            Task { @MainActor [weak button] in
                try? await Task.sleep(for: .seconds(1.4))
                button?.replaceTitle("Copy all")
            }
        }
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    /// A button's style comes from its role, not its title.
    static func style(for role: NotchIslandPromptButtonRole) -> NotchIslandButton.Style {
        switch role {
        case .standard: return .plain
        case .primary: return .accent
        case .destructive: return .destructive
        case .quiet: return .subtle
        }
    }

    func button(_ title: String, _ style: NotchIslandButton.Style, _ action: NotchIslandAction, symbol: String? = nil, appIcon: NSImage? = nil, accessibilityLabel: String? = nil) -> NotchIslandButton {
        let button = NotchIslandButton(title: title, style: style, symbolName: symbol, appIcon: appIcon)
        if let accessibilityLabel {
            button.setAccessibilityLabel(accessibilityLabel)
        }
        button.onPress = { [weak self] in self?.onAction?(action) }
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
}

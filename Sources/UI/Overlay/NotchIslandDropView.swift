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
    private var promptCountdownLabel: NSTextField?
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

    /// Nothing in the drop-down reads a live value today: the call prompt's
    /// countdown is the ring around Skip, which runs by itself.
    func updateLive(_ live: NotchIslandLiveValues) {}

    /// A meeting prompt that only changed its "Stops in 12s" line is updated
    /// in place, so its buttons are not rebuilt under the pointer each second.
    func adoptIfOnlyCountdownChanged(_ newDrop: NotchIslandDrop) -> Bool {
        guard case .meetingPrompt(let old) = drop,
              case .meetingPrompt(let new) = newDrop,
              let promptCountdownLabel,
              !new.countdown.isEmpty else { return false }
        var oldWithoutCountdown = old
        oldWithoutCountdown.countdown = new.countdown
        guard oldWithoutCountdown == new else { return false }
        promptCountdownLabel.stringValue = new.countdown
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
        case .dictationLoading(let title, let detail):
            add(titleBlock(title, detail, wrapsDetail: true))
        case .dictationMessage(let message) where message.preview != nil:
            let quote = body("“\(message.preview ?? "")”", maxLines: 2)
            let hint = NotchIslandPalette.label(
                message.hint ?? "Click where it goes, then press ⌘V.",
                font: .systemFont(ofSize: 12),
                color: NotchIslandPalette.secondaryText
            )
            readableText = [quote, hint]
            add(quote)
            add(hint)
            let dismiss = NotchIslandButton(title: "Dismiss", style: .plain)
            dismiss.onPress = { [weak self] in self?.onAction?(.dictationDismissMessage) }
            dismiss.setContentHuggingPriority(.required, for: .horizontal)
            if let seconds = message.dismissSeconds {
                dismiss.startCountdown(seconds: seconds)
                countdownButton = dismiss
            }
            add(buttonRow(leading: [], trailing: [
                dismiss,
                button(message.actionTitle ?? "Paste", .accent, .dictationMessageAction),
            ]))
        case .dictationMessage(let message):
            let text = body(message.text)
            readableText = [text]
            add(text)
            var trailing = [button("Dismiss", .plain, .dictationDismissMessage)]
            if let actionTitle = message.actionTitle {
                trailing.append(button(actionTitle, .accent, .dictationMessageAction))
            }
            add(buttonRow(leading: [], trailing: trailing))
        case .justInserted(let text, _):
            buildJustInserted(text: text)
        case .meetingPreparing(let title, let detail):
            add(titleBlock(title, detail, wrapsDetail: true))
        case .meetingControls(let note, let unverified, let showsTranscript):
            let subtitle: String
            if unverified {
                subtitle = "Can't confirm call audio yet"
            } else {
                switch note {
                case .off?: subtitle = "Call audio is off"
                case .onForNextMeeting?: subtitle = "Call audio starts next meeting"
                case nil: subtitle = "You and the call"
                }
            }
            add(titleBlock("Recording", subtitle))
            if showsTranscript, let liveTranscriptView {
                liveTranscriptView.removeFromSuperview()
                stack.addArrangedSubview(liveTranscriptView) // not add(): it pins its own size
                readableText.append(liveTranscriptView)
                DispatchQueue.main.async { [weak liveTranscriptView] in liveTranscriptView?.scrollToNewest() }
                var leading = [copyTranscriptButton()]
                if note == .off {
                    leading.append(button("Turn on call audio", .warning, .meetingCallAudio))
                }
                add(buttonRow(leading: leading, trailing: [
                    button("Stop", .destructive, .meetingStop, symbol: "stop.fill"),
                ]))
                break
            }
            let you = NotchIslandBarsView(count: 46, maxHeight: 20, color: NotchIslandPalette.accent)
            let call = NotchIslandBarsView(count: 46, maxHeight: 20, color: NSColor(white: 1, alpha: 0.8))
            youLane = you
            callLane = call
            add(lane("You", you))
            add(lane("Call", call))
            var leading: [NSView] = []
            if note == .off {
                leading.append(button("Turn on", .warning, .meetingCallAudio))
            }
            add(buttonRow(leading: leading, trailing: [
                button("Stop", .destructive, .meetingStop, symbol: "stop.fill"),
            ]))
        case .meetingPrompt(let prompt):
            add(titleBlock(prompt.title, prompt.detail, wrapsDetail: true))
            if !prompt.countdown.isEmpty {
                let countdown = NotchIslandPalette.label(
                    prompt.countdown,
                    font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                    color: NotchIslandPalette.secondaryText
                )
                promptCountdownLabel = countdown
                add(countdown)
            }
            var leading: [NSView] = []
            if let tertiary = prompt.tertiaryTitle, !tertiary.isEmpty {
                leading.append(button(tertiary, .subtle, .meetingTertiary))
            }
            var trailing: [NSView] = []
            if !prompt.secondaryTitle.isEmpty {
                trailing.append(button(prompt.secondaryTitle, .plain, .meetingSecondary))
            }
            if !prompt.primaryTitle.isEmpty {
                let style: NotchIslandButton.Style = prompt.primaryTitle == "Stop" ? .destructive : .accent
                trailing.append(button(prompt.primaryTitle, style, .meetingPrimary))
            }
            add(buttonRow(leading: leading, trailing: trailing))
        case .meetingSaved(let title):
            add(titleBlock(title ?? "Meeting saved", "Saved to Meetings"))
            add(buttonRow(leading: [], trailing: [button("Open", .accent, .meetingOpen)]))
        case .meetingError(let title, let message, let canOpen, let grantsSystemAudio):
            add(titleBlock(title, message, wrapsDetail: true))
            var trailing = [button("OK", .plain, .meetingDismissError)]
            if grantsSystemAudio {
                // The meeting overlay's primary action opens the audio-only
                // Settings pane while the start's denial is on screen.
                trailing.append(button("Open Settings", .accent, .meetingPrimary))
            } else if canOpen {
                trailing.append(button("Open", .accent, .meetingOpen))
            }
            add(buttonRow(leading: [], trailing: trailing))
        case .callPrompt(let title, let detail):
            add(titleBlock(title, detail))
            // The countdown is a ring around Skip, like the dictation
            // Dismiss ring; it pauses while the pointer is over the island.
            let notNow = NotchIslandButton(title: "Skip", style: .plain)
            notNow.onPress = { [weak self] in self?.onAction?(.callDismiss) }
            notNow.setContentHuggingPriority(.required, for: .horizontal)
            notNow.startCountdown(seconds: Double(max(1, live.callSecondsLeft)))
            countdownButton = notNow
            add(buttonRow(leading: [], trailing: [
                notNow,
                button("Remind me", .plain, .callRemind),
                button("Record", .destructive, .callRecord, symbol: "record.circle.fill"),
            ]))
        case .meetingCallAudioAsk:
            add(titleBlock(
                "Call audio is off",
                "Turn it on to record the other people. Starts next meeting.",
                wrapsDetail: true
            ))
            add(buttonRow(leading: [], trailing: [
                button("Skip", .plain, .meetingCallAudioDismiss),
                button("Turn on", .accent, .meetingCallAudio),
            ]))
        case .speakerReview:
            if let speakerReviewView {
                speakerReviewView.removeFromSuperview()
                stack.addArrangedSubview(speakerReviewView)
            }
        }
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
        let titleLabel = NotchIslandPalette.label(title, font: .systemFont(ofSize: 15, weight: .bold), color: NotchIslandPalette.primaryText)
        titleLabel.lineBreakMode = .byTruncatingTail
        var views: [NSView] = [titleLabel]
        if !detail.isEmpty {
            let detailLabel = NotchIslandPalette.label(
                detail,
                font: .systemFont(ofSize: 12),
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
            font: .systemFont(ofSize: 13),
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
        let label = NotchIslandPalette.label(name, font: .systemFont(ofSize: 11, weight: .semibold), color: NotchIslandPalette.secondaryText)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return row([label, bars])
    }

    /// Copy all, which says "Copied" for a beat.
    private func copyTranscriptButton() -> NSView {
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

    func button(_ title: String, _ style: NotchIslandButton.Style, _ action: NotchIslandAction, symbol: String? = nil, appIcon: NSImage? = nil) -> NSView {
        let button = NotchIslandButton(title: title, style: style, symbolName: symbol, appIcon: appIcon)
        button.onPress = { [weak self] in self?.onAction?(action) }
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }
}

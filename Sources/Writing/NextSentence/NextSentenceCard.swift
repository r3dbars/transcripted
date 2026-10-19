import AppKit

/// The Next Sentence card: the likeliest reply in front, the other two peeking out behind it.
/// A mood pad in the corner sets tone and length; a handle at the end of the message stretches it.
/// Hovering a word offers others (scroll to roll one in); words from their history are shaded and
/// say where they came from. The card is one fixed size, so nothing jumps while they play with it.
@MainActor
final class NextSentenceCard: NSObject {
    struct Mark {
        let range: NSRange
        let color: NSColor
        let heading: String
        let quote: String
    }

    struct Peek {
        let index: Int
        let label: String
        let text: String
    }

    struct Content {
        var status: String
        var busy = false
        var replyIndex = 0
        var replyCount = 0
        var replyLabel = ""
        /// The other replies, nearest first.
        var peeks: [Peek] = []
        var text = ""
        var marks: [Mark] = []
        /// Lowercased words that have other words to swap in.
        var swappable: Set<String> = []
        var streaming = false
        /// Cross-fade to the new text (a different reply, tone or length), rather than replace it.
        var fade = false
        var tone = 1
        var length = NextSentencePrompt.mediumLength
        var hint = ""
        var insertTitle = "Insert"
        var insertIcon: NSImage?
        var showsButtons = false
        var listening = false
        /// What they said, shown while it rewrites.
        var heard: String?
        /// Only the status line: for short notes like "Copied".
        var compact = false
    }

    // Callbacks
    var onInsert: ((_ send: Bool) -> Void)?
    var onClose: (() -> Void)?
    var onBeginEditing: (() -> Void)?
    var onEndEditing: (() -> Void)?
    var onTextEdited: (() -> Void)?
    var onReturnDown: (() -> Void)?
    var onReturnUp: (() -> Void)?
    var onPickReply: ((Int) -> Void)?
    var onMood: ((_ tone: Int, _ length: Int) -> Void)?
    var onLength: ((Int) -> Void)?
    var onFreshTake: (() -> Void)?
    var onMic: (() -> Void)?
    var wordOptions: (String) -> [String] = { _ in [] }
    var onWordPick: ((NSRange, String) -> Void)?
    var onWordRoll: ((NSRange, Int) -> Void)?
    var onRemixPart: ((NSRange) -> Void)?
    var onPickSelection: ((NSRange) -> Void)?

    static let margin: CGFloat = 14
    static let headroom: CGFloat = 130
    static let textHeight = NextSentenceCardStyle.lineHeight * NextSentenceCardStyle.textLines + 2
    static let fullHeight: CGFloat = textTop + textHeight + 10 + 28 + 12
    /// Where the text box starts, below the status line.
    static let textTop: CGFloat = 44
    static let compactHeight: CGFloat = 38
    private var width: CGFloat { NextSentenceCardStyle.width }

    private let panel: NextSentencePanel
    private let root = NextSentenceCardRoot()
    private let peekCards = [NextSentencePeekCard(frame: .zero), NextSentencePeekCard(frame: .zero)]
    private let front = NextSentenceFlippedView()
    private let ring = NextSentenceRing(frame: .zero)
    private let busyDot = NSView()
    private let statusLabel = NextSentenceCardStyle.label(NextSentenceCardStyle.titleFont, NextSentenceCardStyle.title)
    private let replyDots = NextSentenceFlippedView()
    private let replyLabel = NextSentenceCardStyle.label(NextSentenceCardStyle.titleFont, NSColor(white: 1, alpha: 0.45))
    private let pad = NextSentenceMoodPad(frame: .zero)
    private let padLabel = NextSentenceCardStyle.label(.systemFont(ofSize: 11, weight: .semibold), NextSentenceCardStyle.title)
    private let scroll = NSScrollView()
    let textView = NextSentenceTextView(width: NextSentenceCardStyle.width - 28)
    private let grip = NextSentenceLengthGrip(frame: .zero)
    private let gripHint = NextSentenceCardStyle.label(.systemFont(ofSize: 10.5, weight: .semibold), NextSentenceCardStyle.title)
    private let ticks = NextSentenceFlippedView()
    private let lengthLabel = NextSentenceCardStyle.label(NextSentenceCardStyle.hintFont, NextSentenceCardStyle.faint)
    private let hintLabel = NextSentenceCardStyle.label(NextSentenceCardStyle.hintFont, NextSentenceCardStyle.faint)
    private let waveform = NextSentenceWaveform(frame: .zero)
    private let micButton = NextSentenceCapsuleButton(title: "", fill: NextSentenceCardStyle.buttonSubtle)
    private let remixButton = NextSentenceCapsuleButton(title: "", fill: NextSentenceCardStyle.buttonSubtle)
    private let insertButton = NextSentenceCapsuleButton(title: "Insert", fill: NextSentenceCardStyle.accent)
    private let remixChip = NextSentenceCapsuleButton(title: "↻ remix", fill: NextSentenceCardStyle.accent, height: 18)
    private let float = NextSentenceWordFloat(frame: .zero)
    private let tip = NextSentenceSourceTip(frame: .zero)

    private(set) var content = Content(status: "")
    private var anchor: CGRect = .zero
    private var shownSignature = ""
    private var lifted: Int?
    private var gripBase = 0
    private var floatRange: NSRange?
    private var floatWork: DispatchWorkItem?
    private var remixRange: NSRange?
    private var insertHeldFull = false

    override init() {
        panel = NextSentencePanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.applyScreenSharingPreference()
        build()
    }

    var isVisible: Bool { panel.isVisible }
    var isEditing: Bool { textView.isEditable }
    /// What's in the card right now, including the user's own edits.
    var currentText: String { textView.string.replacingOccurrences(of: " ▍", with: "") }

    // MARK: Show and hide

    func show(at caretAccessibilityRect: CGRect?, content: Content) {
        if let caretAccessibilityRect, let primary = NSScreen.screens.first {
            anchor = NextSentencePolicy.cocoaRect(fromAccessibility: caretAccessibilityRect, primaryScreenMaxY: primary.frame.maxY)
        } else {
            let mouse = NSEvent.mouseLocation
            anchor = CGRect(x: mouse.x, y: mouse.y - 20, width: 1, height: 20)
        }
        endEditing()
        shownSignature = ""
        lifted = nil
        update(content)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        endEditing()
        closeFloats()
        ring.set(listening: false)
        waveform.set(animating: false)
        panel.orderOut(nil)
    }

    func update(_ new: Content) {
        let wasCompact = content.compact
        let wasListening = content.listening
        content = new
        statusLabel.stringValue = new.status
        busyDot.isHidden = !new.busy
        replyLabel.stringValue = new.replyLabel
        padLabel.stringValue = "\(NextSentencePrompt.Tone.padOrder[new.tone].rawValue.capitalized) · \(NextSentencePrompt.lengthNames[new.length])"
        pad.set(tone: new.tone, length: new.length)
        lengthLabel.stringValue = NextSentencePrompt.lengthNames[new.length]
        hintLabel.stringValue = new.listening ? "" : new.hint
        let signature = "\(new.text)|\(new.streaming)|\(new.marks.map { "\($0.range)" })|\(new.swappable.sorted())"
        if !isEditing && signature != shownSignature {
            if new.fade && !new.streaming { fadeText() }
            textView.textStorage?.setAttributedString(attributed(new))
            shownSignature = signature
            textView.scrollToBeginningOfDocument(nil)
            if let remixRange, NSMaxRange(remixRange) > (textView.string as NSString).length { hideRemixChip() }
        }
        insertButton.set(title: insertHeldFull ? "Release to send" : new.insertTitle, icon: new.insertIcon)
        ring.set(listening: new.listening)
        if new.listening != wasListening { waveform.set(animating: new.listening) }
        for (card, peek) in zip(peekCards, new.peeks + [Peek](repeating: Peek(index: 0, label: "", text: ""), count: 2)) {
            card.set(label: peek.label, text: peek.text)
        }
        glow()
        layout(animatePeeks: wasCompact == new.compact)
    }

    // MARK: Editing

    /// Lets the card take the keyboard (without activating Transcripted) and puts the cursor in the text.
    func beginEditing(typing: String? = nil) {
        guard !isEditing else { return }
        closeFloats()
        panel.allowsKeyboard = true
        textView.isEditable = true
        let plain = currentText
        textView.textStorage?.setAttributedString(NSAttributedString(string: plain, attributes: bodyAttributes))
        matchTypingStyle()
        panel.makeKey()
        panel.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (plain as NSString).length, length: 0))
        if let typing, !typing.isEmpty { textView.insertText(typing, replacementRange: textView.selectedRange()) }
        grip.isHidden = true
    }

    func endEditing() {
        guard isEditing || panel.allowsKeyboard else { return }
        textView.isEditable = false
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        panel.allowsKeyboard = false
        panel.makeFirstResponder(nil)
        panel.resignKey()
        shownSignature = ""
    }

    func deleteBackward() { textView.deleteBackward(nil) }

    /// Replaces `range` with `text`, keeping the shading. Returns the new range.
    @discardableResult
    func replace(_ range: NSRange, with text: String) -> NSRange {
        guard let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return range }
        let attributes = storage.attributes(at: range.location, effectiveRange: nil)
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attributes))
        shownSignature = "edited"
        placeGrip()
        return NSRange(location: range.location, length: (text as NSString).length)
    }

    /// The ring around the card: progress 0...1 in `color`.
    func setRing(_ progress: Double, color: NSColor) { ring.set(progress: progress, color: color) }

    /// Return or Insert held long enough to send.
    func setSendArmed(_ armed: Bool) {
        guard armed != insertHeldFull else { return }
        insertHeldFull = armed
        if armed { NextSentenceCardStyle.tick() }
        insertButton.set(title: armed ? "Release to send" : content.insertTitle, icon: content.insertIcon)
        layoutFoot()
    }

    // MARK: Words

    /// Floats the other words for `range` above it. Called on hover, and again after each swap.
    func showWordFloat(for range: NSRange) {
        let text = textView.string as NSString
        guard NSMaxRange(range) <= text.length else { return closeFloats() }
        let options = wordOptions(text.substring(with: range).lowercased())
        guard !options.isEmpty else { return closeFloats() }
        clearWordHighlight()
        floatRange = range
        textView.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor(white: 1, alpha: 0.12), forCharacterRange: range)
        let rect = textView.convert(textView.rect(for: range), to: root)
        float.show(options, above: rect)
        float.onPick = { [weak self] option in self?.onWordPick?(range, option) }
        float.isHidden = false
    }

    /// Highlights a picked part and puts a remix chip after it.
    func showRemixChip(for range: NSRange) {
        guard NSMaxRange(range) <= (textView.string as NSString).length else { return }
        hideRemixChip()
        remixRange = range
        textView.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NextSentenceCardStyle.accent.withAlphaComponent(0.42),
                                                      forCharacterRange: range)
        let end = textView.rect(for: NSRange(location: NSMaxRange(range) - 1, length: 1))
        let chipWidth = remixChip.fittingWidth
        remixChip.frame = NSRect(x: min(end.maxX + 4, textView.bounds.width - chipWidth), y: end.minY + 1, width: chipWidth, height: 18)
        remixChip.isHidden = false
    }

    func hideRemixChip() {
        if let remixRange, NSMaxRange(remixRange) <= (textView.string as NSString).length {
            textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: remixRange)
        }
        remixRange = nil
        remixChip.isHidden = true
    }

    private func hover(_ hit: (NSRange, NSRect)?) {
        floatWork?.cancel()
        guard !isEditing, let (range, _) = hit else {
            tip.isHidden = true
            return scheduleFloatClose()
        }
        if let mark = content.marks.first(where: { NSIntersectionRange($0.range, range).length > 0 }) {
            scheduleFloatClose()
            let phrase = textView.convert(textView.rect(for: mark.range), to: root)
            tip.show(heading: mark.heading, quote: mark.quote, above: phrase, within: root.bounds.insetBy(dx: 4, dy: 4))
            tip.isHidden = false
            return
        }
        tip.isHidden = true
        guard range != floatRange else { return }
        let word = (textView.string as NSString).substring(with: range).lowercased()
        guard content.swappable.contains(word) else { return scheduleFloatClose() }
        let work = DispatchWorkItem { [weak self] in self?.showWordFloat(for: range) }
        floatWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (floatRange == nil ? 0.3 : 0.05), execute: work)
    }

    private func scheduleFloatClose() {
        guard floatRange != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.float.isHovered else { return }
            self.closeFloats()
        }
        floatWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func closeFloats() {
        floatWork?.cancel()
        clearWordHighlight()
        floatRange = nil
        float.isHidden = true
        tip.isHidden = true
    }

    private func clearWordHighlight() {
        if let floatRange, NSMaxRange(floatRange) <= (textView.string as NSString).length {
            textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: floatRange)
        }
    }

    // MARK: Building

    private var bodyAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = NextSentenceCardStyle.lineHeight
        paragraph.maximumLineHeight = NextSentenceCardStyle.lineHeight
        return [.font: NextSentenceCardStyle.bodyFont, .foregroundColor: NextSentenceCardStyle.body, .paragraphStyle: paragraph,
                .baselineOffset: 1.5]
    }

    private func attributed(_ content: Content) -> NSAttributedString {
        let result = NSMutableAttributedString(string: content.text, attributes: bodyAttributes)
        let ns = content.text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { word, range, _, _ in
            guard let word, content.swappable.contains(word.lowercased()) else { return }
            result.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue,
                                  .underlineColor: NSColor(white: 1, alpha: 0.28)], range: range)
        }
        for mark in content.marks where NSMaxRange(mark.range) <= result.length {
            result.addAttribute(.foregroundColor, value: mark.color, range: mark.range)
            result.removeAttribute(.underlineStyle, range: mark.range)
        }
        if content.streaming {
            var caret = bodyAttributes
            caret[.foregroundColor] = NextSentenceCardStyle.accent
            result.append(NSAttributedString(string: " ▍", attributes: caret))
        }
        return result
    }

    /// What the user types looks exactly like what was written for them.
    private func matchTypingStyle() {
        let attributes = bodyAttributes
        textView.font = NextSentenceCardStyle.bodyFont
        textView.textColor = NextSentenceCardStyle.body
        textView.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        textView.typingAttributes = attributes
        textView.bodyStyle = attributes
    }

    private func fadeText() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.22
        textView.layer?.add(fade, forKey: "fade")
    }

    private func glow() {
        guard let layer = front.layer else { return }
        let color = NextSentenceCardStyle.toneColors[content.tone]
        let neutral = content.tone == 1 || content.listening
        layer.borderColor = color.withAlphaComponent(neutral ? 0.1 : 0.45).cgColor
        layer.shadowColor = (neutral ? NSColor.black : color).cgColor
        layer.shadowOpacity = neutral ? 0.3 : 0.32
        layer.shadowRadius = neutral ? 15 : 12
        layer.shadowOffset = neutral ? CGSize(width: 0, height: -10) : .zero
    }

    private func build() {
        panel.contentView = root
        root.onMouseMoved = { [weak self] point in self?.rootMoved(point) }
        root.onMouseExited = { [weak self] in self?.setLifted(nil) }

        for (rank, card) in peekCards.enumerated() {
            card.onPick = { [weak self] in
                guard let self, self.content.peeks.indices.contains(rank) else { return }
                self.onPickReply?(self.content.peeks[rank].index)
            }
            root.addSubview(card, positioned: .below, relativeTo: nil)
        }
        front.wantsLayer = true
        front.layer?.backgroundColor = NextSentenceCardStyle.background.cgColor
        front.layer?.cornerRadius = NextSentenceCardStyle.cornerRadius
        front.layer?.cornerCurve = .continuous
        front.layer?.borderWidth = 1
        root.addSubview(front)
        root.addSubview(ring)

        busyDot.wantsLayer = true
        busyDot.layer?.backgroundColor = NextSentenceCardStyle.accent.cgColor
        busyDot.layer?.cornerRadius = 3
        replyDots.wantsLayer = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        padLabel.alignment = .right
        pad.onChange = { [weak self] tone, length in self?.onMood?(tone, length) }

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.documentView = textView
        textView.wantsLayer = true
        matchTypingStyle()
        textView.onBeginEditing = { [weak self] in self?.onBeginEditing?() }
        textView.onReturnDown = { [weak self] in self?.onReturnDown?() }
        textView.onReturnUp = { [weak self] in self?.onReturnUp?() }
        textView.onEscape = { [weak self] in self?.onEndEditing?() }
        textView.onTextChange = { [weak self] in self?.onTextEdited?() }
        textView.onPickSelection = { [weak self] range in self?.onPickSelection?(range) }
        textView.onHoverWord = { [weak self] hit in self?.hover(hit) }
        textView.canRoll = { [weak self] range in
            guard let self, !self.isEditing else { return false }
            return self.content.swappable.contains((self.textView.string as NSString).substring(with: range).lowercased())
        }
        textView.onRoll = { [weak self] range, step in self?.onWordRoll?(range, step) }
        textView.addSubview(grip)
        textView.addSubview(remixChip)
        remixChip.isHidden = true
        remixChip.onPress = { [weak self] in
            guard let self, let range = self.remixRange else { return }
            self.onRemixPart?(range)
        }
        grip.onDragStart = { [weak self] in
            guard let self else { return }
            self.gripBase = self.content.length
            self.gripHint.isHidden = false
            self.showGripHint(wanted: self.gripBase)
        }
        grip.onDrag = { [weak self] dx in
            guard let self else { return }
            let step = NextSentencePolicy.gripLength(base: self.gripBase, dragged: dx)
            if step.length != self.content.length {
                NextSentenceCardStyle.tick()
                self.onLength?(step.length)
            }
            self.showGripHint(wanted: step.wanted)
        }
        grip.onDragEnd = { [weak self] in self?.gripHint.isHidden = true }
        gripHint.wantsLayer = true
        gripHint.drawsBackground = true
        gripHint.backgroundColor = NSColor(white: 0.11, alpha: 1)
        gripHint.alignment = .center
        gripHint.layer?.cornerRadius = 6
        gripHint.isHidden = true

        ticks.wantsLayer = true
        micButton.set(title: "", icon: NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Say a change"), color: NextSentenceCardStyle.title)
        micButton.toolTip = "Say a change (or press Caps Lock)"
        micButton.onPress = { [weak self] in self?.onMic?() }
        remixButton.set(title: "", icon: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Fresh take"), color: NextSentenceCardStyle.title)
        remixButton.toolTip = "Hold for a fresh take"
        remixButton.holdDuration = NextSentencePolicy.holdToRemix
        remixButton.onHoldProgress = { [weak self] progress in self?.ring.set(progress: progress, color: NextSentenceCardStyle.accent) }
        remixButton.onHeld = { [weak self] in self?.onFreshTake?() }
        insertButton.holdDuration = NextSentencePolicy.holdToSend
        insertButton.onHoldProgress = { [weak self] progress in
            self?.ring.set(progress: progress, color: NextSentenceCardStyle.send)
            self?.setSendArmed(progress >= 1)
        }
        insertButton.onPress = { [weak self] in self?.onInsert?(false) }
        insertButton.onHeld = { [weak self] in self?.onInsert?(true) }

        for view in [busyDot, statusLabel, replyDots, replyLabel, padLabel, pad, scroll, ticks, lengthLabel, hintLabel,
                     waveform, micButton, remixButton, insertButton] as [NSView] {
            front.addSubview(view)
        }
        float.isHidden = true
        float.onExit = { [weak self] in self?.scheduleFloatClose() }
        tip.isHidden = true
        root.addSubview(gripHint)
        root.addSubview(float)
        root.addSubview(tip)
    }

    // MARK: Layout

    private func layout(animatePeeks: Bool) {
        let cardHeight = content.compact ? Self.compactHeight : Self.fullHeight
        let size = CGSize(width: width, height: cardHeight)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let placement = NextSentencePolicy.place(card: size, under: anchor, in: visible)
        let m = Self.margin
        let frame = CGRect(x: placement.origin.x - m, y: placement.origin.y - m,
                           width: width + 2 * m, height: Self.headroom + cardHeight + m)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        root.frame = CGRect(origin: .zero, size: frame.size)
        front.frame = CGRect(x: m, y: Self.headroom, width: width, height: cardHeight)
        front.layer?.shadowPath = CGPath(roundedRect: front.bounds, cornerWidth: 16, cornerHeight: 16, transform: nil)
        ring.frame = front.frame.insetBy(dx: -3, dy: -3)
        layoutFront()
        layoutPeeks(animated: animatePeeks)
    }

    private func layoutFront() {
        let compact = content.compact
        for view in [replyDots, pad, scroll, hintLabel, micButton, remixButton, insertButton] as [NSView] {
            view.isHidden = compact
        }
        replyLabel.isHidden = true
        padLabel.isHidden = true
        let inset: CGFloat = 16
        let x: CGFloat = content.busy ? inset + 12 : inset
        busyDot.frame = NSRect(x: inset, y: 17, width: 6, height: 6)
        pad.frame = NSRect(x: width - inset - NextSentenceMoodPad.size.width, y: 10, width: NextSentenceMoodPad.size.width,
                           height: NextSentenceMoodPad.size.height)
        let dotsWidth = content.replyCount > 1 ? CGFloat(content.replyCount) * 9 + 6 : 0
        let statusLimit = (compact ? width - inset : pad.frame.minX - 12 - dotsWidth) - x
        let statusWidth = min(ceil(statusLabel.intrinsicContentSize.width), statusLimit)
        statusLabel.frame = NSRect(x: x, y: 12, width: statusWidth, height: 16)
        layoutReplyDots(after: statusLabel.frame.maxX + 10)

        scroll.frame = NSRect(x: inset, y: Self.textTop, width: width - 2 * inset, height: Self.textHeight)
        textView.frame.size.width = width - 2 * inset
        // The text wraps around the pad's lower edge.
        let padOverlap = pad.frame.maxY - Self.textTop + 4
        textView.textContainer?.exclusionPaths = padOverlap > 0
            ? [NSBezierPath(rect: NSRect(x: pad.frame.minX - inset - 8, y: 0, width: 90, height: padOverlap))] : []
        textView.isHidden = compact
        placeGrip()
        layoutFoot()
    }

    private func layoutReplyDots(after x: CGFloat) {
        replyDots.subviews.forEach { $0.removeFromSuperview() }
        let count = content.compact || content.replyCount < 2 ? 0 : content.replyCount
        for index in 0..<count {
            let dot = NSView(frame: NSRect(x: CGFloat(index) * 9, y: 0, width: 5, height: 5))
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 2.5
            dot.layer?.backgroundColor = NSColor(white: 1, alpha: index == content.replyIndex ? 1 : 0.25).cgColor
            replyDots.addSubview(dot)
        }
        replyDots.frame = NSRect(x: x, y: 17.5, width: max(0, CGFloat(count) * 9 - 4), height: 5)
    }

    func placeGrip() {
        let showGrip = !content.compact && !isEditing && !content.streaming && !content.text.isEmpty && !content.listening
        grip.isHidden = !showGrip
        guard showGrip else { return }
        var end = textView.endPoint
        let size = NextSentenceLengthGrip.size
        if end.x + 3 + size.width > textView.bounds.width {
            end = NSPoint(x: -3, y: end.y + NextSentenceCardStyle.lineHeight)
        }
        grip.frame = NSRect(x: end.x + 3, y: end.y + (NextSentenceCardStyle.lineHeight - size.height) / 2, width: size.width, height: size.height)
    }

    private func showGripHint(wanted: Int) {
        let names = NextSentencePrompt.lengthNames
        let shown = NextSentencePolicy.stepLength(wanted, by: 0)
        gripHint.stringValue = wanted > names.count - 1 ? "\(names[shown]) · that's the longest"
            : wanted < 0 ? "\(names[shown]) · that's the shortest" : names[shown]
        placeGrip()
        let gripInRoot = grip.convert(grip.bounds, to: root)
        let hintWidth = ceil(gripHint.intrinsicContentSize.width) + 14
        gripHint.frame = NSRect(x: gripInRoot.midX - hintWidth / 2, y: gripInRoot.minY - 22, width: hintWidth, height: 18)
    }

    private func layoutFoot() {
        let y = Self.textTop + Self.textHeight + 10
        let listening = content.listening && !content.compact
        let heard = content.heard != nil && !content.compact
        ticks.isHidden = true
        lengthLabel.isHidden = true
        micButton.isHidden = content.compact || listening || heard || !content.showsButtons
        remixButton.isHidden = micButton.isHidden
        insertButton.isHidden = micButton.isHidden
        waveform.isHidden = !listening
        hintLabel.isHidden = content.compact

        var right = width - 16
        for button in [insertButton, remixButton, micButton] where !button.isHidden {
            let buttonWidth = button.fittingWidth
            button.frame = NSRect(x: right - buttonWidth, y: y, width: buttonWidth, height: 28)
            right -= buttonWidth + 8
        }
        let hintX: CGFloat
        if listening {
            waveform.frame = NSRect(x: 16, y: y + 7, width: NextSentenceWaveform.size.width, height: NextSentenceWaveform.size.height)
            hintX = waveform.frame.maxX + 10
            hintLabel.stringValue = "Listening. Press Caps Lock again to finish."
        } else if let said = content.heard {
            hintX = 16
            hintLabel.stringValue = "“\(said)”"
        } else {
            hintX = 16
        }
        hintLabel.frame = NSRect(x: hintX, y: y + 7, width: max(0, right - hintX - 4), height: 15)
    }

    private func layoutPeeks(animated: Bool) {
        let m = Self.margin
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !reduce ? 0.3 : 0
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.15)
            context.allowsImplicitAnimation = true
            for (offset, card) in peekCards.enumerated() {
                let rank = CGFloat(offset + 1)
                let shown = !content.compact && content.peeks.count > offset
                let isLifted = lifted == offset
                let scale = 1 - (isLifted ? 0.02 : 0.035) * rank
                let cardWidth = width * scale
                let rise = 14 * rank + (isLifted ? 26 : 0)
                card.animator().frame = NSRect(x: m + (width - cardWidth) / 2, y: Self.headroom - rise, width: cardWidth,
                                               height: Self.fullHeight * scale)
                card.animator().alphaValue = shown ? (isLifted ? 1 : (offset == 0 ? 0.85 : 0.6)) : 0
                card.set(dimmed: !isLifted)
                card.isHidden = !shown
            }
        }
    }

    private func rootMoved(_ point: NSPoint) {
        guard !content.compact, !front.frame.contains(point) else { return setLifted(nil) }
        let hit = peekCards.indices.first { index in
            !peekCards[index].isHidden && peekCards[index].frame.contains(point)
                && !(index == 1 && peekCards[0].frame.contains(point))
        }
        setLifted(hit)
    }

    private func setLifted(_ index: Int?) {
        guard index != lifted else { return }
        lifted = index
        layoutPeeks(animated: true)
    }
}

/// The card window's content: tracks the pointer for the peeking cards, and lets clicks on its empty
/// margins fall through.
final class NextSentenceCardRoot: NextSentenceFlippedView {
    var onMouseMoved: ((NSPoint) -> Void)?
    var onMouseExited: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseMoved(with event: NSEvent) { onMouseMoved?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

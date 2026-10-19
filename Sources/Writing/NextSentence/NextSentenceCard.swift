import AppKit

/// The Next Sentence card: one message, written for them. A mood pad in the corner sets tone and
/// length; a handle at the end of the message stretches it.
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

    struct Content {
        /// Shown faintly in the text box while there's no message yet (or if it failed), and as the
        /// whole card for short notes.
        var status: String
        var busy = false
        var text = ""
        var marks: [Mark] = []
        /// Lowercased words that have other words to swap in.
        var streaming = false
        /// Cross-fade to the new text (a different reply, tone or length), rather than replace it.
        var fade = false
        var tone = 1
        var length = NextSentencePrompt.mediumLength
        var hint = ""
        /// "Insert into Messages. Hold to send.", for the Insert button's tooltip.
        var insertHelp = "Insert. Hold to send."
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
    var onMood: ((_ tone: Int, _ length: Int) -> Void)?
    var onFreshTake: (() -> Void)?
    var onMic: (() -> Void)?
    var wordOptions: (String) -> [String] = { _ in [] }
    var onWordPick: ((NSRange, String) -> Void)?
    var onWordRoll: ((NSRange, Int) -> Void)?
    /// The end handle. Start returns the whole message (before any words were cut); let go hands back
    /// the shorter message, or nil for "write a longer one".
    var onGripStart: (() -> String?)?
    var onGripEnd: ((_ kept: String?, _ whole: String) -> Void)?
    /// Nothing is selected any more: close the options.
    var onSelectionCleared: (() -> Void)?
    var onPickSelection: ((NSRange) -> Void)?

    static let margin: CGFloat = 14
    static let headroom: CGFloat = 130
    static let textHeight = NextSentenceCardStyle.lineHeight * NextSentenceCardStyle.textLines + 2
    static let fullHeight: CGFloat = textTop + textHeight + 10 + 28 + 12
    /// Where the text box starts. The mood pad sits in its top right corner and the text wraps around it.
    static let textTop: CGFloat = 16
    static let compactHeight: CGFloat = 38
    private var width: CGFloat { NextSentenceCardStyle.width }

    private let panel: NextSentencePanel
    private let root = NextSentenceCardRoot()
    private let front = NextSentenceFlippedView()
    private let ring = NextSentenceRing(frame: .zero)
    private let busyDot = NSView()
    private let statusLabel = NextSentenceCardStyle.label(NextSentenceCardStyle.titleFont, NextSentenceCardStyle.title)
    private let placeholder = NextSentenceCardStyle.label(NextSentenceCardStyle.bodyFont, NextSentenceCardStyle.faint)
    private let pad = NextSentenceMoodPad(frame: .zero)
    private let scroll = NSScrollView()
    let textView = NextSentenceTextView(width: NextSentenceCardStyle.width - 28)
    private let grip = NextSentenceLengthGrip(frame: .zero)
    private let gripHint = NextSentenceCardStyle.label(.systemFont(ofSize: 10.5, weight: .semibold), NextSentenceCardStyle.title)
    private let hintLabel = NextSentenceCardStyle.label(NextSentenceCardStyle.hintFont, NextSentenceCardStyle.faint)
    private let waveform = NextSentenceWaveform(frame: .zero)
    private let micButton = NextSentenceCapsuleButton(title: "", fill: NextSentenceCardStyle.buttonSubtle)
    private let remixButton = NextSentenceCapsuleButton(title: "", fill: NextSentenceCardStyle.buttonSubtle)
    private let insertButton = NextSentenceCapsuleButton(title: "Insert", fill: NextSentenceCardStyle.accent, wide: true)
    private let float = NextSentenceWordFloat(frame: .zero)
    private let tip = NextSentenceSourceTip(frame: .zero)
    private let buttonTip = NextSentenceSourceTip(frame: .zero)
    private let rollOverlay = NextSentenceCardStyle.label(NextSentenceCardStyle.bodyFont, NextSentenceCardStyle.body)

    private(set) var content = Content(status: "")
    private var anchor: CGRect = .zero
    private var shownSignature = ""
    private var insertHeldFull = false
    private var placedAbove = false
    private var padActive = false
    /// Bumped on every show, so a leave animation that finishes late can't hide the new card.
    private var shownCount = 0
    /// While the end handle is dragged: the whole message, how many words stay, and whether they've
    /// pulled past the end for a longer version.
    private var gripDrag: (whole: String, kept: Int, longer: Bool)?

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
        update(content)
        panel.alphaValue = 1
        shownCount += 1
        front.layer?.removeAnimation(forKey: "leave")
        panel.orderFrontRegardless()
        animateIn()
        if !content.compact { NextSentenceSounds.shared.play(.open) }
    }

    /// The card springs out of the text cursor: from its corner nearest the caret, a little small,
    /// settling with a soft overshoot, then a thin light runs once around its edge.
    private func animateIn() {
        guard let layer = front.layer else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.duration = 0.15
            layer.add(fade, forKey: "intro")
            return
        }
        // Grow from the corner by the caret: top left when the card sits below the line, bottom left above it.
        let corner = CGPoint(x: 0, y: placedAbove ? front.bounds.height : 0)
        let shrink = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-corner.x, -corner.y, 0), CATransform3DMakeScale(0.9, 0.9, 1)),
            CATransform3DMakeTranslation(corner.x, corner.y, 0))
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = shrink
        spring.toValue = CATransform3DIdentity
        spring.mass = 0.8
        spring.stiffness = 320
        spring.damping = 19
        spring.duration = spring.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(spring, forKey: "introScale")
        layer.add(fade, forKey: "introFade")
        ring.sweepOnce(color: NSColor(white: 1, alpha: 0.55))
    }

    /// `leaving` animates it away first: back toward the caret, or lifting off when it was sent.
    func hide(leaving: Bool = false, sending: Bool = false) {
        endEditing()
        closeFloats()
        ring.set(listening: false)
        waveform.set(animating: false)
        guard leaving, isVisible, let layer = front.layer else { return panel.orderOut(nil) }
        let shown = shownCount
        NextSentenceMotion.leave(layer, toward: CGPoint(x: 0, y: placedAbove ? front.bounds.height : 0), sending: sending) { [weak self] in
            guard let self, shown == self.shownCount else { return }
            self.panel.orderOut(nil)
            self.front.layer?.removeAnimation(forKey: "leave")
        }
    }

    func update(_ new: Content) {
        let wasListening = content.listening
        let previousLength = content.length
        content = new
        statusLabel.stringValue = new.status
        placeholder.stringValue = new.status
        busyDot.isHidden = !new.busy
        pad.set(tone: new.tone, length: new.length)
        hintLabel.stringValue = new.listening ? "" : new.hint
        let signature = "\(new.text)|\(new.streaming)|\(new.marks.map { "\($0.range)" })"
        if !isEditing && signature != shownSignature {
            if new.fade && !new.streaming { NextSentenceMotion.textChanged(textView.layer, direction: new.length - previousLength) }
            textView.textStorage?.setAttributedString(attributed(new))
            shownSignature = signature
            textView.scrollToBeginningOfDocument(nil)
            if optionsRange != nil { closeOptions() }
        }
        insertButton.set(title: insertHeldFull ? "Release to send" : "Insert", icon: nil)
        ring.set(listening: new.listening)
        if new.listening != wasListening { waveform.set(animating: new.listening) }
        glow()
        layout()
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
        if armed {
            NextSentenceCardStyle.tick()
            NextSentenceSounds.shared.play(.armed)
        }
        insertButton.set(title: armed ? "Release to send" : "Insert", icon: nil)
        layoutFoot()
    }

    // MARK: Options for a picked word or part

    /// The word or words picked, while their options float above them.
    private(set) var optionsRange: NSRange?

    /// Floats the options for the picked word or part above it, closest one nearest the text.
    /// Called when they pick it, and again after each swap.
    /// `rolled` is the scroll step that just swapped one in (0 for none), so the list slides the same way.
    func showOptions(for range: NSRange, rolled: Int = 0) {
        let text = textView.string as NSString
        guard NSMaxRange(range) <= text.length else { return closeOptions() }
        let options = Array(wordOptions(text.substring(with: range).lowercased()).prefix(3))
        guard !options.isEmpty else { return closeOptions() }
        if rolled != 0, !float.isHidden, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let slide = CATransition()
            slide.type = .push
            slide.subtype = rolled > 0 ? .fromBottom : .fromTop
            slide.duration = 0.12
            slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            float.layer?.add(slide, forKey: "roll")
        }
        placeOptions(options, for: range)
        float.onPick = { [weak self] option in self?.onWordPick?(range, option) }
    }

    /// A placeholder above the picked part while its options are written.
    func showOptionsLoading(for range: NSRange) {
        guard NSMaxRange(range) <= (textView.string as NSString).length else { return }
        placeOptions(["…"], for: range)
        float.onPick = { _ in }
    }

    private func placeOptions(_ options: [String], for range: NSRange) {
        optionsRange = range
        // The picked part stands out: bright blue behind white text.
        if isEditing { textView.setSelectedRange(range) }
        if let previous = optionsRange, previous != range, NSMaxRange(previous) <= (textView.string as NSString).length {
            clearHighlight(previous)
        }
        textView.layoutManager?.addTemporaryAttributes([.backgroundColor: NextSentenceCardStyle.accent.withAlphaComponent(0.7),
                                                        .foregroundColor: NSColor.white], forCharacterRange: range)
        let rect = textView.convert(textView.rect(for: range), to: root)
        float.show(options, above: rect, within: root.bounds.insetBy(dx: 6, dy: 0))
        float.isHidden = false
    }

    private func clearHighlight(_ range: NSRange) {
        textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
        textView.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
    }

    func closeOptions() {
        if let optionsRange, NSMaxRange(optionsRange) <= (textView.string as NSString).length {
            clearHighlight(optionsRange)
        }
        optionsRange = nil
        float.isHidden = true
    }

    /// Hovering only explains: a tinted phrase says where it came from.
    private func hover(_ hit: (NSRange, NSRect)?) {
        guard !isEditing, let (range, _) = hit,
              let mark = content.marks.first(where: { NSIntersectionRange($0.range, range).length > 0 }) else {
            tip.isHidden = true
            return
        }
        let phrase = textView.convert(textView.rect(for: mark.range), to: root)
        tip.show(heading: mark.heading, quote: mark.quote, above: phrase, within: root.bounds.insetBy(dx: 4, dy: 4))
        tip.isHidden = false
    }

    private func closeFloats() {
        closeOptions()
        tip.isHidden = true
        buttonTip.isHidden = true
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
        for mark in content.marks where NSMaxRange(mark.range) <= result.length {
            result.addAttribute(.foregroundColor, value: mark.color, range: mark.range)
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

    private func glow() {
        guard let layer = front.layer else { return }
        // Tone shows as a soft colored glow around the card, not a border: blue for direct, amber for warm,
        // none for casual. It brightens while the pad is dragged.
        let color = NextSentenceCardStyle.toneColors[content.tone]
        let neutral = content.tone == 1 || content.listening
        layer.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        layer.shadowColor = (neutral ? NSColor.black : color).cgColor
        layer.shadowOpacity = neutral ? 0.3 : (padActive ? 0.85 : 0.6)
        layer.shadowRadius = neutral ? 15 : (padActive ? 26 : 20)
        layer.shadowOffset = neutral ? CGSize(width: 0, height: -10) : .zero
    }

    private func build() {
        panel.contentView = root
        root.onMouseMoved = { [weak self] point in self?.rootMoved(point) }
        root.onMouseExited = { [weak self] in self?.textView.hover(at: nil) }
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
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        placeholder.maximumNumberOfLines = 2
        pad.onChange = { [weak self] tone, length in self?.onMood?(tone, length) }
        pad.onActive = { [weak self] active in
            guard let self else { return }
            self.padActive = active
            self.buttonTip.isHidden = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                self.glow()
            }
        }
        pad.onHover = { [weak self] inside in
            guard let self, !self.padActive else { return }
            self.showButtonTip(inside ? "Left: more direct. Right: warmer. Up: shorter. Down: longer." : nil, over: self.pad)
        }

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
        // Scrolling anywhere over the text rolls the picked word or part, once its options are there.
        textView.canRoll = { [weak self] in
            guard let self, let range = self.optionsRange,
                  NSMaxRange(range) <= (self.textView.string as NSString).length else { return false }
            return !self.wordOptions((self.textView.string as NSString).substring(with: range).lowercased()).isEmpty
        }
        textView.onRoll = { [weak self] step in
            guard let self, let range = self.optionsRange else { return }
            self.onWordRoll?(range, step)
        }
        textView.onSelectionCleared = { [weak self] in self?.onSelectionCleared?() }
        textView.addSubview(grip)
        grip.onHover = { [weak self] inside in
            guard let self, self.gripHint.isHidden else { return }
            self.showButtonTip(inside ? "Drag left to cut words. Drag right to make it longer." : nil, over: self.grip)
        }
        grip.onDragStart = { [weak self] in self?.gripBegan() }
        grip.onDrag = { [weak self] point in self?.gripMoved(to: point) }
        grip.onDragEnd = { [weak self] in self?.gripEnded() }
        gripHint.wantsLayer = true
        gripHint.drawsBackground = true
        gripHint.backgroundColor = NSColor(white: 0.11, alpha: 1)
        gripHint.alignment = .center
        gripHint.layer?.cornerRadius = 6
        gripHint.isHidden = true

        micButton.set(title: "", icon: NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Say a change"), color: NextSentenceCardStyle.title)
        micButton.onPress = { [weak self] in self?.onMic?() }
        remixButton.set(title: "", icon: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Remix the whole message"), color: NextSentenceCardStyle.title)
        // System tooltips don't show over another app's window, so the card draws its own.
        micButton.onHover = { [weak self] inside in self?.showButtonTip(inside ? "Say a change. Or tap fn." : nil, over: self?.micButton) }
        remixButton.onHover = { [weak self] inside in self?.showButtonTip(inside ? "Hold to remix the whole message" : nil, over: self?.remixButton) }
        insertButton.onHover = { [weak self] inside in self?.showButtonTip(inside ? self?.content.insertHelp : nil, over: self?.insertButton) }
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

        for view in [busyDot, statusLabel, scroll, placeholder, pad, hintLabel, waveform, micButton, remixButton, insertButton] as [NSView] {
            front.addSubview(view)
        }
        rollOverlay.isHidden = true
        textView.addSubview(rollOverlay)
        float.isHidden = true
        tip.isHidden = true
        root.addSubview(gripHint)
        root.addSubview(float)
        root.addSubview(tip)
        buttonTip.isHidden = true
        root.addSubview(buttonTip)
    }

    private func showButtonTip(_ text: String?, over button: NSView?) {
        guard let text, let button, !button.isHidden else { buttonTip.isHidden = true; return }
        let rect = button.convert(button.bounds, to: root)
        buttonTip.show(heading: text, quote: "", above: rect, within: root.bounds.insetBy(dx: 4, dy: 4))
        buttonTip.isHidden = false
    }

    /// The new word rolls in from above, where the options float, instead of just appearing.
    func animateWordIn(_ range: NSRange) {
        let text = textView.string as NSString
        guard NSMaxRange(range) <= text.length, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layoutManager = textView.layoutManager else { return }
        let rect = textView.rect(for: range)
        let attributes = textView.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? bodyAttributes
        rollOverlay.attributedStringValue = NSAttributedString(string: text.substring(with: range), attributes: attributes)
        let size = rollOverlay.intrinsicContentSize
        guard size.width <= rect.width + 6 else { return } // a part that wraps lines just appears
        let final = NSRect(x: rect.minX - 2, y: rect.minY + (rect.height - size.height) / 2, width: size.width + 4, height: size.height)
        rollOverlay.frame = final.offsetBy(dx: 0, dy: -9)
        rollOverlay.alphaValue = 0
        rollOverlay.isHidden = false
        layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: range)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.2)
            rollOverlay.animator().frame = final
            rollOverlay.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rollOverlay.isHidden = true
                if NSMaxRange(range) <= (self.textView.string as NSString).length {
                    self.textView.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
                }
            }
        })
    }

    // MARK: Layout

    private func layout() {
        let cardHeight = content.compact ? Self.compactHeight : Self.fullHeight
        let size = CGSize(width: width, height: cardHeight)
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let placement = NextSentencePolicy.place(card: size, under: anchor, in: visible)
        placedAbove = placement.above
        let m = Self.margin
        let frame = CGRect(x: placement.origin.x - m, y: placement.origin.y - m,
                           width: width + 2 * m, height: Self.headroom + cardHeight + m)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        root.frame = CGRect(origin: .zero, size: frame.size)
        front.frame = CGRect(x: m, y: Self.headroom, width: width, height: cardHeight)
        front.layer?.shadowPath = CGPath(roundedRect: front.bounds, cornerWidth: 16, cornerHeight: 16, transform: nil)
        ring.frame = front.frame.insetBy(dx: -3, dy: -3)
        layoutFront()
    }

    private func layoutFront() {
        let compact = content.compact
        for view in [pad, scroll, hintLabel, micButton, remixButton, insertButton] as [NSView] {
            view.isHidden = compact
        }
        // The status line only exists for short notes; otherwise status shows faintly in the text box.
        statusLabel.isHidden = !compact
        busyDot.isHidden = !compact || !content.busy
        let inset: CGFloat = 16
        let x: CGFloat = content.busy ? inset + 12 : inset
        busyDot.frame = NSRect(x: inset, y: 17, width: 6, height: 6)
        statusLabel.frame = NSRect(x: x, y: 12, width: width - inset - x, height: 16)
        pad.frame = NSRect(x: width - inset - NextSentenceMoodPad.size.width, y: 12, width: NextSentenceMoodPad.size.width,
                           height: NextSentenceMoodPad.size.height)
        placeholder.isHidden = compact || !content.text.isEmpty || isEditing
        placeholder.wantsLayer = true
        NextSentenceMotion.shimmer(placeholder, on: !placeholder.isHidden && content.busy)
        placeholder.frame = NSRect(x: inset, y: Self.textTop + 2, width: pad.frame.minX - inset - 12, height: 44)

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

    // MARK: The end handle

    /// Shows the whole message, with the words currently cut faded, so dragging back can bring them back.
    private func gripBegan() {
        buttonTip.isHidden = true
        closeOptions()
        let current = currentText
        let whole = onGripStart?() ?? current
        let kept = NextSentencePolicy.wordCount(current)
        textView.textStorage?.setAttributedString(NSAttributedString(string: whole, attributes: bodyAttributes))
        shownSignature = "grip"
        gripDrag = (whole, kept, false)
        showCut()
    }

    /// The end follows the pointer to the nearest word; past the end of the whole message means longer.
    private func gripMoved(to windowPoint: NSPoint) {
        guard var drag = gripDrag, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let point = textView.convert(windowPoint, from: nil)
        let inContainer = NSPoint(x: point.x - textView.textContainerOrigin.x, y: point.y - textView.textContainerOrigin.y)
        let length = (drag.whole as NSString).length
        let last = textView.rect(for: NSRange(location: max(0, length - 1), length: 1))
        let pastEnd = (point.y > last.maxY + 4) || (point.y >= last.minY - 4 && point.x > last.maxX + 28)
        let index = layoutManager.characterIndex(for: inContainer, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        let kept = pastEnd ? NextSentencePolicy.wordCount(drag.whole) : NextSentencePolicy.wordsKept(before: index, in: drag.whole)
        guard kept != drag.kept || pastEnd != drag.longer else { return }
        let total = max(1, NextSentencePolicy.wordCount(drag.whole))
        NextSentenceSounds.shared.play(pastEnd ? .armed : .trim(kept: Double(kept) / Double(total)))
        drag.kept = kept
        drag.longer = pastEnd
        gripDrag = drag
        NextSentenceCardStyle.tick()
        showCut()
    }

    private func gripEnded() {
        gripHint.isHidden = true
        guard let drag = gripDrag else { return }
        gripDrag = nil
        shownSignature = ""
        let total = NextSentencePolicy.wordCount(drag.whole)
        onGripEnd?(drag.longer ? nil : NextSentencePolicy.trimWords(drag.whole, dropping: total - drag.kept), drag.whole)
    }

    private func showCut() {
        guard let drag = gripDrag, let layoutManager = textView.layoutManager else { return }
        let ns = drag.whole as NSString
        let total = NextSentencePolicy.wordCount(drag.whole)
        let cutAt = (NextSentencePolicy.trimWords(drag.whole, dropping: total - drag.kept) as NSString).length
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: ns.length))
        if cutAt < ns.length {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor(white: 1, alpha: 0.2),
                                                forCharacterRange: NSRange(location: cutAt, length: ns.length - cutAt))
        }
        // The handle sits right after the last word kept.
        let end = textView.rect(for: NSRange(location: max(0, cutAt - 1), length: 1))
        let size = NextSentenceLengthGrip.size
        grip.frame = NSRect(x: end.maxX + 3, y: end.minY + (NextSentenceCardStyle.lineHeight - size.height) / 2, width: size.width, height: size.height)
        showGripHint(drag.longer ? "Let go for a longer version"
                     : drag.kept == total ? "All \(total) words · drag left to cut" : "\(drag.kept) of \(total) words")
    }

    func placeGrip() {
        guard gripDrag == nil else { return }
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

    private func showGripHint(_ text: String) {
        gripHint.stringValue = text
        gripHint.isHidden = text.isEmpty
        let gripInRoot = grip.convert(grip.bounds, to: root)
        let hintWidth = ceil(gripHint.intrinsicContentSize.width) + 14
        gripHint.frame = NSRect(x: gripInRoot.midX - hintWidth / 2, y: gripInRoot.minY - 22, width: hintWidth, height: 18)
    }

    private func layoutFoot() {
        let y = Self.textTop + Self.textHeight + 10
        let listening = content.listening && !content.compact
        let heard = content.heard != nil && !content.compact
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
            hintLabel.stringValue = "Listening. Tap fn again to finish."
        } else if let said = content.heard {
            hintX = 16
            hintLabel.stringValue = "“\(said)”"
        } else {
            hintX = 16
        }
        hintLabel.frame = NSRect(x: hintX, y: y + 7, width: max(0, right - hintX - 4), height: 15)
    }

    private func rootMoved(_ point: NSPoint) {
        let inText = !content.compact && !scroll.isHidden && scroll.convert(scroll.bounds, to: root).contains(point)
        textView.hover(at: inText ? textView.convert(point, from: root) : nil)
    }
}

/// The card window's content: tracks the pointer for word hovers, and lets clicks on its empty
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


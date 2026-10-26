import AppKit

/// The card's size and where it sits. The card is as tall as its message (two lines up to most of the
/// screen), so the whole message is always in view. Its top edge stays put and it grows and shrinks
/// downward, so the mood pad in its top corner never moves under the pointer and the bottom edge
/// follows a stretch drag.
extension NextSentenceCard {
    static let footHeight: CGFloat = 10 + 28 + 12
    static let minLines: CGFloat = 2

    /// The text box's height right now.
    var textBoxHeight: CGFloat {
        if let stretchHeight { return stretchHeight }
        let needed: CGFloat
        if !content.text.isEmpty {
            needed = textView.neededHeight
        } else if content.busy && !content.listening {
            needed = 3 * NextSentenceCardStyle.lineHeight // the skeleton's three lines
        } else {
            let bounds = NSRect(x: 0, y: 0, width: placeholderWidth, height: 2_000)
            needed = placeholder.cell?.cellSize(forBounds: bounds).height ?? 0
        }
        return boxHeight(fitting: needed)
    }

    /// The text box height for text that needs `needed` points: whole lines, within the card's limits.
    func boxHeight(fitting needed: CGFloat) -> CGFloat {
        let line = NextSentenceCardStyle.lineHeight
        let lines = min(maxLines, max(Self.minLines, ceil((needed - 1) / line)))
        return lines * line + 2
    }

    /// The most lines the card grows to before its message scrolls: about 60% of the screen's height.
    var maxLines: CGFloat {
        let room = screenFrame.height * 0.6 - Self.textTop - Self.footHeight
        return max(5, min(24, floor(room / NextSentenceCardStyle.lineHeight)))
    }

    var screenFrame: CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
    }

    var cardHeight: CGFloat { content.compact ? Self.compactHeight : Self.textTop + textBoxHeight + Self.footHeight }

    private var inset: CGFloat { 16 }
    private var placeholderWidth: CGFloat { width - 2 * inset - NextSentenceMoodPad.size.width - 12 }

    /// The text wraps at the card's width and around the mood pad, so its height can be measured.
    private func prepareTextBox() {
        textView.frame.size.width = width - 2 * inset
        let padOverlap = 12 + NextSentenceMoodPad.size.height - Self.textTop + 4
        textView.textContainer?.exclusionPaths = padOverlap > 0
            ? [NSBezierPath(rect: NSRect(x: width - 2 * inset - NextSentenceMoodPad.size.width - 8, y: 0, width: 90, height: padOverlap))] : []
    }

    /// Sizes and places the card. A visible card that changes height animates there unless `animated` is false.
    func layout(animated: Bool = true) {
        prepareTextBox()
        let height = cardHeight
        let visible = screenFrame
        if needsPlacement {
            // Under the caret if a five-line card fits there, otherwise above it; kept while it's open.
            placedAbove = NextSentencePolicy.place(card: CGSize(width: width, height: Self.fullHeight), under: anchor, in: visible).above
            // The top edge is set once. Above the caret it leaves room for a five-line card, so a usual
            // message ends above the caret; a longer one grows down past it.
            pinnedTop = placedAbove ? anchor.maxY + 6 + max(height, content.compact ? 0 : Self.fullHeight) : anchor.minY - 6
            needsPlacement = false
        }
        // Beside the caret, plus wherever they've moved it with the top tab, kept on screen. Only at the
        // screen's bottom edge does a growing card push its top up.
        let baseX = anchor.minX - 14, baseTop = pinnedTop
        let x = min(max(baseX + moveOffset.x, visible.minX + 4), visible.maxX - width - 4)
        let top = min(max(baseTop + moveOffset.y, visible.minY + 4 + height), visible.maxY - 4)
        // Pushed against the screen's edge, it stops there, so moving back answers at once. Only the top
        // and side edges are remembered: a push from the bottom lasts while the card is that tall, so a
        // card that shrinks again (or a stretch pulled back up) returns to its own top edge.
        moveOffset = CGPoint(x: x - baseX, y: min(baseTop + moveOffset.y, visible.maxY - 4) - baseTop)
        let y = top - height
        let card = CGRect(x: x, y: y, width: width, height: height)
        let m = Self.margin
        let exact = CGRect(x: card.minX - m, y: card.minY - m, width: width + 2 * m, height: Self.headroom + height + m)
        let shown = isVisible && front.frame.height > 0
        let before = shown ? CGRect(x: panel.frame.minX + front.frame.minX, y: panel.frame.maxY - front.frame.maxY,
                                    width: front.frame.width, height: front.frame.height) : card
        let animate = animated && shown && abs(before.height - height) > 0.5 && !NextSentenceMotion.reduced
        // While it animates, the window holds both the old and the new card.
        let frame = animate ? exact.union(panel.frame) : exact
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        root.frame = CGRect(origin: .zero, size: frame.size)
        func local(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        layoutGeneration += 1
        guard animate else {
            place(local(card), animated: false)
            layoutFront(animated: false)
            return
        }
        place(local(before), animated: false)
        let generation = layoutGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.resizeDuration
            context.timingFunction = Self.resizeCurve
            context.allowsImplicitAnimation = true
            place(local(card), animated: true)
            layoutFront(animated: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Settle the window to the card's exact size; nothing on screen moves.
                guard let self, generation == self.layoutGeneration else { return }
                self.layout(animated: false)
            }
        })
    }

    private static let resizeDuration = 0.28
    private static var resizeCurve: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1) }

    private func put(_ view: NSView, _ frame: NSRect, _ animated: Bool) {
        if animated { view.animator().frame = frame } else { view.frame = frame }
    }

    /// The card and everything drawn around it, at `rect` in the window.
    private func place(_ rect: CGRect, animated: Bool) {
        put(front, rect, animated)
        put(ring, rect.insetBy(dx: -3, dy: -3), animated)
        put(voiceGlow, rect.insetBy(dx: -NextSentenceVoiceGlow.reach, dy: -NextSentenceVoiceGlow.reach), animated)
        put(chargeRim, rect.insetBy(dx: -NextSentenceChargeRim.reach, dy: -NextSentenceChargeRim.reach), animated)
        let size = NextSentenceStretchBar.size
        put(stretchBar, CGRect(x: rect.midX - size.width / 2, y: rect.maxY - size.height / 2, width: size.width, height: size.height), animated)
        let tab = NextSentenceMoveTab.size
        put(moveTab, CGRect(x: rect.midX - tab.width / 2, y: rect.minY + 1, width: tab.width, height: tab.height), animated)
        guard let layer = front.layer else { return }
        let path = CGPath(roundedRect: CGRect(origin: .zero, size: rect.size), cornerWidth: 16, cornerHeight: 16, transform: nil)
        if animated {
            let reshape = CABasicAnimation(keyPath: "shadowPath")
            reshape.fromValue = layer.shadowPath
            reshape.toValue = path
            reshape.duration = Self.resizeDuration
            reshape.timingFunction = Self.resizeCurve
            layer.add(reshape, forKey: "shadowPath")
        }
        layer.shadowPath = path
    }

    private func layoutFront(animated: Bool) {
        let compact = content.compact
        for view in [pad, scroll, hintLabel, micButton, remixButton, insertButton] as [NSView] {
            view.isHidden = compact
        }
        // While it listens the edge glows, so the mood pad steps aside to keep the corner quiet.
        pad.isHidden = compact || content.listening
        // The status line only exists for short notes; otherwise status shows faintly in the text box.
        statusLabel.isHidden = !compact
        busyDot.isHidden = !compact || !content.busy
        let x: CGFloat = content.busy ? inset + 12 : inset
        busyDot.frame = NSRect(x: inset, y: 17, width: 6, height: 6)
        statusLabel.frame = NSRect(x: x, y: 12, width: width - inset - x, height: 16)
        pad.frame = NSRect(x: width - inset - NextSentenceMoodPad.size.width, y: 12, width: NextSentenceMoodPad.size.width,
                           height: NextSentenceMoodPad.size.height)
        // The text box only shows a status when something went wrong; waiting shows the aurora instead.
        placeholder.isHidden = compact || !content.text.isEmpty || isEditing || content.busy
        let box = textBoxHeight
        moveTab.isHidden = compact
        for backdrop in [glass, tint] { put(backdrop, NSRect(x: 0, y: 0, width: width, height: cardHeight), animated) }
        put(aurora, NSRect(x: 0, y: 0, width: width, height: cardHeight), animated)
        aurora.textFrame = NSRect(x: inset, y: Self.textTop, width: pad.frame.minX - inset - 14, height: box)
        put(placeholder, NSRect(x: inset, y: Self.textTop + 2, width: placeholderWidth, height: box), animated)
        put(scroll, NSRect(x: inset, y: Self.textTop, width: width - 2 * inset, height: box), animated)
        textView.isHidden = compact
        glideView.frame = textView.bounds
        stretchBar.isHidden = compact || content.streaming || content.text.isEmpty || content.listening || content.heard != nil
        layoutFoot(animated: animated)
    }

    func layoutFoot(animated: Bool = false) {
        let y = Self.textTop + textBoxHeight + 10
        let listening = content.listening && !content.compact
        let heard = content.heard != nil && !content.compact
        micButton.isHidden = content.compact || listening || heard || !content.showsButtons
        remixButton.isHidden = micButton.isHidden
        insertButton.isHidden = micButton.isHidden
        waveform.isHidden = true // the edge glow is the listening signal
        let waiting = aurora.active && !content.compact
        hintLabel.isHidden = content.compact || waiting
        statusLine.isHidden = !waiting
        put(statusLine, NSRect(x: 16, y: y + 5, width: width - 32, height: 18), animated)

        var right = width - 16
        for button in [insertButton, remixButton, micButton] where !button.isHidden {
            let buttonWidth = button.fittingWidth
            put(button, NSRect(x: right - buttonWidth, y: y, width: buttonWidth, height: 28), animated)
            right -= buttonWidth + 8
        }
        if listening {
            hintLabel.stringValue = content.hint.isEmpty ? "Listening. Tap \(NextSentencePreferences.hotkey().shortName) again to finish." : content.hint
        } else if let said = content.heard {
            hintLabel.stringValue = "“\(said)”"
        }
        put(hintLabel, NSRect(x: 16, y: y + 7, width: max(0, right - 20), height: 15), animated)
    }
}

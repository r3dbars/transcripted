import AppKit

/// A drag on the card's bottom edge: the whole message, where each sentence ends, how tall the text box
/// is for each number of sentences, and how far it's been pulled.
struct NextSentenceStretch {
    let whole: String
    let ends: [Int]
    let heights: [CGFloat]
    let startY: CGFloat
    let startBox: CGFloat
    var kept: Int
    var longer = false
}

/// Stretching the card: drag its bottom edge up and the message keeps fewer sentences (the card is
/// only as tall as what's kept), down to bring them back, and past the whole message for a longer one.
extension NextSentenceCard {
    func stretchBegan(at screenPoint: NSPoint) {
        buttonTip.isHidden = true
        closeOptions()
        if isEditing { onEndEditing?() }
        let whole = (onGripStart?() ?? currentText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty, let storage = textView.textStorage else { return }
        finishGlide()
        mark.reset()
        let ends = NextSentencePolicy.sentenceEnds(in: whole)
        // How tall the text box is with each number of sentences kept.
        let heights = ends.map { end -> CGFloat in
            storage.setAttributedString(NSAttributedString(string: (whole as NSString).substring(to: end), attributes: bodyAttributes))
            return boxHeight(fitting: textView.neededHeight)
        }
        storage.setAttributedString(NSAttributedString(string: whole, attributes: bodyAttributes))
        shownSignature = "stretch"
        let box = textBoxHeight
        stretchDrag = NextSentenceStretch(whole: whole, ends: ends, heights: heights, startY: screenPoint.y, startBox: box,
                                          kept: heights.lastIndex { $0 <= box + 0.5 }.map { $0 + 1 } ?? ends.count)
        stretchHeight = box
        showStretch()
    }

    func stretchMoved(to screenPoint: NSPoint) {
        guard var drag = stretchDrag, !drag.ends.isEmpty else { return }
        let line = NextSentenceCardStyle.lineHeight
        let full = drag.heights.last ?? drag.startBox
        // Screen y grows upward, so pulling the edge down makes the card taller.
        let box = min(max(drag.startBox + drag.startY - screenPoint.y, boxHeight(fitting: 0)), full + 3 * line, maxLines * line + 2)
        let longer = box > full + 1.4 * line
        let kept = drag.heights.lastIndex { $0 <= box + 0.5 }.map { $0 + 1 } ?? 1
        if kept != drag.kept || longer != drag.longer {
            NextSentenceSounds.shared.play(longer ? .armed : .trim(kept: Double(kept) / Double(drag.ends.count)))
            NextSentenceCardStyle.tick()
        }
        drag.kept = kept
        drag.longer = longer
        stretchDrag = drag
        stretchHeight = box
        showStretch()
        layout(animated: false)
    }

    func stretchEnded() {
        gripHint.isHidden = true
        guard let drag = stretchDrag else { return }
        stretchDrag = nil
        stretchHeight = nil
        textView.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (textView.string as NSString).length))
        shownSignature = ""
        let kept = drag.kept < drag.ends.count ? (drag.whole as NSString).substring(to: drag.ends[max(0, drag.kept - 1)]) : drag.whole
        onGripEnd?(drag.longer ? nil : kept, drag.whole)
        layout()
    }

    /// Sentences past the kept ones are hidden (not just dimmed), so the card reads as the shorter message.
    private func showStretch() {
        guard let drag = stretchDrag, let layoutManager = textView.layoutManager else { return }
        let length = (drag.whole as NSString).length
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
        let cutAt = drag.longer || drag.kept >= drag.ends.count ? length : drag.ends[max(0, drag.kept - 1)]
        if cutAt < length {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: NSRange(location: cutAt, length: length - cutAt))
        }
        let count = drag.ends.count
        showGripHint(drag.longer ? "Let go for a longer version"
                     : count == 1 ? "Pull down for a longer version"
                     : "\(drag.kept) of \(count) sentences")
    }

    /// A small label just under the bottom edge's handle.
    func showGripHint(_ text: String) {
        gripHint.stringValue = text
        gripHint.isHidden = text.isEmpty
        let bar = stretchBar.frame
        let hintWidth = ceil(gripHint.intrinsicContentSize.width) + 14
        gripHint.frame = NSRect(x: bar.midX - hintWidth / 2, y: bar.maxY + 1, width: hintWidth, height: 18)
    }
}

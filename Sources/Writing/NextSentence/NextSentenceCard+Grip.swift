import AppKit

/// The end handle: drag it to cut words off the end (they fade, and dissolve to dust as they go),
/// drag back to bring them back, or past the end for a longer version.
extension NextSentenceCard {
    /// Shows the whole message, with the words currently cut faded, so dragging back can bring them back.
    func gripBegan() {
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
    func gripMoved(to windowPoint: NSPoint) {
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
        if kept < drag.kept { dust(words: kept..<drag.kept, of: drag.whole) }
        drag.kept = kept
        drag.longer = pastEnd
        gripDrag = drag
        NextSentenceCardStyle.tick()
        showCut()
    }

    func gripEnded() {
        gripHint.isHidden = true
        guard let drag = gripDrag else { return }
        gripDrag = nil
        shownSignature = ""
        let total = NextSentencePolicy.wordCount(drag.whole)
        onGripEnd?(drag.longer ? nil : NextSentencePolicy.trimWords(drag.whole, dropping: total - drag.kept), drag.whole)
    }

    func showCut() {
        guard let drag = gripDrag, let layoutManager = textView.layoutManager else { return }
        let ns = drag.whole as NSString
        let total = NextSentencePolicy.wordCount(drag.whole)
        let cutAt = (NextSentencePolicy.trimWords(drag.whole, dropping: total - drag.kept) as NSString).length
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: ns.length))
        if cutAt < ns.length {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor(white: 1, alpha: 0.14),
                                                forCharacterRange: NSRange(location: cutAt, length: ns.length - cutAt))
        }
        // The handle sits right after the last word kept.
        let end = textView.rect(for: NSRange(location: max(0, cutAt - 1), length: 1))
        let size = NextSentenceLengthGrip.size
        grip.frame = NSRect(x: end.maxX + 3, y: end.minY + (NextSentenceCardStyle.lineHeight - size.height) / 2, width: size.width, height: size.height)
        showGripHint(drag.longer ? "Let go for a longer version"
                     : drag.kept == total ? "All \(total) words · drag left to cut" : "\(drag.kept) of \(total) words")
    }

    /// Words just cut dissolve into dust (their faint ghosts stay, so dragging back restores them).
    func dust(words: Range<Int>, of whole: String) {
        let ns = whole as NSString
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, range, _, _ in ranges.append(range) }
        let rects = words.filter { ranges.indices.contains($0) }.map { textView.convert(textView.rect(for: ranges[$0]), to: front) }
        NextSentenceDust.burst(in: front, rects: rects, color: NextSentenceCardStyle.body)
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

    func showGripHint(_ text: String) {
        gripHint.stringValue = text
        gripHint.isHidden = text.isEmpty
        let gripInRoot = grip.convert(grip.bounds, to: root)
        let hintWidth = ceil(gripHint.intrinsicContentSize.width) + 14
        gripHint.frame = NSRect(x: gripInRoot.midX - hintWidth / 2, y: gripInRoot.minY - 22, width: hintWidth, height: 18)
    }

}

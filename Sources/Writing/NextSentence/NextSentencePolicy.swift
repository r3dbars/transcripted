import CoreGraphics
import Foundation

/// Where the card goes and what each key does while it's open. Pure, so tests pin them.
enum NextSentencePolicy {
    // MARK: Placement

    struct Placement: Equatable {
        let origin: CGPoint
        let above: Bool
    }

    /// Converts an Accessibility rect (top-left origin, y down) into Cocoa screen coordinates
    /// (bottom-left origin, y up), given the primary screen's height.
    static func cocoaRect(fromAccessibility rect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenMaxY - rect.minY - rect.height, width: rect.width, height: rect.height)
    }

    /// Just below the line being typed, its left edge lined up with the cursor. If there's no room
    /// below, just above the line, so it never covers what's being written. Kept on screen.
    static func place(card size: CGSize, under caret: CGRect, in visible: CGRect, gap: CGFloat = 6) -> Placement {
        var origin = CGPoint(x: caret.minX - 14, y: caret.minY - size.height - gap)
        let above = origin.y < visible.minY
        if above { origin.y = caret.maxY + gap }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        return Placement(origin: origin, above: above)
    }

    // MARK: Keys while the card is open

    /// Same axes as the mood pad: ↑ shorter, ↓ longer, ← more direct, → warmer. Tab moves between replies.
    enum KeyAction: Equatable {
        case nextReply, previousReply, shorter, longer, moreDirect, warmer, edit, close
        /// Return went down. A tap inserts; held past `holdToSend` it inserts and sends.
        case returnDown
        case returnUp
        /// Any other key: start editing the card's text with it, so they can just type into the card.
        case typeIntoCard
        /// Auto-repeated Return while it's held to send: swallowed, so the app never gets newlines.
        case ignore
        /// Shortcuts with ⌘, ⌃ or ⌥: leave them alone entirely.
        case passThrough
    }

    enum KeyCode {
        static let tab: Int64 = 48
        static let returnKey: Int64 = 36
        static let keypadEnter: Int64 = 76
        static let escape: Int64 = 53
        static let left: Int64 = 123
        static let right: Int64 = 124
        static let down: Int64 = 125
        static let up: Int64 = 126
        static let slash: Int64 = 44
        static let delete: Int64 = 51
        static let fn: Int64 = 63
    }

    static func isReturn(_ keyCode: Int64) -> Bool { keyCode == KeyCode.returnKey || keyCode == KeyCode.keypadEnter }

    static func action(keyCode: Int64, command: Bool, control: Bool, option: Bool, shift: Bool, isRepeat: Bool = false) -> KeyAction {
        if command || control || option { return .passThrough }
        switch keyCode {
        case KeyCode.tab: return shift ? .previousReply : .nextReply
        case KeyCode.up: return .shorter
        case KeyCode.down: return .longer
        case KeyCode.left: return .moreDirect
        case KeyCode.right: return .warmer
        case KeyCode.slash: return .edit
        case KeyCode.returnKey, KeyCode.keypadEnter: return isRepeat ? .ignore : .returnDown
        case KeyCode.escape: return .close
        default: return .typeIntoCard
        }
    }

    /// The open card's key tap leaves Write for Me's own key alone when it's a function key, so its tap
    /// still sees it: tapping it starts and finishes listening, and holding it auto-repeats. (A modifier
    /// key never reaches the card's tap, and a combination like ⌥D already passes through for its ⌥.)
    static func cardPassesThrough(keyCode: Int64, hotkey: NextSentenceHotkey) -> Bool {
        !hotkey.isModifier && !hotkey.isCombination && keyCode == hotkey.keyCode
    }

    /// Key-up only matters for Return, which decides between insert and send.
    static func releaseAction(keyCode: Int64) -> KeyAction {
        isReturn(keyCode) ? .returnUp : .passThrough
    }

    /// Whether the tap swallows the key (the app never sees it).
    static func consumes(_ action: KeyAction) -> Bool {
        action != .passThrough
    }

    // MARK: The fn key

    /// A quick press of fn on its own, not fn held as a modifier for another key.
    static let fnTapLimit: TimeInterval = 0.4

    static func isFnTap(heldFor seconds: TimeInterval, withOtherKey: Bool) -> Bool {
        !withOtherKey && seconds < fnTapLimit
    }

    // MARK: Holds and drags

    /// Hold Return or Insert this long and it sends, not just inserts.
    static let holdToSend: TimeInterval = 0.7
    /// After typing, how long the first Esc waits for a second one to close the card.
    static let escapeConfirmWindow: TimeInterval = 1.5
    /// How often the meaning index looks for new captures while it's on (only new passages are embedded).
    static let indexRefreshInterval: TimeInterval = 120
    /// After the embedding server fails to start, how long before it's tried again.
    static let embeddingRetryInterval: TimeInterval = 600

    static func mayLaunchEmbeddingServer(lastFailure: Date?, now: Date) -> Bool {
        guard let lastFailure else { return true }
        return now.timeIntervalSince(lastFailure) >= embeddingRetryInterval
    }
    /// Hold the remix button this long for a fresh take.
    static let holdToRemix: TimeInterval = 0.65

    static func holdProgress(heldFor seconds: TimeInterval, needed: TimeInterval) -> Double {
        min(1, max(0, seconds / needed))
    }

    static let lengthCount = 5
    static let toneCount = 3

    /// ← → step the tone along the pad (direct, casual, warm) and stop at the ends.
    static func stepTone(_ index: Int, by step: Int) -> Int { min(toneCount - 1, max(0, index + step)) }
    static func stepLength(_ length: Int, by step: Int) -> Int { min(lengthCount - 1, max(0, length + step)) }

    /// The mood pad: x is tone (three columns, direct to warm), y is length (five rows, Tiny at the top).
    /// `point` is in the pad's own coordinates with y down.
    static func padCell(at point: CGPoint, size: CGSize) -> (tone: Int, length: Int) {
        let fx = min(0.999, max(0, point.x / max(1, size.width)))
        let fy = min(0.999, max(0, point.y / max(1, size.height)))
        return (Int(fx * Double(toneCount)), Int(fy * Double(lengthCount)))
    }

    /// The center of a pad cell, where the dot rests.
    static func padCenter(tone: Int, length: Int, size: CGSize) -> CGPoint {
        CGPoint(x: (CGFloat(tone) + 0.5) / CGFloat(toneCount) * size.width,
                y: (CGFloat(length) + 0.5) / CGFloat(lengthCount) * size.height)
    }

    // MARK: The end handle

    /// How many words to keep when the end of the message is dragged to character `index`: every word
    /// that starts before it. At least one word always stays.
    static func wordsKept(before index: Int, in text: String) -> Int {
        let ns = text as NSString
        var kept = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, range, _, stop in
            if range.location < index { kept += 1 } else { stop.pointee = true }
        }
        return max(1, kept)
    }

    static func wordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    /// `text` without its last `count` words, and without a comma or dash left dangling at the end.
    static func trimWords(_ text: String, dropping count: Int) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard count > 0, !words.isEmpty else { return text }
        var result = words.dropLast(min(count, words.count - 1)).joined(separator: " ")
        while let last = result.last, ",;:—–-".contains(last) { result.removeLast() }
        return result
    }


    // MARK: Changing versions and length

    /// The words of `text`, in order.
    static func wordRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, range, _, _ in ranges.append(range) }
        return ranges
    }

    /// Words that are the same in both versions, in the same order (case aside): each pair's range in
    /// `old` and in `new`. These glide to their new place; the rest of `new` is new. Pure, so tests pin it.
    static func matchedWords(from old: String, to new: String) -> [(old: NSRange, new: NSRange)] {
        let oldRanges = wordRanges(in: old), newRanges = wordRanges(in: new)
        let a = oldRanges.map { (old as NSString).substring(with: $0).lowercased() }
        let b = newRanges.map { (new as NSString).substring(with: $0).lowercased() }
        guard !a.isEmpty, !b.isEmpty else { return [] }
        // Longest common subsequence, filled from the end so the walk below reads front to back.
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(old: NSRange, new: NSRange)] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                pairs.append((oldRanges[i], newRanges[j]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    /// Where each sentence of `text` ends (after its punctuation), in order. The last is the end of the text.
    static func sentenceEnds(in text: String) -> [Int] {
        let ns = text as NSString
        var ends: [Int] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            var end = NSMaxRange(range)
            while end > range.location, let scalar = Unicode.Scalar(ns.character(at: end - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(scalar) { end -= 1 }
            if end > range.location { ends.append(end) }
        }
        return ends
    }
}

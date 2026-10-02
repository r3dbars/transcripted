// NotchIslandLiveTranscriptView.swift
// The recording drop-down's live transcript: the whole conversation so far,
// scrolled to the newest words, with the words still being heard faded at
// the end. Kept alive by the island controller across drop-down rebuilds so
// the scroll position survives, and updated in place: finished words are
// only ever appended, and only the faded tail is replaced, so an hour-long
// call costs the same per update as a one-minute one.

import AppKit

@MainActor
final class NotchIslandLiveTranscriptView: NSView {
    static let height: CGFloat = 196

    private let scrollView = NSScrollView()
    private let textView: NSTextView
    private let placeholder: NSTextField

    private var renderedLineCount = 0
    /// Characters of the last committed line already on screen.
    private var renderedLastLineCount = 0
    private var renderedTrimGeneration = 0
    /// The faded words at the end, replaced on every update.
    private var tentativeLength = 0

    private static let font = NSFont.systemFont(ofSize: 12.5)
    private static let labelFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private static let youColor = NSColor(srgbRed: 0.52, green: 0.72, blue: 0.92, alpha: 1)
    private static let themColor = NSColor(white: 1, alpha: 0.72)
    private static let committedColor = NSColor(white: 1, alpha: 0.9)
    private static let tentativeColor = NSColor(white: 1, alpha: 0.42)
    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 5
        return style
    }()

    init(width: CGFloat) {
        let size = NSSize(width: width, height: Self.height)
        textView = NSTextView(frame: NSRect(origin: .zero, size: size))
        placeholder = NotchIslandPalette.label("", font: .systemFont(ofSize: 12.5), color: NotchIslandPalette.secondaryText, wraps: true, width: width)
        super.init(frame: NSRect(origin: .zero, size: size))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.isRichText = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("Live transcript")

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)

        placeholder.frame = NSRect(x: 0, y: Self.height - 40, width: width, height: 34)
        placeholder.autoresizingMask = [.minYMargin]
        addSubview(placeholder)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Live transcript")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(_ log: LiveMeetingCaptionLog, status: LiveMeetingCaptions.Status) {
        placeholder.stringValue = Self.placeholderText(status)
        placeholder.isHidden = !log.isEmpty
        guard let storage = textView.textStorage else { return }
        let followsNewest = isScrolledToBottom

        storage.beginEditing()
        if tentativeLength > 0 {
            storage.deleteCharacters(in: NSRange(location: storage.length - tentativeLength, length: tentativeLength))
            tentativeLength = 0
        }
        let lines = log.lines
        let stale = log.trimGeneration != renderedTrimGeneration
            || lines.count < renderedLineCount
            || (renderedLineCount > 0 && lines.count >= renderedLineCount
                && lines[renderedLineCount - 1].text.count < renderedLastLineCount)
        if stale {
            storage.setAttributedString(NSAttributedString())
            renderedLineCount = 0
            renderedLastLineCount = 0
            renderedTrimGeneration = log.trimGeneration
        }
        if renderedLineCount > 0 {
            let last = lines[renderedLineCount - 1].text
            if last.count > renderedLastLineCount {
                storage.append(Self.words(String(last.dropFirst(renderedLastLineCount)), color: Self.committedColor))
            }
        }
        for index in renderedLineCount..<lines.count {
            storage.append(Self.turn(lines[index].track, lines[index].text, color: Self.committedColor, newParagraph: storage.length > 0))
        }
        renderedLineCount = lines.count
        renderedLastLineCount = lines.last?.text.count ?? 0

        let before = storage.length
        for track in LiveMeetingTrack.allCases {
            guard let pending = log.tentative[track] else { continue }
            if storage.length == before, lines.last?.track == track {
                storage.append(Self.words(" " + pending, color: Self.tentativeColor))
            } else {
                storage.append(Self.turn(track, pending, color: Self.tentativeColor, newParagraph: storage.length > 0))
            }
        }
        tentativeLength = storage.length - before
        storage.endEditing()

        if followsNewest { scrollToNewest() }
    }

    /// Opening the drop-down shows the newest words.
    func scrollToNewest() {
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.scrollToEndOfDocument(nil)
    }

    private var isScrolledToBottom: Bool {
        let visible = scrollView.contentView.documentVisibleRect
        return visible.maxY >= textView.frame.height - 12
    }

    private static func placeholderText(_ status: LiveMeetingCaptions.Status) -> String {
        switch status {
        case .preparing: return "Getting the live transcript ready…"
        case .listening: return "Listening… words show up here as people talk."
        case .unavailable: return "The live transcript couldn't start. The meeting is still recording."
        case .off: return "Live transcript is off."
        }
    }

    private static func turn(_ track: LiveMeetingTrack, _ text: String, color: NSColor, newParagraph: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if newParagraph { result.append(words("\n", color: color)) }
        result.append(NSAttributedString(string: LiveMeetingCaptionLog.label(track) + "  ", attributes: [
            .font: labelFont,
            .foregroundColor: track == .microphone ? youColor : themColor,
            .paragraphStyle: paragraph,
        ]))
        result.append(words(text, color: color))
        return result
    }

    private static func words(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
}

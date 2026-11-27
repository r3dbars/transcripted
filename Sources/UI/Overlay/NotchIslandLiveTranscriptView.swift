// NotchIslandLiveTranscriptView.swift
// The recording drop-down's live transcript: the whole conversation so far,
// scrolled to the newest words, with the words still being heard faded at
// the end. Kept alive by the island controller across drop-down rebuilds so
// the scroll position survives, and updated in place: finished words are
// only ever appended, and only the faded tail is replaced, so an hour-long
// call costs the same per update as a one-minute one.
//
// Ultra-quiet editorial look: no card or border on the black island, a tiny
// tracked YOU / OTHERS header over each turn, and a soft fade at the top so
// older words melt into the notch.

import AppKit
import QuartzCore

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

    private static let font = NSFont.systemFont(ofSize: 13)
    private static let headerFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    /// Your header is the live green, softened; the others' a muted white.
    private static let youColor = DesignTokens.NS.liveOnDark.withAlphaComponent(0.78)
    private static let othersColor = NSColor(white: 1, alpha: 0.34)
    private static let committedColor = NSColor(white: 1, alpha: 0.9)
    /// Words the decoder is still hearing: faint, so they read as a draft.
    private static let tentativeColor = NSColor(white: 1, alpha: 0.34)
    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2.5
        return style
    }()
    private static let headerParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 3
        return style
    }()
    private static let laterHeaderParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 12
        style.paragraphSpacing = 3
        return style
    }()
    /// How far down the top fade reaches once older words scroll past the top.
    private static let fadeHeight: CGFloat = 22
    private let fadeMask = CAGradientLayer()
    private var clipBoundsObserver: NSObjectProtocol?

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

        scrollView.contentView.postsBoundsChangedNotifications = true
        clipBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateFade() }
        }

        placeholder.frame = NSRect(x: 0, y: Self.height - 40, width: width, height: 34)
        placeholder.autoresizingMask = [.minYMargin]
        addSubview(placeholder)

        // Apple Music lyrics style: gentle top fade only once older words scroll off the top.
        wantsLayer = true
        fadeMask.colors = [
            NSColor(white: 0, alpha: 0.22).cgColor,
            NSColor.black.cgColor,
            NSColor.black.cgColor,
        ]
        fadeMask.startPoint = CGPoint(x: 0.5, y: 1) // layer y-up: top
        fadeMask.endPoint = CGPoint(x: 0.5, y: 0)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Live transcript")
    }

    deinit {
        if let clipBoundsObserver {
            NotificationCenter.default.removeObserver(clipBoundsObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        fadeMask.frame = bounds
        let fade = NSNumber(value: Double(min(0.25, Self.fadeHeight / max(1, bounds.height))))
        fadeMask.locations = [0, fade, 1]
        updateFade()
    }

    /// The fade only shows once older words have actually scrolled past the
    /// top edge, so the beginning of a meeting is always 100% crisp.
    private func updateFade() {
        guard let container = textView.textContainer, let layoutManager = textView.layoutManager else { return }
        layoutManager.ensureLayout(for: container)
        let usedHeight = layoutManager.usedRect(for: container).height
        let scrolledPastTop = scrollView.contentView.documentVisibleRect.minY > 2
        let shouldFade = usedHeight > bounds.height - 2 && scrolledPastTop
        let mask: CALayer? = shouldFade ? fadeMask : nil
        if layer?.mask !== mask { layer?.mask = mask }
    }

    /// The newest state while the drop-down is closed and the last catch-up
    /// was under 5 s ago. Updates are incremental, so applying only the
    /// latest one draws the same text as applying every one in between.
    private var pending: (log: LiveMeetingCaptionLog, status: LiveMeetingCaptions.Status)?
    /// The clock the hidden catch-up is gated on. The flush rule is tested
    /// through `NotchIslandPresentation.flushesHiddenTranscript`.
    private let now: () -> CFTimeInterval = CACurrentMediaTime
    private var lastHiddenFlush: CFTimeInterval?

    func apply(_ log: LiveMeetingCaptionLog, status: LiveMeetingCaptions.Status) {
        // Off screen: catch up at most every 5 s, so opening never has to
        // lay out a long backlog in the hover turn.
        guard window != nil || flushesWhileHidden(log) else {
            pending = (log, status)
            return
        }
        pending = nil
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
        updateFade()

        if followsNewest {
            scrollToNewest()
        } else if window == nil, let container = textView.textContainer {
            // Scrolled up before it closed: still lay out now, without moving.
            textView.layoutManager?.ensureLayout(for: container)
        }
    }

    private func flushesWhileHidden(_ log: LiveMeetingCaptionLog) -> Bool {
        let time = now()
        guard NotchIslandPresentation.flushesHiddenTranscript(
            now: time,
            lastFlush: lastHiddenFlush,
            trimGeneration: log.trimGeneration,
            renderedTrimGeneration: renderedTrimGeneration
        ) else { return false }
        lastHiddenFlush = time
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let pending {
            apply(pending.log, status: pending.status)
        }
    }

    /// Opening the drop-down shows the newest words.
    func scrollToNewest() {
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        textView.scrollToEndOfDocument(nil)
        updateFade()
    }

    private var isScrolledToBottom: Bool {
        let visible = scrollView.contentView.documentVisibleRect
        return visible.maxY >= textView.frame.height - 12
    }

    private static func placeholderText(_ status: LiveMeetingCaptions.Status) -> String {
        switch status {
        case .preparing: return "Getting the live transcript ready…"
        case .listening: return "Words show up here as people talk."
        case .unavailable: return "The live transcript couldn't start. The meeting is still recording."
        case .off: return "Live transcript is off."
        }
    }

    /// A turn: its tiny tracked header on its own line, then the words.
    private static func turn(_ track: LiveMeetingTrack, _ text: String, color: NSColor, newParagraph: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        if newParagraph { result.append(words("\n", color: color)) }
        result.append(NSAttributedString(string: LiveMeetingCaptionLog.label(track).uppercased() + "\n", attributes: [
            .font: headerFont,
            .kern: 1.1,
            .foregroundColor: track == .microphone ? youColor : othersColor,
            .paragraphStyle: newParagraph ? laterHeaderParagraph : headerParagraph,
        ]))
        result.append(words(text, color: color))
        return result
    }

    private static func words(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
}

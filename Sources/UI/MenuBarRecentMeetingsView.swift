// MenuBarRecentMeetingsView.swift
// Compact recent meetings list for the menubar popover.

import AppKit
import Foundation

struct RecentMeetingItem {
    let title: String
    let date: Date
    let transcriptURL: URL
}

@MainActor
enum RecentMeetingsScanner {
    static func loadRecent(limit: Int = 3) -> [RecentMeetingItem] {
        let dir = MeetingStoragePaths.transcriptsFolder
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }

        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let markdowns = urls.filter { $0.pathExtension == "md" }
        let items: [(url: URL, date: Date)] = markdowns.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let date = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            return (url, date)
        }

        return Array(
            items
                .sorted(by: { $0.date > $1.date })
                .prefix(limit)
                .map { entry in
                    let styled = MeetingTranscriptStyler.restyleTranscript(at: entry.url)
                    return RecentMeetingItem(title: styled.title, date: entry.date, transcriptURL: styled.url)
                }
        )
    }
}

@MainActor
final class MenuBarRecentMeetingsView: NSView {
    private let headerLabel = NSTextField(labelWithString: "Recent meetings")
    private let emptyLabel = NSTextField(labelWithString: "No meetings yet.")
    private let listContainer = FlippedRecentMeetingsContainer()

    private var rowViews: [NSView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func setupViews() {
        headerLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        headerLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(headerLabel)

        emptyLabel.font = NSFont.systemFont(ofSize: 11)
        emptyLabel.textColor = MenuTokens.textMutedNS
        addSubview(emptyLabel)

        addSubview(listContainer)
    }

    override func layout() {
        super.layout()

        headerLabel.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 16)
        let listY: CGFloat = 24

        if rowViews.isEmpty {
            emptyLabel.isHidden = false
            listContainer.isHidden = true
            emptyLabel.frame = NSRect(x: 0, y: listY, width: bounds.width, height: 14)
            return
        }

        emptyLabel.isHidden = true
        listContainer.isHidden = false

        var y: CGFloat = 0
        for row in rowViews {
            let rowHeight = row.intrinsicContentSize.height
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            y += rowHeight
        }

        listContainer.frame = NSRect(x: 0, y: listY, width: bounds.width, height: y)
    }

    func update(
        meetings: [RecentMeetingItem],
        failedMeetings: [MeetingSessionController.FailedMeetingItem],
        onRetryFailedMeeting: @escaping (UUID) -> Void,
        onDismissFailedMeeting: @escaping (UUID) -> Void
    ) {
        listContainer.subviews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()

        for failed in failedMeetings {
            let row = FailedMeetingRowView(
                item: failed,
                onRetry: { onRetryFailedMeeting(failed.id) },
                onDismiss: { onDismissFailedMeeting(failed.id) }
            )
            listContainer.addSubview(row)
            rowViews.append(row)
        }

        for (index, item) in meetings.enumerated() {
            let row = RecentMeetingRowView(item: item, showsDivider: index < meetings.count - 1)
            listContainer.addSubview(row)
            rowViews.append(row)
        }

        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    var intrinsicHeight: CGFloat {
        let contentHeight = rowViews.reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.height }
        if rowViews.isEmpty { return 40 }
        return 24 + contentHeight
    }
}

private final class FlippedRecentMeetingsContainer: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class RecentMeetingRowView: NSView {
    private let item: RecentMeetingItem
    private let titleLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let moreButton = NSButton(title: "⋯", target: nil, action: nil)
    private let divider = NSView()
    private let showsDivider: Bool
    private var trackingAreaRef: NSTrackingArea?
    private var resetTask: Task<Void, Never>?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MMM d 'at' h:mm a"
        return formatter
    }()

    init(item: RecentMeetingItem, showsDivider: Bool) {
        self.item = item
        self.showsDivider = showsDivider
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    deinit {
        resetTask?.cancel()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.clear.cgColor

        titleLabel.stringValue = item.title
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        dateLabel.stringValue = Self.dateFormatter.string(from: item.date)
        dateLabel.font = NSFont.systemFont(ofSize: 9)
        dateLabel.textColor = MenuTokens.textSecondaryNS
        addSubview(dateLabel)

        moreButton.isBordered = false
        moreButton.bezelStyle = .inline
        moreButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        moreButton.contentTintColor = MenuTokens.textSecondaryNS
        moreButton.target = self
        moreButton.action = #selector(showMenu)
        addSubview(moreButton)

        divider.wantsLayer = true
        divider.layer?.backgroundColor = MenuTokens.sectionDividerNS.cgColor
        divider.isHidden = !showsDivider
        addSubview(divider)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = MenuTokens.recentHoverNS.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !moreButton.frame.contains(point) else {
            super.mouseDown(with: event)
            return
        }
        NSWorkspace.shared.open(item.transcriptURL)
    }

    override func layout() {
        super.layout()
        let moreWidth = max(24, moreButton.fittingSize.width + 8)
        moreButton.frame = NSRect(x: bounds.width - moreWidth, y: 8, width: moreWidth, height: 24)
        let textWidth = bounds.width - moreButton.frame.width - 12
        titleLabel.frame = NSRect(x: 0, y: 6, width: textWidth, height: 14)
        dateLabel.frame = NSRect(x: 0, y: 21, width: textWidth, height: 12)
        divider.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: MenuTokens.recentRowHeight)
    }

    @objc private func showMenu() {
        let menu = NSMenu()
        let copyItem = menu.addItem(withTitle: "Copy transcript", action: #selector(copyTranscript), keyEquivalent: "")
        copyItem.target = self
        let connectItem = menu.addItem(withTitle: "Connect your agent", action: #selector(connectAgent), keyEquivalent: "")
        connectItem.target = self
        let revealItem = menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder), keyEquivalent: "")
        revealItem.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: moreButton.frame.minX, y: moreButton.frame.maxY), in: self)
    }

    @objc private func copyTranscript() {
        guard let text = MeetingTranscriptStyler.transcriptBody(at: item.transcriptURL) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        resetTask?.cancel()
        moreButton.title = "Copied"
        needsLayout = true
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.moreButton.title = "⋯"
            self.needsLayout = true
        }
    }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([item.transcriptURL])
    }

    @objc private func connectAgent() {
        AgentConnectionWindowCoordinator.shared.show(for: item)
    }
}

@MainActor
private final class FailedMeetingRowView: NSView {
    private let item: MeetingSessionController.FailedMeetingItem
    private let onRetry: () -> Void
    private let onDismiss: () -> Void

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)

    init(item: MeetingSessionController.FailedMeetingItem, onRetry: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.item = item
        self.onRetry = onRetry
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = MenuTokens.failedBackgroundNS.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = MenuTokens.failedBorderNS.cgColor

        titleLabel.stringValue = item.title
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)

        subtitleLabel.stringValue = item.subtitle
        subtitleLabel.font = NSFont.systemFont(ofSize: 9)
        subtitleLabel.textColor = MenuTokens.textSecondaryNS
        addSubview(subtitleLabel)

        retryButton.isBordered = false
        retryButton.bezelStyle = .inline
        retryButton.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        retryButton.contentTintColor = MenuTokens.textPrimaryNS
        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.isEnabled = item.isRetryable
        addSubview(retryButton)

        dismissButton.isBordered = false
        dismissButton.bezelStyle = .inline
        dismissButton.font = NSFont.systemFont(ofSize: 10)
        dismissButton.contentTintColor = MenuTokens.textSecondaryNS
        dismissButton.target = self
        dismissButton.action = #selector(dismiss)
        addSubview(dismissButton)
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10
        let dismissSize = dismissButton.fittingSize
        dismissButton.frame = NSRect(x: bounds.width - pad - dismissSize.width, y: 13, width: dismissSize.width, height: dismissSize.height)
        let retrySize = retryButton.fittingSize
        retryButton.frame = NSRect(x: dismissButton.frame.minX - 12 - retrySize.width, y: 13, width: retrySize.width, height: retrySize.height)
        let textWidth = retryButton.frame.minX - pad - 12
        titleLabel.frame = NSRect(x: pad, y: 8, width: textWidth, height: 13)
        subtitleLabel.frame = NSRect(x: pad, y: 22, width: textWidth, height: 11)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: MenuTokens.failedRowHeight)
    }

    @objc private func retry() {
        onRetry()
    }

    @objc private func dismiss() {
        onDismiss()
    }
}

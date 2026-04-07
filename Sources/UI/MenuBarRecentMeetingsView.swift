// MenuBarRecentMeetingsView.swift
// Compact recent meetings list for the menubar popover.

import AppKit
import Foundation

struct RecentMeetingItem {
    let title: String
    let date: Date
    let transcriptURL: URL
}

struct LatestSavedMeetingItem {
    let title: String
    let subtitle: String
    let transcriptURL: URL

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MMM d 'at' h:mm a"
        return formatter
    }()
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
        headerLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
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
        latestSavedMeeting: LatestSavedMeetingItem?,
        meetings: [RecentMeetingItem],
        failedMeetings: [MeetingSessionController.FailedMeetingItem],
        onRetryFailedMeeting: @escaping (UUID) -> Void,
        onDeleteFailedMeeting: @escaping (UUID) -> Void,
        onDismissFailedMeeting: @escaping (UUID) -> Void
    ) {
        listContainer.subviews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()

        let visibleMeetings: [RecentMeetingItem]
        if let latestSavedMeeting {
            let row = LatestSavedMeetingRowView(item: latestSavedMeeting)
            listContainer.addSubview(row)
            rowViews.append(row)
            visibleMeetings = meetings.filter { $0.transcriptURL.standardizedFileURL != latestSavedMeeting.transcriptURL.standardizedFileURL }
        } else {
            visibleMeetings = meetings
        }

        for failed in failedMeetings {
            let row = FailedMeetingRowView(
                item: failed,
                onRetry: { onRetryFailedMeeting(failed.id) },
                onDelete: { onDeleteFailedMeeting(failed.id) },
                onDismiss: { onDismissFailedMeeting(failed.id) }
            )
            listContainer.addSubview(row)
            rowViews.append(row)
        }

        for (index, item) in visibleMeetings.enumerated() {
            let row = RecentMeetingRowView(item: item, showsDivider: index < visibleMeetings.count - 1)
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
private func copyTranscriptBody(from url: URL) -> Bool {
    guard let text = MeetingTranscriptStyler.transcriptBody(at: url) else { return false }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    return true
}

@MainActor
private final class LatestSavedMeetingRowView: NSView {
    private let item: LatestSavedMeetingItem
    private let badgeLabel = NSTextField(labelWithString: "Latest saved")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let openButton = MenuIconButton(
        symbolName: "arrow.up.right.square",
        accessibilityLabel: "Open transcript",
        toolTip: "Open transcript"
    )
    private let copyButton = MenuIconButton(
        symbolName: "doc.on.doc",
        accessibilityLabel: "Copy transcript",
        toolTip: "Copy transcript"
    )
    private let showButton = MenuIconButton(
        symbolName: "folder",
        accessibilityLabel: "Show in Finder",
        toolTip: "Show in Finder"
    )
    private var resetTask: Task<Void, Never>?
    private var trackingAreaRef: NSTrackingArea?

    init(item: LatestSavedMeetingItem) {
        self.item = item
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
        layer?.cornerRadius = 12
        layer?.backgroundColor = MenuTokens.savedBackgroundNS.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = MenuTokens.savedBorderNS.cgColor

        badgeLabel.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        badgeLabel.textColor = MenuTokens.statusGreenNS
        addSubview(badgeLabel)

        titleLabel.stringValue = item.title
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subtitleLabel.stringValue = item.subtitle
        subtitleLabel.font = NSFont.systemFont(ofSize: 9)
        subtitleLabel.textColor = MenuTokens.textSecondaryNS
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)

        [openButton, copyButton, showButton].forEach { addSubview($0) }

        openButton.target = self
        openButton.action = #selector(openTranscript)
        copyButton.target = self
        copyButton.action = #selector(copyTranscript)
        showButton.target = self
        showButton.action = #selector(showInFinder)
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
        layer?.backgroundColor = MenuTokens.savedBorderNS.cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = MenuTokens.savedBackgroundNS.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !openButton.frame.contains(point),
              !copyButton.frame.contains(point),
              !showButton.frame.contains(point) else {
            super.mouseDown(with: event)
            return
        }

        NSWorkspace.shared.open(item.transcriptURL)
    }

    override func layout() {
        super.layout()

        let buttonSize = MenuTokens.secondaryButtonSize
        let buttonY = (bounds.height - buttonSize) / 2

        showButton.frame = NSRect(
            x: bounds.width - buttonSize,
            y: buttonY,
            width: buttonSize,
            height: buttonSize
        )
        copyButton.frame = NSRect(
            x: showButton.frame.minX - 8 - buttonSize,
            y: buttonY,
            width: buttonSize,
            height: buttonSize
        )
        openButton.frame = NSRect(
            x: copyButton.frame.minX - 8 - buttonSize,
            y: buttonY,
            width: buttonSize,
            height: buttonSize
        )

        let textWidth = max(0, openButton.frame.minX - 12)
        badgeLabel.frame = NSRect(x: 10, y: 7, width: textWidth - 10, height: 11)
        titleLabel.frame = NSRect(x: 10, y: 20, width: textWidth - 10, height: 14)
        subtitleLabel.frame = NSRect(x: 10, y: 35, width: textWidth - 10, height: 12)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: MenuTokens.savedRowHeight)
    }

    @objc private func openTranscript() {
        NSWorkspace.shared.open(item.transcriptURL)
    }

    @objc private func copyTranscript() {
        guard copyTranscriptBody(from: item.transcriptURL) else { return }

        resetTask?.cancel()
        copyButton.setSymbol("checkmark", accessibilityLabel: "Transcript copied", tintOverride: MenuTokens.statusGreenNS)
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.copyButton.setSymbol("doc.on.doc", accessibilityLabel: "Copy transcript")
        }
    }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([item.transcriptURL])
    }
}

@MainActor
private final class RecentMeetingRowView: NSView {
    private let item: RecentMeetingItem
    private let titleLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let copyButton = MenuIconButton(
        symbolName: "doc.on.doc",
        accessibilityLabel: "Copy transcript",
        toolTip: "Copy transcript"
    )
    private let showButton = MenuIconButton(
        symbolName: "folder",
        accessibilityLabel: "Show in Finder",
        toolTip: "Show in Finder"
    )
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

        [copyButton, showButton].forEach { addSubview($0) }

        copyButton.target = self
        copyButton.action = #selector(copyTranscript)

        showButton.target = self
        showButton.action = #selector(showInFinder)

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
        guard !copyButton.frame.contains(point), !showButton.frame.contains(point) else {
            super.mouseDown(with: event)
            return
        }
        NSWorkspace.shared.open(item.transcriptURL)
    }

    override func layout() {
        super.layout()
        let buttonSize = MenuTokens.secondaryButtonSize
        copyButton.frame = NSRect(
            x: bounds.width - buttonSize,
            y: (bounds.height - buttonSize) / 2,
            width: buttonSize,
            height: buttonSize
        )

        showButton.frame = NSRect(
            x: copyButton.frame.minX - 8 - buttonSize,
            y: (bounds.height - buttonSize) / 2,
            width: buttonSize,
            height: buttonSize
        )

        let textWidth = max(0, showButton.frame.minX - 12)
        titleLabel.frame = NSRect(x: 0, y: 6, width: textWidth, height: 14)
        dateLabel.frame = NSRect(x: 0, y: 21, width: textWidth, height: 12)
        divider.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: MenuTokens.recentRowHeight)
    }

    @objc private func copyTranscript() {
        guard copyTranscriptBody(from: item.transcriptURL) else { return }

        resetTask?.cancel()
        copyButton.setSymbol("checkmark", accessibilityLabel: "Transcript copied", tintOverride: MenuTokens.statusGreenNS)
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.copyButton.setSymbol("doc.on.doc", accessibilityLabel: "Copy transcript")
        }
    }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([item.transcriptURL])
    }
}

@MainActor
private final class FailedMeetingRowView: NSView {
    private let item: MeetingSessionController.FailedMeetingItem
    private let onRetry: () -> Void
    private let onDelete: () -> Void
    private let onDismiss: () -> Void

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let retryButton = MenuOutlineButton(
        title: "Retry",
        symbolName: "arrow.clockwise",
        accessibilityLabel: "Retry failed meeting",
        toolTip: "Retry failed meeting"
    )
    private let secondaryButton = MenuOutlineButton(title: "Dismiss")

    init(
        item: MeetingSessionController.FailedMeetingItem,
        onRetry: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.item = item
        self.onRetry = onRetry
        self.onDelete = onDelete
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

        detailLabel.stringValue = item.detail
        detailLabel.font = NSFont.systemFont(ofSize: 9.5)
        detailLabel.textColor = MenuTokens.textSecondaryNS
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(detailLabel)

        metaLabel.stringValue = item.meta
        metaLabel.font = NSFont.systemFont(ofSize: 9)
        metaLabel.textColor = MenuTokens.textMutedNS
        metaLabel.lineBreakMode = .byTruncatingTail
        addSubview(metaLabel)

        retryButton.target = self
        retryButton.action = #selector(retry)
        addSubview(retryButton)

        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryAction)
        addSubview(secondaryButton)

        if item.hasAudioFiles {
            secondaryButton.title = "Delete"
            secondaryButton.setSymbol("trash", accessibilityLabel: "Delete kept audio")
            secondaryButton.toolTip = "Delete kept audio"
        } else {
            secondaryButton.title = "Dismiss"
            secondaryButton.setSymbol("xmark", accessibilityLabel: "Dismiss failed meeting")
            secondaryButton.toolTip = "Dismiss failed meeting"
        }

        retryButton.title = item.isRetrying ? "Retrying..." : "Retry"
        retryButton.setSymbol(item.isRetrying ? "arrow.trianglehead.2.clockwise.rotate.90" : "arrow.clockwise", accessibilityLabel: "Retry failed meeting")
        retryButton.isEnabled = item.isRetryable && !item.isRetrying
        retryButton.isHidden = !item.isRetryable && !item.isRetrying
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10
        let secondarySize = secondaryButton.fittingSize
        secondaryButton.frame = NSRect(
            x: bounds.width - pad - secondarySize.width,
            y: bounds.height - pad - secondarySize.height,
            width: secondarySize.width,
            height: secondarySize.height
        )

        if retryButton.isHidden {
            retryButton.frame = .zero
        } else {
            let retrySize = retryButton.fittingSize
            retryButton.frame = NSRect(
                x: secondaryButton.frame.minX - 8 - retrySize.width,
                y: bounds.height - pad - retrySize.height,
                width: retrySize.width,
                height: retrySize.height
            )
        }

        let rightEdge = retryButton.isHidden ? secondaryButton.frame.minX : retryButton.frame.minX
        let textWidth = max(0, rightEdge - pad - 10)
        titleLabel.frame = NSRect(x: pad, y: 8, width: textWidth, height: 14)
        detailLabel.frame = NSRect(x: pad, y: 23, width: textWidth, height: 12)
        metaLabel.frame = NSRect(x: pad, y: 38, width: textWidth, height: 11)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: MenuTokens.failedRowHeight)
    }

    @objc private func retry() {
        onRetry()
    }

    @objc private func secondaryAction() {
        if item.hasAudioFiles {
            onDelete()
        } else {
            onDismiss()
        }
    }
}

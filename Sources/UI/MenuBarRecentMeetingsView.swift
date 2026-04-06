// MenuBarRecentMeetingsView.swift
// "Recent Meetings" section for the menubar popover. Lists the most recent
// transcripts saved under MeetingStoragePaths.transcriptsFolder.
//
// Pure AppKit — controller (MenuBarPanelController) drives updates via
// explicit `update(meetings:)` calls. This view has no subscriptions.

import AppKit
import Foundation

// MARK: - Data model

/// Row model for the recent meetings list. Intentionally derived-only (nothing
/// persisted) so the section can be rebuilt cheaply from the filesystem every
/// time the menubar opens.
struct RecentMeetingItem {
    let title: String
    let date: Date
    let transcriptURL: URL
}

/// Scans `MeetingStoragePaths.transcriptsFolder` for `.md` transcripts and
/// returns the N most recent, sorted newest-first. Parses only the title from
/// either the YAML frontmatter (`title: "..."`) or the filename as a fallback.
/// Uses file creation date as the sort key.
@MainActor
enum RecentMeetingsScanner {

    static func loadRecent(limit: Int = 5) -> [RecentMeetingItem] {
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

        let items: [RecentMeetingItem] = markdowns.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let date = values?.creationDate ?? values?.contentModificationDate ?? Date.distantPast
            let title = extractTitle(from: url)
            return RecentMeetingItem(title: title, date: date, transcriptURL: url)
        }

        return Array(
            items
                .sorted(by: { $0.date > $1.date })
                .prefix(limit)
        )
    }

    /// Best-effort title extraction: check for `title: "..."` in the first ~30
    /// lines (YAML frontmatter region), then fall back to the filename with
    /// underscores replaced.
    private static func extractTitle(from url: URL) -> String {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let lines = text.components(separatedBy: "\n").prefix(40)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("title:") {
                    let value = trimmed.dropFirst("title:".count)
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    if !value.isEmpty { return value }
                }
            }
        }
        return url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
    }
}

// MARK: - Section view

@MainActor
final class MenuBarRecentMeetingsView: NSView {

    private let headerLabel = NSTextField(labelWithString: "Recent Meetings")
    private let emptyLabel = NSTextField(labelWithString: "No meetings yet — press ⌥M to record one.")
    private let failedHeaderLabel = NSTextField(labelWithString: "Needs Attention")
    private let failedContainer = NSView()
    private let listContainer = NSView()

    private var rowViews: [RecentMeetingRowView] = []
    private var failedRowViews: [FailedMeetingRowView] = []
    private var items: [RecentMeetingItem] = []
    private var failedItems: [MeetingSessionController.FailedMeetingItem] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        headerLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        headerLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(headerLabel)

        failedHeaderLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        failedHeaderLabel.textColor = MenuTokens.textPrimaryNS
        failedHeaderLabel.isHidden = true
        addSubview(failedHeaderLabel)

        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.textColor = MenuTokens.textMutedNS
        addSubview(emptyLabel)

        addSubview(failedContainer)
        addSubview(listContainer)
    }

    override func layout() {
        super.layout()

        let headerH: CGFloat = 20
        headerLabel.frame = NSRect(
            x: 0,
            y: bounds.height - headerH,
            width: bounds.width,
            height: headerH
        )

        var cursorY = bounds.height - headerH - 8

        if failedItems.isEmpty {
            failedHeaderLabel.isHidden = true
            failedContainer.isHidden = true
        } else {
            failedHeaderLabel.isHidden = false
            failedContainer.isHidden = false
            failedHeaderLabel.frame = NSRect(x: 0, y: cursorY - 18, width: bounds.width, height: 18)
            cursorY -= 24

            let rowHeight: CGFloat = 48
            let rowSpacing: CGFloat = 6
            let totalFailedHeight = CGFloat(failedRowViews.count) * rowHeight
                + CGFloat(max(0, failedRowViews.count - 1)) * rowSpacing

            failedContainer.frame = NSRect(
                x: 0,
                y: cursorY - totalFailedHeight,
                width: bounds.width,
                height: totalFailedHeight
            )

            var failedY = totalFailedHeight
            for row in failedRowViews {
                failedY -= rowHeight
                row.frame = NSRect(x: 0, y: failedY, width: failedContainer.bounds.width, height: rowHeight)
                failedY -= rowSpacing
            }

            cursorY = failedContainer.frame.minY - 12
        }

        if items.isEmpty {
            listContainer.isHidden = true
            emptyLabel.isHidden = false
            emptyLabel.frame = NSRect(
                x: 0,
                y: cursorY - 18,
                width: bounds.width,
                height: 18
            )
            return
        }

        emptyLabel.isHidden = true
        listContainer.isHidden = false

        let listTop = cursorY
        let rowHeight: CGFloat = 34
        let rowSpacing: CGFloat = 4
        let totalRowsHeight = CGFloat(rowViews.count) * rowHeight
            + CGFloat(max(0, rowViews.count - 1)) * rowSpacing

        listContainer.frame = NSRect(
            x: 0,
            y: listTop - totalRowsHeight,
            width: bounds.width,
            height: totalRowsHeight
        )

        var y = totalRowsHeight
        for row in rowViews {
            y -= rowHeight
            row.frame = NSRect(
                x: 0,
                y: y,
                width: listContainer.bounds.width,
                height: rowHeight
            )
            y -= rowSpacing
        }
    }

    func update(
        meetings: [RecentMeetingItem],
        failedMeetings: [MeetingSessionController.FailedMeetingItem],
        onRetryFailedMeeting: @escaping (UUID) -> Void,
        onDismissFailedMeeting: @escaping (UUID) -> Void
    ) {
        self.items = meetings
        self.failedItems = failedMeetings

        // Rebuild rows from scratch — the list is short (5 items) so there is
        // no value in recycling.
        listContainer.subviews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()
        failedContainer.subviews.forEach { $0.removeFromSuperview() }
        failedRowViews.removeAll()

        for item in meetings {
            let row = RecentMeetingRowView(item: item)
            listContainer.addSubview(row)
            rowViews.append(row)
        }

        for item in failedMeetings {
            let row = FailedMeetingRowView(
                item: item,
                onRetry: { onRetryFailedMeeting(item.id) },
                onDismiss: { onDismissFailedMeeting(item.id) }
            )
            failedContainer.addSubview(row)
            failedRowViews.append(row)
        }

        needsLayout = true
    }

    var intrinsicHeight: CGFloat {
        let headerBlock: CGFloat = 20 + 8
        let failedBlock: CGFloat
        if failedItems.isEmpty {
            failedBlock = 0
        } else {
            let rowHeight: CGFloat = 48
            let rowSpacing: CGFloat = 6
            failedBlock = 18 + 6
                + CGFloat(failedRowViews.count) * rowHeight
                + CGFloat(max(0, failedRowViews.count - 1)) * rowSpacing
                + 12
        }
        if items.isEmpty { return headerBlock + failedBlock + 18 }
        let rowHeight: CGFloat = 34
        let rowSpacing: CGFloat = 4
        return headerBlock + failedBlock
            + CGFloat(rowViews.count) * rowHeight
            + CGFloat(max(0, rowViews.count - 1)) * rowSpacing
    }
}

// MARK: - One row

@MainActor
final class RecentMeetingRowView: NSView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    private let item: RecentMeetingItem

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    init(item: RecentMeetingItem) {
        self.item = item
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = MenuTokens.cardCornerRadius
        layer?.backgroundColor = MenuTokens.cardBackgroundNS.cgColor
        layer?.borderColor = MenuTokens.cardBorderNS.cgColor
        layer?.borderWidth = 1

        titleLabel.stringValue = item.title
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)

        dateLabel.stringValue = Self.dateFormatter.string(from: item.date)
        dateLabel.font = NSFont.systemFont(ofSize: 10)
        dateLabel.textColor = MenuTokens.textSecondaryNS
        addSubview(dateLabel)

        openButton.title = "Open"
        openButton.bezelStyle = .inline
        openButton.font = NSFont.systemFont(ofSize: 11)
        openButton.target = self
        openButton.action = #selector(handleOpen)
        addSubview(openButton)
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10

        let btnW: CGFloat = 56
        openButton.frame = NSRect(
            x: bounds.width - pad - btnW,
            y: (bounds.height - 20) / 2,
            width: btnW,
            height: 20
        )

        let leftW = openButton.frame.minX - pad - 8
        titleLabel.frame = NSRect(
            x: pad,
            y: bounds.height / 2 + 1,
            width: leftW,
            height: 14
        )
        dateLabel.frame = NSRect(
            x: pad,
            y: bounds.height / 2 - 14,
            width: leftW,
            height: 12
        )
    }

    @objc private func handleOpen() {
        NSWorkspace.shared.open(item.transcriptURL)
    }
}

// MARK: - Failed meeting row

@MainActor
final class FailedMeetingRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)
    private let onRetry: () -> Void
    private let onDismiss: () -> Void

    init(
        item: MeetingSessionController.FailedMeetingItem,
        onRetry: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onRetry = onRetry
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        setupViews(item: item)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews(item: MeetingSessionController.FailedMeetingItem) {
        wantsLayer = true
        layer?.cornerRadius = MenuTokens.cardCornerRadius
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.08).cgColor
        layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.25).cgColor
        layer?.borderWidth = 1

        titleLabel.stringValue = item.title
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)

        errorLabel.stringValue = item.errorMessage
        errorLabel.font = NSFont.systemFont(ofSize: 10)
        errorLabel.textColor = MenuTokens.textSecondaryNS
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.maximumNumberOfLines = 1
        addSubview(errorLabel)

        retryButton.bezelStyle = .inline
        retryButton.font = NSFont.systemFont(ofSize: 11)
        retryButton.target = self
        retryButton.action = #selector(handleRetry)
        retryButton.isEnabled = item.isRetryable
        retryButton.title = item.isRetryable ? "Retry" : "Not Retryable"
        addSubview(retryButton)

        dismissButton.bezelStyle = .inline
        dismissButton.font = NSFont.systemFont(ofSize: 11)
        dismissButton.target = self
        dismissButton.action = #selector(handleDismiss)
        addSubview(dismissButton)
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10
        let dismissSize = dismissButton.fittingSize
        let retrySize = retryButton.fittingSize

        dismissButton.frame = NSRect(
            x: bounds.width - pad - dismissSize.width,
            y: 8,
            width: dismissSize.width,
            height: dismissSize.height
        )
        retryButton.frame = NSRect(
            x: dismissButton.frame.minX - 8 - retrySize.width,
            y: 8,
            width: retrySize.width,
            height: retrySize.height
        )

        let textWidth = retryButton.frame.minX - pad - 8
        titleLabel.frame = NSRect(x: pad, y: bounds.height - 20, width: textWidth, height: 14)
        errorLabel.frame = NSRect(x: pad, y: 10, width: textWidth, height: 12)
    }

    @objc private func handleRetry() { onRetry() }
    @objc private func handleDismiss() { onDismiss() }
}

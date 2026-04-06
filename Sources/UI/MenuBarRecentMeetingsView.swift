// MenuBarRecentMeetingsView.swift
// "Recent Transcripts" section for the menubar popover. Lists the most recent
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

    static func loadRecent(limit: Int = 4) -> [RecentMeetingItem] {
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

    private let headerLabel = NSTextField(labelWithString: "Recent Transcripts")
    private let emptyLabel = NSTextField(labelWithString: "No meeting transcripts yet.")
    private let listContainer = NSView()

    private var rowViews: [RecentMeetingRowView] = []
    private var items: [RecentMeetingItem] = []
    private var failedItems: [MeetingSessionController.FailedMeetingItem] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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

        let headerH: CGFloat = 18
        headerLabel.frame = NSRect(
            x: 0,
            y: bounds.height - headerH,
            width: bounds.width,
            height: headerH
        )

        let cursorY = bounds.height - headerH - 8

        if rowViews.isEmpty {
            listContainer.isHidden = true
            emptyLabel.isHidden = false
            emptyLabel.frame = NSRect(
                x: 0,
                y: cursorY - 16,
                width: bounds.width,
                height: 16
            )
            return
        }

        emptyLabel.isHidden = true
        listContainer.isHidden = false

        let listTop = cursorY
        let rowHeight: CGFloat = 36
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

        for item in failedMeetings {
            let row = RecentMeetingRowView(
                failedItem: item,
                onRetry: { onRetryFailedMeeting(item.id) },
                onDismiss: { onDismissFailedMeeting(item.id) }
            )
            listContainer.addSubview(row)
            rowViews.append(row)
        }

        for item in meetings {
            let row = RecentMeetingRowView(item: item)
            listContainer.addSubview(row)
            rowViews.append(row)
        }

        needsLayout = true
    }

    var intrinsicHeight: CGFloat {
        let headerBlock: CGFloat = 18 + 8
        if rowViews.isEmpty { return headerBlock + 16 }
        let rowHeight: CGFloat = 36
        let rowSpacing: CGFloat = 4
        return headerBlock
            + CGFloat(rowViews.count) * rowHeight
            + CGFloat(max(0, rowViews.count - 1)) * rowSpacing
    }
}

// MARK: - One row

@MainActor
final class RecentMeetingRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private let secondaryButton = NSButton()
    private let item: RecentMeetingItem?
    private let failedItem: MeetingSessionController.FailedMeetingItem?
    private let onRetry: (() -> Void)?
    private let onDismiss: (() -> Void)?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    init(item: RecentMeetingItem) {
        self.item = item
        self.failedItem = nil
        self.onRetry = nil
        self.onDismiss = nil
        super.init(frame: .zero)
        setupViews()
    }

    init(
        failedItem: MeetingSessionController.FailedMeetingItem,
        onRetry: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.item = nil
        self.failedItem = failedItem
        self.onRetry = onRetry
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = MenuTokens.cardCornerRadius
        layer?.backgroundColor = (failedItem == nil ? MenuTokens.cardBackgroundNS : NSColor.systemOrange.withAlphaComponent(0.08)).cgColor
        layer?.borderColor = (failedItem == nil ? MenuTokens.cardBorderNS : NSColor.systemOrange.withAlphaComponent(0.2)).cgColor
        layer?.borderWidth = 1

        titleLabel.stringValue = item?.title ?? failedItem?.title ?? ""
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = MenuTokens.textPrimaryNS
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)

        if let item {
            dateLabel.stringValue = Self.dateFormatter.string(from: item.date)
        } else {
            dateLabel.stringValue = failedItem?.errorMessage ?? ""
        }
        dateLabel.font = NSFont.systemFont(ofSize: 9)
        dateLabel.textColor = MenuTokens.textSecondaryNS
        dateLabel.lineBreakMode = .byTruncatingTail
        dateLabel.maximumNumberOfLines = 1
        addSubview(dateLabel)

        actionButton.title = item == nil ? "Retry" : "Open"
        actionButton.bezelStyle = .inline
        actionButton.font = NSFont.systemFont(ofSize: 10)
        actionButton.target = self
        actionButton.action = #selector(handlePrimaryAction)
        actionButton.isEnabled = failedItem?.isRetryable ?? true
        addSubview(actionButton)

        secondaryButton.title = "Dismiss"
        secondaryButton.bezelStyle = .inline
        secondaryButton.font = NSFont.systemFont(ofSize: 10)
        secondaryButton.target = self
        secondaryButton.action = #selector(handleSecondaryAction)
        secondaryButton.isHidden = item != nil
        addSubview(secondaryButton)
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 9
        let secondaryWidth: CGFloat = secondaryButton.isHidden ? 0 : 52
        if !secondaryButton.isHidden {
            secondaryButton.frame = NSRect(
                x: bounds.width - pad - secondaryWidth,
                y: (bounds.height - 16) / 2,
                width: secondaryWidth,
                height: 16
            )
        }
        let primaryWidth: CGFloat = 40
        actionButton.frame = NSRect(
            x: bounds.width - pad - secondaryWidth - (secondaryButton.isHidden ? 0 : 8) - primaryWidth,
            y: (bounds.height - 16) / 2,
            width: primaryWidth,
            height: 16
        )

        let leftW = actionButton.frame.minX - pad - 8
        titleLabel.frame = NSRect(
            x: pad,
            y: bounds.height / 2 + 1,
            width: leftW,
            height: 12
        )
        dateLabel.frame = NSRect(
            x: pad,
            y: bounds.height / 2 - 10,
            width: leftW,
            height: 10
        )
    }

    @objc private func handlePrimaryAction() {
        if let item {
            NSWorkspace.shared.open(item.transcriptURL)
        } else {
            onRetry?()
        }
    }

    @objc private func handleSecondaryAction() {
        onDismiss?()
    }
}

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
        #if canImport(TranscriptedCore)
        let dir = MeetingStoragePaths.transcriptsFolder
        #else
        // Without TranscriptedCore we still expose the section, but it lists
        // nothing so the menubar layout stays consistent across build modes.
        return []
        #endif

        #if canImport(TranscriptedCore)
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
        #endif
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
    private let listContainer = NSView()

    private var rowViews: [RecentMeetingRowView] = []
    private var items: [RecentMeetingItem] = []

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

        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.textColor = MenuTokens.textMutedNS
        addSubview(emptyLabel)

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

        if items.isEmpty {
            listContainer.isHidden = true
            emptyLabel.isHidden = false
            emptyLabel.frame = NSRect(
                x: 0,
                y: bounds.height - headerH - 22,
                width: bounds.width,
                height: 18
            )
            return
        }

        emptyLabel.isHidden = true
        listContainer.isHidden = false

        let listTop = bounds.height - headerH - 8
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

    func update(meetings: [RecentMeetingItem]) {
        self.items = meetings

        // Rebuild rows from scratch — the list is short (5 items) so there is
        // no value in recycling.
        listContainer.subviews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()

        for item in meetings {
            let row = RecentMeetingRowView(item: item)
            listContainer.addSubview(row)
            rowViews.append(row)
        }

        needsLayout = true
    }

    var intrinsicHeight: CGFloat {
        let headerBlock: CGFloat = 20 + 8
        if items.isEmpty { return headerBlock + 18 }
        let rowHeight: CGFloat = 34
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

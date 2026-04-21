import AppKit

@MainActor
final class MenuBarPrimaryActionsView: NSView {
    var onOpenHome: (() -> Void)?
    var onStartDictation: (() -> Void)?
    var onStartMeeting: (() -> Void)?
    var onPasteLastDictation: (() -> Void)?
    var onOpenRecentMeetings: (() -> Void)?

    private let homeRow = MenuBarActionRowView()
    private let homeDivider = NSView()
    private let dictationRow = MenuBarActionRowView()
    private let meetingRow = MenuBarActionRowView()
    private let pasteRow = MenuBarActionRowView()
    private let recentMeetingsRow = MenuBarActionRowView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func setupViews() {
        homeRow.onPress = { [weak self] in self?.onOpenHome?() }
        dictationRow.onPress = { [weak self] in self?.onStartDictation?() }
        meetingRow.onPress = { [weak self] in self?.onStartMeeting?() }
        pasteRow.onPress = { [weak self] in self?.onPasteLastDictation?() }
        recentMeetingsRow.onPress = { [weak self] in self?.onOpenRecentMeetings?() }

        homeDivider.wantsLayer = true
        homeDivider.layer?.backgroundColor = MenuTokens.sectionDividerNS.cgColor

        [homeRow, homeDivider, dictationRow, meetingRow, pasteRow, recentMeetingsRow].forEach(addSubview(_:))
    }

    func update(
        dictationKey: String,
        meetingKey: String,
        dictationState: MenuBarPrimaryActionState,
        meetingState: MenuBarPrimaryActionState,
        pasteDetail: String,
        pasteEnabled: Bool,
        showStartDictation: Bool,
        showStartMeeting: Bool,
        showPasteLastDictation: Bool,
        showRecentMeetings: Bool
    ) {
        homeRow.update(
            symbolName: "house.fill",
            title: "Home",
            detail: "",
            tone: .standard,
            size: .utility
        )

        dictationRow.isHidden = !showStartDictation
        dictationRow.update(
            symbolName: "mic.fill",
            title: "Start Dictation",
            detail: dictationState.subtitle,
            trailingText: dictationKey,
            tone: .accent,
            size: .primary,
            isEnabled: dictationState.isEnabled
        )

        meetingRow.isHidden = !showStartMeeting
        meetingRow.update(
            symbolName: "record.circle.fill",
            title: "Start Meeting",
            detail: meetingState.subtitle,
            trailingText: meetingKey,
            tone: .accent,
            size: .primary,
            isEnabled: meetingState.isEnabled
        )

        pasteRow.isHidden = !showPasteLastDictation
        pasteRow.update(
            symbolName: "arrow.turn.down.right",
            title: "Paste Last Dictation",
            detail: pasteDetail,
            tone: .standard,
            size: .primary,
            isEnabled: pasteEnabled
        )

        recentMeetingsRow.isHidden = !showRecentMeetings
        recentMeetingsRow.update(
            symbolName: "clock.arrow.circlepath",
            title: "Recent Meetings",
            detail: "",
            tone: .standard,
            size: .utility
        )

        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()

        var y: CGFloat = 0
        let homeHeight = homeRow.intrinsicContentSize.height
        homeRow.frame = NSRect(x: 0, y: y, width: bounds.width, height: homeHeight)

        let rows = visibleActionRows
        if rows.isEmpty {
            homeDivider.frame = .zero
        } else {
            y += homeHeight + 6
            homeDivider.frame = NSRect(x: 0, y: y, width: bounds.width, height: 1)
            y += 7

            for (index, row) in rows.enumerated() {
                let rowHeight = row.intrinsicContentSize.height
                row.frame = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
                y += rowHeight
                if index < rows.count - 1 {
                    y += 2
                }
            }
        }

        hiddenActionRows.forEach { $0.frame = .zero }
    }

    var intrinsicHeight: CGFloat {
        let rows = visibleActionRows
        guard !rows.isEmpty else {
            return homeRow.intrinsicContentSize.height
        }

        let rowSpacing = max(0, rows.count - 1) * 2

        return homeRow.intrinsicContentSize.height
            + 14
            + rows.map { $0.intrinsicContentSize.height }.reduce(0, +)
            + CGFloat(rowSpacing)
    }

    private var actionRows: [MenuBarActionRowView] {
        [dictationRow, meetingRow, pasteRow, recentMeetingsRow]
    }

    private var visibleActionRows: [MenuBarActionRowView] {
        actionRows.filter { !$0.isHidden }
    }

    private var hiddenActionRows: [MenuBarActionRowView] {
        actionRows.filter(\.isHidden)
    }
}

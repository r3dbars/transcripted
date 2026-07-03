import AppKit

@MainActor
final class MenuBarPrimaryActionsView: NSView {
    var onOpenHome: (() -> Void)?
    var onStartDictation: (() -> Void)?
    var onStartMeeting: (() -> Void)?
    var onPasteLastDictation: (() -> Void)?
    var onOpenRecentMeetings: (() -> Void)?

    private let homeRow = MenuBarActionRowView()
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

        homeRow.setAutomationIdentifier("transcripted.menubar.primary.home")
        dictationRow.setAutomationIdentifier("transcripted.menubar.primary.start-dictation")
        meetingRow.setAutomationIdentifier("transcripted.menubar.primary.start-meeting")
        pasteRow.setAutomationIdentifier("transcripted.menubar.primary.paste-last-dictation")
        recentMeetingsRow.setAutomationIdentifier("transcripted.menubar.primary.recent-meetings")

        [homeRow, dictationRow, meetingRow, pasteRow, recentMeetingsRow].forEach(addSubview(_:))
    }

    func update(
        dictationTrailing: String,
        meetingTrailing: String,
        dictationState: MenuBarPrimaryActionState,
        meetingState: MenuBarPrimaryActionState,
        pasteDetail: String,
        pasteEnabled: Bool,
        isMeetingRecording: Bool,
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

        // Rows stay monochrome; color is reserved for state, so the one red
        // row in the popover always means "recording right now".
        dictationRow.isHidden = !showStartDictation
        dictationRow.update(
            symbolName: dictationState.symbolName,
            title: dictationState.title,
            detail: dictationState.subtitle,
            trailingText: dictationTrailing,
            tone: .standard,
            size: .primary,
            isEnabled: dictationState.isEnabled
        )

        meetingRow.isHidden = !showStartMeeting
        meetingRow.update(
            symbolName: meetingState.symbolName,
            title: meetingState.title,
            detail: meetingState.subtitle,
            trailingText: meetingTrailing,
            tone: isMeetingRecording ? .recording : .standard,
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
        if !rows.isEmpty {
            y += homeHeight + 8

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
            + 8
            + rows.map { $0.intrinsicContentSize.height }.reduce(0, +)
            + CGFloat(rowSpacing)
    }

    /// Visible rows in keyboard Tab order — Home first, then the visible action
    /// rows — matching `FocusOrderContract.menuBarPrimaryOrder`.
    var keyboardFocusableRows: [MenuBarActionRowView] {
        [homeRow] + visibleActionRows
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

    var smokeSnapshot: [String: MenuBarActionRowSmokeSnapshot] {
        [
            "home": homeRow.smokeSnapshot,
            "startDictation": dictationRow.smokeSnapshot,
            "startMeeting": meetingRow.smokeSnapshot,
            "pasteLastDictation": pasteRow.smokeSnapshot,
            "recentMeetings": recentMeetingsRow.smokeSnapshot,
        ]
    }
}

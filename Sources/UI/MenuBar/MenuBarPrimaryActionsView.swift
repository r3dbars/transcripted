import AppKit

@MainActor
final class MenuBarPrimaryActionsView: NSView {
    var onStartDictation: (() -> Void)?
    var onStartMeeting: (() -> Void)?
    var onPasteLastDictation: (() -> Void)?

    private let dictationRow = MenuBarActionRowView()
    private let meetingRow = MenuBarActionRowView()
    private let pasteRow = MenuBarActionRowView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func setupViews() {
        dictationRow.onPress = { [weak self] in self?.onStartDictation?() }
        meetingRow.onPress = { [weak self] in self?.onStartMeeting?() }
        pasteRow.onPress = { [weak self] in self?.onPasteLastDictation?() }

        meetingRow.setAutomationIdentifier("transcripted.menubar.primary.start-meeting")
        dictationRow.setAutomationIdentifier("transcripted.menubar.primary.start-dictation")
        pasteRow.setAutomationIdentifier("transcripted.menubar.primary.paste-last-dictation")

        [meetingRow, dictationRow, pasteRow].forEach(addSubview(_:))
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
        showPasteLastDictation: Bool
    ) {
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

        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()

        var y: CGFloat = 0
        let rows = visibleActionRows
        for (index, row) in rows.enumerated() {
            let rowHeight = row.intrinsicContentSize.height
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            y += rowHeight
            if index < rows.count - 1 {
                y += 2
            }
        }

        hiddenActionRows.forEach { $0.frame = .zero }
    }

    var intrinsicHeight: CGFloat {
        let rows = visibleActionRows
        guard !rows.isEmpty else { return 0 }

        let rowSpacing = max(0, rows.count - 1) * 2

        return rows.map { $0.intrinsicContentSize.height }.reduce(0, +)
            + CGFloat(rowSpacing)
    }

    /// Visible rows in keyboard Tab order, matching
    /// `FocusOrderContract.menuBarPrimaryOrder`.
    var keyboardFocusableRows: [MenuBarActionRowView] {
        visibleActionRows
    }

    private var actionRows: [MenuBarActionRowView] {
        // Meeting leads: record/stop is the popover's headline action.
        [meetingRow, dictationRow, pasteRow]
    }

    private var visibleActionRows: [MenuBarActionRowView] {
        actionRows.filter { !$0.isHidden }
    }

    private var hiddenActionRows: [MenuBarActionRowView] {
        actionRows.filter(\.isHidden)
    }

    var smokeSnapshot: [String: MenuBarActionRowSmokeSnapshot] {
        [
            "startDictation": dictationRow.smokeSnapshot,
            "startMeeting": meetingRow.smokeSnapshot,
            "pasteLastDictation": pasteRow.smokeSnapshot,
        ]
    }
}

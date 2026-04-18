import AppKit

@MainActor
final class MenuBarPrimaryActionsView: NSView {
    var onStartDictation: (() -> Void)?
    var onStartMeeting: (() -> Void)?
    var onPasteLastDictation: (() -> Void)?
    var onOpenRecentMeetings: (() -> Void)?

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
        dictationRow.onPress = { [weak self] in self?.onStartDictation?() }
        meetingRow.onPress = { [weak self] in self?.onStartMeeting?() }
        pasteRow.onPress = { [weak self] in self?.onPasteLastDictation?() }
        recentMeetingsRow.onPress = { [weak self] in self?.onOpenRecentMeetings?() }

        [dictationRow, meetingRow, pasteRow, recentMeetingsRow].forEach(addSubview(_:))
    }

    func update(
        dictationKey: String,
        meetingKey: String,
        dictationState: MenuBarPrimaryActionState,
        meetingState: MenuBarPrimaryActionState,
        pasteDetail: String,
        pasteEnabled: Bool
    ) {
        dictationRow.update(
            symbolName: "mic.fill",
            title: "Start Dictation",
            detail: dictationState.subtitle,
            trailingText: dictationKey,
            tone: .accent,
            size: .primary,
            isEnabled: dictationState.isEnabled
        )

        meetingRow.update(
            symbolName: "record.circle.fill",
            title: "Start Meeting",
            detail: meetingState.subtitle,
            trailingText: meetingKey,
            tone: .accent,
            size: .primary,
            isEnabled: meetingState.isEnabled
        )

        pasteRow.update(
            symbolName: "arrow.turn.down.right",
            title: "Paste Last Dictation",
            detail: pasteDetail,
            tone: .standard,
            size: .primary,
            isEnabled: pasteEnabled
        )

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

        let firstHeight = dictationRow.intrinsicContentSize.height
        let secondHeight = meetingRow.intrinsicContentSize.height
        let thirdHeight = pasteRow.intrinsicContentSize.height
        let fourthHeight = recentMeetingsRow.intrinsicContentSize.height

        dictationRow.frame = NSRect(x: 0, y: 0, width: bounds.width, height: firstHeight)
        meetingRow.frame = NSRect(x: 0, y: dictationRow.frame.maxY + 2, width: bounds.width, height: secondHeight)
        pasteRow.frame = NSRect(x: 0, y: meetingRow.frame.maxY + 2, width: bounds.width, height: thirdHeight)
        recentMeetingsRow.frame = NSRect(x: 0, y: pasteRow.frame.maxY + 2, width: bounds.width, height: fourthHeight)
    }

    var intrinsicHeight: CGFloat {
        dictationRow.intrinsicContentSize.height
            + meetingRow.intrinsicContentSize.height
            + pasteRow.intrinsicContentSize.height
            + recentMeetingsRow.intrinsicContentSize.height
            + 6
    }
}

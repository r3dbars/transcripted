import AppKit

@MainActor
final class MenuBarPrimaryActionsView: NSView {
    var onStartDictation: (() -> Void)?
    var onStartMeeting: (() -> Void)?

    private let dictationRow = MenuBarActionRowView()
    private let meetingRow = MenuBarActionRowView()

    private static let buttonSpacing: CGFloat = 6

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

        meetingRow.setAutomationIdentifier("transcripted.menubar.primary.start-meeting")
        dictationRow.setAutomationIdentifier("transcripted.menubar.primary.start-dictation")

        [meetingRow, dictationRow].forEach(addSubview(_:))
    }

    func update(
        dictationTrailing: String,
        meetingTrailing: String,
        dictationState: MenuBarPrimaryActionState,
        meetingState: MenuBarPrimaryActionState,
        isMeetingRecording: Bool
    ) {
        // Buttons stay monochrome; color is reserved for state, so the one red
        // icon in the popover always means "recording right now".
        dictationRow.update(
            symbolName: dictationState.symbolName,
            title: dictationState.title,
            displayTitle: MenuBarPrimaryButtonTitle.short(for: dictationState.title),
            detail: dictationState.subtitle,
            trailingText: dictationTrailing,
            tone: .standard,
            size: .button,
            isEnabled: dictationState.isEnabled
        )

        meetingRow.update(
            symbolName: meetingState.symbolName,
            title: meetingState.title,
            displayTitle: MenuBarPrimaryButtonTitle.short(for: meetingState.title),
            detail: meetingState.subtitle,
            trailingText: meetingTrailing,
            tone: isMeetingRecording ? .recording : .standard,
            size: .button,
            isEnabled: meetingState.isEnabled
        )

        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()

        // Two equal buttons side by side: Record/Stop Meeting leads.
        let width = floor((bounds.width - Self.buttonSpacing) / 2)
        var x: CGFloat = 0
        for row in actionRows {
            row.frame = NSRect(x: x, y: 0, width: width, height: row.intrinsicContentSize.height)
            x += width + Self.buttonSpacing
        }
    }

    var intrinsicHeight: CGFloat {
        actionRows.map { $0.intrinsicContentSize.height }.max() ?? 0
    }

    /// Buttons in keyboard Tab order, matching
    /// `FocusOrderContract.menuBarPrimaryOrder`.
    var keyboardFocusableRows: [MenuBarActionRowView] {
        actionRows
    }

    /// Record/Stop Meeting, for the press click (Dictate has its own sounds).
    var meetingButton: MenuBarActionRowView {
        meetingRow
    }

    private var actionRows: [MenuBarActionRowView] {
        // Meeting leads: record/stop is the popover's headline action.
        [meetingRow, dictationRow]
    }

    var smokeSnapshot: [String: MenuBarActionRowSmokeSnapshot] {
        [
            "startDictation": dictationRow.smokeSnapshot,
            "startMeeting": meetingRow.smokeSnapshot,
        ]
    }
}

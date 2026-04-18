import AppKit

@MainActor
final class MenuBarUtilityActionsView: NSView {
    weak var appState: TranscriptedAppState?

    var onOpenConnectAgent: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let connectAgentRow = MenuBarActionRowView()
    private let feedbackRow = MenuBarActionRowView()
    private let updatesRow = MenuBarActionRowView()
    private let settingsRow = MenuBarActionRowView()
    private let quitRow = MenuBarActionRowView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func setupViews() {
        connectAgentRow.onPress = { [weak self] in self?.onOpenConnectAgent?() }
        feedbackRow.onPress = { [weak self] in self?.sendFeedback() }
        updatesRow.onPress = { [weak self] in self?.onCheckForUpdates?() }
        settingsRow.onPress = { [weak self] in self?.onOpenSettings?() }
        quitRow.onPress = { NSApplication.shared.terminate(nil) }

        [connectAgentRow, feedbackRow, updatesRow, settingsRow, quitRow].forEach(addSubview(_:))
    }

    func update(
        updateTitle: String,
        updateDetail: String,
        updateTone: MenuBarActionRowView.Tone,
        updateEnabled: Bool
    ) {
        connectAgentRow.update(
            symbolName: "sparkles",
            title: "Connect Agent",
            detail: "Copy the prompt or MCP setup in Settings.",
            tone: .standard,
            size: .utility
        )

        feedbackRow.update(
            symbolName: "bubble.left",
            title: "Submit Feedback",
            detail: "Open a GitHub feedback form with scrubbed app logs.",
            tone: .standard,
            size: .utility
        )

        updatesRow.update(
            symbolName: "arrow.triangle.2.circlepath.circle",
            title: updateTitle,
            detail: updateDetail,
            tone: updateTone,
            size: .utility,
            isEnabled: updateEnabled
        )

        settingsRow.update(
            symbolName: "gearshape",
            title: "Open Settings",
            detail: "Shortcuts, meetings, dictations, storage, privacy, and more.",
            tone: .standard,
            size: .utility
        )

        quitRow.update(
            symbolName: "power",
            title: "Quit",
            detail: "Close Transcripted completely.",
            tone: .warning,
            size: .utility
        )

        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()

        let rowHeight = MenuBarActionRowView.Size.utility.height
        var y: CGFloat = 0
        for row in [connectAgentRow, feedbackRow, updatesRow, settingsRow, quitRow] {
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            y += rowHeight + 6
        }
    }

    private func sendFeedback() {
        TranscriptedSupportActions.sendFeedback(logger: appState?.logger)
    }

    func dismissTransientUI() {}

    var intrinsicHeight: CGFloat {
        (MenuBarActionRowView.Size.utility.height * 5) + 24
    }
}

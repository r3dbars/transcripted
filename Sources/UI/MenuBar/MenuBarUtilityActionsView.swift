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
        updateVersion: String?,
        updateTone: MenuBarActionRowView.Tone,
        updateEnabled: Bool
    ) {
        connectAgentRow.update(
            symbolName: "sparkles",
            title: "Connect Agent",
            detail: "",
            tone: .standard,
            size: .utility
        )

        feedbackRow.update(
            symbolName: "bubble.left",
            title: "Submit Feedback",
            detail: "",
            tone: .standard,
            size: .utility
        )

        updatesRow.update(
            symbolName: "arrow.triangle.2.circlepath.circle",
            title: updateTitle,
            detail: "",
            trailingText: updateVersion,
            tone: updateTone,
            size: .utility,
            isEnabled: updateEnabled
        )

        settingsRow.update(
            symbolName: "gearshape",
            title: "Settings",
            detail: "",
            tone: .standard,
            size: .utility
        )

        quitRow.update(
            symbolName: "power",
            title: "Quit",
            detail: "",
            trailingText: "⌘Q",
            tone: .warning,
            size: .utility
        )

        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()

        var y: CGFloat = 0
        for row in [connectAgentRow, feedbackRow, updatesRow, settingsRow, quitRow] {
            let rowHeight = row.intrinsicContentSize.height
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            y += rowHeight + 1
        }
    }

    private func sendFeedback() {
        TranscriptedSupportActions.sendFeedback(logger: appState?.logger)
    }

    func dismissTransientUI() {}

    var intrinsicHeight: CGFloat {
        [connectAgentRow, feedbackRow, updatesRow, settingsRow, quitRow]
            .map { $0.intrinsicContentSize.height }
            .reduce(0, +) + 4
    }
}

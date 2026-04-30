import AppKit

@MainActor
final class MenuBarUtilityActionsView: NSView {
    weak var appState: TranscriptedAppState?
    var pasteAvailable: Bool?

    var onOpenConnectAgent: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenSupport: (() -> Void)?

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
        feedbackRow.onPress = { [weak self] in
            self?.onOpenSupport?()
        }
        updatesRow.onPress = { [weak self] in self?.onCheckForUpdates?() }
        settingsRow.onPress = { [weak self] in self?.onOpenSettings?() }
        quitRow.onPress = { [weak self] in
            self?.trackMenuAction("quit")
            NSApplication.shared.terminate(nil)
        }

        [connectAgentRow, feedbackRow, updatesRow, settingsRow, quitRow].forEach(addSubview(_:))
    }

    func update(
        updateTitle: String,
        updateDetail: String,
        updateVersion: String?,
        updateTone: MenuBarActionRowView.Tone,
        updateEnabled: Bool,
        showUpdateRow: Bool = true
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
            title: "Submit feedback for support",
            detail: "Opens the Support tab",
            tone: .standard,
            size: .utility
        )

        updatesRow.update(
            symbolName: "arrow.triangle.2.circlepath.circle",
            title: updateTitle,
            detail: updateDetail,
            trailingText: updateVersion,
            tone: updateTone,
            size: .utility,
            isEnabled: updateEnabled
        )
        updatesRow.isHidden = !showUpdateRow

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
        for row in visibleRows {
            let rowHeight = row.intrinsicContentSize.height
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: rowHeight)
            y += rowHeight + 1
        }

        for row in allRows where row.isHidden {
            row.frame = .zero
        }
    }

    private func trackMenuAction(_ actionID: String) {
        AnalyticsReporter.track(
            "menu_bar_action_clicked",
            properties: [
                "action_id": actionID,
                "dictation_ready": appState?.sttRouter.isModelLoaded == true ? "true" : "false",
                "meeting_recording_ready": TranscriptedPermissionAccess.isGranted(.systemAudioRecording) ? "true" : "false",
                "paste_available": pasteAvailable.map { $0 ? "true" : "false" } ?? "unknown",
            ]
        )
    }

    func dismissTransientUI() {}

    var intrinsicHeight: CGFloat {
        let rows = visibleRows
        let rowSpacing = max(0, rows.count - 1)
        return rows
            .map { $0.intrinsicContentSize.height }
            .reduce(0, +) + CGFloat(rowSpacing)
    }

    private var allRows: [MenuBarActionRowView] {
        [connectAgentRow, feedbackRow, updatesRow, settingsRow, quitRow]
    }

    private var visibleRows: [MenuBarActionRowView] {
        allRows.filter { !$0.isHidden }
    }
}

import AppKit

@MainActor
final class MenuBarSettingsView: NSView {
    private let settingsButton = MenuOutlineButton(
        title: "Settings",
        symbolName: "gearshape",
        accessibilityLabel: "Open settings",
        toolTip: "Open settings"
    )
    private let updatesButton = MenuOutlineButton(
        title: "Check updates",
        symbolName: "arrow.triangle.2.circlepath.circle",
        accessibilityLabel: "Check for updates",
        toolTip: "Check for updates"
    )
    private let quitButton = MenuOutlineButton(
        title: "Quit",
        symbolName: "power",
        accessibilityLabel: "Quit Transcripted",
        toolTip: "Quit Transcripted"
    )

    var onOpenSettings: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func setupViews() {
        [settingsButton, updatesButton, quitButton].forEach { addSubview($0) }

        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        updatesButton.target = self
        updatesButton.action = #selector(checkForUpdates)
        quitButton.target = self
        quitButton.action = #selector(quitApp)
    }

    override func layout() {
        super.layout()

        let buttonHeight = MenuTokens.secondaryButtonSize
        let spacing: CGFloat = 8
        let quitWidth = quitButton.fittingSize.width
        let updatesWidth = min(max(112, updatesButton.fittingSize.width), max(112, bounds.width * 0.38))
        let settingsWidth = bounds.width - quitWidth - updatesWidth - spacing * 2

        settingsButton.frame = NSRect(x: 0, y: 0, width: max(96, settingsWidth), height: buttonHeight)
        updatesButton.frame = NSRect(
            x: settingsButton.frame.maxX + spacing,
            y: 0,
            width: updatesWidth,
            height: buttonHeight
        )
        quitButton.frame = NSRect(
            x: updatesButton.frame.maxX + spacing,
            y: 0,
            width: quitWidth,
            height: buttonHeight
        )
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }

    @objc private func checkForUpdates() {
        onCheckForUpdates?()
    }

    func update(updateState: SparkleUpdaterController.UpdateState) {
        updatesButton.title = updateState.buttonTitle
        if case .available = updateState {
            updatesButton.setSymbol(
                "arrow.down.circle.fill",
                accessibilityLabel: "Install available update"
            )
        } else {
            updatesButton.setSymbol(
                "arrow.triangle.2.circlepath.circle",
                accessibilityLabel: "Check for updates"
            )
        }
        updatesButton.isEnabled = updateState != .checking
        needsLayout = true
    }

    func dismissTransientUI() {}

    var intrinsicHeight: CGFloat { MenuTokens.secondaryButtonSize }
}

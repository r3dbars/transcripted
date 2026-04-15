import AppKit

@MainActor
final class MenuBarContentView: NSView {
    let headerView = MenuBarHeaderView(frame: .zero)
    let shortcutsView = MenuBarShortcutsView(frame: .zero)
    let settingsView = MenuBarSettingsView(frame: .zero)

    private let footerDivider = NSView()

    weak var appState: TranscriptedAppState?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = MenuTokens.surfaceCornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = MenuTokens.surfaceBackgroundNS.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = MenuTokens.surfaceStrokeNS.cgColor

        footerDivider.wantsLayer = true
        footerDivider.layer?.backgroundColor = MenuTokens.sectionDividerNS.cgColor
        addSubview(footerDivider)

        addSubview(headerView)
        addSubview(shortcutsView)
        addSubview(settingsView)
    }

    override func layout() {
        super.layout()

        let pad = MenuTokens.innerPadding
        let width = bounds.width - pad * 2
        var y = pad

        let headerHeight = headerView.intrinsicHeight
        headerView.frame = NSRect(x: pad, y: y, width: width, height: headerHeight)
        y += headerHeight + 12

        let shortcutsHeight = shortcutsView.intrinsicHeight
        shortcutsView.frame = NSRect(x: pad, y: y, width: width, height: shortcutsHeight)
        y += shortcutsHeight + 12

        footerDivider.frame = NSRect(x: pad, y: y, width: width, height: 1)
        y += 12

        let footerHeight = settingsView.intrinsicHeight
        settingsView.frame = NSRect(x: pad, y: y, width: width, height: footerHeight)
    }
}

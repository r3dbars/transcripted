// MenuBarContentView.swift
// Root NSView for the menubar popover — composes all sections in a vertical scroll

import AppKit

@MainActor
final class MenuBarContentView: NSView {
    private let scrollView = NSScrollView()
    private let documentView = NSView()

    let headerView = MenuBarHeaderView(frame: .zero)
    let modelDownloadView = MenuBarModelDownloadView(frame: .zero)
    let hotkeyErrorBanner = HotkeyErrorBanner()
    let shortcutsView = MenuBarShortcutsView(frame: .zero)
    let recentMeetingsView = MenuBarRecentMeetingsView(frame: .zero)
    let settingsView = MenuBarSettingsView(frame: .zero)

    weak var appState: DraftAppState?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        addSubview(scrollView)

        // Add sections to document view
        documentView.addSubview(headerView)
        documentView.addSubview(modelDownloadView)
        documentView.addSubview(hotkeyErrorBanner)
        documentView.addSubview(shortcutsView)
        documentView.addSubview(recentMeetingsView)
        documentView.addSubview(settingsView)
    }

    override func layout() {
        super.layout()
        let pad = MenuTokens.innerPadding
        let w = bounds.width - pad * 2

        scrollView.frame = bounds

        // Layout sections top-to-bottom
        var y: CGFloat = 0

        // Header
        let headerH = headerView.intrinsicHeight
        headerView.frame = NSRect(x: pad, y: 0, width: w, height: headerH)
        y += headerH + 4

        // Model download (conditional)
        if !modelDownloadView.isHidden {
            let modelH = modelDownloadView.intrinsicHeight
            modelDownloadView.frame = NSRect(x: pad, y: y, width: w, height: modelH)
            y += modelH + 4
        }

        // Hotkey error banner (conditional)
        if !hotkeyErrorBanner.isHidden {
            let bannerH = hotkeyErrorBanner.intrinsicHeight
            hotkeyErrorBanner.frame = NSRect(x: pad, y: y, width: w, height: bannerH)
            y += bannerH + 4
        }

        // Shortcuts
        y += 2
        let shortcutsH = shortcutsView.intrinsicHeight
        shortcutsView.frame = NSRect(x: pad, y: y, width: w, height: shortcutsH)
        y += shortcutsH + 4

        // Recent transcripts
        y += 2
        let recentH = recentMeetingsView.intrinsicHeight
        recentMeetingsView.frame = NSRect(x: pad, y: y, width: w, height: recentH)
        y += recentH + 4

        // Settings
        y += 2
        let settingsH = settingsView.intrinsicHeight
        settingsView.frame = NSRect(x: pad, y: y, width: w, height: settingsH)
        y += settingsH + 4

        y += pad

        // Set document view size for scrolling
        // AppKit scroll views use flipped coordinates, but we're using non-flipped
        // The document view origin is at the bottom-left; we need to position sections
        // from top-down. Since we're not flipped, we need to invert.
        let totalHeight = y
        documentView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(totalHeight, bounds.height))

        // Re-layout with correct Y positions (top-down in flipped coordinates)
        layoutSectionsFlipped(totalHeight: totalHeight, pad: pad, w: w)
    }

    /// Layout sections from top to bottom in the document view.
    /// NSScrollView document views grow downward from top when flipped.
    private func layoutSectionsFlipped(totalHeight: CGFloat, pad: CGFloat, w: CGFloat) {
        let docH = documentView.frame.height
        var y = docH

        // Header
        let headerH = headerView.intrinsicHeight
        y -= headerH
        headerView.frame = NSRect(x: pad, y: y, width: w, height: headerH)

        // Model download
        if !modelDownloadView.isHidden {
            y -= 4
            let modelH = modelDownloadView.intrinsicHeight
            y -= modelH
            modelDownloadView.frame = NSRect(x: pad, y: y, width: w, height: modelH)
        }

        // Hotkey error
        if !hotkeyErrorBanner.isHidden {
            y -= 4
            let bannerH = hotkeyErrorBanner.intrinsicHeight
            y -= bannerH
            hotkeyErrorBanner.frame = NSRect(x: pad, y: y, width: w, height: bannerH)
        }

        // Shortcuts
        y -= 6
        let shortcutsH = shortcutsView.intrinsicHeight
        y -= shortcutsH
        shortcutsView.frame = NSRect(x: pad, y: y, width: w, height: shortcutsH)

        // Recent transcripts
        y -= 6
        let recentH = recentMeetingsView.intrinsicHeight
        y -= recentH
        recentMeetingsView.frame = NSRect(x: pad, y: y, width: w, height: recentH)

        // Settings
        y -= 6
        let settingsH = settingsView.intrinsicHeight
        y -= settingsH
        settingsView.frame = NSRect(x: pad, y: y, width: w, height: settingsH)
    }
}

// MARK: - Hotkey Error Banner

@MainActor
final class HotkeyErrorBanner: NSView {
    private let icon = NSImageView()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)

    var onDismiss: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = MenuTokens.cardCornerRadius
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.18).cgColor
        isHidden = true

        if let img = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning") {
            icon.image = img
            icon.contentTintColor = NSColor.systemOrange
        }
        addSubview(icon)

        messageLabel.font = NSFont.systemFont(ofSize: 11)
        messageLabel.textColor = MenuTokens.textSecondaryNS
        addSubview(messageLabel)

        dismissButton.bezelStyle = .inline
        dismissButton.isBordered = false
        dismissButton.font = NSFont.systemFont(ofSize: 11)
        dismissButton.contentTintColor = MenuTokens.textPrimaryNS
        dismissButton.target = self
        dismissButton.action = #selector(dismiss)
        addSubview(dismissButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 8, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let dismissSize = dismissButton.fittingSize
        dismissButton.frame = NSRect(x: bounds.width - 8 - dismissSize.width, y: (bounds.height - dismissSize.height) / 2, width: dismissSize.width, height: dismissSize.height)
        messageLabel.frame = NSRect(x: 30, y: 6, width: bounds.width - 30 - dismissSize.width - 16, height: bounds.height - 12)
    }

    func update(error: String?) {
        if let error = error {
            isHidden = false
            messageLabel.stringValue = error
        } else {
            isHidden = true
        }
        superview?.needsLayout = true
    }

    @objc private func dismiss() { onDismiss?() }

    var intrinsicHeight: CGFloat { 36 }
}

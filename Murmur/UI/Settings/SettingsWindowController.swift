import AppKit
import SwiftUI

/// Window controller for the redesigned settings window
/// Manages the NSWindow lifecycle and hosts the SwiftUI settings view
@available(macOS 14.0, *)
final class SettingsWindowController: NSWindowController {

    // MARK: - Properties

    private let statsService: StatsService
    private let navigationState: SettingsNavigationState

    // MARK: - Window Dimensions

    private static let windowWidth: CGFloat = 800
    private static let windowHeight: CGFloat = 600

    // MARK: - Initialization

    init(statsService: StatsService = .shared) {
        self.statsService = statsService
        self.navigationState = SettingsNavigationState()

        // Create the window
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.windowWidth,
                height: Self.windowHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        configureWindow(window)
        setupContentView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Window Configuration

    private func configureWindow(_ window: NSWindow) {
        window.title = "Transcripted"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(Color.panelCharcoal)

        // Center on screen
        window.center()

        // Prevent resize
        window.minSize = NSSize(width: Self.windowWidth, height: Self.windowHeight)
        window.maxSize = NSSize(width: Self.windowWidth, height: Self.windowHeight)

        // Window level and behavior
        window.level = .normal
        window.isReleasedWhenClosed = false

        // Set window appearance to dark
        window.appearance = NSAppearance(named: .darkAqua)
    }

    private func setupContentView() {
        guard let window = window else { return }

        let settingsView = SettingsContainerView(
            statsService: statsService,
            navigationState: navigationState
        )

        let hostingView = NSHostingView(rootView: settingsView)
        hostingView.autoresizingMask = [.width, .height]

        window.contentView = hostingView
    }

    // MARK: - Public Methods

    /// Show the settings window
    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Refresh stats when window is shown
        Task { @MainActor in
            await statsService.refreshStats()

            // Check if migration is needed
            if navigationState.checkMigrationNeeded() {
                await navigationState.startMigration()
            }
        }
    }

    /// Close the settings window
    func closeWindow() {
        window?.close()
    }

    /// Navigate to a specific tab
    func navigateToTab(_ tab: SettingsTab) {
        navigationState.selectTab(tab)
    }
}

// MARK: - Window Delegate

@available(macOS 14.0, *)
extension SettingsWindowController: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        // Clean up if needed
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Refresh stats when window becomes active
        Task { @MainActor in
            await statsService.refreshStats()
        }
    }
}

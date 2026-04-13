import SwiftUI
import AppKit

@MainActor
final class TranscriptedOnboardingWindowController: NSWindowController {
    private let hostingController: NSHostingController<PermissionsOnboardingView>

    init(onComplete: @escaping () -> Void) {
        self.hostingController = NSHostingController(
            rootView: PermissionsOnboardingView(onComplete: onComplete)
        )

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: MenuTokens.onboardingWindowWidth,
                height: MenuTokens.onboardingWindowHeight
            ),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Transcripted"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentViewController = hostingController
        window.center()
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isVisible: Bool {
        window?.isVisible == true
    }

    func present() {
        guard let window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window?.close()
    }
}

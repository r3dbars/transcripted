import SwiftUI
import AppKit

@MainActor
final class TranscriptedOnboardingWindowController: NSWindowController {
    private let makeView: () -> PermissionsOnboardingView
    private let hostingController: NSHostingController<PermissionsOnboardingView>

    init(makeView: @escaping () -> PermissionsOnboardingView) {
        self.makeView = makeView
        self.hostingController = NSHostingController(
            rootView: makeView()
        )

        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: MenuTokens.onboardingWindowWidth,
                height: MenuTokens.onboardingWindowHeight
            ),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Transcripted"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: MenuTokens.onboardingWindowWidth, height: 680)
        window.contentViewController = hostingController
        window.center()
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isVisible: Bool {
        window?.isVisible == true
    }

    func present() {
        guard let window else { return }
        hostingController.rootView = makeView()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window?.close()
    }
}

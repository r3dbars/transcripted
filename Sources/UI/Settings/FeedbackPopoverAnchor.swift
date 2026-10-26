import AppKit
import SwiftUI

/// SwiftUI's transient popover closes as soon as Finder or Photos gains focus,
/// before a screenshot can be dragged back. Only this presentation edge uses
/// AppKit: the binding and the shared form remain SwiftUI-owned.
struct FeedbackPopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.setAccessibilityElement(false)
        view.onWindowChanged = { [weak coordinator = context.coordinator] view in
            coordinator?.updateWindow(for: view)
        }
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isPresented = $isPresented
        coordinator.update(content: content())
        coordinator.updateWindow(for: view)
        coordinator.synchronize(with: view)
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        view.onWindowChanged = nil
        coordinator.tearDown()
    }

    final class AnchorView: NSView {
        var onWindowChanged: ((AnchorView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(self)
        }

        // The invisible anchor never intercepts a click meant for Feedback.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        var isPresented: Binding<Bool>
        private let popover = NSPopover()
        private var hostingController: NSHostingController<AnyView>?
        private weak var parentWindow: NSWindow?
        private weak var anchorView: AnchorView?
        private var isTearingDown = false

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
            super.init()
            popover.behavior = .applicationDefined
            popover.animates = false
            popover.delegate = self
        }

        func update(content: Content) {
            let root = AnyView(content.onExitCommand { [weak self] in self?.close() })
            if let hostingController {
                hostingController.rootView = root
            } else {
                let controller = NSHostingController(rootView: root)
                controller.sizingOptions = [.preferredContentSize]
                hostingController = controller
                popover.contentViewController = controller
            }
        }

        func updateWindow(for view: AnchorView) {
            anchorView = view
            guard parentWindow !== view.window else { return }
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: parentWindow)
            parentWindow = view.window
            if let window = parentWindow {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(parentWillClose(_:)),
                    name: NSWindow.willCloseNotification, object: window
                )
                synchronize(with: view)
            } else {
                // The anchor was removed with its parent window.
                popover.close()
            }
        }

        func synchronize(with view: AnchorView) {
            guard !isTearingDown else { return }
            if isPresented.wrappedValue {
                guard view.window != nil, hostingController != nil, !popover.isShown else { return }
                popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxX)
                hostingController?.view.window?.hidesOnDeactivate = false
            } else if popover.isShown {
                popover.close()
            }
        }

        func close() {
            isPresented.wrappedValue = false
            popover.close()
        }

        @objc private func parentWillClose(_ notification: Notification) {
            close()
        }

        func popoverDidClose(_ notification: Notification) {
            guard !isTearingDown, isPresented.wrappedValue else { return }
            // AppKit can close a popover when its anchor disappears. Defer the
            // state update so a SwiftUI representable update never writes state
            // while the view tree is being updated.
            Task { @MainActor [weak self] in
                guard let self, !self.popover.isShown else { return }
                self.isPresented.wrappedValue = false
            }
        }

        func popoverShouldDetach(_ popover: NSPopover) -> Bool { false }

        func tearDown() {
            isTearingDown = true
            NotificationCenter.default.removeObserver(self)
            popover.delegate = nil
            popover.close()
            popover.contentViewController = nil
            hostingController = nil
            parentWindow = nil
            anchorView = nil
        }
    }
}

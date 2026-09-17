import AppKit

@MainActor
final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let source = NSWorkspace.shared.frontmostApplication
        let beganActive = NSApp.isActive
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            var observedActive = false
            var requested = false
            var restored = false
            let panel = FloatingOverlayPanel(contentRect: NSRect(x: 100, y: 100, width: 140, height: 32), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            panel.orderFrontRegardless()
            var current = true
            let activation = DictationStartActivation()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000)
                current = false
                activation.cancel()
            }
            let prepared = await activation.prepare(
                isCurrent: { current },
                isActive: {
                    if NSApp.isActive { observedActive = true }
                    return NSApp.isActive
                },
                activate: { requested = true; NSApp.activate(ignoringOtherApps: true) },
                restore: { restored = true; source?.activate(options: []) }
            )
            panel.orderOut(nil)
            try? await Task.sleep(nanoseconds: 250_000_000)
            let targetRestored = NSWorkspace.shared.frontmostApplication?.processIdentifier == source?.processIdentifier
            let report: [String: Any] = [
                "began_in_background": !beganActive,
                "activation_requested": requested,
                "observed_actual_app_activation": observedActive,
                "preparation_completed": prepared,
                "restore_requested": restored,
                "original_frontmost_app_restored": targetRestored
            ]
            let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try! data.write(to: URL(fileURLWithPath: "/tmp/transcripted-1743-live-activation.json"))
            NSApp.terminate(nil)
        }
    }
}
@main struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = Delegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

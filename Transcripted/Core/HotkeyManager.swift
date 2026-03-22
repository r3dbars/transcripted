import AppKit

// MARK: - Global Hotkey Registration (Cmd+Shift+R)

@available(macOS 26.0, *)
extension AppDelegate {

    func registerGlobalHotkey() {
        // Global monitor: catches ⌘⇧R when OTHER apps are frontmost
        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains([.command, .shift]),
               event.charactersIgnoringModifiers?.lowercased() == "r" {
                DispatchQueue.main.async {
                    self?.toggleRecording()
                }
            }
        }
        // Local monitor: catches ⌘⇧R when THIS app is frontmost
        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains([.command, .shift]),
               event.charactersIgnoringModifiers?.lowercased() == "r" {
                DispatchQueue.main.async {
                    self?.toggleRecording()
                }
                return nil  // consume the event
            }
            return event
        }
    }

    func cleanupHotkeyMonitors() {
        if let monitor = globalHotkeyMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localHotkeyMonitor { NSEvent.removeMonitor(monitor) }
    }
}

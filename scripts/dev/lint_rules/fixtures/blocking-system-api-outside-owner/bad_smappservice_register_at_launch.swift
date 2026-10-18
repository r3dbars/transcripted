// lint-fixture-path: Sources/App/TranscriptedAppState.swift
// Shape of e761d0142^ TranscriptedAppState: launch registered the login item
// on main.
import ServiceManagement

@MainActor
final class TranscriptedAppState {
    func registerLoginItemIfNeeded() {
        if SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }
    }
}

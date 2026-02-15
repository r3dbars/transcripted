// DraftApp.swift
// App entry point — keeps the @main struct minimal

import SwiftUI

@main
struct DraftApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 600, height: 550)
    }
}

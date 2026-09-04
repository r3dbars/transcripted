import SwiftUI

@main
struct TranscriptedLabApp: App {
    @StateObject private var workspace = LabWorkspaceStore()

    var body: some Scene {
        WindowGroup("Transcripted Lab") {
            LabContentView()
                .environmentObject(workspace)
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1180, height: 780)
    }
}

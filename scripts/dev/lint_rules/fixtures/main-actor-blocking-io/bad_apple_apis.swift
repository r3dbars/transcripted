// lint-fixture-path: Sources/Meeting/ExampleCaptureBridge.swift
// Shape of f2a61b145^ and friends: Apple file, sound and window-list calls
// inside main-actor code, including `.sync`, which still blocks the caller.
import AppKit

final class ExampleCaptureBridge: ObservableObject {
    func onCue(_ cue: Cue) {
        Task { @MainActor in
            NSSound(named: "Tink")?.play()
        }
    }
}

@MainActor
final class ExampleWindowProbe {
    let queue = DispatchQueue(label: "example")

    func probe(url: URL) throws {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        queue.sync {
            try? FileManager.default.removeItem(at: url)
        }
        let data = try Data(contentsOf: url)
        _ = (list, data)
    }
}

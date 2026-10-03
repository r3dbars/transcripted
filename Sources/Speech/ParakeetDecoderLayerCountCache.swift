// ParakeetDecoderLayerCountCache.swift
// FluidAudio's decoder layer count, read once per loaded AsrManager instead of
// once per inference. `AsrManager` is an actor, so every `await
// manager.decoderLayerCount` is an actor round trip plus a main-actor resume
// right before the encoder runs. The count comes from the loaded model's
// version and doesn't change while that manager is loaded.

/// Holds the decoder layer count for exactly one manager. The manager is held
/// weakly and compared by identity, so a count stored for one manager is never
/// returned for another, even one allocated at the same address later.
/// ParakeetEngine stores it next to `asrManager` and clears it with teardown.
struct ParakeetDecoderLayerCountCache {
    private weak var manager: AnyObject?
    private var layerCount: Int?

    /// The stored count when `manager` is the one it was stored for; nil otherwise.
    func count(for manager: AnyObject) -> Int? {
        guard let stored = self.manager, stored === manager else { return nil }
        return layerCount
    }

    mutating func store(_ count: Int, for manager: AnyObject) {
        self.manager = manager
        layerCount = count
    }

    mutating func clear() {
        manager = nil
        layerCount = nil
    }
}

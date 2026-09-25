import Foundation

/// Bridges Phase 1's memory-only `ScreenSnapshot` (the app's capture output)
/// into Phase 2's pure `ScreenScene` classifier, and gates that bridge on
/// freshness. Both `ScreenSnapshot` and `ScreenScene` already live in Core
/// and already share one coordinate convention (top-left origin, normalized
/// 0...1 — see `ScreenSnapshot`'s and `ScreenScene.NormalizedRect`'s own doc
/// comments), so this file is a straight field-for-field mapping plus a
/// staleness clock, not a second geometry system.
///
/// Screen Memory plan, Phase 2 PR 2b (`docs/plans/screen-memory.md`): "the
/// engine consumes the latest fresh `ScreenSnapshot`-derived Scene
/// (staleness cap 20s) — never awaits capture; absent/stale scene = exactly
/// today's behavior."
extension ScreenScene {
    /// How stale a snapshot may be and still be trusted for a live
    /// suggestion. Chosen so a completion request never blocks on — or even
    /// waits near — the next capture; it either has a recent-enough snapshot
    /// already sitting in memory or it gets today's no-context behavior.
    public static let defaultStalenessCapSeconds: TimeInterval = 20

    /// The read-only, non-blocking path the completion engine calls on every
    /// request: given whatever `ScreenCaptureService` last captured (or
    /// `nil` if capture is off, ungranted, or hasn't run yet), decide
    /// whether it's fresh enough to use and, if so, classify it. Returns
    /// `nil` for "use exactly today's behavior" in every case that isn't a
    /// fresh, present snapshot — absent, too old, or (fail-closed) stamped
    /// with a future `capturedAt`, which a trustworthy clock never produces.
    public static func freshScene(
        from snapshot: ScreenSnapshot?,
        now: Date,
        stalenessCapSeconds: TimeInterval = defaultStalenessCapSeconds,
        frontmostBundleID: String?,
        fieldText: String
    ) -> Scene? {
        guard let snapshot else { return nil }
        let observedAge = now.timeIntervalSince(snapshot.evidence.observedAt)
        let recognitionAge = now.timeIntervalSince(snapshot.evidence.recognizedAt)
        guard observedAge >= 0,
              recognitionAge >= 0,
              observedAge <= stalenessCapSeconds,
              recognitionAge <= stalenessCapSeconds else { return nil }
        return classify(snapshot: snapshot, frontmostBundleID: frontmostBundleID, fieldText: fieldText)
    }

    /// Pure conversion + classification, split out from `freshScene` so a
    /// caller that already knows its snapshot is fresh (or is testing
    /// classification in isolation) doesn't have to fake a clock.
    public static func classify(
        snapshot: ScreenSnapshot,
        frontmostBundleID: String?,
        fieldText: String
    ) -> Scene {
        classify(
            blocks: snapshot.blocks.map(OCRBlock.init(snapshotBlock:)),
            frontmostBundleID: frontmostBundleID,
            targetWindowIdentifier: snapshot.evidence.target?.windowIdentifier,
            fieldText: fieldText
        )
    }
}

extension ScreenScene.OCRBlock {
    /// Field-for-field: both types are top-left-origin, 0...1-normalized
    /// rects sharing one convention already (see this file's header), so
    /// there is no coordinate math here, only a type change.
    init(snapshotBlock: ScreenSnapshot.TextBlock) {
        self.init(
            text: snapshotBlock.text,
            boundingBox: ScreenScene.NormalizedRect(rect: snapshotBlock.boundingBox),
            windowOwnerBundleID: snapshotBlock.windowOwnerBundleIdentifier,
            windowIdentifier: snapshotBlock.windowIdentifier,
            windowTitle: snapshotBlock.windowTitle,
            windowFrame: snapshotBlock.windowFrame.map(ScreenScene.NormalizedRect.init(rect:)),
            confidence: snapshotBlock.confidence
        )
    }
}

extension ScreenScene.NormalizedRect {
    init(rect: NormalizedDisplayRect) {
        self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}

import Foundation
import Testing
@testable import TranscriptedWritingCore

@Suite("Capture change detector")
struct CaptureChangeDetectorTests {
    private let columns = 4
    private let rows = 3

    private func grid(_ tiles: [Double]) -> CaptureChangeDetector.LuminanceGrid {
        CaptureChangeDetector.LuminanceGrid(columns: columns, rows: rows, tiles: tiles)
    }

    private func flat(_ value: Double) -> [Double] {
        [Double](repeating: value, count: columns * rows)
    }

    private let windowGeometry = CaptureChangeDetector.GeometryKey(
        kind: .window,
        identity: "42",
        pixelWidth: 800,
        pixelHeight: 600
    )

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormalizedDisplayRect {
        NormalizedDisplayRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - decision: no previous frame / geometry mismatch → .full

    @Test("No previous grid forces a full recapture")
    func noPreviousGridForcesFull() {
        let decision = CaptureChangeDetector.decision(
            previousGrid: nil,
            previousGeometry: nil,
            currentGrid: grid(flat(0.5)),
            currentGeometry: windowGeometry
        )
        #expect(decision == .full)
    }

    @Test("Geometry mismatch (different identity) forces a full recapture even with an identical grid")
    func geometryMismatchForcesFull() {
        let otherWindow = CaptureChangeDetector.GeometryKey(
            kind: .window,
            identity: "99",
            pixelWidth: 800,
            pixelHeight: 600
        )
        let decision = CaptureChangeDetector.decision(
            previousGrid: grid(flat(0.5)),
            previousGeometry: windowGeometry,
            currentGrid: grid(flat(0.5)),
            currentGeometry: otherWindow
        )
        #expect(decision == .full)
    }

    @Test("Kind switch (window vs display) forces a full recapture even with matching identity/dimensions")
    func kindSwitchForcesFull() {
        let displayGeometry = CaptureChangeDetector.GeometryKey(
            kind: .display,
            identity: "42",
            pixelWidth: 800,
            pixelHeight: 600
        )
        let decision = CaptureChangeDetector.decision(
            previousGrid: grid(flat(0.5)),
            previousGeometry: windowGeometry,
            currentGrid: grid(flat(0.5)),
            currentGeometry: displayGeometry
        )
        #expect(decision == .full)
    }

    @Test("Dimension change forces a full recapture")
    func dimensionChangeForcesFull() {
        let resized = CaptureChangeDetector.GeometryKey(
            kind: .window,
            identity: "42",
            pixelWidth: 1024,
            pixelHeight: 768
        )
        let decision = CaptureChangeDetector.decision(
            previousGrid: grid(flat(0.5)),
            previousGeometry: windowGeometry,
            currentGrid: grid(flat(0.5)),
            currentGeometry: resized
        )
        #expect(decision == .full)
    }

    @Test("Mismatched grid shape (columns/rows) forces a full recapture")
    func gridShapeMismatchForcesFull() {
        let widerGrid = CaptureChangeDetector.LuminanceGrid(
            columns: columns + 1,
            rows: rows,
            tiles: [Double](repeating: 0.5, count: (columns + 1) * rows)
        )
        let decision = CaptureChangeDetector.decision(
            previousGrid: grid(flat(0.5)),
            previousGeometry: windowGeometry,
            currentGrid: widerGrid,
            currentGeometry: windowGeometry
        )
        #expect(decision == .full)
    }

    // MARK: - decision: unchanged

    @Test("Identical grids report unchanged")
    func identicalGridsAreUnchanged() {
        let decision = CaptureChangeDetector.decision(
            previousGrid: grid(flat(0.4)),
            previousGeometry: windowGeometry,
            currentGrid: grid(flat(0.4)),
            currentGeometry: windowGeometry
        )
        #expect(decision == .unchanged)
    }

    @Test("A per-tile delta strictly under the threshold reads as unchanged")
    func deltaUnderThresholdIsUnchanged() {
        var tiles = flat(0.5)
        tiles[0] = 0.5 + CaptureChangeDetector.tileChangeThreshold * 0.5
        let decision = CaptureChangeDetector.decision(
            previousGrid: grid(flat(0.5)),
            previousGeometry: windowGeometry,
            currentGrid: grid(tiles),
            currentGeometry: windowGeometry
        )
        #expect(decision == .unchanged)
    }

    @Test("A per-tile delta clearly over the threshold reads as changed")
    func deltaOverThresholdIsChanged() {
        var tiles = flat(0.5)
        tiles[0] = 0.5 + CaptureChangeDetector.tileChangeThreshold * 2
        let decision = CaptureChangeDetector.decision(
            previousGrid: grid(flat(0.5)),
            previousGeometry: windowGeometry,
            currentGrid: grid(tiles),
            currentGeometry: windowGeometry
        )
        #expect(decision != .unchanged)
    }

    // MARK: - decision: region (small, localized change)

    @Test("A single changed tile produces a padded region around it")
    func singleTileChangeProducesPaddedRegion() {
        // 4x3 grid; change the tile at column 2, row 1 (0-indexed).
        var tiles = flat(0.2)
        tiles[1 * columns + 2] = 0.2 + CaptureChangeDetector.tileChangeThreshold + 0.1
        let decision = CaptureChangeDetector.decision(
            previousGrid: grid(flat(0.2)),
            previousGeometry: windowGeometry,
            currentGrid: grid(tiles),
            currentGeometry: windowGeometry
        )
        guard case let .region(region) = decision else {
            Issue.record("expected .region, got \(decision)")
            return
        }
        // Padded by 1 tile on each side: columns 1...3, rows 0...2 (rows
        // clamp at the grid's own top/bottom edge).
        let tileWidth = 1.0 / Double(columns)
        let tileHeight = 1.0 / Double(rows)
        #expect(region.minX == 1 * tileWidth)
        #expect(region.maxX == 4 * tileWidth)
        #expect(region.minY == 0)
        #expect(region.maxY == 3 * tileHeight)
    }

    @Test("Region padding and geometry clamp exactly at the grid's edges")
    func paddingClampsAtEdges() {
        // Change the top-left corner tile — padding would push one tile
        // outside 0...0 on both axes, which must clamp rather than go negative.
        var tiles = flat(0.1)
        tiles[0] = 0.9
        let decision = CaptureChangeDetector.decision(
            previousGrid: grid(flat(0.1)),
            previousGeometry: windowGeometry,
            currentGrid: grid(tiles),
            currentGeometry: windowGeometry
        )
        guard case let .region(region) = decision else {
            Issue.record("expected .region, got \(decision)")
            return
        }
        #expect(region.minX == 0)
        #expect(region.minY == 0)
        #expect(region.maxX <= 1.0)
        #expect(region.maxY <= 1.0)
        #expect(region.minX >= 0)
        #expect(region.minY >= 0)
    }

    // MARK: - decision: full (mass change, e.g. scroll)

    @Test("A scroll-like mass change (most tiles moved) forces a full recapture, not a giant region")
    func massChangeForcesFull() {
        // Change every row except one -- comfortably past the 40% ceiling.
        var tiles = flat(0.1)
        for column in 0..<columns {
            tiles[0 * columns + column] = 0.9
            tiles[1 * columns + column] = 0.9
        }
        let decision = CaptureChangeDetector.decision(
            previousGrid: grid(flat(0.1)),
            previousGeometry: windowGeometry,
            currentGrid: grid(tiles),
            currentGeometry: windowGeometry
        )
        #expect(decision == .full)
    }

    @Test("Exactly at the full-frame change fraction still returns a region, not full")
    func exactlyAtFractionCeilingStaysRegion() {
        // 12 tiles total; 40% ceiling means up to 4 changed tiles (4/12 = 0.333) stays a region,
        // and changing tiles beyond that must eventually flip to .full. Use a contiguous block
        // of 4 tiles (33% -- comfortably under 40%) to prove the boundary itself is `<=`, not `<`.
        var tiles = flat(0.1)
        for index in 0..<4 {
            tiles[index] = 0.9
        }
        let changedFraction = 4.0 / Double(columns * rows)
        #expect(changedFraction <= CaptureChangeDetector.fullFrameChangeFraction)
        let decision = CaptureChangeDetector.decision(
            previousGrid: grid(flat(0.1)),
            previousGeometry: windowGeometry,
            currentGrid: grid(tiles),
            currentGeometry: windowGeometry
        )
        guard case .region = decision else {
            Issue.record("expected .region at or under the fraction ceiling, got \(decision)")
            return
        }
    }

    // MARK: - mergeBlocks

    private func block(
        text: String,
        _ x: Double,
        _ y: Double,
        _ w: Double,
        _ h: Double
    ) -> ScreenSnapshot.TextBlock {
        ScreenSnapshot.TextBlock(text: text, boundingBox: rect(x, y, w, h))
    }

    @Test("A previous block entirely outside the region is kept")
    func nonIntersectingPreviousBlockIsKept() {
        let previous = [block(text: "kept", 0.0, 0.0, 0.1, 0.1)]
        let region = rect(0.5, 0.5, 0.2, 0.2)
        let merged = CaptureChangeDetector.mergeBlocks(previousBlocks: previous, newBlocks: [], region: region)
        #expect(merged.map(\.text) == ["kept"])
    }

    @Test("A previous block fully inside the region is dropped")
    func fullyContainedPreviousBlockIsDropped() {
        let previous = [block(text: "stale", 0.55, 0.55, 0.05, 0.05)]
        let region = rect(0.5, 0.5, 0.2, 0.2)
        let merged = CaptureChangeDetector.mergeBlocks(previousBlocks: previous, newBlocks: [], region: region)
        #expect(merged.isEmpty)
    }

    @Test("A previous block that only straddles the region's boundary is dropped, not kept")
    func boundaryStraddlingPreviousBlockIsDropped() {
        // Block spans (0.45, 0.45)-(0.55, 0.55); region starts at (0.5, 0.5) --
        // they only overlap in a small corner, touching the region's edge.
        let previous = [block(text: "straddling", 0.45, 0.45, 0.10, 0.10)]
        let region = rect(0.5, 0.5, 0.2, 0.2)
        let merged = CaptureChangeDetector.mergeBlocks(previousBlocks: previous, newBlocks: [], region: region)
        #expect(merged.isEmpty)
    }

    @Test("A previous block that merely touches the region's edge (zero-area overlap) is dropped")
    func edgeTouchingPreviousBlockIsDropped() {
        // Block's right edge exactly meets the region's left edge.
        let previous = [block(text: "touching", 0.3, 0.5, 0.2, 0.1)]
        let region = rect(0.5, 0.5, 0.2, 0.2)
        let merged = CaptureChangeDetector.mergeBlocks(previousBlocks: previous, newBlocks: [], region: region)
        #expect(merged.isEmpty)
    }

    @Test("New blocks are always added, regardless of position")
    func newBlocksAreAlwaysAdded() {
        let newBlocks = [block(text: "fresh", 0.0, 0.0, 0.05, 0.05)]
        let region = rect(0.5, 0.5, 0.2, 0.2)
        let merged = CaptureChangeDetector.mergeBlocks(previousBlocks: [], newBlocks: newBlocks, region: region)
        #expect(merged.map(\.text) == ["fresh"])
    }

    @Test("Kept previous blocks and new blocks are combined, previous first")
    func keptAndNewBlocksAreCombined() {
        let previous = [block(text: "kept", 0.0, 0.0, 0.1, 0.1)]
        let newBlocks = [block(text: "fresh", 0.5, 0.5, 0.05, 0.05)]
        let region = rect(0.5, 0.5, 0.2, 0.2)
        let merged = CaptureChangeDetector.mergeBlocks(previousBlocks: previous, newBlocks: newBlocks, region: region)
        #expect(merged.map(\.text) == ["kept", "fresh"])
    }
}

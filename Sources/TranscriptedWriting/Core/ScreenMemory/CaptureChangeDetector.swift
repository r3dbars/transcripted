import Foundation

/// Decides how much of a captured frame actually needs re-OCRing, given a
/// coarse luminance grid of the previous frame. Pure and deterministic — no
/// CoreGraphics, no Vision, no ScreenCaptureKit — so the thresholds and the
/// region/merge math are provable without a live display, matching every
/// other Core type in this directory. `ScreenCaptureService` owns turning a
/// captured `CGImage` into a `LuminanceGrid` and acting on the `Decision`;
/// this type only compares grids and blocks.
public enum CaptureChangeDetector {
    /// A coarse brightness map of one captured frame: mean luminance (0...1)
    /// per tile, row-major, top-left origin — the same convention as
    /// `NormalizedDisplayRect`. Deliberately coarse (48x30 by default): fine
    /// enough to localize where a chat bubble or a new line of text
    /// appeared, coarse enough that computing and diffing it is orders of
    /// magnitude cheaper than the OCR pass it exists to gate.
    public struct LuminanceGrid: Equatable, Sendable {
        public static let defaultColumns = 48
        public static let defaultRows = 30

        public let columns: Int
        public let rows: Int
        /// row-major: `tiles[row * columns + column]`.
        public let tiles: [Double]

        public init(columns: Int, rows: Int, tiles: [Double]) {
            precondition(columns > 0 && rows > 0, "columns/rows must be positive")
            precondition(tiles.count == columns * rows, "tiles.count must equal columns * rows")
            self.columns = columns
            self.rows = rows
            self.tiles = tiles
        }
    }

    /// Identifies "the same thing being captured again" so a grid is never
    /// diffed against a frame it cannot be meaningfully compared to. A
    /// mismatch here — a different capture kind, a different window or
    /// display, or a resized capture — always forces `.full` rather than
    /// producing a region computed from two unrelated frames.
    public struct GeometryKey: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case window
            case display
        }

        public let kind: Kind
        /// Whatever uniquely identifies what is being captured within
        /// `kind` — a window id on the window path, a display id on the
        /// display path. Synthesized `Equatable` means two `nil` identities
        /// compare equal, so a caller that cannot establish a real identity
        /// should not persist a baseline for that capture at all rather than
        /// pass `nil` and rely on it comparing unequal to a later capture.
        public let identity: String?
        public let pixelWidth: Int
        public let pixelHeight: Int

        public init(kind: Kind, identity: String?, pixelWidth: Int, pixelHeight: Int) {
            self.kind = kind
            self.identity = identity
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
        }
    }

    public enum Decision: Equatable, Sendable {
        /// No tile moved past the threshold: the frame is current already
        /// and OCR can be skipped entirely.
        case unchanged
        /// Only this region (already padded and clamped to 0...1) needs
        /// re-OCRing; everything outside it is unchanged from the previous
        /// frame.
        case region(NormalizedDisplayRect)
        /// Re-OCR the whole frame: either too much changed for a region crop
        /// to be worth it, or there is nothing valid to diff against.
        case full
    }

    /// A tile's mean brightness must move by more than this to count as
    /// "changed". 0.02 (2% of full-scale brightness) comfortably clears the
    /// per-frame noise floor of capturing and downsampling normal UI content
    /// — subpixel anti-aliasing jitter, dithering, a blinking text caret —
    /// while still catching real content change: a new line of text or a
    /// highlighted row moves a 48x30 tile's mean brightness far more than
    /// 2% in practice. Kept deliberately small and one-sided in cost: a
    /// missed threshold (false negative) risks stale text, so it is cheaper
    /// to lean toward slightly over-detecting change than under-detecting it.
    public static let tileChangeThreshold: Double = 0.02

    /// Above this fraction of changed tiles, a bounding region already
    /// covers most of the frame, so OCRing the crop stops being cheaper
    /// than just OCRing everything — and the affine remap plus block-merge
    /// bookkeeping becomes pure overhead for no savings. 0.4 (40%) leaves
    /// wide headroom: a realistic "something changed" case (a new message,
    /// a menu opening, a cursor moving through a paragraph) is typically
    /// well under 10% of tiles, while scroll and window-resize/drag events
    /// — which legitimately invalidate most of the frame — blow well past
    /// 40%, which is exactly when a full recapture is both simpler and
    /// about as fast as a giant region crop would have been.
    public static let fullFrameChangeFraction: Double = 0.4

    /// Tiles of padding added around the union of changed tiles on every
    /// side, before clamping to 0...1. A run of OCR'd text frequently
    /// straddles a tile boundary; padding by a full tile keeps a
    /// partially-changed line from being clipped out of the region crop.
    public static let regionPaddingTiles: Int = 1

    /// Compares `currentGrid` against `previousGrid` and says how much of
    /// the frame needs re-OCRing. Falls back to `.full` whenever there is no
    /// previous grid, the geometry doesn't match (different capture kind,
    /// window/display identity, or pixel dimensions), or the grid shapes
    /// themselves don't line up — every one of these means "there is
    /// nothing safe to diff against", not "diff and get a wrong answer".
    public static func decision(
        previousGrid: LuminanceGrid?,
        previousGeometry: GeometryKey?,
        currentGrid: LuminanceGrid,
        currentGeometry: GeometryKey
    ) -> Decision {
        guard
            let previousGrid,
            let previousGeometry,
            previousGeometry == currentGeometry,
            previousGrid.columns == currentGrid.columns,
            previousGrid.rows == currentGrid.rows
        else {
            return .full
        }

        let columns = currentGrid.columns
        let rows = currentGrid.rows
        var minChangedCol = columns
        var maxChangedCol = -1
        var minChangedRow = rows
        var maxChangedRow = -1
        var changedCount = 0

        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                if abs(currentGrid.tiles[index] - previousGrid.tiles[index]) > tileChangeThreshold {
                    changedCount += 1
                    minChangedCol = min(minChangedCol, column)
                    maxChangedCol = max(maxChangedCol, column)
                    minChangedRow = min(minChangedRow, row)
                    maxChangedRow = max(maxChangedRow, row)
                }
            }
        }

        guard changedCount > 0 else { return .unchanged }

        let changedFraction = Double(changedCount) / Double(columns * rows)
        guard changedFraction <= fullFrameChangeFraction else { return .full }

        let paddedMinCol = max(0, minChangedCol - regionPaddingTiles)
        let paddedMinRow = max(0, minChangedRow - regionPaddingTiles)
        let paddedMaxCol = min(columns - 1, maxChangedCol + regionPaddingTiles)
        let paddedMaxRow = min(rows - 1, maxChangedRow + regionPaddingTiles)

        let tileWidth = 1.0 / Double(columns)
        let tileHeight = 1.0 / Double(rows)
        let rect = NormalizedDisplayRect(
            x: Double(paddedMinCol) * tileWidth,
            y: Double(paddedMinRow) * tileHeight,
            width: Double(paddedMaxCol - paddedMinCol + 1) * tileWidth,
            height: Double(paddedMaxRow - paddedMinRow + 1) * tileHeight
        )
        return .region(clamped(rect))
    }

    /// Clamps a rect's edges into 0...1. Padding is applied in whole tiles
    /// against the grid's own column/row bounds above, so this only guards
    /// against floating-point rounding pushing an edge a hair past 0 or 1.
    private static func clamped(_ rect: NormalizedDisplayRect) -> NormalizedDisplayRect {
        let minX = min(max(rect.minX, 0), 1)
        let minY = min(max(rect.minY, 0), 1)
        let maxX = min(max(rect.maxX, 0), 1)
        let maxY = min(max(rect.maxY, 0), 1)
        return NormalizedDisplayRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    // MARK: - Block merge

    /// Combines the previous snapshot's blocks with freshly OCR'd blocks
    /// after a region-scoped recapture, so downstream consumers still see a
    /// complete, current set of text blocks even though only `region` was
    /// actually re-OCR'd this time:
    /// - Previous blocks whose bounding box does NOT intersect `region` are
    ///   kept as-is — they sit outside what changed, so they are still
    ///   accurate.
    /// - Every new block is added unconditionally — it came from OCRing
    ///   `region` itself, so it is authoritative for whatever text is now
    ///   inside it, including cases where text that used to be there is
    ///   simply gone.
    ///
    /// The intersection test is boundary-inclusive: a previous block that
    /// only touches `region`'s edge is dropped, not kept, matching the
    /// region's own padding — both err toward re-covering a block that
    /// might have changed rather than trusting a stale one that sat right
    /// on the line.
    public static func mergeBlocks(
        previousBlocks: [ScreenSnapshot.TextBlock],
        newBlocks: [ScreenSnapshot.TextBlock],
        region: NormalizedDisplayRect
    ) -> [ScreenSnapshot.TextBlock] {
        let kept = previousBlocks.filter { !$0.boundingBox.intersects(region) }
        return kept + newBlocks
    }
}

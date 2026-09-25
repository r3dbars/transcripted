import Foundation

/// The exact field/window generation a Screen Memory read belongs to.
/// Plain integer identifiers keep Core free of AppKit/CoreGraphics while the
/// app target converts from `pid_t`/`CGWindowID` at the boundary.
public struct TypingTargetIdentity: Equatable, Sendable {
    public let bundleIdentifier: String?
    public let processIdentifier: Int32?
    public let windowIdentifier: UInt32?
    public let fieldSessionIdentifier: String
    public let generation: UInt64

    public init(
        bundleIdentifier: String?,
        processIdentifier: Int32?,
        windowIdentifier: UInt32?,
        fieldSessionIdentifier: String,
        generation: UInt64
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowIdentifier = windowIdentifier
        self.fieldSessionIdentifier = fieldSessionIdentifier
        self.generation = generation
    }

    /// Request-time comparison deliberately ignores the capture generation:
    /// the service owns that counter, while the IME/app can independently
    /// prove that the field session and exact OS window are still current.
    public func matchesWindowAndField(of other: Self) -> Bool {
        bundleIdentifier == other.bundleIdentifier
            && processIdentifier == other.processIdentifier
            && windowIdentifier == other.windowIdentifier
            && fieldSessionIdentifier == other.fieldSessionIdentifier
    }
}

public enum ScreenTextExtractionSource: String, Equatable, Sendable {
    case accessibility
    case visionFull
    case visionRegion
    case visionReused
    case unspecified
}

/// Provenance stays attached to text instead of flattening AX, fresh Vision,
/// and reused Vision into one indistinguishable timestamp.
public struct ScreenTextExtractionEvidence: Equatable, Sendable {
    public let source: ScreenTextExtractionSource
    public let completed: Bool
    public let confidence: Double
    public let observedAt: Date
    public let recognizedAt: Date
    public let reuseCount: Int
    public let target: TypingTargetIdentity?

    public init(
        source: ScreenTextExtractionSource,
        completed: Bool,
        confidence: Double,
        observedAt: Date,
        recognizedAt: Date,
        reuseCount: Int = 0,
        target: TypingTargetIdentity? = nil
    ) {
        self.source = source
        self.completed = completed
        self.confidence = min(1, max(0, confidence))
        self.observedAt = observedAt
        self.recognizedAt = recognizedAt
        self.reuseCount = max(0, reuseCount)
        self.target = target
    }

    public static func unspecified(at date: Date) -> Self {
        Self(
            source: .unspecified,
            completed: true,
            confidence: 1,
            observedAt: date,
            recognizedAt: date
        )
    }
}

/// A capture-space rectangle normalized to the full display, origin top-left,
/// (0,0)-(1,1). Deliberately not CGRect: Core stays free of CoreGraphics so
/// this type — and everything built on it — has no AppKit/CoreGraphics
/// dependency to carry into Phase 2's pure scene classifier.
public struct NormalizedDisplayRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= minX && px <= maxX && py >= minY && py <= maxY
    }

    /// Boundary-inclusive intersection: two rects that only touch along an
    /// edge (sharing a point or a line, zero-area overlap) still count as
    /// intersecting. `CaptureChangeDetector.mergeBlocks` relies on this —
    /// erring toward "intersects" for an edge-touching block matches the
    /// region's own one-tile padding, which exists precisely to avoid
    /// clipping a block that sits right on the boundary.
    public func intersects(_ other: NormalizedDisplayRect) -> Bool {
        minX <= other.maxX && maxX >= other.minX && minY <= other.maxY && maxY >= other.minY
    }
}

/// One on-device OCR pass over the full display, kept memory-only in Phase 1.
/// The app builds this from ScreenCaptureKit + Vision; Core stays a pure,
/// testable shape so Phase 2's scene classifier and Phase 3's redaction can
/// consume it without ever importing AppKit/Vision.
public struct ScreenSnapshot: Equatable, Sendable {
    /// One OCR-recognized run of text, attributed to the window it most
    /// likely belongs to (best-effort — attribution can be nil).
    public struct TextBlock: Equatable, Sendable {
        public let text: String
        public let boundingBox: NormalizedDisplayRect
        public let windowOwnerBundleIdentifier: String?
        /// Exact owner window when attribution succeeded. Bundle identity is
        /// insufficient when two Slack/Chrome windows are visible together.
        public let windowIdentifier: UInt32?
        public let windowTitle: String?
        /// The owning window's own frame, same normalized/display-relative
        /// space as `boundingBox` — `nil` exactly when attribution is `nil`.
        /// Phase 2's scene classifier needs this to bucket a message bubble
        /// as self/other by its position *within its window*, not within
        /// the display (see `ScreenScene.OCRBlock.windowFrame`).
        public let windowFrame: NormalizedDisplayRect?
        /// Vision candidate confidence. AX text is exact and records `1`;
        /// legacy/test blocks may leave this unknown.
        public let confidence: Double?

        public init(
            text: String,
            boundingBox: NormalizedDisplayRect,
            windowOwnerBundleIdentifier: String? = nil,
            windowIdentifier: UInt32? = nil,
            windowTitle: String? = nil,
            windowFrame: NormalizedDisplayRect? = nil,
            confidence: Double? = nil
        ) {
            self.text = text
            self.boundingBox = boundingBox
            self.windowOwnerBundleIdentifier = windowOwnerBundleIdentifier
            self.windowIdentifier = windowIdentifier
            self.windowTitle = windowTitle
            self.windowFrame = windowFrame
            self.confidence = confidence.map { min(1, max(0, $0)) }
        }
    }

    public let capturedAt: Date
    /// CGDirectDisplayID, kept as a plain UInt32 so Core never imports
    /// CoreGraphics' display headers for one integer.
    public let displayID: UInt32
    public let blocks: [TextBlock]
    public let evidence: ScreenTextExtractionEvidence

    public init(
        capturedAt: Date,
        displayID: UInt32,
        blocks: [TextBlock],
        evidence: ScreenTextExtractionEvidence? = nil
    ) {
        self.capturedAt = capturedAt
        self.displayID = displayID
        self.blocks = blocks
        self.evidence = evidence ?? .unspecified(at: capturedAt)
    }

    /// Every window bundle identifier this snapshot's text touched, deduped.
    /// This is what capture-time exclusion logic (and, later, redaction
    /// scoping) checks against — not just the frontmost app, since capture
    /// is full-display and can see windows behind the one in focus.
    public var ownerBundleIdentifiers: Set<String> {
        Set(blocks.compactMap(\.windowOwnerBundleIdentifier))
    }
}

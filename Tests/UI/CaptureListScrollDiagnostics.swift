import Foundation

/// Numeric/Boolean evidence only. Capture titles, paths and transcript text
/// never enter a record, even though the native fixture compares identities
/// locally.
struct CaptureListScrollDiagnosticRecord: Codable, Equatable {
    let phase: Int
    let step: Int
    let modelPublications: Int
    let visibleCount: Int
    let loadMoreCount: Int
    let canLoadMore: Bool
    let isLoadingMore: Bool
    let scrollAttached: Bool
    let scrollStillFirst: Bool
    let clipUnchanged: Bool
    let documentUnchanged: Bool
    let geometryFinite: Bool
    let documentHeightBefore: Double
    let viewportHeightBefore: Double
    let maximumY: Double
    let requestedY: Double
    let actualY: Double
    let documentHeightAfter: Double
    let viewportHeightAfter: Double
    let layoutDelta: Int

    init(
        phase: Int,
        step: Int,
        modelPublications: Int,
        visibleCount: Int,
        loadMoreCount: Int,
        canLoadMore: Bool,
        isLoadingMore: Bool,
        scrollAttached: Bool,
        scrollStillFirst: Bool,
        clipUnchanged: Bool,
        documentUnchanged: Bool,
        documentHeightBefore: Double,
        viewportHeightBefore: Double,
        maximumY: Double,
        requestedY: Double,
        actualY: Double,
        documentHeightAfter: Double,
        viewportHeightAfter: Double,
        layoutDelta: Int
    ) {
        self.phase = phase
        self.step = step
        self.modelPublications = modelPublications
        self.visibleCount = visibleCount
        self.loadMoreCount = loadMoreCount
        self.canLoadMore = canLoadMore
        self.isLoadingMore = isLoadingMore
        self.scrollAttached = scrollAttached
        self.scrollStillFirst = scrollStillFirst
        self.clipUnchanged = clipUnchanged
        self.documentUnchanged = documentUnchanged
        let geometry = [
            documentHeightBefore, viewportHeightBefore, maximumY,
            requestedY, actualY, documentHeightAfter, viewportHeightAfter
        ]
        geometryFinite = geometry.allSatisfy(\.isFinite)
        self.documentHeightBefore = documentHeightBefore.isFinite ? documentHeightBefore : 0
        self.viewportHeightBefore = viewportHeightBefore.isFinite ? viewportHeightBefore : 0
        self.maximumY = maximumY.isFinite ? maximumY : 0
        self.requestedY = requestedY.isFinite ? requestedY : 0
        self.actualY = actualY.isFinite ? actualY : 0
        self.documentHeightAfter = documentHeightAfter.isFinite ? documentHeightAfter : 0
        self.viewportHeightAfter = viewportHeightAfter.isFinite ? viewportHeightAfter : 0
        self.layoutDelta = layoutDelta
    }
}

struct CaptureListScrollDiagnosticHistory {
    static let capacity = 16
    private(set) var records: [CaptureListScrollDiagnosticRecord] = []

    mutating func append(_ record: CaptureListScrollDiagnosticRecord) {
        if records.count == Self.capacity { records.removeFirst() }
        records.append(record)
    }

    /// Only emitted when the existing scenario reports a failure.
    func json() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(records) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

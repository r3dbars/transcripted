import Foundation

func testCaptureListScrollDiagnostics() {
    runSuite("Capture-list Load More scroll diagnostics retain only the latest sixteen ordered records") {
        var history = CaptureListScrollDiagnosticHistory()
        for step in 0..<100 { history.append(captureListScrollDiagnosticFixture(step: step)) }
        assertEqual(history.records.count, 16)
        assertEqual(history.records.map(\.step), Array(84..<100))
        assertEqual(history.records.last?.visibleCount, 99)
    }
    runSuite("Capture-list Load More scroll diagnostics encode only bounded numeric and Boolean fields") {
        var history = CaptureListScrollDiagnosticHistory()
        for step in 0..<20 { history.append(captureListScrollDiagnosticFixture(step: step)) }
        guard let json = history.json(), let data = json.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            assertTrue(false, "the actual diagnostic records must encode")
            return
        }
        assertEqual(rows.count, 16)
        assertTrue(rows.allSatisfy { $0.values.allSatisfy { $0 is NSNumber } }, "there is no content-bearing string value")
        assertTrue(data.count < 16_384, "sixteen fixed-shape records stay within the bounded log payload")
    }
    runSuite("Unknown nonfinite capture-list scroll geometry remains distinguishable and encodable") {
        var history = CaptureListScrollDiagnosticHistory()
        history.append(captureListScrollDiagnosticFixture(step: 1, actualY: .nan))
        assertEqual(history.records.first?.geometryFinite, false)
        assertEqual(history.records.first?.actualY, 0)
        assertNotNil(history.json(), "unknown geometry cannot erase every diagnostic record")
        assertEqual(
            captureListScrollDiagnosticFixture(step: 2, actualY: -12).actualY,
            -12,
            "finite negative geometry is retained"
        )
    }
}

private func captureListScrollDiagnosticFixture(
    step: Int,
    actualY: Double = 1_360
) -> CaptureListScrollDiagnosticRecord {
    .init(
        phase: 1,
        step: step,
        modelPublications: step,
        visibleCount: step,
        loadMoreCount: step / 10,
        canLoadMore: true,
        isLoadingMore: false,
        scrollAttached: true,
        scrollStillFirst: true,
        clipUnchanged: true,
        documentUnchanged: true,
        documentHeightBefore: 10_000,
        viewportHeightBefore: 700,
        maximumY: 9_300,
        requestedY: 1_400,
        actualY: actualY,
        documentHeightAfter: 10_000,
        viewportHeightAfter: 700,
        layoutDelta: 2
    )
}

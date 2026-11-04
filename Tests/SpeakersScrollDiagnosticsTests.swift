import Foundation

func testSpeakersScrollDiagnostics() {
    runSuite("Scroll failure diagnostics retain only the latest sixteen ordered records") {
        var history = SpeakersScrollDiagnosticHistory()
        for step in 0..<100 { history.append(scrollDiagnosticFixture(step: step)) }
        assertEqual(history.records.count, 16)
        assertEqual(history.records.map(\.step), Array(84..<100))
        assertEqual(history.records.last?.modelPublications, 99)
    }
    runSuite("Scroll failure diagnostics encode only bounded numeric and Boolean fields") {
        var history = SpeakersScrollDiagnosticHistory()
        for step in 0..<20 { history.append(scrollDiagnosticFixture(step: step)) }
        guard let json = history.json(), let data = json.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            assertTrue(false, "the actual diagnostic records must encode")
            return
        }
        assertEqual(rows.count, 16)
        assertTrue(rows.allSatisfy { $0.values.allSatisfy { $0 is NSNumber } }, "there is no content-bearing string value")
        assertTrue(data.count < 16_384, "sixteen fixed-shape records stay within the bounded log payload")
    }
    runSuite("Unknown nonfinite scroll geometry remains distinguishable and encodable") {
        var history = SpeakersScrollDiagnosticHistory()
        history.append(scrollDiagnosticFixture(step: 1, actualY: .nan))
        assertEqual(history.records.first?.geometryFinite, false)
        assertEqual(history.records.first?.actualY, 0)
        assertNotNil(history.json(), "unknown geometry cannot erase every diagnostic record")
        assertEqual(scrollDiagnosticFixture(step: 2, actualY: -12).actualY, -12, "finite negative geometry is retained")
    }
}

private func scrollDiagnosticFixture(step: Int, actualY: Double = 1_360) -> SpeakersScrollDiagnosticRecord {
    .init(phase: 1, step: step, modelPublications: step, profileCount: 140,
          directoryCount: 137, reviewCount: 6, profileOrderUnchanged: true,
          directoryOrderUnchanged: true, reviewOrderUnchanged: true, scrollAttached: true,
          scrollStillFirst: true, clipUnchanged: true, documentUnchanged: true,
          documentHeightBefore: 10_000, viewportHeightBefore: 700,
          maximumY: 9_300, requestedY: 1_400, actualY: actualY,
          documentHeightAfter: 10_000, viewportHeightAfter: 700, layoutDelta: 2)
}

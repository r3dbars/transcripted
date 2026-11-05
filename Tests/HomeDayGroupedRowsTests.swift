import Foundation

func testHomeDayGroupedRows() {
    func itemID(_ value: String) -> AnyHashable { AnyHashable(value) }

    func ids(for items: [String]) -> [AnyHashable] {
        items.enumerated().map { offset, item in
            HomeDayGroupedRows.rowID(offset: offset, item: item, id: itemID)
        }
    }

    runSuite("Load More that appends older rows keeps earlier row IDs and never keys a row by its offset") {
        let firstPage = ["alpha", "bravo", "charlie"]
        let afterLoadMore = ["alpha", "bravo", "charlie", "delta", "echo"]
        let firstIDs = ids(for: firstPage)
        let nextIDs = ids(for: afterLoadMore)

        assertEqual(
            Array(nextIDs.prefix(firstIDs.count)),
            firstIDs,
            "rows already on screen keep the same identity after Load More appends older ones"
        )
        assertEqual(
            nextIDs,
            afterLoadMore.map(itemID),
            "each row's ForEach identity is the item's own id, not its offset in the page"
        )
        for (offset, item) in afterLoadMore.enumerated() {
            let rowID = HomeDayGroupedRows.rowID(offset: offset, item: item, id: itemID)
            assertFalse(
                rowID == AnyHashable(offset),
                "row \(item) must not be keyed by offset \(offset)"
            )
        }
    }

    runSuite("Prepending a newer row does not rename the identities of rows already on screen") {
        let alreadyShown = ["bravo", "charlie"]
        let afterNewerSave = ["alpha", "bravo", "charlie"]
        assertEqual(
            Array(ids(for: afterNewerSave).dropFirst()),
            ids(for: alreadyShown),
            "a newer row at the top must not steal the offsets of the rows that were already listed"
        )
    }

    runSuite("Rows in two day sections never share an identity just because they share an offset") {
        let monday = ["morning-sync", "afternoon-sync"]
        let tuesday = ["standup", "retro"]
        let combined = ids(for: monday) + ids(for: tuesday)
        assertEqual(
            Set(combined).count,
            monday.count + tuesday.count,
            "offset 0 on Tuesday is a different capture from offset 0 on Monday"
        )
    }

    runSuite("Day-grouped rows keep the item and only draw a divider between neighbors") {
        let items = ["one", "two", "three"]
        let rows = HomeDayGroupedRows.make(items: items, id: itemID, showsRowDividers: true)
        assertEqual(rows.map(\.item), items)
        assertEqual(rows.map(\.showsDividerAfter), [true, true, false])
        assertEqual(rows.map(\.id), items.map(itemID))

        let undivided = HomeDayGroupedRows.make(items: items, id: itemID, showsRowDividers: false)
        assertEqual(undivided.map(\.showsDividerAfter), [false, false, false])
    }
}

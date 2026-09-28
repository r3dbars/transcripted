import AppKit
import Foundation

private final class StubComboBoxDataSource: NSObject, NSComboBoxDataSource {
    let items: [String]

    init(items: [String]) {
        self.items = items
    }

    func numberOfItems(in comboBox: NSComboBox) -> Int {
        items.count
    }

    func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
        items.indices.contains(index) ? items[index] : nil
    }
}

@MainActor
func testRetainedDataSourceComboBox() async {
    runSuite("RetainedDataSourceComboBox keeps its data source alive after the caller lets go") {
        let combo = RetainedDataSourceComboBox()
        weak var weakSource: StubComboBoxDataSource?
        do {
            let source = StubComboBoxDataSource(items: ["Ada", "Grace"])
            weakSource = source
            combo.setRetainedDataSource(source)
        }

        assertNotNil(weakSource, "AppKit only keeps an unretained pointer, so the box must own its data source")
        assertTrue(combo.usesDataSource, "installing a data source should switch the box to data source mode")
        assertTrue(combo.dataSource === weakSource, "AppKit should see the retained data source")
        assertEqual(combo.numberOfItems, 2, "the box should still read items from the retained data source")
    }

    runSuite("Speaker name boxes never hand AppKit an unretained data source") {
        let sheet = readSourceFixture("Sources/UI/Settings/SpeakerNamingSheet.swift")
        let field = readSourceFixture("Sources/UI/Settings/SpeakerNameAutocompleteField.swift")
        for (label, source) in [("naming sheet", sheet), ("autocomplete field", field)] {
            assertFalse(
                source.contains(".dataSource = "),
                "\(label) should install its data source with setRetainedDataSource, not a raw assign"
            )
            assertTrue(
                source.contains("setRetainedDataSource("),
                "\(label) should use RetainedDataSourceComboBox's retained data source"
            )
        }
        assertFalse(
            sheet.contains("extension SpeakerRowView: NSComboBoxDataSource"),
            "the row owns its name box, so the box must not point back at the row as data source"
        )
    }
}

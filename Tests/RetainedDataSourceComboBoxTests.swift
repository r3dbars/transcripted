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

    runSuite("A plain dataSource assignment also keeps the source alive") {
        let combo = RetainedDataSourceComboBox()
        combo.usesDataSource = true
        weak var weakSource: StubComboBoxDataSource?
        do {
            let source = StubComboBoxDataSource(items: ["Ada"])
            weakSource = source
            combo.dataSource = source
        }
        assertNotNil(weakSource, "a speaker name box can't be handed an unretained data source, however it's set")
        assertEqual(combo.numberOfItems, 1, "the box still reads from it")

        weak var weakReplacement: StubComboBoxDataSource?
        do {
            let replacement = StubComboBoxDataSource(items: ["Grace", "Linus"])
            weakReplacement = replacement
            combo.setRetainedDataSource(replacement)
        }
        assertNil(weakSource, "a replaced source is let go")
        assertNotNil(weakReplacement, "the new one is kept")
        combo.reloadData()
        assertEqual(combo.numberOfItems, 2, "the box reads the new source")
    }
}

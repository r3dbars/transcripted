import AppKit

/// `NSComboBox.dataSource` is `assign` in AppKit (unsafe, not weak). If the
/// object behind it is freed while the box can still receive keystrokes, the
/// next edit makes `-[NSComboBoxCell _complete:]` message freed memory and the
/// app crashes (Sentry APPLE-MACOS-2H: deleting text in a speaker name box).
///
/// This subclass keeps its data source alive for as long as the box itself
/// lives, so the pointer AppKit holds can never dangle. A data source set here
/// must not hold the box, or a view that owns the box, strongly.
class RetainedDataSourceComboBox: NSComboBox {
    private var retainedDataSource: (any NSComboBoxDataSource)?

    /// Installs `source` as the box's data source and keeps it alive.
    func setRetainedDataSource(_ source: (any NSComboBoxDataSource)?) {
        retainedDataSource = source
        usesDataSource = source != nil
        dataSource = source
    }
}

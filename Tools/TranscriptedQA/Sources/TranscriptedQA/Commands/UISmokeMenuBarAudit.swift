import Foundation

struct MenuBarAuditTarget: Equatable {
    let identifier: String
    let requiresEnabled: Bool?

    init(_ identifier: String, requiresEnabled: Bool? = true) {
        self.identifier = identifier
        self.requiresEnabled = requiresEnabled
    }
}

struct MenuBarAuditRow: Equatable {
    let rowNumber: Int
    let title: String
    let targets: [MenuBarAuditTarget]
    let minimumHitSize: Double

    var checkID: String { "menu-audit-row-\(rowNumber)" }
    var targetSummary: String { targets.map(\.identifier).joined(separator: ", ") }

    static let manualProofTailRows: [MenuBarAuditRow] = [
        MenuBarAuditRow(
            rowNumber: 25,
            title: "Audit row 25: Start Dictation menu action is visible, enabled, and 40pt",
            targets: [
                MenuBarAuditTarget("transcripted.menubar.primary.start-dictation"),
            ],
            minimumHitSize: 40
        ),
        MenuBarAuditRow(
            rowNumber: 27,
            title: "Audit row 27: Start Meeting menu action is visible, enabled, and 40pt",
            targets: [
                MenuBarAuditTarget("transcripted.menubar.primary.start-meeting"),
            ],
            minimumHitSize: 40
        ),
        MenuBarAuditRow(
            rowNumber: 31,
            title: "Audit row 31: menu utility actions are visible, enabled, and 40pt",
            targets: [
                MenuBarAuditTarget("transcripted.menubar.utility.open-transcripted"),
                MenuBarAuditTarget("transcripted.menubar.utility.check-updates", requiresEnabled: nil),
                MenuBarAuditTarget("transcripted.menubar.utility.quit"),
            ],
            minimumHitSize: 40
        ),
    ]

    struct Failure: Equatable {
        let checkID: String
        let title: String
        let target: String
        let detail: String
    }

    static func firstFailure(in observed: [AXObservedElement], rows: [MenuBarAuditRow] = manualProofTailRows) -> Failure? {
        let observedByIdentifier = Dictionary(uniqueKeysWithValues: observed.compactMap { element -> (String, AXObservedElement)? in
            guard let identifier = element.identifier else { return nil }
            return (identifier, element)
        })

        for row in rows {
            for target in row.targets {
                guard let element = observedByIdentifier[target.identifier] else {
                    return Failure(
                        checkID: row.checkID,
                        title: row.title,
                        target: target.identifier,
                        detail: "Expected menu action identifier was missing from the AX tree."
                    )
                }
                if let requiresEnabled = target.requiresEnabled, element.isEnabled != requiresEnabled {
                    return Failure(
                        checkID: row.checkID,
                        title: row.title,
                        target: target.identifier,
                        detail: "Expected AXEnabled=\(requiresEnabled), got \(String(describing: element.isEnabled))."
                    )
                }
                guard let frame = element.frame else {
                    return Failure(
                        checkID: row.checkID,
                        title: row.title,
                        target: target.identifier,
                        detail: "Expected a readable AX frame for hit-target proof."
                    )
                }
                if frame.width < row.minimumHitSize || frame.height < row.minimumHitSize {
                    return Failure(
                        checkID: row.checkID,
                        title: row.title,
                        target: target.identifier,
                        detail: "Expected at least \(Int(row.minimumHitSize))x\(Int(row.minimumHitSize))pt hit target, got \(Int(frame.width))x\(Int(frame.height))pt."
                    )
                }
            }
        }
        return nil
    }
}

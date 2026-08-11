import AppKit
import SwiftUI

struct AutoEnterAppCandidate: Identifiable, Equatable {
    let bundleID: String
    let name: String

    var id: String { bundleID }

    static func runningApps() -> [AutoEnterAppCandidate] {
        let transcriptedBundleID = Bundle.main.bundleIdentifier
        let candidates = NSWorkspace.shared.runningApplications.compactMap { app -> AutoEnterAppCandidate? in
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  bundleID != transcriptedBundleID else {
                return nil
            }

            return AutoEnterAppCandidate(
                bundleID: bundleID,
                name: app.localizedName ?? bundleID
            )
        }

        var seen = Set<String>()
        return candidates
            .filter { seen.insert($0.bundleID).inserted }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

struct CorrectionDraftRow: Identifiable, Equatable {
    let id: UUID
    var spoken: String
    var replacement: String

    init(id: UUID = UUID(), spoken: String = "", replacement: String = "") {
        self.id = id
        self.spoken = spoken
        self.replacement = replacement
    }

    init(entry: CustomDictionaryEntry) {
        self.init(spoken: entry.spoken, replacement: entry.replacement)
    }

    static func rows(from rawText: String) -> [CorrectionDraftRow] {
        let rows = CustomDictionaryPreferences.entries(from: rawText).map(CorrectionDraftRow.init(entry:))
        return rows.isEmpty ? [CorrectionDraftRow()] : rows
    }

    static func rawText(from rows: [CorrectionDraftRow]) -> String {
        rows.compactMap { row in
            let spoken = row.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacement = row.replacement.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !spoken.isEmpty else { return nil }
            if replacement.isEmpty || replacement == spoken {
                return spoken
            }
            return "\(spoken) -> \(replacement)"
        }
        .joined(separator: "\n")
    }
}

struct CorrectionEditorRow: View {
    @Binding var spoken: String
    @Binding var replacement: String
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            TextField("okay ours", text: $spoken)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("Mistake"))

            TextField("OKRs", text: $replacement)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(Text("Fix"))

            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(SettingsHoverButtonStyle(tone: .destructive, cornerRadius: 7))
            .accessibilityLabel(Text("Remove correction"))
            .help("Remove this correction.")
        }
    }
}


import Foundation

public enum LegacyAgentFolderCleanup {
    private static let legacyHelperFilenames = ["CLAUDE.md", "AGENT.md"]

    /// Remove historical helper docs that used to be dropped into the meetings folder.
    public static func removeLegacyHelperFiles(from folder: URL) {
        let fm = FileManager.default
        for filename in legacyHelperFilenames {
            let fileURL = folder.appendingPathComponent(filename)
            guard fm.fileExists(atPath: fileURL.path) else { continue }
            try? fm.removeItem(at: fileURL)
        }
    }
}

import Foundation
import XCTest

enum SpeakerMigrationFixtureCleanup {
    static func remove(_ root: URL) {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.resolvingSymlinksInPath()
        let prefix = "voiceprint-migration-"
        let resolved = root.resolvingSymlinksInPath()
        guard root.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil,
              resolved.deletingLastPathComponent() == temporaryRoot,
              resolved.lastPathComponent == root.lastPathComponent else {
            XCTFail("refusing to remove a migration fixture outside its owned temporary root")
            return
        }
        guard fileManager.fileExists(atPath: root.path) else { return }
        do {
            try fileManager.removeItem(at: root)
        } catch {
            XCTFail("owned migration fixture cleanup failed")
        }
    }
}

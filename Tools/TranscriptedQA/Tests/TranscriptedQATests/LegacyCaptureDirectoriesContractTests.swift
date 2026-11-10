import XCTest
import TranscriptedCaptureKit
@testable import transcripted_qa

/// Drift guard for the legacy Draft/legacy-shared capture-directory layout.
///
/// `QADataDirectories.resolve(meetingsDir:...)` used to hardcode its own copy
/// of the legacy Draft (`~/Library/Application Support/Draft/...`) and
/// legacy-shared (`~/Documents/Transcripted`) paths to infer a matching
/// state/log layout when a caller passes an explicit `--path`. That copy
/// drifted from `CaptureLibraryResolver`'s legacy-fallback list before (see
/// `a5a766cc`, `b2b54268`). QA now derives its legacy roots from
/// `CaptureLibraryResolver.legacyCaptureDirectories(homeDirectory:)` instead
/// of re-declaring them — this test proves an explicit `--path` pointing at
/// each of those resolver-vended legacy locations is still recognized and
/// resolved to the matching sibling directories, so a future reintroduction
/// of a hand-rolled copy that falls out of sync fails here instead of
/// shipping silently.
final class LegacyCaptureDirectoriesContractTests: XCTestCase {
    private var home: URL!
    private var ownedParent: URL!

    override func setUpWithError() throws {
        ownedParent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        home = ownedParent
            .appendingPathComponent("LegacyCaptureDirectoriesContractTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        guard let home, let ownedParent else { return }
        let prefix = "LegacyCaptureDirectoriesContractTests-"
        let leaf = home.lastPathComponent
        let canonical = home.resolvingSymlinksInPath().standardizedFileURL
        guard leaf.hasPrefix(prefix), UUID(uuidString: String(leaf.dropFirst(prefix.count))) != nil,
              canonical.deletingLastPathComponent() == ownedParent,
              canonical == home.standardizedFileURL,
              try home.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try home.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw NSError(domain: "LegacyCaptureDirectoriesContractTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Refusing fixture cleanup outside its owned UUID directory"])
        }
        try FileManager.default.removeItem(at: home)
    }

    func testExplicitDraftMeetingsPathResolvesToDraftLayout() {
        let legacy = CaptureLibraryResolver.legacyCaptureDirectories(homeDirectory: home)

        let resolved = QADataDirectories.resolve(
            meetingsDir: legacy.draftMeetings.path,
            homeDirectory: home,
            environment: [:]
        )

        XCTAssertEqual(
            resolved.meetingsDir.standardizedFileURL.path,
            legacy.draftMeetings.standardizedFileURL.path,
            "explicit --path at the resolver's legacy Draft meetings folder should resolve unchanged"
        )
        XCTAssertEqual(
            resolved.dictationsDir.standardizedFileURL.path,
            legacy.draftDictations.standardizedFileURL.path,
            "QA should infer the resolver's legacy Draft dictations folder as the sibling directory"
        )
        XCTAssertEqual(
            resolved.stateDir.standardizedFileURL.path,
            legacy.draftRoot.appendingPathComponent("meetings", isDirectory: true).standardizedFileURL.path,
            "QA should infer the Draft-era state directory from the resolver's legacy Draft root"
        )
    }

    func testExplicitLegacySharedPathResolvesToSharedLayout() {
        let legacy = CaptureLibraryResolver.legacyCaptureDirectories(homeDirectory: home)

        let resolved = QADataDirectories.resolve(
            meetingsDir: legacy.sharedRoot.path,
            homeDirectory: home,
            environment: [:]
        )

        XCTAssertEqual(
            resolved.meetingsDir.standardizedFileURL.path,
            legacy.sharedRoot.standardizedFileURL.path,
            "explicit --path at the resolver's legacy shared folder should resolve unchanged"
        )
        XCTAssertEqual(
            resolved.stateDir.standardizedFileURL.path,
            legacy.sharedRoot.standardizedFileURL.path,
            "QA should infer the legacy shared folder itself as the state directory, matching the resolver's list"
        )
    }

    func testSiblingOfLegacySharedPathKeepsCurrentLayout() {
        let legacy = CaptureLibraryResolver.legacyCaptureDirectories(homeDirectory: home)
        let sibling = legacy.sharedRoot.deletingLastPathComponent()
            .appendingPathComponent("Transcripted Backup", isDirectory: true)
            .appendingPathComponent("meetings", isDirectory: true)

        let resolved = QADataDirectories.resolve(
            meetingsDir: sibling.path,
            homeDirectory: home,
            environment: [:]
        )

        let currentState = home.standardizedFileURL
            .appendingPathComponent("Library/Application Support/Transcripted/state", isDirectory: true)
        XCTAssertEqual(
            resolved.stateDir.standardizedFileURL.path,
            currentState.standardizedFileURL.path,
            "a folder that only shares a name prefix with the legacy shared folder must not inherit its layout"
        )
    }
    func testLegacyNamePrefixSiblingsKeepCurrentStateAndLogs() {
        let legacy = CaptureLibraryResolver.legacyCaptureDirectories(homeDirectory: home)
        let current = home.appendingPathComponent("Library/Application Support/Transcripted", isDirectory: true)
        for root in [legacy.sharedRoot, legacy.draftRoot.appendingPathComponent("meetings", isDirectory: true)] {
            let sibling = URL(fileURLWithPath: root.path + " Backup", isDirectory: true)
                .appendingPathComponent("meetings", isDirectory: true)
            let resolved = QADataDirectories.resolve(meetingsDir: sibling.path, homeDirectory: home, environment: [:])
            XCTAssertEqual(resolved.meetingsDir.path, sibling.path, "the explicit meetings path must remain unchanged")
            XCTAssertEqual(resolved.stateDir.path, current.appendingPathComponent("state").path,
                           "a legacy-name sibling must keep current state layout")
            XCTAssertEqual(resolved.logFilePath, current.appendingPathComponent("logs/app.jsonl").path,
                           "a legacy-name sibling must keep current logs")
            XCTAssertEqual(resolved.dictationsDir.path, sibling.deletingLastPathComponent().appendingPathComponent("dictations").path)
        }
    }

    func testCurrentLayoutNamePrefixSiblingsKeepTheirOwnDictationChild() {
        let current = home.appendingPathComponent("Library/Application Support/Transcripted", isDirectory: true)
        for root in [current.appendingPathComponent("captures/meetings"), current.appendingPathComponent("state")] {
            let sibling = URL(fileURLWithPath: root.path + " Backup", isDirectory: true)
            let resolved = QADataDirectories.resolve(meetingsDir: sibling.path, homeDirectory: home, environment: [:])
            XCTAssertEqual(resolved.dictationsDir.path, sibling.appendingPathComponent("dictations").path,
                           "a current-layout prefix sibling must not borrow the default dictations directory")
        }
    }

    func testRealLegacyDescendantsStillInheritLegacyStateAndLogs() {
        let legacy = CaptureLibraryResolver.legacyCaptureDirectories(homeDirectory: home)
        let draftState = legacy.draftRoot.appendingPathComponent("meetings", isDirectory: true)
        for root in [legacy.sharedRoot, draftState] {
            let descendant = root.appendingPathComponent("owned-nested-captures", isDirectory: true)
            let resolved = QADataDirectories.resolve(meetingsDir: descendant.path, homeDirectory: home, environment: [:])
            XCTAssertEqual(resolved.meetingsDir.path, descendant.path)
            XCTAssertEqual(resolved.stateDir.path, root.path, "a genuine legacy descendant must retain its legacy layout")
            XCTAssertEqual(resolved.logFilePath, home.appendingPathComponent("Library/Logs/Transcripted/app.jsonl").path)
        }
    }

    func testExplicitStateLogAndDictationOverridesStillWinForLegacyPath() {
        let legacy = CaptureLibraryResolver.legacyCaptureDirectories(homeDirectory: home)
        let overrides = home.appendingPathComponent("explicit-overrides", isDirectory: true)
        let resolved = QADataDirectories.resolve(
            meetingsDir: legacy.sharedRoot.path,
            dictationsDir: overrides.appendingPathComponent("dictations").path,
            stateDir: overrides.appendingPathComponent("state").path,
            logPath: overrides.appendingPathComponent("synthetic.jsonl").path,
            homeDirectory: home,
            environment: [:]
        )
        XCTAssertEqual(resolved.meetingsDir.path, legacy.sharedRoot.path)
        XCTAssertEqual(resolved.dictationsDir.path, overrides.appendingPathComponent("dictations").path)
        XCTAssertEqual(resolved.stateDir.path, overrides.appendingPathComponent("state").path)
        XCTAssertEqual(resolved.logFilePath, overrides.appendingPathComponent("synthetic.jsonl").path)
    }

}

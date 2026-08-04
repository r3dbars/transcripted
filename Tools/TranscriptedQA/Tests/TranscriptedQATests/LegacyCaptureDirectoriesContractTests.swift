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

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyCaptureDirectoriesContractTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let home {
            try? FileManager.default.removeItem(at: home)
        }
    }

    func testExplicitDraftMeetingsPathResolvesToDraftLayout() {
        let legacy = CaptureLibraryResolver.legacyCaptureDirectories(homeDirectory: home)

        let resolved = QADataDirectories.resolve(
            meetingsDir: legacy.draftMeetings.path,
            homeDirectory: home
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
            homeDirectory: home
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
}

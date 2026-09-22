import Foundation
import XCTest
@testable import transcripted_cli

final class CLIModelPathsTests: XCTestCase {
    func testRelocatedContainingAppComesBeforeInstalledApp() {
        let app = URL(fileURLWithPath: "/tmp/Release Candidate/Renamed.app", isDirectory: true)
        let paths = CLIModelPaths.bundledResourceDirectories(
            executableURL: app.appendingPathComponent("Contents/Helpers/transcripted-cli"),
            homeDirectory: URL(fileURLWithPath: "/tmp/isolated-home")
        )
        XCTAssertEqual(paths.map(\.path), [
            app.resolvingSymlinksInPath().appendingPathComponent("Contents/Resources").path,
            "/Applications/Transcripted.app/Contents/Resources",
            "/tmp/isolated-home/Applications/Transcripted.app/Contents/Resources",
        ])
    }

    func testStandaloneExecutableDoesNotTreatCheckoutAsAppResources() {
        let paths = CLIModelPaths.bundledResourceDirectories(
            executableURL: URL(fileURLWithPath: "/tmp/checkout/.build/release/transcripted-cli"),
            homeDirectory: URL(fileURLWithPath: "/tmp/isolated-home")
        )
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(paths.first?.path, "/Applications/Transcripted.app/Contents/Resources")
        XCTAssertFalse(paths.contains { $0.path.contains("checkout") })
    }

    func testHelpersDirectoryOutsideAppDoesNotSupplyModels() {
        let paths = CLIModelPaths.bundledResourceDirectories(
            executableURL: URL(fileURLWithPath: "/tmp/not-an-app/Contents/Helpers/transcripted-cli")
        )
        XCTAssertFalse(paths.contains { $0.path.contains("not-an-app") })
    }

    func testSymlinkedHelperResolvesItsOriginalApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CLIModelPaths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("Relocated.app/Contents/Helpers/transcripted-cli")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: executable)
        let link = root.appendingPathComponent("cli-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        let paths = CLIModelPaths.bundledResourceDirectories(executableURL: link)
        XCTAssertEqual(paths.first, root.resolvingSymlinksInPath().appendingPathComponent("Relocated.app/Contents/Resources", isDirectory: true))
    }

    func testInstalledAppIsNotListedTwice() {
        let paths = CLIModelPaths.bundledResourceDirectories(
            executableURL: URL(fileURLWithPath: "/Applications/Transcripted.app/Contents/Helpers/transcripted-cli")
        )
        XCTAssertEqual(paths.filter { $0.path == "/Applications/Transcripted.app/Contents/Resources" }.count, 1)
    }

    func testExecutablePathIsAbsoluteAndDoesNotDependOnWorkingDirectory() throws {
        let executable = try XCTUnwrap(CLIModelPaths.executableURL)
        XCTAssertTrue(executable.path.hasPrefix("/"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
    }
}

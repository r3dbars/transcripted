import XCTest
@testable import TranscriptedCore

/// Pins the behaviour of `TranscriptSaver.defaultSaveDirectory` so a future revert
/// of the markdown-first storage refactor is loud. Pre-refactor, a custom
/// `transcriptSaveLocation` was used as the literal save directory; post-refactor it
/// is treated as a capture-library root and meetings land under `<custom>/meetings`.
@available(macOS 14.0, *)
final class TranscriptSaverDefaultSaveDirectoryTests: XCTestCase {

    private let preferenceKey = "transcriptSaveLocation"
    private var originalPreference: Any?

    override func setUp() {
        super.setUp()
        originalPreference = UserDefaults.standard.object(forKey: preferenceKey)
        UserDefaults.standard.removeObject(forKey: preferenceKey)
    }

    override func tearDown() {
        if let originalPreference {
            UserDefaults.standard.set(originalPreference, forKey: preferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: preferenceKey)
        }
        super.tearDown()
    }

    func testReturnsDefaultTranscriptsWhenNoCustomPathSet() {
        XCTAssertEqual(
            TranscriptSaver.defaultSaveDirectory,
            CoreStoragePaths.default.transcripts
        )
    }

    func testReturnsDefaultTranscriptsWhenCustomPathIsBlank() {
        UserDefaults.standard.set("   ", forKey: preferenceKey)

        XCTAssertEqual(
            TranscriptSaver.defaultSaveDirectory,
            CoreStoragePaths.default.transcripts
        )
    }

    func testCustomAbsolutePathAppendsMeetingsSubdirectory() {
        let customRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptSaverDefaultSaveDirectoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: customRoot) }
        try? FileManager.default.createDirectory(at: customRoot, withIntermediateDirectories: true)

        UserDefaults.standard.set(customRoot.path, forKey: preferenceKey)

        XCTAssertEqual(
            TranscriptSaver.defaultSaveDirectory,
            customRoot.appendingPathComponent("meetings", isDirectory: true)
        )
    }

    func testRelativeCustomPathFallsBackToDefault() {
        UserDefaults.standard.set("relative/path", forKey: preferenceKey)

        XCTAssertEqual(
            TranscriptSaver.defaultSaveDirectory,
            CoreStoragePaths.default.transcripts
        )
    }

    func testTraversalCustomPathFallsBackToDefault() {
        UserDefaults.standard.set("/Users/someone/../../etc/passwd", forKey: preferenceKey)

        XCTAssertEqual(
            TranscriptSaver.defaultSaveDirectory,
            CoreStoragePaths.default.transcripts
        )
    }

    func testSystemCustomPathFallsBackToDefault() {
        UserDefaults.standard.set("/System/Library/Transcripted", forKey: preferenceKey)

        XCTAssertEqual(
            TranscriptSaver.defaultSaveDirectory,
            CoreStoragePaths.default.transcripts
        )
    }
}

import XCTest
@testable import TranscriptedCore

/// Pins how `RecordingValidator` resolves the directory it probes for disk space
/// and write permissions. The markdown-first refactor treats the
/// `transcriptSaveLocation` preference as a capture-library root, so the validator
/// must probe `<custom>/meetings`, not the bare custom path — otherwise the
/// permission preflight file ends up in the wrong directory.
@available(macOS 14.0, *)
final class RecordingValidatorResolvedSaveDirectoryTests: XCTestCase {

    private let preferenceKey = "transcriptSaveLocation"
    private var originalPreference: Any?
    private var paths: CoreStoragePaths!

    override func setUp() {
        super.setUp()
        originalPreference = UserDefaults.standard.object(forKey: preferenceKey)
        UserDefaults.standard.removeObject(forKey: preferenceKey)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingValidatorResolvedSaveDirectoryTests-\(UUID().uuidString)", isDirectory: true)
        paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("transcripts"),
            speakerDB: root.appendingPathComponent("s.sqlite"),
            statsDB: root.appendingPathComponent("st.sqlite"),
            failedQueue: root.appendingPathComponent("fq.json"),
            speakerClips: root.appendingPathComponent("clips"),
            audioCaptures: root.appendingPathComponent("caps"),
            logs: root.appendingPathComponent("logs")
        )
    }

    override func tearDown() {
        if let originalPreference {
            UserDefaults.standard.set(originalPreference, forKey: preferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: preferenceKey)
        }
        super.tearDown()
    }

    func testReturnsPathsTranscriptsWhenNoCustomLocation() {
        XCTAssertEqual(
            RecordingValidator.resolvedSaveDirectory(paths: paths),
            paths.transcripts
        )
    }

    func testReturnsPathsTranscriptsWhenCustomLocationBlank() {
        UserDefaults.standard.set("   ", forKey: preferenceKey)

        XCTAssertEqual(
            RecordingValidator.resolvedSaveDirectory(paths: paths),
            paths.transcripts
        )
    }

    func testAppendsMeetingsSubdirectoryForCustomLocation() {
        let customRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingValidatorResolvedSaveDirectoryTests-custom-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: customRoot) }
        try? FileManager.default.createDirectory(at: customRoot, withIntermediateDirectories: true)

        UserDefaults.standard.set(customRoot.path, forKey: preferenceKey)

        XCTAssertEqual(
            RecordingValidator.resolvedSaveDirectory(paths: paths),
            customRoot.appendingPathComponent("meetings", isDirectory: true)
        )
    }

    func testRelativeCustomLocationFallsBackToPathsTranscripts() {
        UserDefaults.standard.set("relative/path", forKey: preferenceKey)

        XCTAssertEqual(
            RecordingValidator.resolvedSaveDirectory(paths: paths),
            paths.transcripts
        )
    }

    func testTraversalCustomLocationFallsBackToPathsTranscripts() {
        UserDefaults.standard.set("/tmp/foo/../../etc", forKey: preferenceKey)

        XCTAssertEqual(
            RecordingValidator.resolvedSaveDirectory(paths: paths),
            paths.transcripts
        )
    }

    func testSystemCustomLocationFallsBackToPathsTranscripts() {
        UserDefaults.standard.set("/System/Library/Transcripted", forKey: preferenceKey)

        XCTAssertEqual(
            RecordingValidator.resolvedSaveDirectory(paths: paths),
            paths.transcripts
        )
    }
}

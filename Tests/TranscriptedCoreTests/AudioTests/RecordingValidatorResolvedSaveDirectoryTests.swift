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
    private var originalArguments: [String: Any] = [:]
    private var paths: CoreStoragePaths!

    override func setUp() {
        super.setUp()
        originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        // An empty value masks any persistent location without changing it.
        setPreference("")

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
        UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
        super.tearDown()
    }

    // XCTest runs these cases serially within this test process. Keep each
    // override scoped to setUp/tearDown; parallel workers have separate processes.
    private func setPreference(_ value: String) {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[preferenceKey] = value
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    func testVolatileLocationReachesDefaultAccessorWithoutPersistentWrites() throws {
        let processName = ProcessInfo.processInfo.processName
        let bundleID = Bundle.main.bundleIdentifier
        let domain = bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? processName
        // Never inspect a product preference domain, even if this fixture is
        // accidentally linked into the app instead of a test executable.
        guard !["Transcripted", "Draft"].contains(processName),
              bundleID != "com.justinbetker.draft",
              domain == "swiftpm-testing-helper" || domain == "com.apple.dt.xctest.tool"
                || domain.hasSuffix("Tests") else {
            XCTFail("Preference isolation proof requires a test-process domain")
            return
        }
        let persistentBefore = UserDefaults.standard.persistentDomain(forName: domain)
        let argumentsBefore = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.setVolatileDomain(argumentsBefore, forName: UserDefaults.argumentDomain)
        }
        let customRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VolatileLocation-\(UUID().uuidString)", isDirectory: true)
        setPreference(customRoot.path)
        XCTAssertEqual(RecordingValidator.resolvedSaveDirectory(paths: paths), customRoot.appendingPathComponent("meetings", isDirectory: true))
        // Blank is the no-custom-location control, without exposing an
        // underlying persistent location as removeObject would.
        setPreference("")
        XCTAssertEqual(RecordingValidator.resolvedSaveDirectory(paths: paths), paths.transcripts)
        let persistentAfter = UserDefaults.standard.persistentDomain(forName: domain)
        XCTAssertTrue((persistentBefore as NSDictionary?) == (persistentAfter as NSDictionary?),
                      "Volatile overrides must not alter persistent preferences")
        UserDefaults.standard.setVolatileDomain(argumentsBefore, forName: UserDefaults.argumentDomain)
        XCTAssertTrue((argumentsBefore as NSDictionary).isEqual(
            UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)),
            "The complete prior argument domain must be restored")
    }

    func testReturnsPathsTranscriptsWhenNoCustomLocation() {
        XCTAssertEqual(
            RecordingValidator.resolvedSaveDirectory(paths: paths),
            paths.transcripts
        )
    }

    func testReturnsPathsTranscriptsWhenCustomLocationBlank() {
        setPreference("   ")

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

        setPreference(customRoot.path)

        XCTAssertEqual(
            RecordingValidator.resolvedSaveDirectory(paths: paths),
            customRoot.appendingPathComponent("meetings", isDirectory: true)
        )
    }

    func testRelativeCustomLocationFallsBackToPathsTranscripts() {
        setPreference("relative/path")

        XCTAssertEqual(
            RecordingValidator.resolvedSaveDirectory(paths: paths),
            paths.transcripts
        )
    }

    func testTraversalCustomLocationFallsBackToPathsTranscripts() {
        setPreference("/tmp/foo/../../etc")

        XCTAssertEqual(
            RecordingValidator.resolvedSaveDirectory(paths: paths),
            paths.transcripts
        )
    }

    func testSystemCustomLocationFallsBackToPathsTranscripts() {
        setPreference("/System/Library/Transcripted")

        XCTAssertEqual(
            RecordingValidator.resolvedSaveDirectory(paths: paths),
            paths.transcripts
        )
    }
}

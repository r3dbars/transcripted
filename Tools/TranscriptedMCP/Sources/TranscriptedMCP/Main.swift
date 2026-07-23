import Foundation
import MCP

@main
struct TranscriptedMCP {
    static let serverVersion = "1.0.0"

    static func main() async throws {
        let startupStartedAt = ProcessInfo.processInfo.systemUptime

        if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
            print(Self.helpText)
            return
        }

        if CommandLine.arguments.contains("--version") {
            print("transcripted-mcp \(serverVersion)")
            return
        }

        if CommandLine.arguments.contains("--self-test") {
            try runSelfTest()
            return
        }

        let directories = TranscriptedDataDirectories.resolve()

        log("Starting transcripted-mcp v\(serverVersion)")

        var createdDirectoryCount = 0
        for directory in directories.watchedDirectories + [directories.indexDir] {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                createdDirectoryCount += 1
            }
        }
        if createdDirectoryCount > 0 {
            log("Created missing MCP data directories (count_bucket=\(MCPLogPrivacy.countBucket(createdDirectoryCount)))")
        }

        // Create and populate index
        let index: TranscriptIndex
        do {
            // On-device semantic search. NLEmbedding ships with macOS (no bundled
            // model, no download); when its language assets are missing the
            // provider reports unavailable and search stays lexical-only.
            let embeddingProvider = NLEmbeddingProvider()
            if embeddingProvider.isAvailable {
                log("Semantic search enabled (\(embeddingProvider.modelID), dim \(embeddingProvider.dimension))")
            } else {
                log("Semantic search unavailable on this host; using lexical search only")
            }
            index = try TranscriptIndex(indexDir: directories.indexDir, embeddingProvider: embeddingProvider)
            try MCPStartupIndexing.prepareForAttach(
                index: index,
                meetingDirs: directories.meetingDirs,
                dictationDirs: directories.dictationDirs
            )
            log(MCPStartupDiagnostics.message(
                phase: .lexicalIndexReady,
                elapsedSeconds: ProcessInfo.processInfo.systemUptime - startupStartedAt
            ))
        } catch {
            log("MCP startup failed during lexical index preparation")
            throw error
        }

        let watchers = directories.watchedDirectories.map { directory in
            FileWatcher(directory: directory) {
                do {
                    try index.reconcile(meetingDirs: directories.meetingDirs, dictationDirs: directories.dictationDirs)
                } catch {
                    log("Failed to reconcile the watched capture index")
                }
            }
        }
        watchers.forEach { $0.start() }

        // Create MCP server
        let server = Server(
            name: "transcripted",
            version: serverVersion,
            capabilities: .init(
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        await registerToolHandlers(server: server, index: index, directories: directories)
        await TranscriptedUIResources.register(
            server: server, index: index, directories: directories, serverVersion: serverVersion
        )

        // Start stdio transport
        let transport = StdioTransport()
        try await server.start(transport: transport)
        log(MCPStartupDiagnostics.message(
            phase: .transportReady,
            elapsedSeconds: ProcessInfo.processInfo.systemUptime - startupStartedAt
        ))

        if index.embeddingStore != nil {
            Task.detached(priority: .utility) {
                let semanticStartedAt = ProcessInfo.processInfo.systemUptime
                log(MCPStartupDiagnostics.message(phase: .semanticIndexStarted, elapsedSeconds: 0))
                MCPStartupIndexing.completeAfterAttach(index: index)
                log(MCPStartupDiagnostics.message(
                    phase: .semanticIndexReady,
                    elapsedSeconds: ProcessInfo.processInfo.systemUptime - semanticStartedAt
                ))
            }
        }

        await server.waitUntilCompleted()

        watchers.forEach { $0.stop() }
        log("MCP server stopped")
    }

    private static let helpText = """
    OVERVIEW: Read-only MCP server for Transcripted meetings and dictations.

    USAGE: transcripted-mcp [--self-test] [--version] [--help]

    OPTIONS:
      --self-test   Verify directory resolution and SQLite indexing, then exit.
      --version     Show the version.
      -h, --help    Show help information.

    ENVIRONMENT:
      TRANSCRIPTED_DATA_DIR         Shared root with meetings/ and dictations/.
      TRANSCRIPTED_MEETINGS_DIR     Meeting directory override.
      TRANSCRIPTED_DICTATIONS_DIR   Dictation directory override.
      TRANSCRIPTED_INDEX_DIR        SQLite index directory override.
    """

    private static func runSelfTest() throws {
        let directories = TranscriptedDataDirectories.resolve()

        for directory in directories.watchedDirectories + [directories.indexDir] {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        try withLogsSuppressed {
            let index = try TranscriptIndex(indexDir: directories.indexDir)
            try index.reconcile(meetingDirs: directories.meetingDirs, dictationDirs: directories.dictationDirs)
        }

        let result = TranscriptedMCPSelfTestResult(
            ok: true,
            meetingsDirectory: directories.meetingsDir.path,
            dictationsDirectory: directories.dictationsDir.path,
            meetingDirectories: directories.meetingDirs.map(\.path),
            dictationDirectories: directories.dictationDirs.map(\.path),
            indexDirectory: directories.indexDir.path,
            meetingFileCount: markdownFileCount(in: directories.meetingDirs),
            dictationFileCount: markdownFileCount(in: directories.dictationDirs)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(result)
        print(String(decoding: data, as: UTF8.self))
    }

    private static func markdownFileCount(in directories: [URL]) -> Int {
        directories.reduce(0) { $0 + markdownFileCount(in: $1) }
    }

    private static func markdownFileCount(in directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var count = 0
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "md" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                count += 1
            }
        }
        return count
    }
}

private struct TranscriptedMCPSelfTestResult: Codable {
    let ok: Bool
    let meetingsDirectory: String
    let dictationsDirectory: String
    let meetingDirectories: [String]
    let dictationDirectories: [String]
    let indexDirectory: String
    let meetingFileCount: Int
    let dictationFileCount: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case meetingsDirectory = "meetings_directory"
        case dictationsDirectory = "dictations_directory"
        case meetingDirectories = "meeting_directories"
        case dictationDirectories = "dictation_directories"
        case indexDirectory = "index_directory"
        case meetingFileCount = "meeting_file_count"
        case dictationFileCount = "dictation_file_count"
    }
}

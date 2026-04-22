import Foundation
import MCP

@main
struct TranscriptedMCP {
    static func main() async throws {
        if CommandLine.arguments.contains("--version") {
            print("transcripted-mcp 1.0.0")
            return
        }

        if CommandLine.arguments.contains("--self-test") {
            try runSelfTest()
            return
        }

        let directories = TranscriptedDataDirectories.resolve()

        log("Starting transcripted-mcp v1.0.0")
        log("Meetings directory: \(directories.meetingsDir.path)")
        log("Dictations directory: \(directories.dictationsDir.path)")
        log("Index directory: \(directories.indexDir.path)")

        for directory in directories.watchedDirectories + [directories.indexDir] {
            if !FileManager.default.fileExists(atPath: directory.path) {
                log("Creating missing directory: \(directory.path)")
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        // Create and populate index
        let index: TranscriptIndex
        do {
            index = try TranscriptIndex(indexDir: directories.indexDir)
            try index.reconcile(meetingsDir: directories.meetingsDir, dictationsDir: directories.dictationsDir)
        } catch {
            log("Failed to initialize index: \(error.localizedDescription)")
            throw error
        }

        let watchers = directories.watchedDirectories.map { directory in
            FileWatcher(directory: directory) { changedURL in
                do {
                    try index.indexSingleFile(changedURL, allowedRoots: directories.watchedDirectories)
                } catch {
                    log("Failed to index \(changedURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        watchers.forEach { $0.start() }

        // Create MCP server
        let server = Server(
            name: "transcripted",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await registerToolHandlers(server: server, index: index, directories: directories)

        log("MCP server ready, waiting for connections")

        // Start stdio transport
        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()

        watchers.forEach { $0.stop() }
        log("MCP server stopped")
    }

    private static func runSelfTest() throws {
        let directories = TranscriptedDataDirectories.resolve()

        for directory in directories.watchedDirectories + [directories.indexDir] {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        let index = try TranscriptIndex(indexDir: directories.indexDir)
        try index.reconcile(meetingsDir: directories.meetingsDir, dictationsDir: directories.dictationsDir)

        let result = TranscriptedMCPSelfTestResult(
            ok: true,
            meetingsDirectory: directories.meetingsDir.path,
            dictationsDirectory: directories.dictationsDir.path,
            indexDirectory: directories.indexDir.path,
            meetingFileCount: markdownFileCount(in: directories.meetingsDir),
            dictationFileCount: markdownFileCount(in: directories.dictationsDir)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(result)
        print(String(decoding: data, as: UTF8.self))
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
    let indexDirectory: String
    let meetingFileCount: Int
    let dictationFileCount: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case meetingsDirectory = "meetings_directory"
        case dictationsDirectory = "dictations_directory"
        case indexDirectory = "index_directory"
        case meetingFileCount = "meeting_file_count"
        case dictationFileCount = "dictation_file_count"
    }
}

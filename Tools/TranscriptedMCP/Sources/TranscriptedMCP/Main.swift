import Foundation
import MCP

@main
struct TranscriptedMCP {
    static func main() async throws {
        let directories = TranscriptedDataDirectories.resolve()

        log("Starting transcripted-mcp v1.0.0")
        log("Meetings directories: \(directories.meetingDirs.map(\.path).joined(separator: ", "))")
        log("Dictations directories: \(directories.dictationDirs.map(\.path).joined(separator: ", "))")
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
            try index.reconcile(meetingDirs: directories.meetingDirs, dictationDirs: directories.dictationDirs)
        } catch {
            log("Failed to initialize index: \(error.localizedDescription)")
            throw error
        }

        let watchers = directories.watchedDirectories.map { directory in
            FileWatcher(directory: directory) { changedURL in
                do {
                    try index.indexSingleFile(changedURL)
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
}

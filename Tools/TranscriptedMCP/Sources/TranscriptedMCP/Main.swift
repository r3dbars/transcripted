import Foundation
import MCP

private func defaultTranscriptedTranscriptsDirectory() -> URL {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    return appSupport
        .appendingPathComponent("Draft", isDirectory: true)
        .appendingPathComponent("meetings", isDirectory: true)
        .appendingPathComponent("transcripts", isDirectory: true)
}

@main
struct TranscriptedMCP {
    static func main() async throws {
        let dataDir: URL = {
            if let override = ProcessInfo.processInfo.environment["TRANSCRIPTED_DATA_DIR"] {
                return URL(fileURLWithPath: override)
            }
            return defaultTranscriptedTranscriptsDirectory()
        }()

        log("Starting transcripted-mcp v1.0.0")
        log("Data directory: \(dataDir.path)")

        // Ensure data directory exists
        if !FileManager.default.fileExists(atPath: dataDir.path) {
            log("Data directory does not exist yet. Will serve empty results until first recording.")
            try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        }

        // Create and populate index
        let index: TranscriptIndex
        do {
            index = try TranscriptIndex(dataDir: dataDir)
            try index.reconcile(dataDir: dataDir)
        } catch {
            log("Failed to initialize index: \(error.localizedDescription)")
            throw error
        }

        // Start file watcher for new transcripts
        let watcher = FileWatcher(directory: dataDir) { changedURL in
            do {
                try index.indexSingleFile(changedURL)
            } catch {
                log("Failed to index \(changedURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
        watcher.start()

        // Create MCP server
        let server = Server(
            name: "transcripted",
            version: "1.0.0",
            capabilities: .init(tools: .init(listChanged: false))
        )

        await registerToolHandlers(server: server, index: index, dataDir: dataDir)

        log("MCP server ready, waiting for connections")

        // Start stdio transport
        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()

        watcher.stop()
        log("MCP server stopped")
    }
}

import Foundation

enum TranscriptLoader {
    /// Load and decode a JSON sidecar file. Returns nil on any error.
    static func load(_ url: URL) -> AgentTranscript? {
        guard let data = try? Data(contentsOf: url) else {
            log("Cannot read file: \(url.lastPathComponent)")
            return nil
        }
        do {
            return try JSONDecoder().decode(AgentTranscript.self, from: data)
        } catch {
            log("Failed to decode \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// Enumerate all JSON sidecar files in a directory.
    static func enumerateSidecars(in directory: URL) -> [(url: URL, modDate: TimeInterval)] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return []
        }

        return files.compactMap { url in
            guard url.pathExtension == "json",
                  url.lastPathComponent.hasPrefix("Call_") else { return nil }
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate?.timeIntervalSince1970) ?? 0
            return (url, modDate)
        }
    }

    /// Build a speaker lookup: speakerId -> (name, persistentId)
    static func speakerLookup(from transcript: AgentTranscript) -> [String: (name: String, persistentId: String?)] {
        var lookup: [String: (name: String, persistentId: String?)] = [:]
        for speaker in transcript.speakers {
            lookup[speaker.id] = (speaker.name, speaker.persistentSpeakerId)
        }
        return lookup
    }
}

/// Log to stderr (stdout is reserved for MCP JSON-RPC).
func log(_ message: String) {
    fputs("[transcripted-mcp] \(message)\n", stderr)
}

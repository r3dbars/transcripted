import Foundation

enum ContextSidecarKind {
    case meeting
    case dictationDay
}

struct ContextSidecarFile {
    let url: URL
    let modDate: TimeInterval
    let kind: ContextSidecarKind
}

enum TranscriptLoader {
    /// Load and decode a JSON sidecar file. Returns nil on any error.
    static func load(_ url: URL) -> AgentTranscript? {
        loadMeeting(url)
    }

    static func loadMeeting(_ url: URL) -> AgentTranscript? {
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

    static func loadDictationDay(_ url: URL) -> AgentDictationDay? {
        guard let data = try? Data(contentsOf: url) else {
            log("Cannot read file: \(url.lastPathComponent)")
            return nil
        }
        do {
            return try JSONDecoder().decode(AgentDictationDay.self, from: data)
        } catch {
            log("Failed to decode \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    static func sidecarKind(for url: URL) -> ContextSidecarKind? {
        guard url.pathExtension == "json" else { return nil }

        let filename = url.deletingPathExtension().lastPathComponent
        if filename.hasPrefix("Call_") {
            return .meeting
        }
        if filename.hasPrefix("Dictations_") {
            return .dictationDay
        }

        return nil
    }

    /// Enumerate all JSON sidecar files in a directory.
    static func enumerateSidecars(in directory: URL) -> [ContextSidecarFile] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return []
        }

        return files.compactMap { url in
            guard let kind = sidecarKind(for: url) else { return nil }
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate?.timeIntervalSince1970) ?? 0
            return ContextSidecarFile(url: url, modDate: modDate, kind: kind)
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

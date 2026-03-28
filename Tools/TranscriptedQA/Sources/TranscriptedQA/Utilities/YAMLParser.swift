import Foundation

/// Minimal YAML frontmatter parser (regex-based, not a full YAML parser)
struct YAMLParser {
    let raw: String
    let body: String
    let fields: [String: String]

    init(content: String) {
        // Split frontmatter from body
        if content.hasPrefix("---\n"),
           let endRange = content.range(of: "\n---\n", range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex) {
            raw = String(content[content.index(content.startIndex, offsetBy: 4)..<endRange.lowerBound])
            body = String(content[endRange.upperBound...])
        } else {
            raw = ""
            body = content
        }

        // Parse simple key: value pairs (not nested)
        var parsed: [String: String] = [:]
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), !trimmed.hasPrefix("#") else { continue }
            if let colonIdx = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                // Strip surrounding quotes
                let stripped = value.hasPrefix("\"") && value.hasSuffix("\"")
                    ? String(value.dropFirst().dropLast())
                    : value
                parsed[key] = stripped
            }
        }
        fields = parsed
    }

    var hasFrontmatter: Bool { !raw.isEmpty }

    func hasKey(_ key: String) -> Bool {
        fields[key] != nil
    }

    func value(for key: String) -> String? {
        fields[key]
    }
}

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

        // Parse simple key: value pairs and lists
        var parsed: [String: String] = [:]
        var currentKey: String?
        var listItems: [String] = []

        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            if trimmed.hasPrefix("- ") {
                // List item — associate with most recent key
                let item = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                listItems.append(item)
                continue
            }

            // Flush any pending list items to the previous key
            if let key = currentKey, !listItems.isEmpty {
                parsed[key] = listItems.joined(separator: ", ")
                listItems = []
            }

            if let colonIdx = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

                if value.isEmpty {
                    // Value may follow as a list
                    currentKey = key
                    continue
                }

                // Handle inline list syntax: key: [item1, item2]
                if value.hasPrefix("[") && value.hasSuffix("]") {
                    let inner = String(value.dropFirst().dropLast())
                    let items = inner.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    parsed[key] = items.joined(separator: ", ")
                    currentKey = key
                    continue
                }

                // Strip surrounding quotes
                let stripped = value.hasPrefix("\"") && value.hasSuffix("\"")
                    ? String(value.dropFirst().dropLast())
                    : value
                parsed[key] = stripped
                currentKey = key
            }
        }

        // Flush any trailing list items
        if let key = currentKey, !listItems.isEmpty {
            parsed[key] = listItems.joined(separator: ", ")
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

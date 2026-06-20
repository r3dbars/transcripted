import Foundation
import TranscriptedCaptureKit

/// Minimal frontmatter adapter for QA validators.
struct YAMLParser {
    let raw: String
    let body: String
    let fields: [String: String]

    init(content: String) {
        if let document = CaptureMarkdownParser.parseFrontmatter(from: content) {
            raw = document.frontmatter
            body = document.body
            fields = document.values
        } else {
            raw = ""
            body = content
            fields = [:]
        }
    }

    var hasFrontmatter: Bool { !raw.isEmpty }

    func hasKey(_ key: String) -> Bool {
        fields[key] != nil
    }

    func value(for key: String) -> String? {
        fields[key]
    }
}

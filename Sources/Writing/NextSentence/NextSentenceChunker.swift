import Foundation

/// Splits Transcripted's saved captures into passages small enough to search by meaning.
/// Pure, so tests pin it. Day files (dictations, writing) split on their `## time - title` entries,
/// with the bookkeeping lines dropped; meetings split into runs of speaker turns.
enum NextSentenceChunker {
    struct Chunk: Equatable, Sendable {
        let kind: String
        let date: String
        let title: String
        let text: String
    }

    static let targetLength = 700
    static let minimumLength = 40

    private static let bookkeeping = ["Entry ID:", "Captured:", "Source app:", "Bundle ID:", "Delivery:", "Words:",
                                      "Characters:", "Audio:", "Accepted words:", "Recorded "]

    static func chunks(markdown: String, kind: String) -> [Chunk] {
        let (front, body) = splitFrontMatter(markdown)
        let date = front["date"] ?? ""
        let title = front["title"] ?? ""
        return kind == "meeting" ? meeting(body, date: date, title: title) : dayFile(body, kind: kind, date: date)
    }

    // MARK: Day files

    private static func dayFile(_ body: String, kind: String, date: String) -> [Chunk] {
        var chunks: [Chunk] = []
        for section in body.components(separatedBy: "\n## ").dropFirst() {
            let lines = section.components(separatedBy: "\n")
            let heading = lines.first ?? ""
            let text = lines.dropFirst()
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { line in !line.isEmpty && !bookkeeping.contains { line.hasPrefix($0) } && !line.hasPrefix("#") }
                .joined(separator: " ")
            guard looksLikeProse(text) else { continue }
            let time = heading.components(separatedBy: " - ").first ?? ""
            for piece in split(text) {
                chunks.append(Chunk(kind: kind, date: date, title: time, text: piece))
            }
        }
        return chunks
    }

    /// Writing captures can be keystroke noise ("g i t h u b"); keep only real sentences.
    static func looksLikeProse(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard text.count >= minimumLength, words.count >= 6 else { return false }
        let letters = words.reduce(0) { $0 + $1.count }
        return Double(letters) / Double(words.count) >= 2.5
    }

    // MARK: Meetings

    private static func meeting(_ body: String, date: String, title: String) -> [Chunk] {
        var chunks: [Chunk] = []
        var current = ""
        for block in body.components(separatedBy: "\n\n") {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("**") else { continue }
            // **02:03**  [System/Riley]\ntext  ->  "Riley: text"
            var lines = trimmed.components(separatedBy: "\n")
            let header = lines.removeFirst()
            let speaker = header.range(of: #"\[([^\]]+)\]"#, options: .regularExpression)
                .map { String(header[$0]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
                .map { $0.components(separatedBy: "/").last ?? $0 } ?? ""
            let said = lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !said.isEmpty else { continue }
            let turn = speaker.isEmpty ? said : "\(speaker): \(said)"
            if !current.isEmpty, current.count + turn.count > targetLength {
                chunks += split(current).map { Chunk(kind: "meeting", date: date, title: title, text: $0) }
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + turn
        }
        if current.count >= minimumLength {
            chunks += split(current).map { Chunk(kind: "meeting", date: date, title: title, text: $0) }
        }
        return chunks
    }

    // MARK: Helpers

    /// Long text in roughly `targetLength` pieces, broken between words.
    static func split(_ text: String) -> [String] {
        guard text.count > targetLength * 3 / 2 else { return [text] }
        var pieces: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            if current.count + word.count + 1 > targetLength, current.count >= minimumLength {
                pieces.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : " ") + word
        }
        if current.count >= minimumLength { pieces.append(current) } else if !current.isEmpty, !pieces.isEmpty {
            pieces[pieces.count - 1] += " " + current
        }
        return pieces
    }

    static func splitFrontMatter(_ markdown: String) -> (front: [String: String], body: String) {
        guard markdown.hasPrefix("---\n") else { return ([:], markdown) }
        let rest = markdown.dropFirst(4)
        guard let end = rest.range(of: "\n---\n") else { return ([:], markdown) }
        var front: [String: String] = [:]
        for line in rest[..<end.lowerBound].components(separatedBy: "\n") {
            guard !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            front[key] = value
        }
        return (front, String(rest[end.upperBound...]))
    }

    /// Lowercased letters and digits only, single-spaced: for "is this passage the screen itself".
    static func normalized(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ").joined(separator: " ")
    }
}

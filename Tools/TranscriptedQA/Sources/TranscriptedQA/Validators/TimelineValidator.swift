import Foundation
import TranscriptedCaptureKit

struct TimelineValidator {
    let directory: URL

    func validate() -> [ValidationResult] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return [.warn("timeline/dir-readable", target: directory.path, detail: "Timeline directory does not exist")]
        }

        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "md" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
            return [.fail("timeline/dir-readable", target: directory.path, detail: "Cannot read directory")]
        }

        if files.isEmpty {
            return [.warn("timeline/files-exist", target: directory.path, detail: "No timeline markdown files found")]
        }

        var results: [ValidationResult] = [
            .pass("timeline/files-exist", target: directory.lastPathComponent)
        ]

        for file in files {
            let name = file.lastPathComponent
            guard let markdown = try? String(contentsOf: file, encoding: .utf8) else {
                results.append(.fail("timeline/readable", target: name, detail: "Cannot read file"))
                continue
            }

            guard let parsed = TimelineMarkdownParser.parseTimelineDay(from: markdown, markdownURL: file) else {
                results.append(.fail("timeline/parseable", target: name, detail: "Expected capture_type timeline markdown"))
                continue
            }

            results.append(.pass("timeline/parseable", target: name))
            if parsed.date.isEmpty {
                results.append(.fail("timeline/date-present", target: name, detail: "Missing date frontmatter"))
            } else {
                results.append(.pass("timeline/date-present", target: name))
            }
            if parsed.cardCount == parsed.cards.count {
                results.append(.pass("timeline/card-count", target: name))
            } else {
                results.append(.fail("timeline/card-count", target: name, detail: "card_count does not match parsed cards"))
            }

            let lowercased = markdown.lowercased()
            if lowercased.contains("screenshot") || lowercased.contains("ocr") {
                results.append(.fail("timeline/privacy-safe", target: name, detail: "Timeline markdown must not include screenshots or raw OCR references"))
            } else {
                results.append(.pass("timeline/privacy-safe", target: name))
            }
        }

        return results
    }
}

import Foundation

enum PostHogPayloadSanitizer {
    private static let maxValueLength = 120
    private static let blockedExactKeys: Set<String> = [
        "audio_device",
        "source_app_bundle_id",
        "source_app_name",
    ]
    private static let blockedKeyFragments = [
        "authorization",
        "bearer",
        "email",
        "error",
        "file",
        "path",
        "speaker",
        "text",
        "title",
        "token",
        "transcript",
        "url",
    ]

    static func sanitizeProperties(_ properties: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]

        for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
            guard !shouldDrop(key: key) else { continue }

            let cleaned = SentryPayloadSanitizer.sanitizeText(value)
            guard !cleaned.isEmpty else { continue }

            sanitized[key] = cleaned.count > maxValueLength
                ? String(cleaned.prefix(maxValueLength)) + "..."
                : cleaned
        }

        return sanitized
    }

    private static func shouldDrop(key: String) -> Bool {
        let normalized = key.lowercased()
        if blockedExactKeys.contains(normalized) {
            return true
        }

        return blockedKeyFragments.contains(where: { normalized.contains($0) })
    }
}

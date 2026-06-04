import Foundation

enum LogPrivacySanitizer {
    private static let redactedSensitiveValue = "[redacted-sensitive-value]"
    private static let redactedPath = "[redacted-path]"
    private static let redactedURL = "[redacted-url]"
    private static let redactedEmail = "[redacted-email]"
    private static let redactedSecret = "[redacted-secret]"

    private static let sensitiveKeyFragments: [String] = [
        "audio",
        "credential",
        "device",
        "dsn",
        "email",
        "file",
        "filename",
        "name",
        "password",
        "path",
        "profile",
        "secret",
        "token",
        "transcript",
        "url",
    ]

    private static let safeSensitiveLookingKeys: Set<String> = [
        "audiodurations",
        "audioactivecoeff",
        "audioactivedurations",
        "audioactiveratio",
        "audiogaps",
        "audiographgeneration",
        "audiohassignal",
        "audioinputselectionloadms",
        "audiopeak",
        "audiorms",
        "deviceswitches",
        "inputchannels",
        "inputdeviceclass",
        "inputratehz",
        "newprofiles",
        "outputchannels",
        "outputdeviceclass",
        "outputratehz",
        "profilecallcount",
        "profileid",
        "routechangecount",
        "routechangecountbucket",
        "speakerid",
        "speakerids",
        "speakers",
        "systembackend",
        "systemchannels",
        "systemoutputdeviceclass",
        "systemoutputratehz",
        "systemratehz",
        "systemstatus",
        "transcriptionengine",
        "transcriptid",
    ]

    private static let rawURLRegex = makeRegex(#"https?://[^\s"]+"#, options: [.caseInsensitive])
    private static let emailRegex = makeRegex(#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])
    private static let apiKeyRegex = makeRegex(#"sk-[A-Za-z0-9_-]+"#)
    private static let authSchemeRegex = makeRegex(#"(Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]+"#, options: [.caseInsensitive])
    private static let secretAssignmentRegex = makeRegex(
        #"(?i)\b((?:access_)?token|refresh_token|api[_-]?key|x-api-key|signature|x-amz-signature|password|passphrase|secret|client[_-]?secret|credential|dsn)\s*[:=]\s*([^\s,;]+)"#
    )
    private static let commonSecretRegex = makeRegex(
        #"\b(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|phc_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|AIza[0-9A-Za-z\-_]{35}|xox[baprs]-[A-Za-z0-9-]{10,}|xoxx-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9._-]{10,}\.[A-Za-z0-9._-]{10,})\b"#
    )
    private static let pathStartRegex = makeRegex(
        #"(?<!https:)(?<!http:)(?<![A-Za-z0-9._%+\-])/(?:System/Volumes/Data/)?(?:Users|Volumes|private/tmp|private/var|var|tmp|Applications|Library|opt)(?=/|$)"#
    )

    static func sanitizeText(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        result = redactFilePaths(in: result)
        result = replace(rawURLRegex, in: result, with: redactedURL)
        result = replace(apiKeyRegex, in: result, with: "sk-****")
        result = replace(commonSecretRegex, in: result, with: redactedSecret)
        result = replace(authSchemeRegex, in: result, with: "$1 ****")
        result = replace(secretAssignmentRegex, in: result, with: "$1=\(redactedSecret)")
        result = replace(emailRegex, in: result, with: redactedEmail)
        return result
    }

    static func sanitizeMetadata(_ metadata: [String: String]?) -> [String: String]? {
        guard let metadata else { return nil }

        let sanitized = metadata.reduce(into: [String: String]()) { result, pair in
            if shouldRedactValue(forKey: pair.key) {
                result[pair.key] = redactedSensitiveValue
            } else {
                let value = sanitizeText(pair.value)
                if !value.isEmpty {
                    result[pair.key] = value
                }
            }
        }

        return sanitized.isEmpty ? nil : sanitized
    }

    private static func shouldRedactValue(forKey key: String) -> Bool {
        let normalized = normalize(key)
        guard !safeSensitiveLookingKeys.contains(normalized) else { return false }
        return sensitiveKeyFragments.contains(where: { normalized.contains($0) })
    }

    private static func normalize(_ key: String) -> String {
        String(key.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func makeRegex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
            return regex
        }
        assertionFailure("Log sanitizer regex failed to compile; pattern will be skipped: \(pattern)")
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: "(?!)")
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    private static func redactFilePaths(in text: String) -> String {
        var result = text
        let matches = pathStartRegex.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        )

        for match in matches.reversed() {
            guard let start = Range(match.range, in: result)?.lowerBound else { continue }
            let end = pathEnd(in: result, from: start)
            guard start < end else { continue }
            result.replaceSubrange(start..<end, with: redactedPath)
        }

        return result
    }

    private static func pathEnd(in text: String, from start: String.Index) -> String.Index {
        var index = start

        while index < text.endIndex {
            let character = text[index]
            if character == "\n" || character == "\r" || character == "\t" || character == "\"" {
                break
            }

            if character == "," || character == ";" || character == ")" || character == "]" || character == "}" {
                break
            }

            if character == " " {
                let prefix = text[start..<index]
                let token = nextToken(in: text, after: index)
                if looksLikeMetadataToken(token) {
                    break
                }
                if pathPrefixLooksLikeFile(prefix) && !nextTokenCouldContinuePath(token) {
                    break
                }
            }

            index = text.index(after: index)
        }

        return index
    }

    private static func nextToken(in text: String, after spaceIndex: String.Index) -> String {
        var index = text.index(after: spaceIndex)
        while index < text.endIndex, text[index] == " " {
            index = text.index(after: index)
        }

        var token = ""
        while index < text.endIndex {
            let character = text[index]
            if character == " " || character == "\n" || character == "\r" || character == "\t" {
                break
            }
            token.append(character)
            index = text.index(after: index)
        }
        return token.trimmingCharacters(in: CharacterSet(charactersIn: ",;:)]}"))
    }

    private static func nextTokenCouldContinuePath(_ token: String) -> Bool {
        let normalized = token.trimmingCharacters(in: CharacterSet(charactersIn: ",;:)]}"))
        let lowercased = normalized.lowercased()
        guard !normalized.contains("@"),
              !lowercased.hasPrefix("http://"),
              !lowercased.hasPrefix("https://") else {
            return false
        }
        return normalized.contains("/") || pathTokenLooksLikeFile(normalized)
    }

    private static func pathPrefixLooksLikeFile(_ prefix: Substring) -> Bool {
        guard let slash = prefix.lastIndex(of: "/") else { return false }
        return pathTokenLooksLikeFile(String(prefix[prefix.index(after: slash)...]))
    }

    private static func pathTokenLooksLikeFile(_ token: String) -> Bool {
        guard let dot = token.lastIndex(of: ".") else { return false }
        let ext = token[token.index(after: dot)...]
        guard (1...8).contains(ext.count) else { return false }
        return ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static func looksLikeMetadataToken(_ token: String) -> Bool {
        guard let separator = token.firstIndex(of: "=") else { return false }
        let key = String(token[..<separator]).lowercased()
        return [
            "attempt",
            "code",
            "duration",
            "error",
            "event",
            "operation",
            "reason",
            "stage",
            "status",
        ].contains(key)
    }
}

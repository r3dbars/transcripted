// PlatformFormatter.swift
// Detects target platform and provides formatting rules for drafting

import AppKit

enum PlatformFormatter: String, CaseIterable {
    // Pre-compiled regexes for post-processing (avoids recompilation per draft)
    private static let boldRegex = try! NSRegularExpression(pattern: #"\*\*([^*]+)\*\*"#)
    private static let italicAsteriskRegex = try! NSRegularExpression(pattern: #"\*([^*]+)\*"#)
    private static let italicUnderscoreRegex = try! NSRegularExpression(pattern: #"_([^_]+)_"#)
    private static let headerRegex = try! NSRegularExpression(pattern: #"(?m)^#{1,6} "#)
    case slack
    case imessage
    case email
    case discord
    case teams
    case generic

    /// Detect platform from the app the user will paste into
    static func detect(from app: NSRunningApplication?) -> PlatformFormatter {
        switch app?.bundleIdentifier {
        case "com.tinyspeck.slackmacgap": return .slack
        case "com.apple.MobileSMS": return .imessage
        case "com.apple.mail": return .email
        case "com.hnc.Discord": return .discord
        case "com.microsoft.teams2", "com.microsoft.teams": return .teams
        default: return .generic
        }
    }

    /// Instructions appended to the system prompt so the model produces platform-native formatting
    var formattingInstructions: String {
        switch self {
        case .slack:
            return """
                Format for Slack. Use *bold* (single asterisks), NOT **bold**. \
                Use _italic_ (underscores), NOT *italic*. Use - for bullet points. \
                Do NOT use ## headers (Slack renders them as literal text). \
                Keep paragraphs short. Use line breaks between thoughts. \
                Emoji are fine if they match the user's style.
                """
        case .imessage:
            return """
                Format as a plain text message (iMessage). No markdown at all — no bold, \
                no italic, no headers, no bullet points. Keep it casual and brief. \
                One or two short paragraphs max. Emoji are fine if they match the user's style.
                """
        case .email:
            return """
                Format as a professional email. Use proper paragraphs with greeting and sign-off \
                if appropriate for the formality level. Markdown is fine (bold, italic, lists). \
                Structure longer replies with clear paragraphs.
                """
        case .discord:
            return """
                Format for Discord. Use **bold** (double asterisks) and *italic* (single asterisks). \
                Use - for bullet points. Discord supports markdown headers but keep them minimal. \
                Keep messages conversational.
                """
        case .teams:
            return """
                Format for Microsoft Teams. Use **bold** and *italic*. \
                Use - for bullet points. Keep formatting clean and professional. \
                Teams supports markdown but rendering can be inconsistent with complex formatting.
                """
        case .generic:
            return ""
        }
    }

    /// Post-process the draft output to fix common formatting issues per platform.
    /// This is a safety net — the prompt should handle most cases, but the model occasionally
    /// forgets and outputs generic markdown.
    func postProcess(_ text: String) -> String {
        switch self {
        case .slack:
            var result = text
            // Fix **bold** → *bold* (Slack uses single asterisks)
            var range = NSRange(result.startIndex..., in: result)
            result = Self.boldRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "*$1*")
            // Remove markdown headers (Slack renders them as literal text)
            range = NSRange(result.startIndex..., in: result)
            result = Self.headerRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            return result

        case .imessage:
            var result = text
            // Strip all markdown formatting
            var range = NSRange(result.startIndex..., in: result)
            result = Self.boldRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1")
            range = NSRange(result.startIndex..., in: result)
            result = Self.italicAsteriskRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1")
            range = NSRange(result.startIndex..., in: result)
            result = Self.italicUnderscoreRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1")
            range = NSRange(result.startIndex..., in: result)
            result = Self.headerRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            return result

        case .email, .discord, .teams, .generic:
            // These platforms handle markdown well enough — no post-processing needed
            return text
        }
    }
}

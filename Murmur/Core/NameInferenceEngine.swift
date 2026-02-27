import Foundation
import EventKit

// MARK: - NameMatch

struct NameMatch {
    let name: String
    let speakerId: String
    let confidence: Double     // 0.0–1.0
    let source: MatchSource

    enum MatchSource {
        case directAddress   // "Hey Nate, what do you think?"
        case selfIntro       // "This is Nate speaking"
        case calendarInvite  // Name found in calendar event attendees
        case contactsMatch   // Voice matched against saved contact
    }
}

// MARK: - NameInferenceEngine

/// Extracts speaker names from transcript text using NLP pattern matching.
/// Works in tandem with VoiceProfileDatabase to build the voice fingerprint
/// → name mapping over time without any manual onboarding.
///
/// Approach:
///  1. Scan each utterance for direct-address patterns ("hey [Name]")
///  2. The speaker who responds *immediately after* = that name
///  3. Cross-reference calendar attendees to validate / disambiguate
///  4. Apply matches above confidence threshold to VoiceProfileDatabase
final class NameInferenceEngine {

    // MARK: - Configuration

    /// Minimum confidence before auto-applying a name to a voice profile.
    static let autoApplyThreshold: Double = 0.85

    /// Minimum confidence to *suggest* a name (shown in UI for user confirmation).
    static let suggestThreshold: Double = 0.60

    // MARK: - Direct-address patterns

    private static let patterns: [(NSRegularExpression, Double)] = {
        let raw: [(String, Double)] = [
            // High confidence — explicit direct address
            (#"(?i)\bhey[,\s]+([A-Z][a-z]+)\b"#, 0.90),
            (#"(?i)\bhi[,\s]+([A-Z][a-z]+)\b"#, 0.88),
            (#"(?i)\bthanks[,\s]+([A-Z][a-z]+)\b"#, 0.85),
            (#"(?i)\bthank you[,\s]+([A-Z][a-z]+)\b"#, 0.85),
            (#"(?i)\bgood (morning|afternoon|evening)[,\s]+([A-Z][a-z]+)\b"#, 0.87),
            (#"(?i)^([A-Z][a-z]+)[,\?!]"#, 0.80),  // Utterance starts with name

            // Medium confidence — conversational cues
            (#"(?i)\bso[,\s]+([A-Z][a-z]+)[,\s]"#, 0.70),
            (#"(?i)\bright[,\s]+([A-Z][a-z]+)\?"#, 0.68),
            (#"(?i)\bwhat do you think[,\s]+([A-Z][a-z]+)"#, 0.75),
            (#"(?i)\b([A-Z][a-z]+)[,\s]+do you"#, 0.72),
            (#"(?i)\b([A-Z][a-z]+)[,\s]+can you"#, 0.72),

            // Self-introduction
            (#"(?i)\bthis is ([A-Z][a-z]+)\b"#, 0.92),
            (#"(?i)\bmy name is ([A-Z][a-z]+)\b"#, 0.95),
            (#"(?i)\bi'?m ([A-Z][a-z]+)[,\s\.]"#, 0.88),
        ]
        return raw.compactMap { pattern, confidence in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, confidence)
        }
    }()

    // MARK: - Common noise words to ignore

    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "but", "or", "so", "very", "really", "just",
        "good", "great", "okay", "ok", "yes", "no", "well", "also", "already",
        "morning", "afternoon", "evening", "everyone", "all", "guys", "team",
        "there", "here", "sure", "right", "yeah", "yep", "nope", "exactly",
        "maybe", "actually", "basically", "definitely", "probably", "like"
    ]

    // MARK: - Inference

    /// Analyze a sequence of utterances and return name→speakerId matches.
    /// - Parameters:
    ///   - utterances: Ordered utterances from a transcription session
    ///   - calendarEventTitle: Optional meeting title (used for attendee lookup)
    static func inferNames(
        from utterances: [LocalUtterance],
        calendarEventTitle: String? = nil
    ) async -> [NameMatch] {
        var matches: [NameMatch] = []

        // Pass 1: direct address patterns
        for (i, utterance) in utterances.enumerated() {
            let names = extractNames(from: utterance.transcript)
            guard !names.isEmpty else { continue }

            // The *next* speaker after a direct address = the addressed person
            let nextSpeakerId: String? = utterances.indices.contains(i + 1)
                ? utterances[i + 1].speakerId
                : nil

            for (name, confidence) in names {
                if let targetId = nextSpeakerId, targetId != utterance.speakerId {
                    matches.append(NameMatch(
                        name: name,
                        speakerId: targetId,
                        confidence: confidence,
                        source: .directAddress
                    ))
                }

                // Self-intro patterns assign the name to the current speaker
                if isSelfIntroduction(utterance.transcript, name: name) {
                    matches.append(NameMatch(
                        name: name,
                        speakerId: utterance.speakerId,
                        confidence: min(confidence + 0.05, 1.0),
                        source: .selfIntro
                    ))
                }
            }
        }

        // Pass 2: calendar attendee cross-reference (boosts confidence)
        if let title = calendarEventTitle {
            let calendarNames = await fetchCalendarAttendees(meetingTitle: title)
            matches = boostWithCalendar(matches: matches, calendarNames: calendarNames)
        }

        // Deduplicate: for each speakerId keep highest-confidence match
        return deduplicate(matches)
    }

    // MARK: - Apply to database

    /// Apply inferred names to VoiceProfileDatabase if above threshold.
    static func applyMatches(_ matches: [NameMatch], to db: VoiceProfileDatabase) {
        for match in matches {
            if match.confidence >= autoApplyThreshold {
                db.upsert(speakerId: match.speakerId, name: match.name, autoLabeled: true)
                print("🏷 Auto-labeled \(match.speakerId) → \"\(match.name)\" "
                    + "(confidence: \(String(format: "%.0f", match.confidence * 100))%, "
                    + "source: \(match.source))")
            }
        }
    }

    /// Returns matches that need user confirmation (above suggest but below auto-apply).
    static func pendingConfirmations(_ matches: [NameMatch]) -> [NameMatch] {
        matches.filter { $0.confidence >= suggestThreshold && $0.confidence < autoApplyThreshold }
    }

    // MARK: - Helpers

    private static func extractNames(from text: String) -> [(name: String, confidence: Double)] {
        let nsText = text as NSString
        var found: [(String, Double)] = []

        for (regex, baseConfidence) in patterns {
            let range = NSRange(location: 0, length: nsText.length)
            let matches = regex.matches(in: text, range: range)
            for match in matches {
                // Last capture group = the name
                let groupIdx = match.numberOfRanges - 1
                let nameRange = match.range(at: groupIdx)
                if nameRange.location != NSNotFound {
                    let name = nsText.substring(with: nameRange)
                    if !stopWords.contains(name.lowercased()) && name.count >= 2 {
                        found.append((name.capitalized, baseConfidence))
                    }
                }
            }
        }
        return found
    }

    private static func isSelfIntroduction(_ text: String, name: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("this is \(name.lowercased())")
            || lower.contains("my name is \(name.lowercased())")
            || lower.hasPrefix("i'm \(name.lowercased())")
            || lower.hasPrefix("i am \(name.lowercased())")
    }

    private static func fetchCalendarAttendees(meetingTitle: String) async -> Set<String> {
        let store = EKEventStore()

        // Request access (no-op if already granted)
        guard (try? await store.requestAccess(to: .event)) == true else {
            return []
        }

        let now = Date()
        let window = DateInterval(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600))
        let predicate = store.predicateForEvents(
            withStart: window.start,
            end: window.end,
            calendars: nil
        )

        let events = store.events(matching: predicate)
        let matchingEvents = events.filter {
            $0.title?.localizedCaseInsensitiveContains(meetingTitle) == true
        }

        var names: Set<String> = []
        for event in matchingEvents {
            for attendee in event.attendees ?? [] {
                if let name = attendee.name, !name.isEmpty {
                    // Extract first name only
                    let firstName = name.components(separatedBy: " ").first ?? name
                    names.insert(firstName)
                }
            }
        }
        return names
    }

    private static func boostWithCalendar(
        matches: [NameMatch],
        calendarNames: Set<String>
    ) -> [NameMatch] {
        matches.map { match in
            if calendarNames.contains(match.name) {
                return NameMatch(
                    name: match.name,
                    speakerId: match.speakerId,
                    confidence: min(match.confidence + 0.10, 1.0),
                    source: match.source
                )
            }
            return match
        }
    }

    private static func deduplicate(_ matches: [NameMatch]) -> [NameMatch] {
        var best: [String: NameMatch] = [:]  // keyed by speakerId
        for match in matches {
            if let existing = best[match.speakerId] {
                if match.confidence > existing.confidence {
                    best[match.speakerId] = match
                }
            } else {
                best[match.speakerId] = match
            }
        }
        return Array(best.values)
    }
}

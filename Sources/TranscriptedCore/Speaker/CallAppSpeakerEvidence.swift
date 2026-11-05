import Foundation

/// What the call app (Zoom, Meet, Teams, Slack) showed while one call-audio
/// voice talked, saved next to that voice's frontmatter `speakers:` row as
/// context. It is never a label: a voice's name comes only from its
/// voiceprint or from the person naming it. Agents and the review read it as
/// a second opinion.
///
/// Frontmatter keys (flat, under the speaker row, all optional):
/// - `call_app_name`: the name the call app showed speaking while this
///   voice talked (`CallSpeakerAttributionPolicy`).
/// - `call_app_agreement`: how that compares with the voiceprint's own
///   answer for this voice (`Agreement`).
/// - `call_app_seconds`, `call_app_share`, `call_app_coverage`: how strong
///   the overlap was (`CallSpeakerAttributionPolicy.Evidence`).
/// - `call_app_withheld`: the call app showed something, but not enough to
///   name anyone (a `CallSpeakerAttributionPolicy.WithheldReason`). Written
///   without a name.
///
/// Names are user content: local Markdown only, never logs or telemetry.
public struct CallAppSpeakerEvidence: Sendable, Equatable {
    /// The call-app name against the voiceprint's answer for the same voice.
    public enum Agreement: String, Sendable, Equatable, CaseIterable {
        /// Same person (compared trimmed and case-insensitively).
        case agrees
        /// The voiceprint says someone else. Both are kept; the voiceprint's
        /// answer stays the label.
        case conflicts
        /// The voiceprint had no name for this voice.
        case noVoiceprintGuess = "no_voiceprint_guess"
    }

    public var name: String?
    public var agreement: Agreement?
    public var strength: CallSpeakerAttributionPolicy.Evidence?
    public var withheld: CallSpeakerAttributionPolicy.WithheldReason?

    public init(
        name: String? = nil,
        agreement: Agreement? = nil,
        strength: CallSpeakerAttributionPolicy.Evidence? = nil,
        withheld: CallSpeakerAttributionPolicy.WithheldReason? = nil
    ) {
        self.name = name
        self.agreement = agreement
        self.strength = strength
        self.withheld = withheld
    }

    /// A name the policy found for this voice, compared with what the
    /// voiceprint suggests (`voiceprintName`; nil or blank when it had none).
    public static func named(
        _ name: String,
        strength: CallSpeakerAttributionPolicy.Evidence?,
        voiceprintName: String?
    ) -> CallAppSpeakerEvidence {
        CallAppSpeakerEvidence(
            name: name,
            agreement: agreement(callAppName: name, voiceprintName: voiceprintName),
            strength: strength
        )
    }

    /// The voiceprint's name against the call app's. A " (likely)" hedge on
    /// the voiceprint name is ignored.
    public static func agreement(callAppName: String, voiceprintName: String?) -> Agreement {
        var voiceprint = voiceprintName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if voiceprint.hasSuffix(SpeakerMapping.likelyNameSuffix) {
            voiceprint = String(voiceprint.dropLast(SpeakerMapping.likelyNameSuffix.count))
        }
        let voiceprintKey = CallSpeakerAttributionPolicy.normalizedKey(voiceprint)
        guard !voiceprintKey.isEmpty else { return .noVoiceprintGuess }
        return voiceprintKey == CallSpeakerAttributionPolicy.normalizedKey(callAppName) ? .agrees : .conflicts
    }

    /// The row's frontmatter lines, already indented for a `speakers:` row,
    /// in a fixed order. `escape` is the writer's YAML string escaper.
    func frontmatterLines(escape: (String) -> String) -> [String] {
        var lines: [String] = []
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("    call_app_name: \"\(escape(name))\"")
            if let agreement {
                lines.append("    call_app_agreement: \(agreement.rawValue)")
            }
            if let strength {
                lines.append("    call_app_seconds: \(Self.decimal(strength.seconds, places: 1))")
                lines.append("    call_app_share: \(Self.decimal(strength.share, places: 2))")
                lines.append("    call_app_coverage: \(Self.decimal(strength.coverage, places: 2))")
            }
        } else if let withheld {
            lines.append("    call_app_withheld: \(withheld.rawValue)")
        }
        return lines
    }

    private static func decimal(_ value: Double, places: Int) -> String {
        let finite = value.isFinite ? max(0, value) : 0
        return String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), finite)
    }
}

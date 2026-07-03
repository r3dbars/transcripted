import Foundation

/// Name variant expansion for speaker matching.
///
/// The `variants` table below is intentionally mirrored from
/// `Sources/TranscriptedCore/Speaker/SpeakerProfileMerger.swift` in the main
/// Transcripted app. The two cannot share a module (this standalone server has
/// no compile-time dependency on Core, and Core must not depend on the Tools
/// packages), so they are kept byte-for-byte identical instead. Any edit here
/// MUST be mirrored there, and vice versa.
enum NameVariants {
    private static let variants: [String: Set<String>] = [
        "mike": ["michael", "mike", "mikey"],
        "michael": ["michael", "mike", "mikey"],
        "mikey": ["michael", "mike", "mikey"],
        "nate": ["nate", "nathan", "nathaniel"],
        "nathan": ["nate", "nathan", "nathaniel"],
        "nathaniel": ["nate", "nathan", "nathaniel"],
        "dave": ["dave", "david"],
        "david": ["dave", "david"],
        "alex": ["alex", "alexander", "alexandra"],
        "alexander": ["alex", "alexander"],
        "alexandra": ["alex", "alexandra"],
        "dan": ["dan", "daniel", "danny"],
        "daniel": ["dan", "daniel", "danny"],
        "danny": ["dan", "daniel", "danny"],
        "matt": ["matt", "matthew"],
        "matthew": ["matt", "matthew"],
        "chris": ["chris", "christopher", "christine", "christina"],
        "christopher": ["chris", "christopher"],
        "christine": ["chris", "christine"],
        "christina": ["chris", "christina"],
        "nick": ["nick", "nicholas", "nic"],
        "nicholas": ["nick", "nicholas", "nic"],
        "nic": ["nick", "nicholas", "nic"],
        "rob": ["rob", "robert", "robbie", "bob", "bobby"],
        "robert": ["rob", "robert", "robbie", "bob", "bobby"],
        "bob": ["rob", "robert", "bob", "bobby"],
        "bobby": ["rob", "robert", "bob", "bobby"],
        "ed": ["ed", "edward", "eddie"],
        "edward": ["ed", "edward", "eddie"],
        "eddie": ["ed", "edward", "eddie"],
        "joe": ["joe", "joseph", "joey"],
        "joseph": ["joe", "joseph", "joey"],
        "joey": ["joe", "joseph", "joey"],
        "tom": ["tom", "thomas", "tommy"],
        "thomas": ["tom", "thomas", "tommy"],
        "tommy": ["tom", "thomas", "tommy"],
        "sam": ["sam", "samuel", "samantha"],
        "samuel": ["sam", "samuel"],
        "samantha": ["sam", "samantha"],
        "jen": ["jen", "jennifer", "jenny"],
        "jennifer": ["jen", "jennifer", "jenny"],
        "jenny": ["jen", "jennifer", "jenny"],
        "will": ["will", "william", "bill", "billy"],
        "william": ["will", "william", "bill", "billy"],
        "bill": ["will", "william", "bill", "billy"],
        "billy": ["will", "william", "bill", "billy"],
        "jim": ["jim", "james", "jimmy"],
        "james": ["jim", "james", "jimmy"],
        "jimmy": ["jim", "james", "jimmy"],
        "tony": ["tony", "anthony"],
        "anthony": ["tony", "anthony"],
        "steve": ["steve", "steven", "stephen"],
        "steven": ["steve", "steven", "stephen"],
        "stephen": ["steve", "steven", "stephen"],
        "ben": ["ben", "benjamin", "benny"],
        "benjamin": ["ben", "benjamin", "benny"],
        "benny": ["ben", "benjamin", "benny"],
        "andy": ["andy", "andrew", "drew"],
        "andrew": ["andy", "andrew", "drew"],
        "drew": ["andy", "andrew", "drew"],
        "marques": ["marques", "marquez"],
        "marquez": ["marques", "marquez"],
    ]

    /// Expand a name into all its variants.
    /// "Mike" -> {"mike", "michael", "mikey"}
    /// "Mike Smith" -> {"mike smith", "michael smith", "mike", "michael", "mikey"}
    static func expandName(_ input: String) -> Set<String> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let lowered = trimmed.lowercased()
        var result: Set<String> = [lowered]

        if let group = variants[lowered] {
            result.formUnion(group)
        }

        let parts = lowered.components(separatedBy: " ")
        if parts.count > 1, let firstName = parts.first, let group = variants[firstName] {
            let lastName = parts.dropFirst().joined(separator: " ")
            for variant in group {
                result.insert("\(variant) \(lastName)")
                result.insert(variant)
            }
        }

        return result
    }

    /// Check if two names are variants of each other.
    static func areNameVariants(_ name1: String, _ name2: String) -> Bool {
        let a = name1.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let b = name2.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        if let v = variants[a], v.contains(b) { return true }
        if let v = variants[b], v.contains(a) { return true }
        if a.contains(b) || b.contains(a) { return true }
        return false
    }
}

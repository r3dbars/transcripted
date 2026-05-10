import Foundation

enum NameVariants {
    /// Common English name variants (informal -> formal and vice versa).
    static let table: [String: Set<String>] = [
        "mike": ["michael", "mike", "mikey"],
        "michael": ["michael", "mike", "mikey"],
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
        "rob": ["rob", "robert", "robbie", "bob", "bobby"],
        "robert": ["rob", "robert", "robbie", "bob", "bobby"],
        "bob": ["rob", "robert", "bob", "bobby"],
        "ed": ["ed", "edward", "eddie"],
        "edward": ["ed", "edward", "eddie"],
        "joe": ["joe", "joseph", "joey"],
        "joseph": ["joe", "joseph", "joey"],
        "tom": ["tom", "thomas", "tommy"],
        "thomas": ["tom", "thomas", "tommy"],
        "sam": ["sam", "samuel", "samantha"],
        "samuel": ["sam", "samuel"],
        "samantha": ["sam", "samantha"],
        "jen": ["jen", "jennifer", "jenny"],
        "jennifer": ["jen", "jennifer", "jenny"],
        "will": ["will", "william", "bill", "billy"],
        "william": ["will", "william", "bill", "billy"],
        "bill": ["will", "william", "bill", "billy"],
        "jim": ["jim", "james", "jimmy"],
        "james": ["jim", "james", "jimmy"],
        "tony": ["tony", "anthony"],
        "anthony": ["tony", "anthony"],
        "steve": ["steve", "steven", "stephen"],
        "steven": ["steve", "steven", "stephen"],
        "stephen": ["steve", "steven", "stephen"],
        "ben": ["ben", "benjamin", "benny"],
        "benjamin": ["ben", "benjamin", "benny"],
        "andy": ["andy", "andrew", "drew"],
        "andrew": ["andy", "andrew", "drew"],
        "drew": ["andy", "andrew", "drew"],
        "marques": ["marques", "marquez"],
        "marquez": ["marques", "marquez"],
    ]

    static func areVariants(_ name1: String, _ name2: String) -> Bool {
        let a = name1.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let b = name2.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }

        if let variants = table[a], variants.contains(b) { return true }
        if let variants = table[b], variants.contains(a) { return true }

        // Handles "Marques Brownlee" vs "Marques".
        return a.contains(b) || b.contains(a)
    }
}

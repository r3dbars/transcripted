import Foundation

func testSpeakerNameTypingSuggestionPolicy() {
    let kimID = UUID()
    let parkID = UUID()
    let kim = SpeakerNameChoice(id: kimID, displayName: "Daniel Kim", callCount: 4)
    let park = SpeakerNameChoice(id: parkID, displayName: "Daniel Park", callCount: 4)
    let people = [kim, park]

    runSuite("Typing a shared first name lists every matching saved person") {
        assertEqual(
            suggestionNames(query: "Dan", people: people),
            ["Daniel Kim", "Daniel Park"],
            "Dan is a prefix of both saved Daniels"
        )
    }

    runSuite("A last-name fragment lists the person whose name starts with it") {
        assertEqual(
            suggestionNames(query: "kim", people: people),
            ["Daniel Kim"],
            "kim is the start of Kim, so only Daniel Kim is offered"
        )
    }

    runSuite("A contains match still lists the person") {
        assertEqual(
            suggestionNames(query: "ark", people: people),
            ["Daniel Park"],
            "ark sits inside Park, so Daniel Park is still offered"
        )
    }

    runSuite("An empty name field lists no typing suggestions") {
        assertEqual(
            suggestionNames(query: "", people: people),
            [],
            "nothing typed, nothing listed"
        )
        assertEqual(
            suggestionNames(query: "   ", people: people),
            [],
            "spaces alone still count as empty"
        )
    }

    runSuite("The voice being named is not offered as a suggestion") {
        assertEqual(
            suggestionNames(query: "Dan", people: people, excluding: kimID),
            ["Daniel Park"],
            "Daniel Kim is this voice, so only Daniel Park remains"
        )
    }

    runSuite("Unfocused fields hide typing suggestions") {
        assertEqual(
            suggestionNames(query: "Dan", people: people, isFocused: false),
            [],
            "the list is only for the field that has the keyboard"
        )
    }

    runSuite("Dismissed typing suggestions stay hidden") {
        assertEqual(
            suggestionNames(query: "Dan", people: people, listDismissed: true),
            [],
            "Escape hides the list until the next edit"
        )
    }

    runSuite("A prefilled current name is not treated as a search") {
        assertEqual(
            suggestionNames(
                query: "Daniel Kim",
                people: people,
                untouchedPrefill: "Daniel Kim"
            ),
            [],
            "opening a picker on the current label is not a query"
        )
        assertEqual(
            suggestionNames(
                query: "Dan",
                people: people,
                untouchedPrefill: "Daniel Kim"
            ),
            ["Daniel Kim", "Daniel Park"],
            "once the person types, the list filters as usual"
        )
    }

    runSuite("Typing suggestions stop at five people") {
        let crowd = (1...6).map { index in
            SpeakerNameChoice(
                id: UUID(),
                displayName: "Alex \(index)",
                callCount: 7 - index
            )
        }
        let shown = suggestionNames(query: "Alex", people: crowd)
        assertEqual(shown.count, 5, "the popup under the box caps at five")
        assertEqual(shown.first, "Alex 1", "higher call counts still rank first")
        assertFalse(shown.contains("Alex 6"), "the sixth match stays off the list")
    }

    runSuite("Nothing lists when the query matches nobody") {
        assertEqual(
            suggestionNames(query: "zzz", people: people),
            [],
            "no loose match, no list"
        )
    }

    runSuite("Typing suggestions ignore case and accents") {
        let jose = SpeakerNameChoice(id: UUID(), displayName: "José García", callCount: 2)
        assertEqual(
            suggestionNames(query: "jose", people: [jose, kim]),
            ["José García"],
            "case and accents do not hide a prefix match"
        )
        assertEqual(
            suggestionNames(query: "GARCÍA", people: [jose]),
            ["José García"],
            "an accented last name still matches its unaccented typing"
        )
    }

    runSuite("Arrow keys move the highlight through the visible suggestions") {
        typealias Policy = SpeakerNameTypingSuggestionPolicy
        assertEqual(
            Policy.movedHighlight(from: nil, by: 1, count: 2),
            0,
            "down from no highlight lands on the first row"
        )
        assertEqual(
            Policy.movedHighlight(from: 0, by: 1, count: 2),
            1,
            "down moves to the next row"
        )
        assertEqual(
            Policy.movedHighlight(from: 1, by: 1, count: 2),
            1,
            "down past the end stays on the last row"
        )
        assertEqual(
            Policy.movedHighlight(from: nil, by: -1, count: 2),
            1,
            "up from no highlight lands on the last row"
        )
        assertEqual(
            Policy.movedHighlight(from: 1, by: -1, count: 2),
            0,
            "up moves to the previous row"
        )
        assertEqual(
            Policy.movedHighlight(from: 0, by: -1, count: 2),
            0,
            "up past the start stays on the first row"
        )
        assertNil(
            Policy.movedHighlight(from: nil, by: 1, count: 0),
            "arrows do nothing when the list is empty"
        )
    }

    runSuite("Return with a highlight picks that suggestion; Return without one submits the typed name") {
        typealias Policy = SpeakerNameTypingSuggestionPolicy
        assertEqual(
            Policy.returnDecision(highlighted: 1, suggestionCount: 2),
            .selectIndex(1),
            "Return keeps the row the arrows landed on"
        )
        assertEqual(
            Policy.returnDecision(highlighted: nil, suggestionCount: 2),
            .submitTyped,
            "Return without arrows leaves the typed name alone"
        )
        assertEqual(
            Policy.returnDecision(highlighted: 0, suggestionCount: 0),
            .submitTyped,
            "a stale highlight does not pick from an empty list"
        )
        assertEqual(
            Policy.returnDecision(highlighted: nil, suggestionCount: 2, hoverHighlight: 1),
            .submitTyped,
            "a pointer hover is not a Return target"
        )
        assertEqual(
            Policy.returnDecision(highlighted: 0, suggestionCount: 2, hoverHighlight: 1),
            .selectIndex(0),
            "Return keeps the arrow highlight even when another row is hovered"
        )
    }

    runSuite("An exact name ranks ahead of a longer prefix match") {
        let ann = SpeakerNameChoice(id: UUID(), displayName: "Ann", callCount: 1)
        let anna = SpeakerNameChoice(id: UUID(), displayName: "Anna", callCount: 12)
        assertEqual(
            suggestionNames(query: "Ann", people: [anna, ann]),
            ["Ann", "Anna"],
            "Ann is an exact match, so it stays above Anna even when Anna has more calls"
        )
    }

    runSuite("A hyphenated given name ranks as its own word") {
        let anneMarie = SpeakerNameChoice(id: UUID(), displayName: "Anne-Marie", callCount: 1)
        let rosemarie = SpeakerNameChoice(id: UUID(), displayName: "Rosemarie", callCount: 12)
        assertEqual(
            suggestionNames(query: "Marie", people: [rosemarie, anneMarie]),
            ["Anne-Marie", "Rosemarie"],
            "Marie in Anne-Marie is a word start, ahead of a contains match with more calls"
        )
        assertEqual(
            suggestionNames(query: "Anne", people: [anneMarie, kim]),
            ["Anne-Marie"],
            "the first half of a hyphenated name is still a prefix"
        )
    }

    runSuite("Cyrillic and transliterated names stay distinct") {
        let cyrillic = SpeakerNameChoice(id: UUID(), displayName: "Андрій", callCount: 3)
        let latin = SpeakerNameChoice(id: UUID(), displayName: "Andrii", callCount: 3)
        let people = [cyrillic, latin]
        assertEqual(
            suggestionNames(query: "Андрій", people: people),
            ["Андрій"],
            "the native spelling is an exact match for itself"
        )
        assertEqual(
            suggestionNames(query: "Andrii", people: people),
            ["Andrii"],
            "the transliteration is an exact match for itself"
        )
        assertEqual(
            suggestionNames(query: "Андр", people: people),
            ["Андрій"],
            "a Cyrillic prefix does not pick up the Latin spelling"
        )
        assertEqual(
            suggestionNames(query: "Andr", people: people),
            ["Andrii"],
            "a Latin prefix does not pick up the Cyrillic spelling"
        )
    }

    runSuite("Browsing everyone lists the full sorted directory, not the typing cap") {
        let crowd = (1...6).map { index in
            SpeakerNameChoice(
                id: UUID(),
                displayName: "Alex \(index)",
                callCount: 7 - index
            )
        }
        let own = crowd[0]
        assertEqual(
            suggestionNames(query: "", people: crowd, isBrowsingAll: true),
            ["Alex 1", "Alex 2", "Alex 3", "Alex 4", "Alex 5", "Alex 6"],
            "the chevron shows every saved person, highest call count first"
        )
        assertEqual(
            suggestionNames(
                query: "zzz",
                people: crowd,
                excluding: own.id,
                isBrowsingAll: true
            ),
            ["Alex 2", "Alex 3", "Alex 4", "Alex 5", "Alex 6"],
            "browsing still hides this voice and ignores the typed filter"
        )
        assertEqual(
            suggestionNames(
                query: "Alex 1",
                people: crowd,
                untouchedPrefill: "Alex 1",
                isBrowsingAll: true
            ).count,
            6,
            "the chevron is allowed to open on the unused current name"
        )
        assertEqual(
            suggestionNames(query: "", people: crowd, isFocused: false, isBrowsingAll: true),
            [],
            "an unfocused field does not leave the directory hanging open"
        )
    }

    runSuite("Escape hides the list, then cancels if the caller asked") {
        typealias Policy = SpeakerNameTypingSuggestionPolicy
        assertEqual(
            Policy.escapeDecision(suggestionsVisible: true, hasCancelHandler: true),
            .hideSuggestions,
            "the first Escape only puts the list away"
        )
        assertEqual(
            Policy.escapeDecision(suggestionsVisible: false, hasCancelHandler: true),
            .cancel,
            "Escape with no list dismisses the naming field"
        )
        assertEqual(
            Policy.escapeDecision(suggestionsVisible: false, hasCancelHandler: false),
            .ignore,
            "Escape with no cancel handler leaves the field alone"
        )
    }
}

private func suggestionNames(
    query: String,
    people: [SpeakerNameChoice],
    isFocused: Bool = true,
    excluding excludedID: UUID? = nil,
    listDismissed: Bool = false,
    untouchedPrefill: String? = nil,
    isBrowsingAll: Bool = false
) -> [String] {
    SpeakerNameTypingSuggestionPolicy.suggestions(
        query: query,
        isFocused: isFocused,
        people: people,
        excluding: excludedID,
        listDismissed: listDismissed,
        untouchedPrefill: untouchedPrefill,
        isBrowsingAll: isBrowsingAll
    ).map(\.person.displayName)
}

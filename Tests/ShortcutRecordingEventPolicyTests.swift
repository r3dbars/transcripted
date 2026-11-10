import Foundation

func testShortcutRecordingEventPolicy() {
    let tokens = [NSObject(), NSObject()]
    withExtendedLifetime(tokens) {
        let owner = ObjectIdentifier(tokens[0])
        let foreign = ObjectIdentifier(tokens[1])

        runSuite("A visible shortcut owner records only its own event identity") {
            assertEqual(ShortcutRecordingEventPolicy.action(
                owner: owner, eventWindow: owner, ownerVisible: true
            ), .record)
            assertEqual(ShortcutRecordingEventPolicy.action(
                owner: foreign, eventWindow: foreign, ownerVisible: true
            ), .record, "ownership follows the supplied identity rather than a particular token")
        }

        runSuite("Foreign and missing event windows pass and clear pending shortcut modifiers") {
            assertEqual(ShortcutRecordingEventPolicy.action(
                owner: owner, eventWindow: foreign, ownerVisible: true
            ), .passAndClearPending)
            assertEqual(ShortcutRecordingEventPolicy.action(
                owner: owner, eventWindow: nil, ownerVisible: true
            ), .passAndClearPending)
            assertEqual(ShortcutRecordingEventPolicy.action(
                owner: foreign, eventWindow: owner, ownerVisible: true
            ), .passAndClearPending, "equal visibility does not make different identities match")
        }

        runSuite("An absent shortcut owner stops recording and passes every event") {
            for visible in [false, true] {
                for event in [nil, owner, foreign] as [ObjectIdentifier?] {
                    assertEqual(ShortcutRecordingEventPolicy.action(
                        owner: nil, eventWindow: event, ownerVisible: visible
                    ), .stopAndPass, "an event identity or visible flag cannot replace a missing owner")
                }
            }
        }

        runSuite("A closed shortcut owner stops recording even when the event identity matches") {
            for event in [nil, owner, foreign] as [ObjectIdentifier?] {
                assertEqual(ShortcutRecordingEventPolicy.action(
                    owner: owner, eventWindow: event, ownerVisible: false
                ), .stopAndPass, "closed-owner admission takes precedence over event matching")
            }
        }

        runSuite("A visible matching owner can be admitted after the closed-owner decision") {
            assertEqual(ShortcutRecordingEventPolicy.action(
                owner: owner, eventWindow: owner, ownerVisible: false
            ), .stopAndPass)
            assertEqual(ShortcutRecordingEventPolicy.action(
                owner: owner, eventWindow: owner, ownerVisible: true
            ), .record, "the pure decision uses the current visibility input")
        }
    }
}

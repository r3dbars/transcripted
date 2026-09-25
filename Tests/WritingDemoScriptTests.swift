import Foundation

// Behavioral coverage for the intro's autocomplete demo script
// (Sources/UI/Settings/Writing/WritingDemoScript.swift).

func testWritingDemoScript() {
    typealias Script = WritingDemoScript

    runSuite("Writing demo cycles a Slack reply, an email and a note") {
        assertEqual(Script.scenes.map(\.app), ["Slack", "Mail", "Notes"])
        for scene in Script.scenes {
            let words = scene.suggestion.split(separator: " ").count
            assertTrue(words <= 8 && scene.suggestion.count <= 80, "\(scene.app): within Gemma's 8-word / 80-character cap")
            assertTrue(scene.typed.hasSuffix(" "), "\(scene.app): the suggestion starts at a word boundary")
        }
    }

    runSuite("Writing demo: Tab takes one word and its trailing space") {
        assertEqual(Script.wordSteps(in: "take a look after lunch"), ["take ", "a ", "look ", "after ", "lunch"])
        assertEqual(Script.wordSteps(in: "done"), ["done"])
        assertEqual(Script.wordSteps(in: ""), [])
    }

    runSuite("Writing demo frames type, suggest, accept word by word, then count") {
        for index in Script.scenes.indices {
            let scene = Script.scenes[index]
            let frames = Script.frames(for: index)
            let typing = frames.filter { $0.phase == .typing }
            assertEqual(typing.count, scene.typed.count, "\(scene.app): one frame per typed character")
            assertEqual(typing.last?.fieldText, scene.typed)
            assertTrue(typing.allSatisfy { $0.ghostText.isEmpty && !$0.tabPressed }, "no suggestion while typing")

            let suggesting = frames.first { $0.phase == .suggesting }
            assertEqual(suggesting?.ghostText, scene.suggestion, "\(scene.app): the whole suggestion shows before Tab")
            assertEqual(suggesting?.fieldText, scene.typed)

            let accepting = frames.filter { $0.phase == .accepting }
            assertEqual(accepting.count, Script.wordSteps(in: scene.suggestion).count, "\(scene.app): one Tab per word")
            assertTrue(accepting.allSatisfy(\.tabPressed))
            assertEqual(accepting.last?.ghostText, "")
            for frame in accepting {
                assertEqual(frame.fieldText + frame.ghostText, scene.typed + scene.suggestion, "accepted plus remaining is the whole line")
            }

            let saved = frames.last
            assertEqual(saved?.phase, .saved)
            assertEqual(saved?.fieldText, scene.typed + scene.suggestion)
            assertEqual(saved?.keystrokesSaved, scene.suggestion.count, "keystrokes saved counts accepted characters")
            assertTrue(frames.dropLast().allSatisfy { $0.keystrokesSaved == nil }, "the count shows only at the end")
            assertTrue(frames.allSatisfy { $0.duration > 0 }, "every frame holds for a while")
        }
        assertEqual(
            Script.allFrames.count,
            Script.scenes.indices.reduce(0) { $0 + Script.frames(for: $1).count },
            "one cycle is every scene in order"
        )
        assertEqual(Script.allFrames.first?.sceneIndex, 0)
        assertEqual(Script.allFrames.last?.sceneIndex, Script.scenes.count - 1)
    }

    runSuite("Writing demo holds still on one frame under Reduce Motion") {
        let still = Script.stillFrame
        assertEqual(still.sceneIndex, 0)
        assertEqual(still.phase, .suggesting)
        assertEqual(still.ghostText, Script.scenes[0].suggestion, "the still frame shows the suggestion")
        assertFalse(still.tabPressed)
        assertEqual(Script.keystrokesSavedText(23), "23 keystrokes saved")
        assertEqual(Script.keystrokesSavedText(1), "1 keystroke saved")
    }
}
